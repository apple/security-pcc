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

import CloudBoardCommon
import CloudBoardDomain
import CloudBoardMetrics
import Foundation
import os
import PersistentServiceClientRouterAPI

/// Routes persistent service queries from cloud apps to the appropriate client router executables and
/// responses back to them.
///
/// Each enabled client router is identified by its service ID and Mach service name. The router
/// maintains XPC connections to each client router and relays queries and responses between the
/// cloud app (via cb_jobhelper) and the client router processes.
package actor PersistentServiceRouter {
    private static let logger = Logger(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "PersistentServiceRouter"
    )

    /// Known persistent service client routes.
    /// Maps service name to (serviceID, machServiceName).
    private static let knownRoutes: [String: (serviceID: UInt64, machServiceName: String)] = [
        "trusted-filter": (
            serviceID: PersistentService.Identity.serviceID(for: "trusted-filter"),
            machServiceName: "com.apple.cloudos.PrivateFilterClientRouter"
        ),
    ]

    /// Returns the enabled routers for the given list of service names,
    /// filtering against the known routes.
    package static func enabledRouters(
        for serviceNames: [String]
    ) -> [(serviceID: UInt64, machServiceName: String)] {
        serviceNames.compactMap { self.knownRoutes[$0] }
    }

    /// Reverse lookup: returns the service name for a given service ID, if known.
    package static func serviceName(for serviceID: UInt64) -> String? {
        self.knownRoutes.first(where: { $0.value.serviceID == serviceID })?.key
    }

    private var routes: [UInt64: PersistentServiceClientRouterAPIXPCClient]

    /// The UUID of the helper instance using this router, sent with each query so the
    /// client router can identify and route responses back to the correct helper.
    private let helperID: UUID

    /// Callback invoked when a persistent service response is received from any client router.
    private let onResponse: @Sendable (PersistentService.Response) async -> Void

    /// Backing continuation for `attestationUsageReports`. The XPC client callbacks on each
    /// route yield `(report, serviceID)` tuples here synchronously; the router's owner
    /// (`CloudBoardJobHelper`) iterates the stream in a structured task and does the expensive
    /// validation there.
    private let attestationUsageReportsContinuation:
        AsyncStream<(PersistentServiceClientRouter.AttestationUsageReport, UInt64)>.Continuation

    /// Attestation usage reports received from any connected client router, paired with
    /// the serviceID of the router that emitted them. Caller must consume this in a
    /// long-lived task for the duration of the router's lifetime.
    package nonisolated let attestationUsageReports:
        AsyncStream<(PersistentServiceClientRouter.AttestationUsageReport, UInt64)>

    /// Bounded queue depth for `attestationUsageReports`, clamped `>= 1`. See
    /// `SecureConfig.defaultAttestationUsageReportsBufferLimit` for the rationale.
    private let attestationUsageReportsBufferLimit: Int

    /// Creates a new router with connections to the specified client routers.
    /// - Parameters:
    ///   - enabledRouters: List of (serviceID, machServiceName) pairs for enabled client routers
    ///   - helperID: The UUID of the helper instance, used to identify this helper to client routers
    ///   - attestationUsageReportsBufferLimit: Bounded depth of the attestation-usage-report queue.
    ///   - onResponse: Callback for persistent service responses from client routers
    package init(
        enabledRouters: [(serviceID: UInt64, machServiceName: String)],
        helperID: UUID,
        attestationUsageReportsBufferLimit: Int = SecureConfig.defaultAttestationUsageReportsBufferLimit,
        onResponse: @escaping @Sendable (PersistentService.Response) async -> Void
    ) async {
        self.helperID = helperID
        self.onResponse = onResponse
        self.routes = [:]
        // Clamp at the point of use so the queue is never zero-depth (which
        // would drop every report), regardless of caller.
        let bufferLimit = max(1, attestationUsageReportsBufferLimit)
        self.attestationUsageReportsBufferLimit = bufferLimit
        let (stream, continuation) = AsyncStream<(PersistentServiceClientRouter.AttestationUsageReport, UInt64)>
            .makeStream(bufferingPolicy: .bufferingOldest(bufferLimit))
        self.attestationUsageReports = stream
        self.attestationUsageReportsContinuation = continuation

        for router in enabledRouters {
            let serviceID = router.serviceID
            Self.logger.info(
                "Creating connection to client router for serviceID \(serviceID, privacy: .public)"
            )
            let client = await PersistentServiceClientRouterAPIXPCClient(
                machServiceName: router.machServiceName,
                helperID: helperID,
                responseHandler: onResponse,
                attestationUsageReportHandler: { [continuation, bufferLimit] report in
                    switch continuation.yield((report, serviceID)) {
                    case .enqueued:
                        break
                    case .dropped:
                        Self.logger.error(
                            "Attestation usage report dropped for serviceID \(serviceID, privacy: .public) — queue at capacity (limit \(bufferLimit, privacy: .public))"
                        )
                    case .terminated:
                        // Router's consumer has finished the stream (we're in
                        // teardown); the XPC callback landed during that
                        // window. Silent drop is correct here.
                        break
                    @unknown default:
                        Self.logger.error(
                            "Unknown yield result for attestation usage report (serviceID \(serviceID, privacy: .public)); treating as dropped"
                        )
                    }
                }
            )
            await client.activate()
            self.routes[serviceID] = client
        }
    }

    deinit {
        self.attestationUsageReportsContinuation.finish()
    }

    /// Finish the `attestationUsageReports` stream so any consumer's
    /// `for await` loop observes termination and exits. Safe to call from
    /// any isolation context; `AsyncStream.Continuation.finish()` is
    /// thread-safe and idempotent.
    package nonisolated func shutdownAttestationUsageReports() {
        self.attestationUsageReportsContinuation.finish()
    }

    /// Register all the enabled routers.
    package func registerRouters() async {
        for router in self.routes.values {
            await router.sendRegister()
        }
    }

    /// Routes a persistent service query to the appropriate client router.
    package func sendQuery(
        to identity: PersistentService.Identity,
        payload: Data,
        correlationID: PersistentService.QueryCorrelationID,
        timeout: Duration?
    ) async throws {
        guard let client = self.routes[identity.serviceID] else {
            Self.logger.error("No client router found for serviceID \(identity.serviceID, privacy: .public)")
            throw PersistentServiceRouterError.noRouteForService(identity.serviceID)
        }

        await client.sendQuery(
            payload: payload,
            correlationID: correlationID,
            timeout: timeout
        )
    }

    /// Broadcasts a node approval to all connected client routers.
    ///
    /// Key IDs are unique across services, so broadcasting is safe and avoids
    /// the need to track which service a given attestation originated from.
    package func sendNodeApproval(keyID: Data, approved: Bool) async {
        for (serviceID, client) in self.routes {
            Self.logger.info(
                "Sending node approval (approved=\(approved, privacy: .public)) for keyID: \(keyID.base64EncodedString(), privacy: .public) to serviceID \(serviceID, privacy: .public)"
            )
            await client.sendNodeApproval(keyID: keyID, approved: approved)
        }
    }

    /// Broadcasts a REL-use commit result to all connected client routers.
    ///
    /// Key IDs are unique across services, so broadcasting is safe and avoids
    /// the need to track which service a given attestation originated from.
    package func sendRelUseCommitted(keyID: Data, success: Bool) async {
        for (serviceID, client) in self.routes {
            Self.logger.info(
                "Sending REL-use commit (success=\(success, privacy: .public)) for keyID: \(keyID.base64EncodedString(), privacy: .public) to serviceID \(serviceID, privacy: .public)"
            )
            await client.sendRelUseCommitted(keyID: keyID, success: success)
        }
    }

    /// Notifies all connected client routers that this helper is exiting.
    ///
    /// Called during teardown so routers can immediately purge per-helper state
    /// without waiting for a disconnect grace period.
    package func sendHelperExiting() async {
        for (serviceID, client) in self.routes {
            Self.logger.info(
                "Sending helper exiting to serviceID \(serviceID, privacy: .public)"
            )
            await client.sendHelperExiting()
        }
    }

    /// Disconnect from a specific service's client router.
    ///
    /// Sends a helper-exiting signal so the router can immediately purge per-helper state,
    /// then removes the route so no further queries or attestation reports are sent.
    package func disconnectService(_ serviceID: UInt64) async {
        guard let client = self.routes.removeValue(forKey: serviceID) else { return }
        Self.logger.info(
            "Disconnecting from serviceID \(serviceID, privacy: .public) after failure"
        )
        await client.sendHelperExiting()
    }
}

/// Errors thrown by ``PersistentServiceRouter`` when routing queries to client router processes.
///
/// The associated `UInt64` is the persistent service ID that identifies the target service.
package enum PersistentServiceRouterError: Error {
    case noRouteForService(UInt64)
}
