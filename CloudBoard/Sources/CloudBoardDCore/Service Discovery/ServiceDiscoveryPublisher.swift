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

import CloudBoardCommon
import CloudBoardController
import CloudBoardLogging
import CloudBoardMetrics
import CloudBoardPlatformUtilities
import Foundation
import GRPCClientConfiguration
import InternalSwiftProtobuf
import Logging
import NIOCore
import os

/// namespace for types used to interoperate between ``ServiceDiscoveryPublisher`` and
/// ``ServiceDiscoveryServiceProtocol`` implementations
enum ServiceDiscovery {
    typealias Client = Com_Apple_Ase_Traffic_Servicediscovery_Api_V1_ServiceRegistrationAsyncClient
    typealias Request = Com_Apple_Ase_Traffic_Servicediscovery_Api_V1_RegistrationRequest
    typealias Response = Com_Apple_Ase_Traffic_Servicediscovery_Api_V1_RegistrationResponse

    struct ServiceDetails: CustomStringConvertible {
        var workloadType: ServiceDiscoveryWorkloadConfig.WorkloadType
        var workloadTags: [String: RoutingTagValue]
        var retractionPromise: Promise<Void, Never>
        var deregistrationCompletedPromise: Promise<Void, Never>

        var description: String {
            "ServiceDetails: type=\(self.workloadType) tags=\(self.workloadTags)"
        }
    }

    struct Locality {
        var region: String
        var zone: String?

        static let qa = Locality(region: "QA", zone: "default")
    }

    struct ServiceUpdate {
        var name: String
        var details: ServiceDetails
    }

    /// Abstraction on the ``GRPCAsyncBidirectionalStreamingCall<Request, Response>``
    struct Announcement: Sendable {
        typealias ResponseStream = AsyncSequence<Response, Swift.Error> & Sendable
        let responseStream: any ResponseStream
        let send: @Sendable (Request) async throws -> Void
        let finish: @Sendable () -> Void
    }
}

final class ServiceDiscoveryPublisher: ServiceDiscoveryPublisherProtocol, Sendable {
    fileprivate static let logger: os.Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "ServiceDiscovery.Publisher"
    )

    private let serviceDiscoveryComms: any ServiceDiscoveryCommsProtocol
    private let serviceAddress: SocketAddress
    private let locality: ServiceDiscovery.Locality
    private let id: String
    private let lbConfig: [String: String]
    private let backoffConfig: GRPCClientConfiguration.ConnectionBackoff?
    private let metrics: any MetricsSystem
    private let nodeInfo: NodeInfo?
    private let cellID: String?
    private let hotProperties: HotPropertiesController?
    private let registeredServiceCount = OSAllocatedUnfairLock(initialState: 0)
    private let statusMonitor: StatusMonitor
    private let nodeReleaseDigest: String
    private let routingGroupAliases: [String]?
    private let bootID: String?
    private let dependencyHealthChecker: ServiceDependencyHealthChecker?

    private struct State {
        var serviceUpdateContinuation: AsyncStream<ServiceDiscovery.ServiceUpdate>.Continuation?
        var services: [String: ServiceDiscovery.ServiceDetails] = [:]
        var draining: Bool = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        serviceDiscoveryComms: any ServiceDiscoveryCommsProtocol,
        serviceAddress: SocketAddress,
        locality: ServiceDiscovery.Locality,
        lbConfig: [String: String],
        backoffConfig: GRPCClientConfiguration.ConnectionBackoff?,
        statusMonitor: StatusMonitor,
        hotProperties: HotPropertiesController? = nil,
        nodeInfo: NodeInfo? = nil,
        cellID: String? = nil,
        metrics: any MetricsSystem,
        nodeReleaseDigest: String,
        routingGroupAliases: [String]?,
        bootID: String?,
        dependencyHealthChecker: ServiceDependencyHealthChecker? = nil
    ) throws {
        self.serviceDiscoveryComms = serviceDiscoveryComms
        self.serviceAddress = serviceAddress
        self.locality = locality
        self.id = UUID().uuidString
        self.lbConfig = lbConfig
        self.backoffConfig = backoffConfig
        self.hotProperties = hotProperties
        self.nodeInfo = nodeInfo
        self.cellID = cellID
        self.statusMonitor = statusMonitor
        self.metrics = metrics
        self.nodeReleaseDigest = nodeReleaseDigest
        self.routingGroupAliases = routingGroupAliases
        self.bootID = bootID
        self.dependencyHealthChecker = dependencyHealthChecker
    }

    convenience init(
        serviceDiscoveryComms: any ServiceDiscoveryCommsProtocol,
        configuration: CloudBoardDConfiguration.ServiceDiscovery,
        serviceAddress: SocketAddress,
        hotProperties: HotPropertiesController?,
        nodeInfo: NodeInfo?,
        cellID: String?,
        statusMonitor: StatusMonitor,
        metrics: any MetricsSystem,
        nodeReleaseDigest: String,
        routingGroupAliases: [String]?,
        bootID: String?,
        dependencyHealthChecker: ServiceDependencyHealthChecker?
    ) throws {
        try self.init(
            serviceDiscoveryComms: serviceDiscoveryComms,
            serviceAddress: serviceAddress,
            locality: ServiceDiscovery.Locality(
                region: configuration.serviceRegion,
                zone: configuration.serviceZone
            ),
            lbConfig: configuration.lbConfig,
            backoffConfig: configuration.backoffConfig,
            statusMonitor: statusMonitor,
            hotProperties: hotProperties,
            nodeInfo: nodeInfo,
            cellID: cellID,
            metrics: metrics,
            nodeReleaseDigest: nodeReleaseDigest,
            routingGroupAliases: routingGroupAliases,
            bootID: bootID,
            dependencyHealthChecker: dependencyHealthChecker
        )
    }

    func run() async throws {
        if let dependencyHealthChecker = self.dependencyHealthChecker {
            Self.logger.info("Waiting for control plane(BMC-node) to report healthy status")
            try await dependencyHealthChecker.waitForHealthyState()
            Self.logger.info("Control plane(BMC-node) healthy")
        }

        Self.logger.log("Publishing initial service state")
        let serviceUpdateStream: AsyncStream<ServiceDiscovery.ServiceUpdate> =
            self.state.withLock { state in
                let (serviceUpdateStream, serviceUpdateContinuation) =
                    AsyncStream<ServiceDiscovery.ServiceUpdate>.makeStream()
                let alreadyRegisteredServices = state.services

                // Publish all services that were registered before we got to this point.
                for service in alreadyRegisteredServices {
                    Self.logger.log(
                        "Publishing \(service.key, privacy: .public) as current service state with config \(service.value, privacy: .public)"
                    )
                    serviceUpdateContinuation.yield(
                        ServiceDiscovery.ServiceUpdate(
                            name: service.key,
                            details: service.value
                        )
                    )
                }
                state.serviceUpdateContinuation = serviceUpdateContinuation
                return serviceUpdateStream
            }

        try await withLifecycleManagementHandlers(
            label: "serviceDiscoveryPublisher",
            operation: {
                do {
                    try await withThrowingDiscardingTaskGroup { group in
                        for await update in serviceUpdateStream {
                            group.addTaskWithLogging(
                                operation: "serviceDiscoveryPublisher-\(update.name)",
                                sensitiveError: false,
                                logger: Self.logger
                            ) {
                                try await self.publishService(update)
                            }
                        }
                    }
                } catch {
                    await self.clearState(reason: "error")
                    throw error
                }
            },
            onDrain: { await self.drain()
            },
            onPostDrain: { await self.drainComplete() }
        )
    }

    func announceService(name: String, workloadConfig: ServiceDiscoveryWorkloadConfig) {
        let promise: Promise<Void, Never>? = self.state.withLock { state in
            let serviceState = state.services[name]
            if serviceState?.workloadType == workloadConfig.workloadType,
               serviceState?.workloadTags == workloadConfig.workloadTags {
                Self.logger.log("Announcing \(name, privacy: .public) with duplicate config, no change")
                return nil
            }

            if state.draining {
                Self.logger.log(
                    "Not registering \(name, privacy: .public) during drain with config \(workloadConfig, privacy: .public)"
                )
                return nil
            }

            // In either case, we have a change here.
            let details = ServiceDiscovery.ServiceDetails(
                workloadType: workloadConfig.workloadType,
                workloadTags: workloadConfig.workloadTags,
                retractionPromise: .init(),
                deregistrationCompletedPromise: .init()
            )
            state.services[name] = details

            if let serviceState {
                Self.logger.log(
                    "Re-announcing \(name, privacy: .public) with config \(workloadConfig, privacy: .public) replacing \(serviceState.workloadTags, privacy: .public)"
                )

                state.serviceUpdateContinuation?.yield(.init(name: name, details: details))
                return serviceState.retractionPromise
            } else {
                Self.logger.log(
                    "Announcing \(name, privacy: .public) with config \(workloadConfig, privacy: .public)"
                )
                state.serviceUpdateContinuation?.yield(.init(name: name, details: details))
                return nil
            }
        }

        if let promise {
            promise.succeed()
        }
    }

    func retractService(name: String) {
        let promise: Promise<Void, Never>? = self.state.withLock { state in
            state.services.removeValue(forKey: name)?.retractionPromise
        }

        if let promise {
            Self.logger.log("Retracting \(name, privacy: .public)")
            promise.succeed()
        } else {
            Self.logger.warning(
                "Asked to retract service \(name, privacy: .public) but it was not published"
            )
        }
    }

    enum UpdateEndResult: Sendable {
        /// The service was retracted
        case retracted
        /// unexpected error thrown during local processing from which we can't recover
        case terminalError(any Error)
        /// Connection level error which is likely transient. We should try to reconnect.
        case nonTerminalError(any Error)
    }

    enum UpdatesError: Error {
        case unexpectedEndOfRequestStream
        case unexpectedEndOfResponseStream
    }

    private func publishService(_ update: ServiceDiscovery.ServiceUpdate) async throws {
        // Ensure the deregistration promise is always fulfilled when this method exits
        defer {
            update.details.deregistrationCompletedPromise.succeed()
        }

        var connectionBackoff = RetryBackoff(config: self.backoffConfig)
        Self.logger.info(
            "Connection backoff created with configuration: \(connectionBackoff.config, privacy: .public)"
        )
        while true {
            Self.logger.log(
                "ServiceDiscoveryPublisher is (re)beginning publication of \(update.name, privacy: .public)"
            )
            try Task.checkCancellation()
            let announcement = self.serviceDiscoveryComms.announceService(update)

            enum Action {
                case reconnect
                case fail(any Error)
                case complete
            }

            Self.logger.info("Publishing current service state for \(update.name, privacy: .public)")

            let action: Action = await withTaskGroup(of: UpdateEndResult.self) { group in
                group.addTaskWithLogging(
                    operation: "Consume service discovery update responses for \(update.name)",
                    sensitiveError: false,
                    logger: Self.logger
                ) { [update] in
                    await self.consumeUpdates(
                        stream: announcement.responseStream,
                        serviceName: update.name
                    )
                }

                group.addTaskWithLogging(
                    operation: "Publish service discovery updates for \(update.name)",
                    sensitiveError: false,
                    logger: Self.logger
                ) { [update] in
                    await self.publishUpdates(
                        update,
                        announcement: announcement
                    )
                }

                for await result in group {
                    switch result {
                    case .retracted:
                        // Retracted the service, we can wait for everything else implicitly.
                        return .complete
                    case .nonTerminalError(let error):
                        // If one task terminates, we want to cancel the others.
                        group.cancelAll()
                        if error is CancellationError {
                            Self.logger.log("ServiceDiscoveryPublisher got cancelled")
                        } else {
                            Self.logger.warning(
                                "ServiceDiscoveryPublisher encountered non-terminal error \(String(unredacted: error), privacy: .public)"
                            )
                        }
                        return .reconnect
                    case .terminalError(let error):
                        // If one task terminates, we want to cancel the others.
                        group.cancelAll()
                        return .fail(error)
                    }
                }

                return .reconnect
            }

            switch action {
            case .reconnect:
                Self.logger.error(
                    "ServiceDiscoveryPublisher loop for \(update.name, privacy: .public) terminated but will reconnect"
                )
                let backoff = connectionBackoff.backoff()
                self.metrics.emit(Metrics.ServiceDiscoveryPublisher.BackoffDurationHistogram(value: backoff.seconds))
                try await Task.sleep(for: backoff)
                continue
            case .fail(let error):
                Self.logger.error("""
                ServiceDiscoveryPublisher encountered terminal error for \
                \(update.name, privacy: .public): \
                \(String(unredacted: error), privacy: .public)
                """)
                throw error
            case .complete:
                // All is well, return cleanly.
                Self.logger.log(
                    "ServiceDiscoveryPublisher published and retracted service \(update.name, privacy: .public)"
                )
                return
            }
        }
    }

    private func publishUpdates(
        _ service: ServiceDiscovery.ServiceUpdate,
        announcement: ServiceDiscovery.Announcement
    ) async -> UpdateEndResult {
        Self.logger.log("Beginning service discovery publisher loop for \(service.name, privacy: .public)")
        var result = await self.sendServiceRegistration(
            serviceName: service.name,
            workloadType: service.details.workloadType,
            workloadTags: service.details.workloadTags,
            announcement: announcement
        )
        if let result {
            self.statusMonitor.serviceRegistrationErrored()
            return result
        }
        self.statusMonitor.serviceRegistrationSucceeded()

        Self.logger.log("Registered \(service.name, privacy: .public)")
        self.serviceRegistered()
        defer {
            self.serviceDeregistered()
        }

        do {
            try await Future(service.details.retractionPromise).valueWithCancellation
        } catch {
            Self.logger.warning(
                "Cancelling service discovery publisher loop for \(service.name, privacy: .public)"
            )
            self.statusMonitor.serviceDeregistrationCancelled()
            return .terminalError(error)
        }

        result = await self.sendServiceRetraction(
            serviceName: service.name,
            announcement: announcement
        )
        if let result {
            self.statusMonitor.serviceDeregistrationErrored()
            return result
        }
        self.statusMonitor.serviceDeregistered()

        Self.logger.log("Retracted \(service.name, privacy: .public)")
        announcement.finish()
        return .retracted
    }

    private func consumeUpdates(
        stream: any AsyncSequence<ServiceDiscovery.Response, Swift.Error>,
        serviceName: String
    ) async -> UpdateEndResult {
        do {
            Self.logger.info("Beginning service discovery reader loop for \(serviceName, privacy: .public)")
            for try await _ in stream {
                // These updates are empty, but we need to consume them.
                ()
            }
            Self.logger.warning(
                "Unexpected end of service discovery reader loop for \(serviceName, privacy: .public)"
            )
            return .nonTerminalError(UpdatesError.unexpectedEndOfResponseStream)
        } catch {
            Self.logger.warning("""
            Non-terminal error in service discovery reader loop for \
            \(serviceName, privacy: .public): \
            \(String(unredacted: error), privacy: .public)
            """)
            return .nonTerminalError(error)
        }
    }

    private func sendServiceRegistration(
        serviceName: String,
        workloadType: ServiceDiscoveryWorkloadConfig.WorkloadType,
        workloadTags: [String: RoutingTagValue],
        announcement: ServiceDiscovery.Announcement
    ) async -> UpdateEndResult? {
        let cloudOSBuildVersionToPublish = self.nodeInfo?.cloudOSBuildVersion
        let cloudOSReleaseTypeToPublish = self.nodeInfo?.cloudOSReleaseType
        let serverOSBuildVersionToPublish = self.nodeInfo?.serverOSBuildVersion
        let machineNameToPublish = self.nodeInfo?.machineName
        let ensembleIDToPublish = self.nodeInfo?.ensembleID
        let rackIDToPublish = self.nodeInfo?.rackID
        let bootIDToPublish = self.bootID
        let request: ServiceDiscovery.Request
        do {
            Self.logger.info("Publishing \(serviceName, privacy: .public) with tags: \(workloadTags, privacy: .public)")
            request = try .with {
                $0.registration = try .with {
                    $0.registrationID = self.id
                    $0.serviceName = serviceName
                    $0.instanceInfo = try .with {
                        $0.locality = .init(self.locality)
                        $0.address = try .init(self.serviceAddress)
                        var meta: [String: Com_Apple_Ase_Traffic_Servicediscovery_Api_V1_Meta] = [
                            "lb": .with {
                                $0.fields = .init(self.lbConfig)
                            },
                            // Note these are inconsistent in using Id vs ID. this matches ROPES though
                            "description": .with {
                                $0.fields = .init(optionalFields: [
                                    "cloudOSBuildVersion": cloudOSBuildVersionToPublish,
                                    "cloudOSReleaseType": cloudOSReleaseTypeToPublish,
                                    "serverOSBuildVersion": serverOSBuildVersionToPublish,
                                    "machineName": machineNameToPublish,
                                    "ensembleID": ensembleIDToPublish,
                                    "rackID": rackIDToPublish,
                                    "bootId": bootIDToPublish,
                                    "cellId": self.cellID,
                                    "releaseDigest": self.nodeReleaseDigest,
                                ])
                                if let routingGroupAliases {
                                    $0.fields["routingGroupAliases"] = .with {
                                        $0.listValue = .with {
                                            $0.values = routingGroupAliases.map { stringValue in
                                                .with {
                                                    $0.stringValue = stringValue
                                                }
                                            }
                                        }
                                    }
                                }
                            },
                        ]
                        switch workloadType {
                        case .compute:
                            meta["workload"] = .with {
                                $0.fields = [String: Com_Apple_Ase_Traffic_Servicediscovery_Api_V1_MetaValue](
                                    workloadTags
                                )
                            }
                        case .proxy(let proxyMetadata):
                            meta["trusted-proxy"] = .with {
                                $0.fields["services"] = .with {
                                    $0.listValue = .with {
                                        $0.values = proxyMetadata.services.map { service in
                                            .with { $0.stringValue = service }
                                        }
                                    }
                                }
                                let proxyRGAs = proxyMetadata.routingGroupAliasOverrides ?? self.routingGroupAliases
                                if let proxyRGAs {
                                    $0.fields["routingGroupAliases"] = .with {
                                        $0.listValue = .with {
                                            $0.values = proxyRGAs.map { stringValue in
                                                .with { $0.stringValue = stringValue }
                                            }
                                        }
                                    }
                                }
                            }
                            meta["workload"] = .with {
                                $0.fields = [String: Com_Apple_Ase_Traffic_Servicediscovery_Api_V1_MetaValue](
                                    workloadTags
                                )
                            }
                        }
                        $0.meta = meta
                    }
                }
            }
        } catch {
            Self.logger.error(
                "Terminal error constructing registration message: \(String(unredacted: error), privacy: .public)"
            )
            return .terminalError(error)
        }
        do {
            let registrationMessage = (try? request.jsonString()) ?? "<unserialisable>"
            Self.logger.log("Registration message: \(registrationMessage, privacy: .public)")
            try await announcement.send(request)
            return nil
        } catch {
            Self.logger.warning(
                "Non-terminal error publishing registration message: \(String(unredacted: error), privacy: .public)"
            )
            return .nonTerminalError(error)
        }
    }

    private func sendServiceRetraction(
        serviceName: String,
        announcement: ServiceDiscovery.Announcement
    ) async -> UpdateEndResult? {
        Self.logger.log("Retracting \(serviceName, privacy: .public)")
        let request = ServiceDiscovery.Request.with {
            $0.deregistration = .with {
                $0.registrationID = self.id
                $0.serviceName = serviceName
            }
        }
        do {
            Self.logger.log("Deregistration message: \(String(describing: request), privacy: .public)")
            try await announcement.send(request)
            return nil
        } catch {
            Self.logger.warning(
                "Non-terminal error publishing deregistration message: \(String(unredacted: error), privacy: .public)"
            )
            return nil // don't trigger a retry, just leave the entry to age-out
        }
    }

    private func drain() async {
        self.state.withLock { state in
            state.draining = true
        }
    }

    private func drainComplete() async {
        let deregistrationPromises = await self.clearState(reason: "drainComplete")

        // Wait for all deregistrations to complete before returning
        await withTaskGroup(of: Void.self) { group in
            for promise in deregistrationPromises {
                group.addTask {
                    await Future(promise).value
                }
            }
            await group.waitForAll()
        }
    }

    private func clearState(reason: String) async -> [Promise<Void, Never>] {
        let services = self.state.withLock { state in
            let services = state.services
            state.services = [:]

            return services
        }

        // retract all
        for service in services {
            Self.logger.log(
                "Retracting \(service.key, privacy: .public) due to \(reason, privacy: .public)"
            )
            service.value.retractionPromise.succeed()
        }
        self.statusMonitor.serviceDiscoveryPublisherDraining()

        // Return the deregistration completion promises so caller can wait for them
        return services.values.map(\.deregistrationCompletedPromise)
    }

    private func serviceRegistered() {
        self.registeredServiceCount.withLock { count in
            count += 1
            self.metrics.emit(Metrics.ServiceDiscoveryPublisher.RegisteredServices(value: count))
        }
    }

    private func serviceDeregistered() {
        self.registeredServiceCount.withLock { count in
            count -= 1
            self.metrics.emit(Metrics.ServiceDiscoveryPublisher.RegisteredServices(value: count))
        }
    }
}

extension Com_Apple_Ase_Traffic_Servicediscovery_Api_V1_SocketAddress {
    init(_ address: SocketAddress) throws {
        self = try .with {
            guard let ip = address.ipAddress, let port = address.port else {
                ServiceDiscoveryPublisher.logger.error(
                    "Unable to convert \(address, privacy: .public) for service discovery"
                )
                throw ServiceDiscoveryError.unableToConvertSocketAddress(address)
            }
            $0.ip = ip
            $0.port = UInt32(port)
        }
    }
}

enum ServiceDiscoveryError: Error {
    case unableToConvertSocketAddress(SocketAddress)
}

extension Com_Apple_Ase_Traffic_Servicediscovery_Api_V1_Locality {
    init(_ locality: ServiceDiscovery.Locality) {
        self = .with {
            $0.region = locality.region

            if let zone = locality.zone {
                $0.zone = zone
            }
        }
    }
}

extension [String: Com_Apple_Ase_Traffic_Servicediscovery_Api_V1_MetaValue] {
    init(_ data: [String: String]) {
        self = data.mapValues { stringValue in
            .with {
                $0.stringValue = stringValue
            }
        }
    }
}

extension [String: Com_Apple_Ase_Traffic_Servicediscovery_Api_V1_MetaValue] {
    init(_ data: [String: RoutingTagValue]) {
        self = data.mapValues { routingTagValue in
            return .with {
                switch routingTagValue {
                case .string(let stringValue):
                    $0.stringValue = stringValue
                case .stringList(let stringValues):
                    $0.listValue = .with {
                        $0.values = stringValues.map { stringValue in
                            .with {
                                $0.stringValue = stringValue
                            }
                        }
                    }
                @unknown default:
                    ServiceDiscoveryPublisher.logger.error(
                        "Unknown routing tag value type: \(routingTagValue, privacy: .public)"
                    )
                    $0.stringValue = "<failed-to-decode>"
                }
            }
        }
    }
}

extension [String: Com_Apple_Ase_Traffic_Servicediscovery_Api_V1_MetaValue] {
    init(optionalFields: [String: String?]) {
        var result = [String: Com_Apple_Ase_Traffic_Servicediscovery_Api_V1_MetaValue]()
        for (key, value) in optionalFields {
            if let value {
                result[key] = .with { $0.stringValue = value }
            }
        }
        self = result
    }
}

extension RetryBackoff {
    public init(
        config: GRPCClientConfiguration.ConnectionBackoff?
    ) where AContinuousClock == ContinuousClock {
        if let config {
            self.init(
                initial: config.initial.map { .milliseconds($0) },
                maximum: config.maximum.map { .milliseconds($0) },
                factor: config.factor,
                jitterPercent: config.jitterPercent,
                coolDown: config.coolDown.map { .milliseconds($0) } ?? .seconds(3)
            )
        } else {
            self.init()
        }
    }
}
