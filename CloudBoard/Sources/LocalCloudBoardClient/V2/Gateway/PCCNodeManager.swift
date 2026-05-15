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

import Foundation
internal import InternalGRPC
internal import NIOCore
import os
internal import Synchronization

extension PCCHarness {
    enum PCCNodeManagerError: Error {
        case unknownEndpoint
    }

    final class PCCNodeManager: Sendable {
        let registeredComputeAppEndpoints: [ComputeCloudAppEndpoint]
        let registeredProxyAppEndpoints: [ProxyCloudAppEndpoint]
        let trackedComputeEndpointPool: TrackedPool<ComputeCloudAppEndpoint, ComputeCloudAppEndpoint>
        let queueManager: ComputeNodeQueueManager

        private let endpointClients: [HostAndPort: GatewayPCCClient]
        private let useTLS: Bool
        private let serviceDiscovery: ServiceDiscoveryAbstraction.RegistrationClientProtocol?

        // Storage for per-endpoint observers
        private let invokeWorkloadMessageObservers: Mutex<[HostAndPort: InvokeWorkloadMessageObserver]> = .init([:])
        private let proxyDialBackMessageObservers: Mutex<[ProxyCloudAppEndpoint: ProxyDialBackMessageObserver]> =
            .init([:])

        private let eventLoopGroup: EventLoopGroup

        fileprivate static let logger: os.Logger = .init(
            subsystem: "com.apple.cloudos.cloudboard",
            category: "LocalCloudBoardClient.PCCNodeManager"
        )

        init(
            registeredComputeAppEndpoints: [ComputeCloudAppEndpoint],
            registeredProxyAppEndpoints: [ProxyCloudAppEndpoint],
            useTLS: Bool,
            serviceDiscovery: ServiceDiscoveryAbstraction.RegistrationClientProtocol?
        ) {
            self.registeredComputeAppEndpoints = registeredComputeAppEndpoints
            self.registeredProxyAppEndpoints = registeredProxyAppEndpoints
            self.useTLS = useTLS
            self.serviceDiscovery = serviceDiscovery
            self.queueManager = ComputeNodeQueueManager()

            var trackedComputeEndpoints = [ComputeCloudAppEndpoint: ComputeCloudAppEndpoint]()
            var endpointMaxConcurrentRequests = [ComputeCloudAppEndpoint: Int?]()
            for endpoint in registeredComputeAppEndpoints {
                trackedComputeEndpoints[endpoint] = endpoint
                // Use endpoint-specific limit if set, otherwise will fall back to default (100)
                endpointMaxConcurrentRequests[endpoint] = endpoint.maxConcurrentRequests
            }
            self.trackedComputeEndpointPool = .init(
                trackedComputeEndpoints,
                defaultMaxConcurrentRequests: 100,
                elementMaxConcurrentRequests: endpointMaxConcurrentRequests,
                queueManager: self.queueManager
            )

            self.eventLoopGroup = PlatformSupport.makeEventLoopGroup(
                loopCount: System.coreCount,
                networkPreference: .userDefined(.networkFramework)
            )

            let allEndpoints: [any CloudAppEndpoint] =
                registeredComputeAppEndpoints +
                registeredProxyAppEndpoints

            var endpointClients: [HostAndPort: GatewayPCCClient] = [:]
            for endpoint in allEndpoints {
                let callback: @Sendable (any CloudAppEndpoint, LocalCloudBoardAttestationBundle) -> Void =
                    if let serviceDiscovery {
                        { [serviceDiscovery] receivedEndpoint, attestationBundle in
                            PCCNodeManager.updateServiceDiscoveryFromAttestation(
                                serviceDiscovery: serviceDiscovery,
                                for: receivedEndpoint,
                                attestationBundle: attestationBundle
                            )
                        }
                    } else {
                        { _, _ in
                            // No-op: Service discovery not configured
                        }
                    }

                endpointClients[endpoint.hostAndPort] = GatewayPCCClient(
                    eventLoopGroup: self.eventLoopGroup,
                    endpoint: endpoint,
                    useTLS: useTLS,
                    onAttestationReceived: callback
                )
            }
            self.endpointClients = endpointClients
        }

        deinit {
            do {
                try self.eventLoopGroup.syncShutdownGracefully()
            } catch {
                // Nothing we can do
                ()
            }
        }

        func run() async throws {
            try await withThrowingTaskGroup(of: Void.self) { group in
                // Even if no reachable endpoint has been registered, we want the gateway to keep running until the
                // active environment is torn down.
                group.addTask {
                    do {
                        try await Task.sleep(nanoseconds: .max)
                    } catch {
                        // Cancelled, do nothing
                        ()
                    }
                }

                // Create gRPC clients for each registered endpoint
                for endpointClient in self.endpointClients.values {
                    group.addTask {
                        do {
                            try await endpointClient.run()
                        } catch {
                            // Log the failure but don't propagate - individual endpoint failures should not bring down
                            // the entire gateway
                            os.Logger(subsystem: "com.apple.cloudos.cloudboard", category: "PCCNodeManager")
                                .error("Endpoint \(endpointClient.endpoint.hostAndPort) failed: \(error)")
                        }
                    }
                }

                // Watch for attestations indefinitely, or until cancelled.
                try await group.waitForAll()
            }
        }

        func client(for endpoint: any CloudAppEndpoint) throws -> GatewayPCCClient {
            guard let client = self.endpointClients[endpoint.hostAndPort] else {
                throw PCCNodeManagerError.unknownEndpoint
            }
            return client
        }

        // MARK: - Observer Methods

        /// Set observer for a specific endpoint
        package func setInvokeWorkloadMessageObserver(
            _ observer: InvokeWorkloadMessageObserver?,
            for endpoint: any CloudAppEndpoint
        ) {
            self.invokeWorkloadMessageObservers.withLock { observers in
                if let observer {
                    observers[endpoint.hostAndPort] = observer
                } else {
                    observers.removeValue(forKey: endpoint.hostAndPort)
                }
            }
        }

        /// Get observer for a specific endpoint
        package func invokeWorkloadMessageObserver(
            for endpoint: any CloudAppEndpoint
        ) -> InvokeWorkloadMessageObserver? {
            self.invokeWorkloadMessageObservers.withLock { $0[endpoint.hostAndPort] }
        }

        /// Set observer for a specific proxy endpoint
        package func setProxyDialBackMessageObserver(
            _ observer: ProxyDialBackMessageObserver?,
            for endpoint: ProxyCloudAppEndpoint
        ) {
            self.proxyDialBackMessageObservers.withLock { observers in
                if let observer {
                    observers[endpoint] = observer
                } else {
                    observers.removeValue(forKey: endpoint)
                }
            }
        }

        /// Get observer for a specific proxy endpoint
        package func proxyDialBackMessageObserver(
            for endpoint: ProxyCloudAppEndpoint
        ) -> ProxyDialBackMessageObserver? {
            self.proxyDialBackMessageObservers.withLock { $0[endpoint] }
        }

        // MARK: - Service Discovery Update

        /// Gathers ensemble information for compute endpoints from a service discovery snapshot
        /// - Parameters:
        ///   - snapshot: Service discovery snapshot mapping endpoints to registration info
        ///   - computeEndpoints: List of compute endpoints to look up
        ///   - filter: Optional filter predicate to select specific ensembles
        /// - Returns: Array of tuples containing ensemble ID, boot ID, and endpoint for matching entries
        package static func gatherEnsemblesFromServiceDiscovery(
            snapshot: [LocalCloudBoardGRPCAsyncClient.EndPoint: ServiceDiscoveryAbstraction.RegistrationInfo],
            computeEndpoints: [ComputeCloudAppEndpoint],
            filter: (ServiceDiscoveryAbstraction.RegistrationInfo) -> Bool = { _ in true }
        ) -> [(ensembleId: String, bootId: String, endpoint: ComputeCloudAppEndpoint)] {
            var ensembles: [(ensembleId: String, bootId: String, endpoint: ComputeCloudAppEndpoint)] = []

            for computeEndpoint in computeEndpoints {
                // Look up this compute endpoint in service discovery by constructing the key
                let serviceDiscoveryKey = LocalCloudBoardGRPCAsyncClient.EndPoint(
                    host: computeEndpoint.host,
                    port: computeEndpoint.port
                )

                if let registrationInfo = snapshot[serviceDiscoveryKey],
                   let bootId = registrationInfo.bootId,
                   filter(registrationInfo) {
                    ensembles.append((
                        ensembleId: registrationInfo.ensembleId,
                        bootId: bootId,
                        endpoint: computeEndpoint
                    ))
                }
            }

            return ensembles
        }

        /// Updates service discovery with ensemble/boot/rack IDs from an attestation bundle
        /// Called when a compute node's attestation is received to dynamically populate service discovery
        package static func updateServiceDiscoveryFromAttestation(
            serviceDiscovery: ServiceDiscoveryAbstraction.RegistrationClientProtocol?,
            for endpoint: any CloudAppEndpoint,
            attestationBundle: LocalCloudBoardAttestationBundle
        ) {
            guard let sd = serviceDiscovery else {
                return // No service discovery configured
            }

            // Only process compute node attestations
            guard case .compute(let computeAppData) = attestationBundle.appData else {
                return
            }

            // Extract ensemble/boot/rack IDs from the attestation bundle
            guard let ensembleId = computeAppData.ensembleId,
                  let bootId = computeAppData.bootId else {
                Self.logger.warning("""
                Attestation for endpoint \(endpoint.hostAndPort) missing ensemble/boot IDs, \
                cannot populate service discovery
                """)
                return
            }

            let rackId = computeAppData.rackId

            Self.logger.info("""
            Populating service discovery with IDs from attestation: \
            endpoint=\(endpoint.hostAndPort, privacy: .public) \
            ensembleId=\(ensembleId, privacy: .public) \
            bootId=\(bootId, privacy: .public) \
            rackId=\(rackId ?? "nil", privacy: .public)
            """)

            let registration = ServiceDiscoveryAbstraction.RegistrationInfo(
                ensembleId: ensembleId,
                bootId: bootId,
                rackId: rackId
            )

            sd.update(
                for: LocalCloudBoardGRPCAsyncClient.EndPoint(host: endpoint.host, port: endpoint.port),
                info: registration
            )
        }
    }
}
