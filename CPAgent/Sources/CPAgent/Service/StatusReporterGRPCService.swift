// Copyright © 2026 Apple Inc. All Rights Reserved.

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

import CPAgentProtos
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import Logging
import ServiceLifecycle

// MARK: - Server

/// Hosts the StatusReporter gRPC service over a Unix Domain Socket for CloudBoard status reporting.
/// If the socket directory does not exist (shared volume not mounted), logs a warning and idles.
struct StatusGRPCServer: Service {
    let socketPath: String
    let statusReporterGRPCService: StatusReporterGRPCService
    private let logger = Logger(label: "CPAgent.StatusGRPCServer")

    init(
        socketPath: String = "/var/run/cloudboard/status.sock",
        statusReporterGRPCService: StatusReporterGRPCService
    ) {
        self.socketPath = socketPath
        self.statusReporterGRPCService = statusReporterGRPCService
    }

    func run() async throws {
        logger.info("Starting...")
        let socketDirectory = (socketPath as NSString).deletingLastPathComponent
        guard FileManager.default.fileExists(atPath: socketDirectory) else {
            logger.warning(
                "Socket directory does not exist, status gRPC server will not start",
                metadata: ["directory": "\(socketDirectory)"])
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(600))
            }
            return
        }

        let transport = HTTP2ServerTransport.Posix(
            address: .unixDomainSocket(path: socketPath),
            transportSecurity: .plaintext
        )

        let server = GRPCServer(
            transport: transport,
            services: [statusReporterGRPCService]
        )

        logger.info("Status gRPC server starting", metadata: ["socketPath": "\(self.socketPath)"])

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await server.serve()
                }
                group.addTask {
                    _ = try await server.transport.listeningAddress
                    try FileManager.default.setAttributes(
                        [.posixPermissions: 0o666], ofItemAtPath: socketPath)
                }
                try await group.waitForAll()
            }
        } catch {
            logger.error(
                "Status gRPC server failed, will not restart",
                metadata: [
                    "socketPath": "\(self.socketPath)", "error": "\(String(reportable: error))",
                ])
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(600))
            }
        }
        logger.info("finished")
    }
}

// MARK: - Service handler

/// gRPC service handler for CloudBoard status reporting.
/// CloudBoard opens a long-lived client stream and pushes full component-tree snapshots.
/// Only one client stream may be connected at a time; additional connection attempts are rejected.
/// `reportStatus` is `nonisolated` so concurrent connection attempts don't serialize on the actor;
/// it only hops onto the actor briefly to check/update `isClientConnected`.
actor StatusReporterGRPCService: Proto_CPAgentStatus_StatusReporter.SimpleServiceProtocol {
    let nodeStatusStore: NodeStatusStore
    private let logger = Logger(label: "CPAgent.StatusReporterGRPCService")
    private var isClientConnected = false

    init(nodeStatusStore: NodeStatusStore) {
        self.nodeStatusStore = nodeStatusStore
    }

    nonisolated func reportStatus(
        request: GRPCCore.RPCAsyncSequence<Proto_CPAgentStatus_StatusReport, any Swift.Error>,
        context: GRPCCore.ServerContext
    ) async throws -> Proto_CPAgentStatus_StatusResponse {
        guard await tryAcquireConnection() else {
            logger.warning("Rejecting CloudBoard status stream: a client is already connected")
            throw RPCError(
                code: .failedPrecondition,
                message: "Only one status reporter client may be connected at a time")
        }
        defer {
            Task { await releaseConnection() }
        }

        logger.info("CloudBoard status stream connected")

        do {
            for try await report in request {
                logger.debug(
                    "Received status report",
                    metadata: [
                        "reporter": "\(report.reporterIdentifier)",
                        "components": "\(report.components.count)",
                    ])
                try validate(report)
                await nodeStatusStore.update(report)
            }
        } catch let error as StatusReportValidationError {
            logger.warning(
                "Rejecting status report", metadata: ["error": "\(String(reportable: error))"])
            throw RPCError(code: .invalidArgument, message: String(reportable: error))
        } catch {
            logger.debug("Status stream ended", metadata: ["error": "\(String(reportable: error))"])
        }

        logger.info("CloudBoard status stream disconnected")
        await nodeStatusStore.clear()
        return Proto_CPAgentStatus_StatusResponse()
    }

    private func tryAcquireConnection() -> Bool {
        guard !isClientConnected else { return false }
        isClientConnected = true
        return true
    }

    private func releaseConnection() {
        isClientConnected = false
    }

    /// Rejects reports with more components, or larger strings, than CloudBoard is expected to ever send.
    private nonisolated func validate(_ report: Proto_CPAgentStatus_StatusReport) throws {
        guard report.components.count <= Self.maxComponents else {
            throw StatusReportValidationError.tooManyComponents
        }
        try Self.validateStringSize(report.reporterIdentifier)
        for component in report.components {
            for path in component.componentPath {
                try Self.validateStringSize(path)
            }
            if let message = component.state?.stringPayload {
                try Self.validateStringSize(message)
            }
        }
    }

    private static let maxComponents = 32
    private static let maxStringBytes = 1024

    private static func validateStringSize(_ value: String) throws {
        guard value.utf8.count <= maxStringBytes else {
            throw StatusReportValidationError.stringFieldTooLarge
        }
    }
}

extension Proto_CPAgentStatus_ComponentStatus.OneOf_State {
    /// The human-readable string carried by whichever state is set, if any.
    fileprivate var stringPayload: String? {
        switch self {
        case .initializing(let value): return value.phase
        case .ready: return nil
        case .degraded(let value): return value.reason
        case .busy(let value): return value.reason
        case .transientError(let value): return value.message
        case .terminalError(let value): return value.message
        case .draining(let value): return value.reason
        case .drained(let value): return value.reason
        }
    }
}

private enum StatusReportValidationError: Error, ReportableError {
    case tooManyComponents
    case stringFieldTooLarge

    var publicDescription: String {
        switch self {
        case .tooManyComponents:
            return "StatusReportValidationError.tooManyComponents"
        case .stringFieldTooLarge:
            return "StatusReportValidationError.stringFieldTooLarge"
        }
    }
}
