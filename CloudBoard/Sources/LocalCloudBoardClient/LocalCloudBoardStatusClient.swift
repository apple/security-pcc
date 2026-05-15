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

// Don't add any dependencies here to CloudBoard itself except static libraries
import Foundation
internal import InternalGRPC
internal import NIOCore
internal import NIOTransportServices
import os

/// Error types for the Status client
public enum LocalCloudBoardStatusClientError: Error, Equatable {
    case connectionFailed(String)
}

/// Client for querying CloudBoard daemon status
///
/// This client provides a simple interface to the CloudBoard Status gRPC service,
/// allowing applications to check daemon health.
///
/// Example usage:
/// ```swift
/// let statusClient = LocalCloudBoardStatusClient(host: "localhost", port: 50052)
///
/// // Check status
/// let status = try await statusClient.checkStatus()
/// print("Daemon status: \(status.status)")
/// print("Is healthy: \(status.status.isHealthy)")
/// ```
public class LocalCloudBoardStatusClient {
    /// Default status server port
    public static let defaultPort = 50052

    public static let logger: os.Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "LocalCloudBoardStatusClient"
    )

    /// Identifies a status server endpoint
    public struct EndPoint: Hashable, Sendable, CustomStringConvertible {
        public var host: String
        public var port: Int

        public init(host: String, port: Int) {
            self.host = host
            self.port = port
        }

        public var description: String {
            "\(self.host):\(self.port)"
        }
    }

    private let endpoint: EndPoint
    private let eventLoopGroup: EventLoopGroup
    private let channel: GRPCChannel
    private let client: Cloudboard_Status_V1_StatusAsyncClient

    /// Creates a new Status client
    /// - Parameters:
    ///   - host: Hostname of the CloudBoard daemon (default: "localhost")
    ///   - port: Port of the status server (default: 50052)
    ///   - useTLS: Whether to use TLS for the connection (default: true)
    ///   - connectionTimeout: Connection timeout (default: 5 seconds)
    public init(
        host: String = "localhost",
        port: Int = defaultPort,
        useTLS: Bool = true,
        connectionTimeout: Duration = .seconds(5)
    ) {
        self.endpoint = EndPoint(host: host, port: port)

        self.eventLoopGroup = PlatformSupport.makeEventLoopGroup(
            loopCount: 1,
            networkPreference: .userDefined(.networkFramework)
        )

        let timeoutSeconds = Int64(connectionTimeout.components.seconds)

        if useTLS {
            let queue = DispatchQueue(
                label: "com.apple.LocalCloudBoardStatusClient.Verification.queue",
                qos: DispatchQoS.userInitiated
            )
            self.channel = ClientConnection
                .usingTLSBackedByNetworkFramework(on: self.eventLoopGroup)
                .withTLSHandshakeVerificationCallback(on: queue, verificationCallback: { _, _, verifyComplete in
                    // For testing/development: accept self-signed certificates
                    // In production, this should validate the daemon's certificate
                    verifyComplete(true)
                })
                .withConnectionTimeout(minimum: .seconds(timeoutSeconds))
                .withConnectionBackoff(retries: .none)
                .connect(host: host, port: port)
        } else {
            self.channel = ClientConnection
                .insecure(group: self.eventLoopGroup)
                .withConnectionTimeout(minimum: .seconds(timeoutSeconds))
                .withConnectionBackoff(retries: .none)
                .connect(host: host, port: port)
        }

        self.client = Cloudboard_Status_V1_StatusAsyncClient(channel: self.channel)
    }

    /// Convenience initializer using an EndPoint
    /// - Parameters:
    ///   - endPoint: The status server endpoint
    ///   - useTLS: Whether to use TLS for the connection (default: true)
    ///   - connectionTimeout: Connection timeout (default: 5 seconds)
    public convenience init(endPoint: EndPoint, useTLS: Bool = true, connectionTimeout: Duration = .seconds(5)) {
        self.init(host: endPoint.host, port: endPoint.port, useTLS: useTLS, connectionTimeout: connectionTimeout)
    }

    /// Performs a one-shot status check
    /// - Returns: The current status of the CloudBoard daemon as a JSON string
    /// - Throws: LocalCloudBoardStatusClientError if the check fails
    public func checkStatus() async throws -> String {
        Self.logger.debug("Checking status at \(self.endpoint.description)")

        do {
            let response = try await self.client.check(Cloudboard_Status_V1_StatusRequest())
            Self.logger.debug("Received status JSON: \(response.cloudboardStatusJson)")
            return response.cloudboardStatusJson
        } catch {
            Self.logger.error("Status check failed: \(error)")
            throw LocalCloudBoardStatusClientError.connectionFailed(
                "Failed to check status at \(self.endpoint): \(error)"
            )
        }
    }

    /// Closes the client connection and shuts down the event loop group
    /// Should be called when the client is no longer needed
    public func close() async {
        Self.logger.debug("Closing connection to \(self.endpoint.description)")
        do {
            try await self.channel.close().get()
            try await self.eventLoopGroup.shutdownGracefully()
        } catch {
            Self.logger.error("Error during close: \(error)")
        }
    }

    deinit {
        // Best effort cleanup - errors are suppressed since we can't handle them in deinit
        // Clients should call close() explicitly for proper async cleanup
        try? self.channel.close().wait()
        try? self.eventLoopGroup.syncShutdownGracefully()
    }
}

@available(*, unavailable)
extension LocalCloudBoardStatusClient: Sendable {}
