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

// Gateway configuration and worker selection
import Foundation

// MARK: - Compute Node Selection Protocols

// Namespaced to PCCHarness
extension PCCHarness {
    /// Protocol for compute node selection
    public protocol ComputeNodeSelector: Sendable {
        /// Selects a compute node from a set of available endpoints
        /// - Parameters:
        ///   - context: Context about the original request from the client to the proxy as well as the request from the
        ///   proxy
        ///   - availableEndpoints: All known compute node endpoints previously registered with the PCC Gateway
        /// - Returns: The selected compute node endpoint. If `nil` is returned, the proxy will receive a `nodeBusy`
        /// error
        func selectNode(
            context: ComputeNodeSelectionContext,
            availableEndpoints: [ComputeCloudAppEndpoint]
        ) -> ComputeCloudAppEndpoint?
    }

    /// Package-private protocol for full-control node selection that supports full negotiation between PCC Gateway and
    /// CloudBoard, as well as returning PCC Gateway errors
    package protocol FullControlComputeNodeSelector: Sendable {
        func selectNode(
            context: ComputeNodeSelectionContext,
            availableEndpoints: [ComputeCloudAppEndpoint]
        ) -> ExtendedSelectionResult?
    }

    package struct ComputeNodeSelectorCallback: ComputeNodeSelector {
        private let select: @Sendable (PCCHarness.ComputeNodeSelectionContext, [PCCHarness.ComputeCloudAppEndpoint])
            -> PCCHarness.ComputeCloudAppEndpoint?

        package init(
            select: @Sendable @escaping (PCCHarness.ComputeNodeSelectionContext, [PCCHarness.ComputeCloudAppEndpoint])
                -> PCCHarness.ComputeCloudAppEndpoint?
        ) {
            self.select = select
        }

        package func selectNode(
            context: PCCHarness.ComputeNodeSelectionContext,
            availableEndpoints: [PCCHarness.ComputeCloudAppEndpoint]
        ) -> PCCHarness.ComputeCloudAppEndpoint? {
            return self.select(context, availableEndpoints)
        }
    }
}

// MARK: - Gateway Configuration

// Namespaced to PCCHarness
extension PCCHarness {
    /// Configuration for the simulated PCC Gateway
    public struct PCCGatewayConfig: Sendable {
        /// Whether to use TLS for CloudBoard connections (default: false for testing)
        package var useTLS: Bool
        /// Internal storage using extended strategy
        package var extendedComputeNodeSelectionStrategy: ExtendedComputeNodeSelectionStrategy
        /// Optional service discovery for validating reuse constraints
        package var serviceDiscovery: ServiceDiscoveryAbstraction.ConsumerClientProtocol?
        /// Configuration for injecting ensemble selections during negotiate/pick for tests
        public var injectedEnsembleSelectionConfig: InjectedEnsembleSelectionConfig?
        /// Factor by which the simulated ROPES tries to scale the announced pick ratio during
        /// negotiate/pick. Clamped to the proxy-announced `ratioCanScaleTo` and to available
        /// candidates. Defaults to 1 (no scaling), preserving historical behaviour.
        package var negotiatePickDesiredScale: UInt32 = 1

        /// Public accessor that hides the extended strategy details
        public var computeNodeSelectionStrategy: ComputeNodeSelectionStrategy {
            get {
                switch self.extendedComputeNodeSelectionStrategy {
                case .automatic(let routingMode):
                    return .automatic(routingMode: routingMode)
                case .custom(let selector):
                    return .custom(selector)
                case .customFullControl:
                    // Full control strategies are not exposed publicly
                    fatalError("Full control strategies are not publicly accessible")
                case .negotiatePick:
                    return .negotiatePick
                case .returnError:
                    // Error return strategies are not exposed publicly
                    fatalError("Error return strategies are not publicly accessible")
                }
            }
            set {
                self.extendedComputeNodeSelectionStrategy = newValue.asExtended
            }
        }

        public init(
            computeNodeSelectionStrategy: ComputeNodeSelectionStrategy = .automatic(routingMode: .fromAllNodes),
            useTLS: Bool = true
        ) {
            self = .init(
                extendedComputeNodeSelectionStrategy: computeNodeSelectionStrategy.asExtended,
                useTLS: useTLS,
                serviceDiscovery: nil
            )
        }

        /// Package-internal initializer that accepts extended strategy
        package init(
            extendedComputeNodeSelectionStrategy: ExtendedComputeNodeSelectionStrategy,
            useTLS: Bool = true,
            serviceDiscovery: ServiceDiscoveryAbstraction.ConsumerClientProtocol? = nil
        ) {
            self.extendedComputeNodeSelectionStrategy = extendedComputeNodeSelectionStrategy
            self.useTLS = useTLS
            self.serviceDiscovery = serviceDiscovery
        }
    }

    /// This provides full control of the "ROPES simulation" path as to whether the selection
    /// is considered to be a reuse or not.
    public struct SelectedComputeNode: Sendable {
        public var endpoint: ComputeCloudAppEndpoint
        public var computeNodeWorkload: [String: [String]]

        public init(
            endpoint: ComputeCloudAppEndpoint,
            computeNodeWorkload: [String: [String]]
        ) {
            self.endpoint = endpoint
            self.computeNodeWorkload = computeNodeWorkload
        }
    }

    /// Simplified subset of InvokeProxyInitiate.NegotiateEnsembleChoice
    package struct NegotiateEnsembleChoice {
        var freeChoice: Bool
        var trustedEnsembles: [EnsembleInstanceId]
        var trustedRackIds: [String]

        init(proto: Com_Apple_Cloudboard_Api_V1_InvokeProxyInitiate.NegotiateEnsembleChoice) {
            self.freeChoice = proto.freeChoice
            self.trustedEnsembles = proto.trustedEnsembles.map { .init(from: $0) }
            self.trustedRackIds = proto.trustedRackIds
        }
    }

    /// Simplified subset of InvokeProxyInitiate.ReuseConstraints
    /// Note: This is package only this till it's more stable
    package struct ReuseConstraints: Sendable, CustomStringConvertible {
        // note: naming convention matches the protos! ID not Id
        package var ensembleID: String
        package var bootID: String
        package var rackID: String?
        package var workloadAdditions: [String: [String]]

        /// local cloudboard client concept allowing explicit control of whether the reuse
        /// is considered to be viable - remember this doesn't mean you have to *send the Initiate to
        /// that endpoint* just that the target is "present" (no restarted and registered with SD)
        package var forceReuseFailure: Bool

        // only the normal parts that were in the proto included
        package var description: String {
            "ensembleID: \(self.ensembleID) bootID: \(self.bootID) rackID: \(self.rackID ?? "nil") workloadAdditions: \(self.workloadAdditions)"
        }

        internal init(
            proto: Com_Apple_Cloudboard_Api_V1_InvokeProxyInitiate.ReuseConstraints,
            forceReuseFailure: Bool
        ) {
            self.ensembleID = proto.ensemble.ensembleID
            self.bootID = proto.ensemble.bootID
            self.rackID = proto.hasRackID ? proto.rackID : nil
            self.workloadAdditions = proto.workloadAdditions.param.asMap()
            self.forceReuseFailure = forceReuseFailure
        }
    }

    /// Information for compute node selection
    public struct ComputeNodeSelectionContext: Sendable {
        /// Metadata provided by the proxy for the outbound compute node request
        public struct InvokeProxyInitiate: Sendable {
            /// Unique identifier, in the context of the client request, for the outbound request
            public var taskID: String
            /// Group ID that must be unique across outbound requests, unless two requests are associated with the same
            /// computation, e.g. the same inference (FT/ET split) in which case the group ID must be the same in both
            /// requests
            public var groupID: String
            /// Service name identifying the requested compute service type
            public var serviceName: String
            /// Workload parameters that can be taken into account when making a routing decision and that will be
            /// forwarded to the compute node (but might be transformed by the PCC Gateway in certain circumstances)
            public var workloadParameters: [String: [String]]
            /// Whether the request is discardable, i.e. whether it can be rejected by the PCC Gateway under high load
            /// to save capacity for higher priority requests
            public var isDiscardable: Bool

            /// Additional routing constraints related to reuse of previously trusted nodes
            package var reuseConstraints: ReuseConstraints?
            /// Rules on how to select ensembles for trust reasons
            /// This is for information purposes only, the point of this code is to be able to violate
            /// those terms to test the protections within the system
            package var negotiate: NegotiateEnsembleChoice?

            init(
                taskID: String,
                groupID: String,
                serviceName: String,
                workloadParameters: [String: [String]],
                isDiscardable: Bool,
                reuseConstraints: ReuseConstraints?,
                negotiate: NegotiateEnsembleChoice?
            ) {
                self.taskID = taskID
                self.groupID = groupID
                self.serviceName = serviceName
                self.workloadParameters = workloadParameters
                self.isDiscardable = isDiscardable
                self.reuseConstraints = reuseConstraints
                self.negotiate = negotiate
            }
        }

        /// Original client-provided request context
        public var originalRequestContext: RequestContext
        /// Proxy-provided metadata for the outbound compute request
        public var initiate: InvokeProxyInitiate

        init(originalRequestContext: RequestContext, initiate: InvokeProxyInitiate) {
            self.originalRequestContext = originalRequestContext
            self.initiate = initiate
        }
    }
}

// MARK: - Message Observers

extension PCCHarness {
    /// Observer for InvokeWorkload messages with a specific endpoint
    package struct InvokeWorkloadMessageObserver: Sendable {
        /// Called when gateway sends a message to node (InvokeWorkloadRequest)
        package let onRequestToNode: @Sendable (ObservedInvokeWorkloadRequest) -> Void

        /// Called when gateway receives a message from node (InvokeWorkloadResponse)
        package let onResponseFromNode: @Sendable (ObservedInvokeWorkloadResponse) -> Void

        package init(
            onRequestToNode: @escaping @Sendable (ObservedInvokeWorkloadRequest) -> Void = { _ in },
            onResponseFromNode: @escaping @Sendable (ObservedInvokeWorkloadResponse) -> Void = { _ in }
        ) {
            self.onRequestToNode = onRequestToNode
            self.onResponseFromNode = onResponseFromNode
        }
    }

    package enum ObserverAction {
        /// just pass the message along
        case passthrough
        /// Drop the message entirely - this is only reasonable for specific subsets of messages
        /// but it can be a means to cause some tests to take a specific path that would otherwise be
        /// dependent on timing considerations
        case drop
    }

    /// Observer for InvokeProxyDialBack messages with a specific proxy node
    package struct ProxyDialBackMessageObserver: Sendable {
        /// Called when gateway sends message to proxy (InvokeProxyDialBackRequest)
        package let onRequestToProxy: @Sendable (ObservedInvokeProxyDialBackRequest) -> Void

        /// Called when gateway receives message from proxy (InvokeProxyDialBackResponse)
        package let onResponseFromProxy: @Sendable (ObservedInvokeProxyDialBackResponse) -> ObserverAction

        package init(
            onRequestToProxy: @escaping @Sendable (ObservedInvokeProxyDialBackRequest) -> Void = { _ in },
            onResponseFromProxy: @escaping @Sendable (ObservedInvokeProxyDialBackResponse) -> ObserverAction = { _ in
                .passthrough
            }
        ) {
            self.onRequestToProxy = onRequestToProxy
            self.onResponseFromProxy = onResponseFromProxy
        }

        package init(
            onRequestToProxy: @escaping @Sendable (ObservedInvokeProxyDialBackRequest) -> Void = { _ in },
            onResponseFromProxy: @escaping @Sendable (ObservedInvokeProxyDialBackResponse) -> Void
        ) {
            self.onRequestToProxy = onRequestToProxy
            self.onResponseFromProxy = {
                onResponseFromProxy($0)
                return .passthrough
            }
        }
    }
}

// MARK: - Test Injection API

extension PCCHarness {
    /// API for injecting ensemble selection during negotiate/pick
    /// This allows testing negotiation constraint violations
    public struct TestEnsembleInjection: Sendable {
        /// The ensemble ID to inject (may be invalid/untrusted for testing violation paths)
        public let ensembleID: String

        /// The boot ID to inject (may not match trusted boot ID for testing reboot scenarios)
        public let bootID: String

        /// The rack ID to include (may not match trusted rack for testing violations)
        public let rackID: String

        public init(ensembleID: String, bootID: String, rackID: String) {
            self.ensembleID = ensembleID
            self.bootID = bootID
            self.rackID = rackID
        }
    }

    /// Strategy for injecting ensemble selection during negotiate/pick
    public enum EnsembleInjectionStrategy: Sendable {
        /// Inject a specific ensemble
        case specific(TestEnsembleInjection)

        /// Inject any candidate different from what proxy selected
        /// Guarantees mismatch between proxy's selection and gateway's actual use
        case differentFromProxySelection
    }

    /// Configuration for injecting test ensemble selections during negotiate/pick
    public struct InjectedEnsembleSelectionConfig: Sendable {
        /// Strategy for injecting ensemble selection
        public var strategy: EnsembleInjectionStrategy

        /// If true, the injected selection is expected to fail validation
        public var expectValidationFailure: Bool

        public init(
            strategy: EnsembleInjectionStrategy,
            expectValidationFailure: Bool = false
        ) {
            self.strategy = strategy
            self.expectValidationFailure = expectValidationFailure
        }
    }
}
