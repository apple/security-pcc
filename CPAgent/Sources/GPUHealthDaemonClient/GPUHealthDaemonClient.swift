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

import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import Logging
import ServiceLifecycle

/// Target configuration for GPU Health Monitor connection
public enum GPUHealthDaemonTarget: Sendable {
    case unixDomainSocket(path: String)
    case tcp(host: String, port: Int)
}

public enum GPUHealthDaemonError: Error {
    case notConnected
}

public actor GPUHealthDaemonClient: Service, GPUHealthProvider {
    public typealias HealthResponse = GpuHealth_V1_GetHealthResponse
    public typealias TelemetryResponse = GpuHealth_V1_GetTelemetryResponse
    public typealias HealthStatus = GpuHealth_V1_InstanceStatus

    private let logger = Logger(label: "CPAgent.GPUHealthDaemonClient")
    private let target: GPUHealthDaemonTarget
    private let reconnectInterval: TimeInterval = 0.1

    private var grpcClient: GRPCClient<HTTP2ClientTransport.Posix>?
    private var instanceHealthClient:
        GpuHealth_V1_GpuHealthService.Client<HTTP2ClientTransport.Posix>?

    /// Initialize the GPU Health Monitor Client
    /// - Parameter target: The target configuration for the gRPC connection
    public init(target: GPUHealthDaemonTarget) {
        self.target = target
    }

    /// Run the service - establishes connection and maintains it continuously
    public func run() async throws {
        logger.info("Starting GPU Health Daemon Client service")

        let transport = try createTransport()

        try await withGracefulShutdownHandler {
            try await withThrowingTaskGroup(of: Void.self) { group in
                let client = GRPCClient(transport: transport)
                self.grpcClient = client
                self.instanceHealthClient = GpuHealth_V1_GpuHealthService.Client(wrapping: client)

                try await client.runConnections()
            }
        } onGracefulShutdown: {
            Task {
                //await self.shutdown()
            }
        }
        logger.info("GPU Health Daemon Client service finished")
    }

    private func shutdown() async {
        logger.info("Shutting down GPU Health Daemon Client service")
        await closeConnection()
    }

    /// Creates the appropriate transport based on target configuration
    private func createTransport() throws -> HTTP2ClientTransport.Posix {
        switch target {
        case .unixDomainSocket(let path):
            return try HTTP2ClientTransport.Posix(
                target: .unixDomainSocket(path: path),
                transportSecurity: .plaintext
            )
        case .tcp(let host, let port):
            return try HTTP2ClientTransport.Posix(
                target: .dns(host: host, port: port),
                transportSecurity: .plaintext
            )
        }
    }

    private func closeConnection() async {
        instanceHealthClient = nil

        if let client = grpcClient {
            client.beginGracefulShutdown()
            grpcClient = nil
        }
    }

    /// Get the current health status of the GPU instance
    /// - Returns: The health response or nil if not connected
    public func getHealth() async throws -> HealthResponse {
        guard let client = instanceHealthClient else {
            logger.warning("Cannot get health: not connected to GPU Health Daemon")
            throw GPUHealthDaemonError.notConnected
        }

        let request = GpuHealth_V1_GetHealthRequest()
        return try await client.getHealth(request)
    }

    public func getActiveFaults() async throws -> GpuHealth_V1_GetActiveFaultsResponse {
        guard let client = instanceHealthClient else {
            logger.warning("Cannot get active faults: not connected to GPU Health Daemon")
            throw GPUHealthDaemonError.notConnected
        }
        return try await client.getActiveFaults(GpuHealth_V1_GetActiveFaultsRequest())
    }

    /// Get detailed per-GPU telemetry
    /// - Returns: The telemetry response containing per-GPU metrics
    public func getTelemetry() async throws -> TelemetryResponse {
        guard let client = instanceHealthClient else {
            logger.warning("Cannot get telemetry: not connected to GPU Health Daemon")
            throw GPUHealthDaemonError.notConnected
        }

        let request = GpuHealth_V1_GetTelemetryRequest()
        return try await client.getTelemetry(request)
    }

    /// Get connection target information
    public var connectionTarget: GPUHealthDaemonTarget {
        return target
    }
}
