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

#if canImport(CipherMLSE)
import CipherMLSE
#endif
import CloudBoardCommon
import CloudBoardDomain
import CloudBoardJobAPI
import CloudBoardJobHelperAPI
import CloudBoardLogging
import Foundation
import InternalSwiftProtobuf
import os
import Synchronization

package protocol PIRHelperProtocol: Sendable {
    typealias EncryptedRequestHandler = @Sendable (PIREncryptedRequest, PIREncryptedRequestTraceContext) async throws
        -> PIREncryptedResponse
    func setEncryptedRequestHandler(_: @escaping EncryptedRequestHandler)
    func warmup(assetsMetadata: [AssetMetadata]) async throws
    func makeRequest(requestPayload: Data, traceContext: PIRRequestTraceContext) async throws -> Data
}

#if canImport(CipherMLSE)

final class PIRHelper: PIRHelperProtocol {
    private static let logger: os.Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: String(describing: PIRHelper.self)
    )
    private static let tracingLogger: os.Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard.tracing",
        category: String(describing: PIRHelper.self)
    )

    private typealias EncryptedResponseMessage = Apple_Parsec_Encryptedvisualsearch_V1_EncryptedVisualSearchResponse

    private let encryptedRequestHandler: Mutex<EncryptedRequestHandler?> = .init(nil)

    func setEncryptedRequestHandler(_ handler: @escaping EncryptedRequestHandler) {
        self.encryptedRequestHandler.withLock {
            $0 = handler
        }
    }

    func warmup(assetsMetadata: [AssetMetadata]) async throws {
        Self.logger.info("Warming up CipherML with assets \(assetsMetadata, privacy: .public)")
        let cipherMLAssets: [CipherMLSEActor.AssetMetadata] = assetsMetadata.map {
            .init(usecaseName: $0.id, configFolder: $0.path, assetVersion: $0.version)
        }
        do {
            try await CipherMLSEActor.warmup(assets: cipherMLAssets)
        } catch {
            Self.logger.error("Failed to warmup CipherML: \(String(unredacted: error), privacy: .public)")
            throw error
        }
        Self.logger.info("Warmed up CipherML with assets \(assetsMetadata, privacy: .public)")
    }

    func makeRequest(requestPayload: Data, traceContext: PIRRequestTraceContext) async throws -> Data {
        Self.logger.debug("Making PIR request")
        let query: CipherMLSE_QueryRequest
        do {
            query = try CipherMLSE_QueryRequest(serializedBytes: requestPayload)
        } catch {
            Self.logger.error("failed to deserialize PIR query: \(String(unredacted: error), privacy: .public)")
            throw CloudAppToJobHelperPIRError.failedToDeserializeMessage
        }

        let encryptedRequestHandler = try self.encryptedRequestHandler.withLock {
            guard let handler = $0 else {
                throw CloudAppToJobHelperPIRError.noEncryptedRequestHandlerSet
            }
            return handler
        }

        let response = try await CipherMLSEActor.process(query) { encryptedRequestMessage in
            Self.logger.debug("Handling PIR encrypted request")
            let pirEncryptedRequestTraceContext = PIREncryptedRequestTraceContext(
                pccServerRequestID: traceContext.pccServerRequestID,
                pirRequestID: traceContext.pirRequestID,
                pirEncryptedRequestID: UUID().uuidString,
                traceID: traceContext.traceID,
                spanID: TraceContextCache.singletonCache.generateNewSpanID()
            )
            let requestSummary = PIREncryptedRequestSummaryProvisioner(
                traceContext: pirEncryptedRequestTraceContext,
                pirRequestSpanID: traceContext.spanID
            )

            do {
                let encryptedRequest = try PIREncryptedRequest(encryptedData: encryptedRequestMessage.serializedData())
                let encryptedResponse = try await encryptedRequestHandler(
                    encryptedRequest,
                    pirEncryptedRequestTraceContext
                )
                let encryptedResponseMessage: EncryptedResponseMessage = try .init(
                    serializedBytes: encryptedResponse.encryptedData
                )
                let result: WrappedSimplePirTool.Response = try .with {
                    $0.result = try .init(message: encryptedResponseMessage)
                }
                await requestSummary.log(to: Self.tracingLogger)
                return result
            } catch {
                Self.logger.error(
                    "failed to handle encrypted PIR request: \(String(unredacted: error), privacy: .public)"
                )
                await requestSummary.populate(error: error)
                await requestSummary.log(to: Self.tracingLogger)
                return .with { $0.error = .init(wrapping: error) }
            }
        }
        return response
    }
}

#endif

final class NoOpPIRHelper: PIRHelperProtocol {
    private static let logger: os.Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: String(describing: NoOpPIRHelper.self)
    )

    func setEncryptedRequestHandler(_: @escaping EncryptedRequestHandler) {
        Self.logger.info("setEncryptedRequestHandler called on No-Op PIRHelper")
    }

    func warmup(assetsMetadata _: [AssetMetadata]) async throws {
        Self.logger.info("warmup called on No-Op PIRHelper")
    }

    func makeRequest(requestPayload _: Data, traceContext _: PIRRequestTraceContext) async throws -> Data {
        Self.logger.error("makeRequest called on No-Op PIRHelper")
        throw CloudAppToJobHelperPIRError.internalError
    }
}

actor PIREncryptedRequestSummaryProvisioner {
    var requestSummary: PIREncryptedRequestSummary

    init(
        traceContext: PIREncryptedRequestTraceContext,
        pirRequestSpanID: UInt64
    ) {
        self.requestSummary = .init(traceContext: traceContext, pirRequestSpanID: pirRequestSpanID)
        self.requestSummary.startTimeNanos = RequestSummaryClock.now
    }

    func populate(error: Error) {
        self.requestSummary.populate(error: error)
    }

    func log(to logger: Logger) {
        self.requestSummary.endTimeNanos = RequestSummaryClock.now
        self.requestSummary.log(to: logger)
    }
}

struct PIREncryptedRequestSummary: RequestSummary, Sendable {
    let serviceName = "cb_jobhelper"
    let operationName = "HandlePIREncryptedRequest"
    let type = "RequestSummary"
    let namespace = "cloudboard"
    let automatedDeviceGroup: String? = nil
    let requestID: String?
    let traceID: UUID
    let pirRequestID: String
    let pirEncryptedRequestID: String
    // the parent span (one PIR request needs multiple encrypted requests to fulfill)
    let pirRequestSpanID: UInt64
    let pirEncryptedRequestSpanID: UInt64

    var startTimeNanos: Int64?
    var endTimeNanos: Int64?

    var error: Error?

    init(
        pccServerRequestID: String,
        pirRequestID: String,
        pirEncryptedRequestID: String,
        traceID: UUID,
        pirRequestSpanID: UInt64,
        pirEncryptedRequestSpanID: UInt64
    ) {
        self.requestID = pccServerRequestID
        self.pirRequestID = pirRequestID
        self.pirEncryptedRequestID = pirEncryptedRequestID
        self.traceID = traceID
        self.pirRequestSpanID = pirRequestSpanID
        self.pirEncryptedRequestSpanID = pirEncryptedRequestSpanID
    }

    init(
        traceContext: PIREncryptedRequestTraceContext,
        pirRequestSpanID: UInt64
    ) {
        self.init(
            pccServerRequestID: traceContext.pccServerRequestID,
            pirRequestID: traceContext.pirRequestID,
            pirEncryptedRequestID: traceContext.pirEncryptedRequestID,
            traceID: traceContext.traceID,
            pirRequestSpanID: pirRequestSpanID,
            pirEncryptedRequestSpanID: traceContext.spanID
        )
    }

    func log(to logger: Logger) {
        logger.log("""
        ttl=RequestSummary
        request.uuid=\(self.requestID ?? "UNKNOWN", privacy: .public)
        tracing.trace_id=\(self.traceID.traceIDString, privacy: .public)
        tracing.span_id=\(self.pirEncryptedRequestSpanID.hexEncoded, privacy: .public)
        tracing.parent_span_id=\(self.pirRequestSpanID.hexEncoded, privacy: .public)
        tracing.name=\(self.operationName, privacy: .public)
        tracing.type=\(self.type, privacy: .public)
        tracing.start_time_unix_nano=\(self.startTimeNanos ?? 0, privacy: .public)
        tracing.end_time_unix_nano=\(self.endTimeNanos ?? 0, privacy: .public)
        request.duration_ms=\(self.durationMicros.map { String($0 / 1000) } ?? "", privacy: .public)
        service.name=\(self.serviceName, privacy: .public)
        service.namespace=\(self.namespace, privacy: .public)
        tracing.status=\(status?.rawValue ?? "", privacy: .public)
        error.type=\(self.error.map { String(describing: Swift.type(of: $0)) } ?? "", privacy: .public)
        error.description=\(self.error.map { "\(String(reportable: $0))" } ?? "", privacy: .public)
        error.detailed=\(self.error.map { String(describing: $0) } ?? "", privacy: .private)
        pir.request.uuid=\(self.pirRequestID, privacy: .public)
        pir.encryptedRequest.uuid=\(self.pirEncryptedRequestID, privacy: .public)
        """)
    }
}
