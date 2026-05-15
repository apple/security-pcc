// Copyright © 2025 Apple Inc. All Rights Reserved.

// APPLE INC.
// PRIVATE CLOUD COMPUTE SOURCE CODE INTERNAL USE LICENSE AGREEMENT
// PLEASE READ THE FOLLOWING PRIVATE CLOUD COMPUTE SOURCE CODE INTERNAL USE LICENSE AGREEMENT (“AGREEMENT”) CAREFULLY BEFORE DOWNLOADING OR USING THE APPLE SOFTWARE ACCOMPANYING THIS AGREEMENT(AS DEFINED BELOW). BY DOWNLOADING OR USING THE APPLE SOFTWARE, YOU ARE AGREEING TO BE BOUND BY THE TERMS OF THIS AGREEMENT. IF YOU DO NOT AGREE TO THE TERMS OF THIS AGREEMENT, DO NOT DOWNLOAD OR USE THE APPLE SOFTWARE. THESE TERMS AND CONDITIONS CONSTITUTE A LEGAL AGREEMENT BETWEEN YOU AND APPLE.
// IMPORTANT NOTE: BY DOWNLOADING OR USING THE APPLE SOFTWARE, YOU ARE AGREEING ON YOUR OWN BEHALF AND/OR ON BEHALF OF YOUR COMPANY OR ORGANIZATION TO THE TERMS OF THIS AGREEMENT.
// 1. As used in this Agreement, the term “Apple Software” collectively means and includes all of the Apple Private Cloud Compute materials provided by Apple here, including but not limited to the Apple Private Cloud Compute software, tools, data, files, frameworks, libraries, documentation, logs and other Apple-created materials. In consideration for your agreement to abide by the following terms, conditioned upon your compliance with these terms and subject to these terms, Apple grants you, for a period of ninety (90) days from the date you download the Apple Software, a limited, non-exclusive, non-sublicensable license under Apple’s copyrights in the Apple Software to download, install, compile and run the Apple Software internally within your organization only on a single Apple-branded computer you own or control, for the sole purpose of verifying the security and privacy characteristics of Apple Private Cloud Compute. This Agreement does not allow the Apple Software to exist on more than one Apple-branded computer at a time, and you may not distribute or make the Apple Software available over a network where it could be used by multiple devices at the same time. You may not, directly or indirectly, redistribute the Apple Software or any portions thereof. The Apple Software is only licensed and intended for use as expressly stated above and may not be used for other purposes or in other contexts without Apple's prior written permission. Except as expressly stated in this notice, no other rights or licenses, express or implied, are granted by Apple herein.
// 2. The Apple Software is provided by Apple on an "AS IS" basis. APPLE MAKES NO WARRANTIES, EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION THE IMPLIED WARRANTIES OF NON-INFRINGEMENT, MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE, REGARDING THE APPLE SOFTWARE OR ITS USE AND OPERATION ALONE OR IN COMBINATION WITH YOUR PRODUCTS, SYSTEMS, OR SERVICES. APPLE DOES NOT WARRANT THAT THE APPLE SOFTWARE WILL MEET YOUR REQUIREMENTS, THAT THE OPERATION OF THE APPLE SOFTWARE WILL BE UNINTERRUPTED OR ERROR-FREE, THAT DEFECTS IN THE APPLE SOFTWARE WILL BE CORRECTED, OR THAT THE APPLE SOFTWARE WILL BE COMPATIBLE WITH FUTURE APPLE PRODUCTS, SOFTWARE OR SERVICES. NO ORAL OR WRITTEN INFORMATION OR ADVICE GIVEN BY APPLE OR AN APPLE AUTHORIZED REPRESENTATIVE WILL CREATE A WARRANTY.
// 3. IN NO EVENT SHALL APPLE BE LIABLE FOR ANY DIRECT, SPECIAL, INDIRECT, INCIDENTAL OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) ARISING IN ANY WAY OUT OF THE USE, REPRODUCTION, COMPILATION OR OPERATION OF THE APPLE SOFTWARE, HOWEVER CAUSED AND WHETHER UNDER THEORY OF CONTRACT, TORT (INCLUDING NEGLIGENCE), STRICT LIABILITY OR OTHERWISE, EVEN IF APPLE HAS BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
// 4. This Agreement is effective until terminated. Your rights under this Agreement will terminate automatically without notice from Apple if you fail to comply with any term(s) of this Agreement. Upon termination, you agree to cease all use of the Apple Software and destroy all copies, full or partial, of the Apple Software. This Agreement constitutes the entire understanding of the parties with respect to the subject matter contained herein, and supersedes all prior negotiations, representations, or understandings, written or oral. This Agreement will be governed and construed in accordance with the laws of the State of California, without regard to its choice of law rules.
// You may report security issues about Apple products to product-security@apple.com, as described here: https://www.apple.com/support/security/. Non-security bugs and enhancement requests can be made via https://bugreport.apple.com as described here: https://developer.apple.com/bug-reporting/
// EA1937
// 10/02/2024

//
//  OTLPGRPCClient.swift
//  CloudMetrics
//
//  Created by Oliver Chick (ORAC) on 23/12/2024.
//

private import CloudMetricsConstants
package import CloudMetricsHealthFramework
private import CloudMetricsUtils
import Foundation
internal import GRPC
private import Logging
private import NIO
private import NIOTransportServices
private import NIOHPACK
private import OpenTelemetryProtocolExporterCommon
private import OpenTelemetryProtocolExporterGrpc
@preconcurrency package import OpenTelemetrySdk
private import os

/// GRPC client for exporting OTLP metrics to a gRPC collector.
///
/// This client endeavours to conform to the [OTLP spec](https://github.com/open-telemetry/opentelemetry-proto/blob/2bd940b2b77c1ab57c27166af21384906da7bb2b/docs/specification.md).
///
/// This client receives a stream of metric data for different destinations.
/// Each time that stream is written to, this client will then send the data to an OTLP backend.
package final class OTLPGRPCClient: Sendable {
    private typealias UnderlyingClient = Opentelemetry_Proto_Collector_Metrics_V1_MetricsServiceAsyncClient
    private typealias Response = Opentelemetry_Proto_Collector_Metrics_V1_ExportMetricsServiceResponse

    private enum State {
        case shutdown
        case running(CloudMetricsUtils.Promise<Void, Error>)
    }

    /// Stream that we receive metric data on, that we will then send over gRPC to a collector
    private let metricDataStream: AsyncStream<CollectedMetricsData>
    /// Provides us with updates when we need to reload certs
    private let tlsConfigStream: NICCertExpiryHandler
    private let configuration: Configuration
    private let metricsFilter: MetricsFilter
    /// Continuation that we can use to report on our health
    ///
    /// We use a continuation here to avoid taking a dependency on another component.
    private let healthContinuation: AsyncStream<CloudMetricsHealthState>.Continuation
    private let state: OSAllocatedUnfairLock<State> = .init(initialState: .shutdown)

    /// Underlying autogenerated gRPC client stub.
    ///
    /// We put a lock around this as we need to reseat it when the TLS certs roll.
    private let underlyingGRPCClient: OSAllocatedUnfairLock<UnderlyingClient>

    /// How many sets of metric data we've tried to publish.
    ///
    /// - Note: This is not incremented on retries.
    private let publishCount: OSAllocatedUnfairLock<[String: Int]> = .init(initialState: [:])

    /// Number of times we've failed to publish, even after retries.
    private let metricsPublishFailure: OSAllocatedUnfairLock<Int> = .init(initialState: 0)

    /// How many times we've rolled over certs.
    private let certRolloverCount: OSAllocatedUnfairLock<Int> = .init(initialState: 0)

    /// os-style logger
    private let logger = Logger(subsystem: kCloudMetricsLoggingSubsystem, category: "OTLPGRPCClient")

    /// SPM-style logger, just for passing to grpc-swift.
    private let requestLogger = Logging.Logger(label: "OLTPGRPC")
    
    /// SPM-style logger, for passing to ClientConnection.
    private let clientConnectionLogger = Logging.Logger(label: "ClientConnection")

    /// Number of times that we've rolled over our certs.
    package var numberCertRollovers: Int { self.certRolloverCount.withLock { $0 } }
    
    /// updates to process
    private let updatesToProcess: OSAllocatedUnfairLock<[String: CollectedMetricsData]> = .init(initialState: [:])

    package init(
        metricDataStream: AsyncStream<CollectedMetricsData>,
        tlsConfigStream: NICCertExpiryHandler,
        configuration: Configuration,
        healthContinuation: AsyncStream<CloudMetricsHealthState>.Continuation,
        metricsFilter: MetricsFilter
    ) {
        self.metricDataStream = metricDataStream
        self.tlsConfigStream = tlsConfigStream
        self.configuration = configuration
        self.healthContinuation = healthContinuation
        self.metricsFilter = metricsFilter

        let tlsConfig: GRPCTLSConfiguration?
        if configuration.openTelemetryEndpoint.mtls {
            switch configuration.keySource {
            case .keychain:
                tlsConfig = try? .loadTLSCerts()
            case .localCerts(let certs):
                tlsConfig = .makeClientConfigurationBackedByNIOSSL(
                    certificateChain: certs.mtlsCertificateChain.map { .certificate($0) },
                    privateKey: .privateKey(certs.mtlsPrivateKey),
                    trustRoots: certs.mtlsTrustRoots
                )
            case .none:
                tlsConfig = nil
            }
        } else {
            self.logger.log("mtls disabled, not loading certificates.")
            tlsConfig = nil
        }

        let client = Self.makeUnderlyingGRPCClient(
            configuration: configuration,
            tlsConfig: tlsConfig,
            logger: self.clientConnectionLogger
        )

        self.underlyingGRPCClient = .init(initialState: client)
    }

    private static func makeUnderlyingGRPCClient(
        configuration: Configuration,
        tlsConfig: GRPCTLSConfiguration?,
        logger: Logging.Logger
    ) -> UnderlyingClient {
        var clientConfiguration = ClientConnection.Configuration.default(
            target: .hostAndPort(
                configuration.openTelemetryEndpoint.hostname,
                configuration.openTelemetryEndpoint.port
            ),
            eventLoopGroup: .singletonNIOTSEventLoopGroup,
        )
        clientConfiguration.tlsConfiguration = tlsConfig
        clientConfiguration.backgroundActivityLogger = logger
        clientConfiguration.connectivityStateDelegate = GRPCConnectionMonitor()

        let channel = ClientConnection(configuration: clientConfiguration)
        return .init(channel: channel)
    }

    /// - Parameter testCertRollover: when true the client will reload certificates when narrative certs rollover
    /// even when not configured to source keys from the keychain.
    package func run(testCertRollover: Bool = false) async throws {
        let promise = try self.state.withLock { state in
            switch state {
            case .running:
                self.logger.error("OTLPGRPCClient already running")
                throw CloudMetricsInternalError.invalidStateTransition
            case .shutdown:
                let promise: CloudMetricsUtils.Promise<Void, Error> = .init()
                state = .running(promise)
                return promise
            }
        }
        defer {
            self.state.withLock { $0 = .shutdown }
            logger.log("OTLPGRPCClient shutdown")
        }
        self.logger.log("OTLPGRPCClient starting")
        try await withThrowingTaskGroup(of: Void.self) { group in
            if testCertRollover || (
                self.configuration.keySource == .keychain &&
                    self.configuration.openTelemetryEndpoint.mtls
            ) {
                // Cert rollover Task
                group.addTask {
                    for await newTLSConfig in self.tlsConfigStream {
                        self.logger.log("RenewCertificate called")

                        let newClient = Self.makeUnderlyingGRPCClient(
                            configuration: self.configuration,
                            tlsConfig: newTLSConfig,
                            logger: self.clientConnectionLogger
                        )
                        self.underlyingGRPCClient.withLock { oldClient in
                            let promise = NIOTSEventLoopGroup.singleton.next().makePromise(of: Void.self)
                            promise.futureResult.whenSuccess {
                                self.logger.log("Closed down old gRPC client")
                            }
                            promise.futureResult.whenFailure {
                                self.logger.error("Error closing down gRPC client. error=\($0, privacy: .public)")
                            }
                            oldClient.channel.closeGracefully(deadline: .distantFuture, promise: promise)
                            oldClient = newClient
                        }
                        let newCount = self.certRolloverCount.withLock {
                            $0 += 1
                            return $0
                        }
                        self.logger
                            .log(
                                "Successfully renewed the certificate. certificate_number=\(newCount, privacy: .public)"
                            )
                    }
                }
            }
            // Task to listen to the stream of incoming metric data and then
            // create a gRPC request for each.
            group.addTask {
                for try await update in self.metricDataStream {
                    do {
                        try await self.export(metricStreamUpdate: update)
                        self.metricsPublishFailure.withLock { $0 = 0 }
                        self.healthContinuation.yield(.healthy)
                    } catch {
                        let unhealthy = self.metricsPublishFailure.withLock { failures in
                            failures += 1
                            return failures >= self.configuration.publishFailureThreshold
                        }
                        if unhealthy {
                            self.healthContinuation.yield(.unhealthy)
                        }
                    }
                }
            }
            group.addTask {
                // Wait for the shutdown
                self.logger.log("OTLPGRPCClient running")
                do {
                    try await CloudMetricsUtils.Future(promise).valueWithCancellation
                    self.logger.log("OTLPGRPCClient shutting down")
                    let promise = NIOTSEventLoopGroup.singleton.next().makePromise(of: Void.self)
                    self.underlyingGRPCClient.withLock { underlyingGRPCClient in
                        underlyingGRPCClient.channel.closeGracefully(deadline: .distantFuture, promise: promise)
                    }
                    do {
                        try await promise.futureResult.get()
                        self.logger.log("gRPC channel shutdown")
                    } catch {
                        self.logger.log("""
                        Error shutting down gRPC client. \
                        error=\(String(reportable: error), privacy: .public)
                        """)
                    }
                } catch {
                    promise.fail(with: error)
                    self.logger.log("Force shutting down gRPC channel")
                    _ = self.underlyingGRPCClient.withLock { $0.channel.close() }
                }
            }
            defer {
                logger.log("Cancelling child tasks")
                group.cancelAll()
                logger.log("Cancelled child tasks")
            }
            try await group.next()
        }
    }

    /// Sends the metric data for a destination to an OTLP collector.
    package func export(metricStreamUpdate: CollectedMetricsData) async throws {
        let metrics = metricStreamUpdate.metrics
        let destination = metricStreamUpdate.destination
        let clientName = metricStreamUpdate.client

        let publishCount = self.publishCount.withLock { counts in
            var updatedCount = 1
            if let count = counts[clientName] {
                updatedCount = count + 1
            }
            counts[clientName] = updatedCount
            return updatedCount
        }

        let metricsToPublish = metrics.filter { metric in
            self.metricsFilter.shouldPublish(metricName: metric.name, destination: destination)
        }
        let filteredOutCount = metrics.count - metricsToPublish.count
        let exportRequest = Opentelemetry_Proto_Collector_Metrics_V1_ExportMetricsServiceRequest.with {
            $0.resourceMetrics = MetricsAdapter.toProtoResourceMetrics(metricData: metricsToPublish)
        }

        let headers = HPACKHeaders([
            ("X-MOSAIC-WORKSPACE", destination.workspace ?? ""),
            ("X-MOSAIC-NAMESPACE", destination.namespace ?? ""),
        ])

        // Calculate the deadline for us to finish exporting by. Remember that this is the sum of
        // all of the retries, so we can't just take the timeout from the config and plonk it straight
        // into the gRPC timeout.
        let deadline: NIODeadline
        if let timeout = configuration.openTelemetry.timeout {
            deadline = NIODeadline.now() + TimeAmount(timeout)
        } else {
            deadline = NIODeadline.distantFuture
        }

        var attemptCount = 0
        repeat {
            attemptCount += 1
            let requestID = UUID()
            let size = exportRequest.textFormatString().data(using: .utf8)?.count
            self.logger.log("""
            Publish started. \
            client=\(clientName, privacy: .public) \
            publish_count=\(publishCount, privacy: .public) \
            attempt=\(attemptCount, privacy: .public) \
            request_id=\(requestID, privacy: .public) \
            num_metrics_to_publish=\(metricsToPublish.count) \
            num_metrics_filtered_out=\(filteredOutCount, privacy: .public),
            size_bytes=\(size.map({String(describing: $0)}) ?? "<unknown>", privacy: .public))
            """)
            let callOptions = CallOptions(
                customMetadata: headers,
                timeLimit: .deadline(deadline),
                requestIDHeader: requestID.uuidString,
                logger: self.requestLogger
            )

            let client = self.underlyingGRPCClient.withLock { $0 }
            let response: Response
            do {
                response = try await client.export(exportRequest, callOptions: callOptions)
            } catch let status as GRPCStatus {
                let retryable = status.code.isOTLPRetryable
                logger.error("""
                gRPC error. \
                grpc_error_code=\(status.code, privacy: .public) \
                grpc_status_message=\(status.message ?? "<none>", privacy: .private) \
                error_retryable=\(retryable, privacy: .public) \
                publish_count=\(publishCount, privacy: .public) \
                request_id=\(requestID, privacy: .public)
                """)
                guard retryable else {
                    throw status
                }
                // """
                // When retrying, the client SHOULD implement
                // an exponential backoff strategy.
                // """
                let backoff = min(
                    configuration.openTelemetry.maxBackoff,
                    configuration.openTelemetry.defaultBackoff * (2 ^ attemptCount)
                )
                guard deadline > .now() + .init(backoff) else {
                    logger.log("""
                    Request timed out. \
                    request_id=\(requestID, privacy: .public)
                    """)
                    throw status
                }
                logger.log("""
                Waiting before reattempting request \
                backoff=\(backoff) \
                publish_count=\(publishCount, privacy: .public) \
                request_id=\(requestID, privacy: .public)
                """)
                do {
                    try await Task.sleep(for: backoff)
                } catch {
                    logger.error("""
                    Error thrown whilst waiting to publish. \
                    error=\(String(reportable: error), privacy: .public) \
                    publish_count=\(publishCount, privacy: .public) \
                    request_id=\(requestID, privacy: .public)
                    """)
                    throw status
                }
                continue
            } catch {
                self.logger.error("""
                Publish failed. \
                publish_count=\(publishCount, privacy: .public)
                error=\(String(reportable: error), privacy: .public) \
                request_id=\(requestID, privacy: .public)
                """)
                throw error
            }
            self.logger.log("""
            Publish success. \
            publish_count=\(publishCount, privacy: .public)
            attempt=\(attemptCount, privacy: .public) \
            request_id=\(requestID, privacy: .public)
            """)
            try self.handle(response: response)
            return
        } while true
    }

    // Comments in function below are quotes from the OTLP spec.
    private func handle(response: Response) throws {
        // """
        // On success, the server response MUST be a
        // Export<signal>ServiceResponse message
        // ( ExportTraceServiceResponse for traces,
        // ExportMetricsServiceResponse for
        // metrics
        // """
        guard response.hasPartialSuccess else {
            self.logger.log("Publish completed")
            return
        }

        // """
        // Servers MAY also use the partial_success
        // field to convey warnings/suggestions to
        // clients even when the server fully accepts the
        // request. In such cases, the
        // rejected_<signal> field MUST have a value
        // of 0 , and the error_message field MUST
        // be non-empty.
        // """
        let rejectedDataPoints = Int(response.partialSuccess.rejectedDataPoints)
        guard rejectedDataPoints > 0 else {
            self.logger.warning("""
            Publish accepted data but sent warning. \
            warning=\(response.partialSuccess.errorMessage, privacy: .public)
            """)
            return
        }

        // """
        // Additionally, the server MUST initialize the
        // partial_success field
        // ( ExportTracePartialSuccess message for
        // traces, ExportMetricsPartialSuccess
        // message for metrics,
        // ExportLogsPartialSuccess message for
        // logs and ExportProfilesPartialSuccess
        // for profiles), and it MUST set the respective
        // rejected_spans , rejected_data_points ,
        // rejected_log_records or
        // rejected_profiles field with the number of
        // spans/data points/log records/profiles it
        // rejected.
        // """

        self.logger.error("""
        Publish rejected data points \
        rejected_data_points=\(rejectedDataPoints) \
        error=\(response.partialSuccess.errorMessage, privacy: .public)
        """)
        throw CloudMetricsInternalError.serverRejectedDataPoints(rejectedDataPoints)
    }

    internal func shutdown() async throws {
        try self.state.withLock { state in
            switch state {
            case .shutdown:
                self.logger.error("OTLPGRPCClient already shutdown")
                throw CloudMetricsInternalError.invalidStateTransition
            case .running(let promise): promise.succeed()
            }
        }
    }
}

extension GRPCStatus.Code {
    var isOTLPRetryable: Bool {
        // """
        // The client SHOULD interpret gRPC
        // status codes as retryable or not-retryable
        // according to the following table:
        // """
        switch self {
        case .cancelled, .deadlineExceeded, .aborted, .outOfRange,
             .unavailable, .dataLoss: return true
        case .unknown, .invalidArgument, .notFound, .alreadyExists,
             .permissionDenied, .unauthenticated, .failedPrecondition,
             .unimplemented, .internalError: return false
        // """
        // The client SHOULD interpret
        // RESOURCE_EXHAUSTED code as retryable only
        // if the server signals that the recovery from
        // resource exhaustion is possible. This is
        // signaled by the server by returning a status
        // containing RetryInfo.
        // """
        //
        // N.b., we haven't yet implemented this
        case .resourceExhausted: return false
        default: return false
        }
    }
}
