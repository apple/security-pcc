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

package import CloudBoardAsyncXPC

package protocol CloudBoardControllerAPIServerToClientProtocol: Actor {
    func shutdown() async throws
}

/// Protocol for handling CloudBoard controller API server delegate methods.
///
/// The `connectionIdentifier` parameter is used throughout this protocol to uniquely identify
/// and associate operations with specific client connections to the CloudBoard controller.
/// This string-based identifier allows the server to:
/// - Track multiple concurrent client connections
/// - Associate workloads with their originating connections
/// - Route status updates and control commands to the correct client context
/// - Maintain isolation between different client sessions
///
/// The connection identifier is typically generated when a client establishes a connection
/// and remains constant for the lifetime of that connection session.
package protocol CloudBoardControllerAPIServerDelegateProtocol:
AnyObject, Sendable {
    /// Registers a new workload with the CloudBoard controller.
    ///
    /// - Parameters:
    ///   - connectionIdentifier: Unique identifier for the client connection that owns this workload.
    ///     Used to associate the workload with its originating client session and enable proper
    ///     cleanup when the connection is terminated.
    ///   - config: Metadata to be provided to ROPES/Service Discovery. May change over time.
    ///   - properties: Static workload properties.
    func registerWorkload(
        connectionIdentifier: Int, config: InternalWorkloadConfig, properties: WorkloadProperties
    ) async throws

    /// Updates the health status for workloads associated with a specific connection.
    ///
    /// - Parameters:
    ///   - connectionIdentifier: Unique identifier for the client connection whose workload
    ///     status is being updated. This ensures status updates are properly attributed
    ///     to the correct client and workload context.
    ///   - status: The current health and operational status of the workload controller.
    func updateHealthStatus(connectionIdentifier: Int, status: WorkloadControllerStatus) async throws

    /// Restarts prewarmed instances for workloads associated with a specific connection.
    ///
    /// - Parameters:
    ///   - connectionIdentifier: Unique identifier for the client connection whose prewarmed
    ///     instances should be restarted. This ensures the restart operation only affects
    ///     instances belonging to the specified client connection.
    func restartPrewarmedInstances(connectionIdentifier: Int) async throws

    /// Reports that a persistent service has failed terminally.
    ///
    /// Unlike the other methods here, this is routed by `serviceId` rather than by `connectionIdentifier`, because a
    /// terminal failure can occur before the service ever registers a workload (e.g. asset download exhausts its
    /// retries during initialization). The owning manager transitions its health monitor to a terminal state.
    ///
    /// - Parameters:
    ///   - connectionIdentifier: Unique identifier for the reporting client connection (for logging/diagnostics).
    ///   - serviceId: Identifier of the persistent service that failed (e.g. "trusted-filter").
    ///   - reason: Human-readable description of the failure, for logging.
    func reportPersistentServiceTerminalFailure(
        connectionIdentifier: Int, serviceId: String, reason: String
    ) async throws
}

package protocol CloudBoardControllerAPIServerProtocol:
CloudBoardControllerAPIServerToClientProtocol {
    func connect(
        listenerDelegate: CloudBoardAsyncXPCListenerDelegate,
        serverDelegate: CloudBoardControllerAPIServerDelegateProtocol
    ) async
}
