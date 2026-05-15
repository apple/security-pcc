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

// PCCHarness - Main entry point for V2 API
import CryptoKit
import Foundation
internal import Synchronization
internal import CloudAttestation
import os

// Errors related to PCCHarness operations
public enum PCCHarnessError: Error {
    case endpointNotFound
    case endpointAlreadyRegistered
    case endpointAlreadyRegisteredWithDifferentAppType
    case gatewayUnexpectedlyFinished
    case gatewayFailure(Error)
}

/// PCCHarness is used to set up a (local) PCC test environment. It is used to register compute and proxy cloud app
/// endpoints as well as to configure the simulated PCC Gateway. Once configured, `withActiveEnvironment` creates an
/// active environment as configured to make requests against.
public final class PCCHarness: Sendable {
    fileprivate static let logger: os.Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "LocalCloudBoardClient.PCCHarness"
    )

    // MARK: - Internal State

    private let registeredProxyAppEndpoints: Mutex<[HostAndPort: ProxyCloudAppEndpoint]> = .init([:])
    private let registeredComputeAppEndpoints: Mutex<[HostAndPort: ComputeCloudAppEndpoint]> = .init([:])
    private let gatewayConfig: Mutex<PCCGatewayConfig>

    // MARK: - Initialization

    /// Initializes a PCC harness for testing local or remote proxy or compute PCC nodes
    /// - Parameter gatewayConfig: PCC Gateway configuration to control PCC Gateway behavior, e.g. the compute node
    /// selection for requests from proxy nodes.
    public init(gatewayConfig: PCCGatewayConfig = PCCGatewayConfig()) {
        self.gatewayConfig = .init(gatewayConfig)
    }

    // MARK: - Configuration

    /// Set or update the compute node selection strategy
    /// - Parameter strategy: The new strategy to use for selecting compute nodes
    public func setComputeNodeSelectionStrategy(_ strategy: ComputeNodeSelectionStrategy) {
        self.gatewayConfig.withLock { $0.computeNodeSelectionStrategy = strategy }
    }

    /// Set or update the compute node selection strategy with extended capabilities (package-internal)
    /// - Parameter strategy: The extended strategy to use for selecting compute nodes
    package func setExtendedComputeNodeSelectionStrategy(_ strategy: ExtendedComputeNodeSelectionStrategy) {
        self.gatewayConfig.withLock { $0.extendedComputeNodeSelectionStrategy = strategy }
    }

    /// Set or update the service discovery instance (package-internal)
    /// - Parameter serviceDiscovery: The service discovery instance to use for negotiate/pick flows
    package func setServiceDiscovery(_ serviceDiscovery: ServiceDiscoveryAbstraction.ConsumerClientProtocol?) {
        self.gatewayConfig.withLock { config in
            let updatedConfig = PCCGatewayConfig(
                extendedComputeNodeSelectionStrategy: config.extendedComputeNodeSelectionStrategy,
                useTLS: config.useTLS,
                serviceDiscovery: serviceDiscovery
            )
            config = updatedConfig
        }
    }

    // MARK: - Endpoint Registration

    /// Registers a proxy cloud app endpoint
    /// - Parameters:
    ///   - host: Host of the proxy cloud app endpoint
    ///   - port: Port of the proxy cloud app endpoint
    /// - Returns: Endpoint handle that can be used to make requests to proxy cloud app endpoints in an active
    /// environment
    public func registerProxyApp(
        host: String,
        port: Int
    ) throws -> ProxyCloudAppEndpoint {
        let endpoint = ProxyCloudAppEndpoint(host: host, port: port)

        // Check if already registered
        guard self.registeredProxyAppEndpoints.withLock({ $0[endpoint.hostAndPort] == nil }) else {
            throw PCCHarnessError.endpointAlreadyRegistered
        }
        guard self.registeredComputeAppEndpoints.withLock({ $0[endpoint.hostAndPort] == nil }) else {
            throw PCCHarnessError.endpointAlreadyRegisteredWithDifferentAppType
        }

        self.registeredProxyAppEndpoints.withLock { $0[endpoint.hostAndPort] = endpoint }
        return endpoint
    }

    // Overloaded for ABI compatibility
    public func registerComputeApp(
        host: String,
        port: Int,
        serviceName: String,
        metadata: [String: [String]]? = nil
    ) throws -> ComputeCloudAppEndpoint {
        return try self.registerComputeApp(
            host: host,
            port: port,
            serviceName: serviceName,
            metadata: metadata,
            maxConcurrentRequests: nil
        )
    }

    /// Registers a compute cloud app endpoint
    /// - Parameters:
    ///   - host: Host of the compute cloud app endpoint
    ///   - port: Port of the compute cloud app endpoint
    ///   - serviceName: Service name associated with the compute cloud app, available to PCC Gateway proxy callback
    ///     when making routing decisions
    ///   - metadata: Service discovery metadata associated with the compute cloud app, available to PCC Gateway proxy
    ///     callback when making routing decisions
    ///   - maxConcurrentRequests: Maximum number of concurrent requests this endpoint can handle.
    ///     If nil, the endpoint has no concurrency limit.
    /// - Returns: Endpoint handle that can be used to make requests to compute cloud app endpoints in an active
    /// environment
    public func registerComputeApp(
        host: String,
        port: Int,
        serviceName: String,
        metadata: [String: [String]]? = nil,
        maxConcurrentRequests: Int? = nil
    ) throws -> ComputeCloudAppEndpoint {
        let endpoint = ComputeCloudAppEndpoint(
            host: host,
            port: port,
            serviceName: serviceName,
            metadata: metadata,
            maxConcurrentRequests: maxConcurrentRequests
        )

        // Check if already registered
        guard self.registeredComputeAppEndpoints.withLock({ $0[endpoint.hostAndPort] == nil }) else {
            throw PCCHarnessError.endpointAlreadyRegistered
        }
        guard self.registeredProxyAppEndpoints.withLock({ $0[endpoint.hostAndPort] == nil }) else {
            throw PCCHarnessError.endpointAlreadyRegisteredWithDifferentAppType
        }

        self.registeredComputeAppEndpoints.withLock { $0[endpoint.hostAndPort] = endpoint }
        return endpoint
    }

    enum EnvironmentTaskGroupResult<ReturnType: Sendable>: Sendable {
        case gatewayFinished
        case gatewayFailure(Error)
        case attestationValidatorFinished
        case bodyFinished(ReturnType)
        case bodyFailure(Error)
    }

    /// Creates an environment for making requests to PCC compute or PCC endpoints.
    ///
    /// The environment captures a snapshot of the current PCCHarness state (registered endpoints and gateway
    /// configuration) at the time this method is called. Subsequent changes to the PCCHarness (e.g., registering
    /// additional endpoints or updating gateway configuration) will NOT affect the created environment.
    ///
    /// - Parameters:
    ///   - options: Environment options, e.g. which attestation environment to use for attestation validation
    ///   - body: Handler that is provided with an active environment
    /// - Returns: The return value of the provided handler
    public func withActiveEnvironment<ReturnType: Sendable>(
        options: EnvironmentOptions = .init(),
        _ body: @escaping @Sendable (Environment) async throws -> ReturnType
    ) async throws -> ReturnType {
        let gateway = PCCGateway(
            registeredComputeAppEndpoints: Array(self.registeredComputeAppEndpoints.withLock { $0 }.values),
            registeredProxyAppEndpoints: Array(self.registeredProxyAppEndpoints.withLock { $0 }.values),
            config: self.gatewayConfig.withLock { $0 }
        )

        let attestationValidator = AttestationBundleValidator(
            attestationEnvironment: options.attestationEnvironment.toInternal
        )

        let environment = Environment(
            gateway: gateway,
            config: .init(attestationEnvironment: options.attestationEnvironment.toInternal),
            attestationValidator: attestationValidator
        )

        return try await withThrowingTaskGroup(of: EnvironmentTaskGroupResult<ReturnType>.self) { group in
            // Start the gateway (watchAttestation streams)
            group.addTask {
                do {
                    try await gateway.run()
                    return .gatewayFinished
                } catch {
                    return .gatewayFailure(error)
                }
            }

            // Start request execution log attestation validator
            group.addTask {
                await attestationValidator.runRequestExecutionLogAttestationValidator(
                    attestationStream: attestationValidator.relAttestationStream
                )
                return .attestationValidatorFinished
            }

            group.addTask {
                do {
                    return try await .bodyFinished(body(environment))
                } catch {
                    return .bodyFailure(error)
                }
            }

            if let taskResult = try await group.next() {
                group.cancelAll()
                switch taskResult {
                case .gatewayFinished:
                    Self.logger.error("PCCGateway unexpectedly finished")
                    throw PCCHarnessError.gatewayUnexpectedlyFinished
                case .gatewayFailure(let error):
                    Self.logger.error("PCCGateway failed: \(error)")
                    throw PCCHarnessError.gatewayFailure(error)
                case .attestationValidatorFinished:
                    Self.logger.error("AttestationValidator unexpectedly finished")
                    throw PCCHarnessError.gatewayUnexpectedlyFinished
                case .bodyFinished(let result):
                    Self.logger.info("withActiveEnvironment body finished. Returning result.")
                    return result
                case .bodyFailure(let error):
                    Self.logger.error("withActiveEnvironment body failed: \(error)")
                    throw error
                }
            } else {
                Self.logger.critical(
                    "withActiveEnvironment group.next() returned null for task group with at least two tasks"
                )
                throw LocalCloudBoardClientError
                    .internalError(
                        "withActiveEnvironment group.next() returned null for task group with at least two tasks"
                    )
            }
        }
    }
}
