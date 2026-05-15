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
import os
internal import InternalGRPC

extension PCCHarness {
    /// Error codes returned to proxy when compute node selection fails
    public enum GatewayComputeNodeSelectionError: UInt32, Error, Sendable {
        /// No nodes registered that serve the requested workload
        case unknownWorkload = 4000
        /// All compute nodes are busy
        case nodesBusy = 4002
        /// Request was discarded
        case discarded = 4008
        /// Unknown error from CloudBoard
        case cloudBoardUnknownError = 5002
        /// Resource exhausted in CloudBoard, e.g. due to having the reached the maximum number of concurrent requests
        case cloudBoardResourceExhausted = 5008
        /// Internal error in CloudBoard
        case cloudBoardInternalError = 5013
        /// Internal server error on PCC Gateway
        case internalServerError = 6000

        /// Converts a gRPC status code to a gateway compute node selection error
        ///
        /// This method provides best-effort alignment with ROPES' error code mapping.
        ///
        /// - Parameter code: The gRPC status code to convert
        /// - Returns: The corresponding gateway compute node selection error
        /// - Precondition: The gRPC status code must not be `.ok`
        internal static func fromGRPCCode(_ code: GRPCStatus.Code) throws -> GatewayComputeNodeSelectionError {
            switch code {
            case .ok:
                throw LocalCloudBoardClientError.internalError("GRPCStatus code for error should never be ok")
            case .internalError:
                return .cloudBoardInternalError
            case .resourceExhausted:
                return .cloudBoardResourceExhausted
            default:
                return .cloudBoardUnknownError
            }
        }
    }

    typealias UsageTrackedAppEndpoint = TrackedPool<ComputeCloudAppEndpoint, ComputeCloudAppEndpoint>.Token

    /// Internal compute node selection representation that maps selected endpoints to `UsageTrackedAppEndpoint`s
    enum ProxyInvokeComputeNodeSelection {
        /// Use negotiate/pick protocol: attempt direct reservation of trusted ensembles,
        /// fallback to sending options to proxy for selection
        case pick
        /// Endpoint to talk to, and the workload parameters to use for it (may be edited from the original!)
        case directChoice(UsageTrackedAppEndpoint, workloadParameters: [String: [String]])
        /// Return a specific PCC Gateway error code
        case error(GatewayComputeNodeSelectionError)
    }

    /// Result of extended full control selection - can return either a selected node or an error
    package enum ExtendedSelectionResult: Sendable {
        case pick
        case selected(SelectedComputeNode)
        case error(GatewayComputeNodeSelectionError)
    }

    /// Internal default implementation for simple selection using closures
    struct ClosureBasedSimpleSelector: ComputeNodeSelector {
        private let selector: @Sendable (
            ComputeNodeSelectionContext,
            [ComputeCloudAppEndpoint]
        ) -> ComputeCloudAppEndpoint?

        /// Creates a closure-based simple selector
        ///
        /// - Parameter selector: The closure that will be called to select a compute node
        init(
            _ selector: @escaping @Sendable (
                ComputeNodeSelectionContext,
                [ComputeCloudAppEndpoint]
            ) -> ComputeCloudAppEndpoint?
        ) {
            self.selector = selector
        }

        /// Selects a compute node from the available endpoints
        ///
        /// - Parameters:
        ///   - context: Context information about the request requiring compute node selection
        ///   - availableEndpoints: List of registered compute app endpoints available for selection
        /// - Returns: The selected compute cloud app endpoint, or `nil` if no suitable node is available. If `nil` is
        /// returned, the proxy will receive a `nodesBusy` error.
        func selectNode(
            context: ComputeNodeSelectionContext,
            availableEndpoints: [ComputeCloudAppEndpoint]
        ) -> ComputeCloudAppEndpoint? {
            return self.selector(context, availableEndpoints)
        }
    }

    /// Internal default implementation for full-control selection using closures
    struct ClosureBasedFullControlSelector: FullControlComputeNodeSelector {
        private let selector: @Sendable (
            ComputeNodeSelectionContext,
            [ComputeCloudAppEndpoint]
        ) -> ExtendedSelectionResult?

        /// Creates a closure-based full-control selector
        ///
        /// Full-control selectors can exercise the full negotiation flow with the proxy as well as return errors.
        ///
        /// - Parameter selector: The closure that will be called to select a compute node or return an error
        init(
            _ selector: @escaping @Sendable (
                ComputeNodeSelectionContext,
                [ComputeCloudAppEndpoint]
            ) -> ExtendedSelectionResult?
        ) {
            self.selector = selector
        }

        /// Selects a compute node from the available endpoints or returns an error
        ///
        /// - Parameters:
        ///   - context: Context information about the request requiring compute node selection
        ///   - availableEndpoints: List of registered compute app endpoints available for selection
        /// - Returns: The selection result (either a selected node or an error), or `nil` if no nodes are busy
        func selectNode(
            context: ComputeNodeSelectionContext,
            availableEndpoints: [ComputeCloudAppEndpoint]
        ) -> ExtendedSelectionResult? {
            return self.selector(context, availableEndpoints)
        }
    }

    /// Routing mode for automatic node selection
    public enum AutomaticRoutingMode: Sendable {
        /// Select from all registered compute nodes (using a least busy strategy)
        case fromAllNodes
        /// Filter by service name, then select using a least busy strategy
        case byServiceName
    }

    /// Strategy for how to choose a compute node for outbound PCC calls from proxy nodes
    public enum ComputeNodeSelectionStrategy: Sendable {
        case automatic(routingMode: AutomaticRoutingMode)
        case custom(any ComputeNodeSelector)
        case negotiatePick

        fileprivate static let logger: os.Logger = .init(
            subsystem: "com.apple.cloudos.cloudboard",
            category: "LocalCloudBoardClient.ComputeNodeSelectionStrategy"
        )

        /// Create a custom selection strategy using a closure
        ///
        /// This is a convenience factory method to allow for implementing a compute node selection strategy via
        /// closure.
        ///
        /// - Parameter selector: A closure that selects a compute node from available endpoints
        /// - Returns: A custom selection strategy that is applied on each outbound PCC call from a proxy node
        public static func custom(
            _ selector: @escaping @Sendable (
                ComputeNodeSelectionContext,
                [ComputeCloudAppEndpoint]
            ) -> ComputeCloudAppEndpoint?
        ) -> Self {
            return .custom(ClosureBasedSimpleSelector(selector))
        }

        /// Converts the public `ComputeNodeSelectionStrategy` to the internal
        /// `ExtendedComputeNodeSelectionStrategy` which supports additional capabilities.
        var asExtended: ExtendedComputeNodeSelectionStrategy {
            switch self {
            case .automatic(let routingMode):
                return .automatic(routingMode: routingMode)
            case .custom(let selector):
                return .custom(selector)
            case .negotiatePick:
                return .negotiatePick
            }
        }
    }

    /// Package-private extended strategy with full control capabilities
    package enum ExtendedComputeNodeSelectionStrategy: Sendable {
        case automatic(routingMode: AutomaticRoutingMode)
        case custom(any ComputeNodeSelector)
        case customFullControl(any FullControlComputeNodeSelector)
        /// Directly return a specific error code to the proxy (for testing failure scenarios)
        case returnError(GatewayComputeNodeSelectionError)
        /// Use negotiate pick protocol where gateway offers available ensembles to proxy for selection
        case negotiatePick

        fileprivate static let logger: os.Logger = .init(
            subsystem: "com.apple.cloudos.cloudboard",
            category: "LocalCloudBoardClient.ExtendedComputeNodeSelectionStrategy"
        )

        /// Create a simple selection strategy using a closure
        ///
        /// This package-internal factory method creates a selector that chooses a compute node
        /// but cannot directly return errors (those are handled by the framework).
        ///
        /// - Parameter selector: A closure that selects a compute node from available endpoints
        /// - Returns: A custom extended selection strategy
        package static func custom(
            _ selector: @escaping @Sendable (
                ComputeNodeSelectionContext,
                [ComputeCloudAppEndpoint]
            ) -> ComputeCloudAppEndpoint?
        ) -> Self {
            return .custom(ClosureBasedSimpleSelector(selector))
        }

        /// Create a full-control selection strategy using a closure that can return errors
        ///
        /// This creates a selector with full control over the selection result, including the ability to return
        /// specific error codes directly to the proxy.
        ///
        /// - Parameter selector: A closure that returns either a selected node or an error
        /// - Returns: A custom full-control extended selection strategy
        package static func fullControl(
            _ selector: @escaping @Sendable (
                ComputeNodeSelectionContext,
                [ComputeCloudAppEndpoint]
            ) -> ExtendedSelectionResult?
        ) -> Self {
            return .customFullControl(ClosureBasedFullControlSelector(selector))
        }

        /// Applies the selection strategy to choose a compute node for the request
        ///
        /// This takes the configured strategy and applies it to the pool of available compute nodes, either initiating
        /// a negotiation flow, or returning a selected node with its workload configuration, or an error code to return
        /// to the proxy.
        ///
        /// The method handles several selection modes:
        /// - **Automatic routing**: Selects the least busy node, optionally filtered by service name
        /// - **Custom selection**: Delegates to a custom selector that chooses from available endpoints
        /// - **Full-control selection**: Delegates to a custom selector with full control
        /// - **Error return**: Directly returns a specific error code
        ///
        /// For successful selections, the method also applies conventional ROPES workload manipulation,
        /// which may modify the workload parameters based on reuse constraints.
        ///
        /// - Parameters:
        ///   - computePool: The tracked pool of compute endpoints to select from
        ///   - context: Context information about the request requiring compute node selection
        ///   - serviceDiscovery: Optional service discovery client for reuse constraint validation
        /// - Returns: A proxy invoke compute node selection result (either a node choice or an error)
        /// - Throws: If the pool operations fail or if conventional ROPES workload manipulation fails
        func apply(
            to computePool: TrackedPool<ComputeCloudAppEndpoint, ComputeCloudAppEndpoint>,
            context: ComputeNodeSelectionContext,
            serviceDiscovery: ServiceDiscoveryAbstraction.ConsumerClientProtocol?
        ) throws -> ProxyInvokeComputeNodeSelection {
            switch self {
            case .returnError(let errorCode):
                return .error(errorCode)
            case .negotiatePick:
                return .pick
            case .automatic(let routingMode):
                // This is *not* enforcement, it's best effort distribution
                // ROPES is inherently reactive for this (as another ROPES instance might grab the PCC node)
                // it self heals, by trying another (or giving up and letting the client know).
                //
                // Currently the local framework entirely ignores any of that - we keep it simple but do our best
                // to distribute evenly as, in the realistic case (max one request per node) then doing this will
                // behave reasonably if the consumer of the framework has configured the maximum concurrent requests
                // to match the available workers

                let choice: UsageTrackedAppEndpoint
                switch routingMode {
                case .fromAllNodes:
                    // Select from all registered compute nodes
                    choice = try computePool.useLeastBusy()
                case .byServiceName:
                    // Filter by service name, then select least busy
                    let requestedServiceName = context.initiate.serviceName
                    let matchingEndpoints = computePool.allValues.filter { endpoint in
                        endpoint.serviceName == requestedServiceName
                    }

                    guard !matchingEndpoints.isEmpty else {
                        Self.logger
                            .log("No compute nodes found with serviceName '\(requestedServiceName, privacy: .public)'")
                        return .error(.unknownWorkload)
                    }

                    // Find the least busy among matching endpoints
                    choice = try computePool.useLeastBusyFrom(matchingEndpoints)
                }

                let workload = try applyConventionalROPESWorkloadManipulation(
                    context: context,
                    serviceDiscovery: serviceDiscovery
                )
                return .directChoice(choice, workloadParameters: workload)
            case .custom(let selector):
                // Extract registered endpoints from pool
                let availableEndpoints = computePool.allValues

                guard let endpoint = selector.selectNode(
                    context: context,
                    availableEndpoints: availableEndpoints
                ) else {
                    return .error(.nodesBusy)
                }

                let choice: UsageTrackedAppEndpoint
                do {
                    choice = try computePool.useSpecific(endpoint)
                } catch let error as TrackedPoolError {
                    switch error {
                    case .keyNotFound(let choice):
                        throw LocalCloudBoardClientError.internalError(
                            "The worker choice function selected \(choice) but that is not a valid worker"
                        )
                    default:
                        throw LocalCloudBoardClientError.internalError("Unexpected error \(error)")
                    }
                } catch {
                    throw LocalCloudBoardClientError.internalError("Unexpected error \(error)")
                }
                let workload = try self.applyConventionalROPESWorkloadManipulation(
                    context: context,
                    serviceDiscovery: serviceDiscovery
                )
                return .directChoice(choice, workloadParameters: workload)
            case .customFullControl(let selector):
                // Extract registered endpoints from pool
                let availableEndpoints = computePool.allValues
                guard let selectionResult = selector.selectNode(
                    context: context,
                    availableEndpoints: availableEndpoints
                ) else {
                    return .error(.nodesBusy)
                }

                switch selectionResult {
                case .pick:
                    return .pick
                case .selected(let selection):
                    do {
                        let client = try computePool.useSpecific(selection.endpoint)
                        return .directChoice(client, workloadParameters: selection.computeNodeWorkload)
                    } catch let error as TrackedPoolError {
                        switch error {
                        case .keyNotFound(let choice):
                            throw LocalCloudBoardClientError.internalError(
                                "The worker choice function selected \(choice) but that is not a valid worker"
                            )
                        default:
                            throw LocalCloudBoardClientError.internalError("Unexpected error \(error)")
                        }
                    } catch {
                        throw LocalCloudBoardClientError.internalError("Unexpected error \(error)")
                    }
                case .error(let error):
                    return .error(error)
                }
            }
        }

        /// Applies conventional ROPES workload parameter manipulation based on reuse constraints
        ///
        /// This method replicates the logic in ROPES where workload parameters are transformed based on
        /// reuse requirements. The logic is deliberately *not* application-specific (e.g., it doesn't inject
        /// run mode for split FT/ET), only generalized transformations that would be expected to always apply.
        ///
        /// When reuse constraints are present in the request, this method:
        /// 1. Checks if the target ensemble is viable (exists, matches boot ID)
        /// 2. If viable, merges the reuse workload additions into the base workload parameters
        /// 3. If not viable or forced to fail, leaves the workload parameters unchanged
        ///
        /// The viability check uses service discovery to verify that the target ensemble exists and matches
        /// the expected boot ID. If service discovery is not available, reuse is simply assumed to work
        /// (this is the happy path for testing).
        ///
        /// - Parameters:
        ///   - context: Context information about the request, including reuse constraints
        ///   - serviceDiscovery: Optional service discovery client for validating reuse targets
        /// - Returns: The workload parameters, potentially modified with reuse additions
        /// - Throws: If service discovery snapshot fails or if there's a conflict in workload parameters
        func applyConventionalROPESWorkloadManipulation(
            context: ComputeNodeSelectionContext,
            serviceDiscovery: ServiceDiscoveryAbstraction.ConsumerClientProtocol?
        ) throws -> [String: [String]] {
            var workloadParameters = context.initiate.workloadParameters
            if let reuseConstraints = context.initiate.reuseConstraints {
                var reuseConsideredViable = false
                if reuseConstraints.forceReuseFailure {
                    Self.logger.log("reuse target \(reuseConstraints, privacy: .public) is forced to be unviable")
                } else if let sd = serviceDiscovery {
                    let snapshot = try sd.snapshot()
                    if let target = snapshot.values
                        .first(where: { $0.ensembleId == reuseConstraints.ensembleID }) {
                        if target.bootId == reuseConstraints.bootID {
                            Self.logger.log("reuse target \(reuseConstraints, privacy: .public) is present")
                        } else {
                            Self.logger.log("reuse target \(reuseConstraints, privacy: .public) bootId does not match")
                        }
                    } else {
                        Self.logger.log("reuse target \(reuseConstraints, privacy: .public) is not present")
                    }
                    // we don't care about the rack (yet) - nothing is currently enforcing the negotiate cycle
                } else {
                    // We convert the choice decisions into the simple legal happy path
                    // if consumers want to control this they can use the forceReuseFailure
                    // property directly
                    reuseConsideredViable = true
                    Self.logger.log("reuse simply assumed to work")
                }
                if reuseConsideredViable {
                    workloadParameters = try workloadParameters.merging(reuseConstraints.workloadAdditions) { a, b in
                        // ROPES would cause a grpc error, we aren't interested in testing this
                        // as we should always prevent it happening
                        throw LocalCloudBoardClientError
                            .internalError("attempt to override via reuse workload \(a) vs \(b)")
                    }
                }
            }
            return workloadParameters
        }
    }
}
