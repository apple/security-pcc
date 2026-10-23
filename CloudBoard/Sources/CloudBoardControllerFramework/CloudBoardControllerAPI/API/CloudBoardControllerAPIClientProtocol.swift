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

// Message for CloudBoard to configure controller
public struct WorkloadProperties: Codable, CustomStringConvertible, Sendable {
    public var workloadName: String
    public var cloudAppName: String

    public init(workloadName: String, cloudAppName: String) {
        self.workloadName = workloadName
        self.cloudAppName = cloudAppName
    }

    public var description: String {
        """
        \(String(describing: Self.self))(\
        workloadName: \(self.workloadName), \
        cloudAppName: \(self.cloudAppName))
        """
    }
}

/// Internal workload configuration type that can carry information about either compute or proxy workloads across XPC
/// boundaries
package enum InternalWorkloadConfig: Codable, CustomStringConvertible, Sendable {
    case compute(ComputeWorkloadConfig)
    case proxy(ProxyWorkloadConfig)
    case persistentService(PersistentServiceConfig)

    public var description: String {
        switch self {
        case .compute(let computeWorkloadConfig):
            return """
            compute(
            \(computeWorkloadConfig)
            )
            """
        case .proxy(let proxyWorkloadConfig):
            return """
            proxy(
            \(proxyWorkloadConfig)
            )
            """
        case .persistentService(let workloadConfig):
            return """
            persistentService(
            \(workloadConfig)
            )
            """
        }
    }

    package var maxBatchSize: Int {
        switch self {
        case .compute(let config): config.maxBatchSize
        case .proxy(let config): config.maxBatchSize
        case .persistentService: 0
        }
    }

    package var currentBatchSize: Int {
        switch self {
        case .compute(let config): config.currentBatchSize
        case .proxy(let config): config.currentBatchSize
        case .persistentService: 0
        }
    }

    package var optimalBatchSize: Int {
        switch self {
        case .compute(let config): config.optimalBatchSize
        case .proxy(let config): config.optimalBatchSize
        case .persistentService: 0
        }
    }
}

// Message for Ropes/ServiceDiscovery
@available(
    *,
    deprecated,
    message: "Use ComputeWorkloadConfig with registerComputeWorkload or ProxyWorkloadConfig with registerProxyWorkload instead"
)
public struct WorkloadConfig: Codable, CustomStringConvertible, Sendable {
    public enum WorkloadType: Codable, Sendable {
        case worker
        case proxy
    }

    public enum RoutingTagValue: Codable, CustomStringConvertible, Sendable, Equatable, Hashable {
        case string(String)
        case stringList([String])

        public var description: String {
            switch self {
            case .string(let stringValue):
                return stringValue
            case .stringList(let stringValues):
                return "[" + stringValues.joined(separator: ", ") + "]"
            }
        }
    }

    public var workloadType: WorkloadType
    public var maxBatchSize: Int
    public var optimalBatchSize: Int
    public var currentBatchSize: Int

    @available(*, deprecated, renamed: "workloadTags")
    public var routingTags: [String: [String]] {
        get {
            self._tags.mapValues { value in
                switch value {
                case .string(let string):
                    return [string]
                case .stringList(let stringList):
                    return stringList
                }
            }
        }
        set {
            self._tags = newValue.mapValues { .stringList($0) }
        }
    }

    public var workloadTags: [String: RoutingTagValue] {
        get {
            return self._tags
        }
        set {
            self._tags = newValue
        }
    }

    private var _tags: [String: RoutingTagValue]

    @available(*, deprecated, renamed: "init(maxBatchSize:optimalBatchSize:currentBatchSize:workloadTags:)")
    public init(
        maxBatchSize: Int,
        optimalBatchSize: Int,
        currentBatchSize: Int,
        routingTags: [String: [String]]
    ) {
        self.workloadType = .worker
        self._tags = routingTags.mapValues { .stringList($0) }
        self.maxBatchSize = maxBatchSize
        self.optimalBatchSize = optimalBatchSize
        self.currentBatchSize = currentBatchSize
    }

    public init(
        maxBatchSize: Int,
        optimalBatchSize: Int,
        currentBatchSize: Int,
        workloadTags: [String: RoutingTagValue]
    ) {
        self.workloadType = .worker
        self._tags = workloadTags
        self.maxBatchSize = maxBatchSize
        self.optimalBatchSize = optimalBatchSize
        self.currentBatchSize = currentBatchSize
    }

    public init(
        maxBatchSize: Int,
        optimalBatchSize: Int,
        currentBatchSize: Int,
        workloadTags: [String: RoutingTagValue],
        workloadType: WorkloadType
    ) {
        self._tags = workloadTags
        self.maxBatchSize = maxBatchSize
        self.optimalBatchSize = optimalBatchSize
        self.currentBatchSize = currentBatchSize
        self.workloadType = workloadType
    }

    public var description: String {
        """
        \(String(describing: Self.self))(
        maxBatchSize: \(self.maxBatchSize), \
        optimalBatchSize: \(self.optimalBatchSize), \
        currentBatchSize: \(self.currentBatchSize), \
        workloadType: \(self.workloadType), \
        workloadTags: \(self._tags))
        """
    }
}

public enum RoutingTagValue: Codable, CustomStringConvertible, Sendable, Equatable, Hashable {
    case string(String)
    case stringList([String])

    public var description: String {
        switch self {
        case .string(let stringValue):
            return stringValue
        case .stringList(let stringValues):
            return "[" + stringValues.joined(separator: ", ") + "]"
        }
    }
}

/// Compute workload configuration for ROPES/Service Discovery metadata
public struct ComputeWorkloadConfig: Codable, CustomStringConvertible, Sendable {
    public var maxBatchSize: Int
    public var optimalBatchSize: Int
    public var currentBatchSize: Int
    public var workloadTags: [String: RoutingTagValue]
    public var appRoutingKeys: [String]

    /// Compute node workload configuration
    /// - Parameters:
    ///   - maxBatchSize: Maximum number of concurrent requests the workload supports
    ///   - optimalBatchSize:  Optimal number of concurrent requests the workload supports
    ///   - currentBatchSize: Current  number of concurrent requests the workload is handling
    ///   - workloadTags: Metadata to be announced to Service Discovery under the "workload" field
    ///   - appRoutingKeys: Routing keys to be announced to Service Discovery under the "appRoutingKeys" field
    public init(
        maxBatchSize: Int,
        optimalBatchSize: Int,
        currentBatchSize: Int,
        workloadTags: [String: RoutingTagValue],
        appRoutingKeys: [String]
    ) {
        self.maxBatchSize = maxBatchSize
        self.optimalBatchSize = optimalBatchSize
        self.currentBatchSize = currentBatchSize
        self.workloadTags = workloadTags
        self.appRoutingKeys = appRoutingKeys
    }

    public init(
        maxBatchSize: Int,
        optimalBatchSize: Int,
        currentBatchSize: Int,
        workloadTags: [String: RoutingTagValue]
    ) {
        self.init(
            maxBatchSize: maxBatchSize,
            optimalBatchSize: optimalBatchSize,
            currentBatchSize: currentBatchSize,
            workloadTags: workloadTags,
            appRoutingKeys: []
        )
    }

    public init(
        maxBatchSize: Int,
        optimalBatchSize: Int,
        currentBatchSize: Int,
        appRoutingKeys: [String]
    ) {
        self.init(
            maxBatchSize: maxBatchSize,
            optimalBatchSize: optimalBatchSize,
            currentBatchSize: currentBatchSize,
            workloadTags: [:],
            appRoutingKeys: appRoutingKeys
        )
    }

    public var description: String {
        """
        \(String(describing: Self.self))(
        maxBatchSize: \(self.maxBatchSize), \
        optimalBatchSize: \(self.optimalBatchSize), \
        currentBatchSize: \(self.currentBatchSize), \
        workloadTags: \(self.workloadTags), \
        appRoutingKeys: \(self.appRoutingKeys))
        """
    }
}

/// Proxy workload configuration for ROPES/Service Discovery metadata
public struct ProxyWorkloadConfig: Codable, CustomStringConvertible, Sendable {
    public struct ProxyMetadata: Codable, CustomStringConvertible, Equatable, Sendable {
        /// List of proxied services
        public var services: [String]
        /// Internal-only field to carry workload controller provided routing group aliases for backward compatibility.
        /// Not exposed publicly as RGAs should no longer be managed by workloads themselves. Instead RGAs are
        /// directly read from secure-config by cloudboardd
        package var routingGroupAliasOverrides: [String]?

        /// Metadata to be provided to Service Discovery under the "trusted-proxy" field
        /// - Parameter services: List of proxied services
        public init(services: [String]) {
            self.init(services: services, routingGroupAliasOverrides: nil)
        }

        package init(services: [String], routingGroupAliasOverrides: [String]?) {
            self.services = services
            self.routingGroupAliasOverrides = routingGroupAliasOverrides
        }

        public var description: String {
            """
            \(String(describing: Self.self))(
            services: \(self.services))
            """
        }
    }

    public var maxBatchSize: Int
    public var optimalBatchSize: Int
    public var currentBatchSize: Int
    public var metadata: ProxyMetadata
    public var workloadTags: [String: RoutingTagValue]

    /// Proxy node workload configuration
    /// - Parameters:
    ///   - maxBatchSize: Maximum number of concurrent requests the workload supports
    ///   - optimalBatchSize:  Optimal number of concurrent requests the workload supports
    ///   - currentBatchSize: Current  number of concurrent requests the workload is handling
    ///   - metadata: Metadata to be announced to Service Discovery under the "trusted-proxy" field
    ///   - workloadTags: Metadata to be announced to Service Discovery under the "workload" field
    public init(
        maxBatchSize: Int,
        optimalBatchSize: Int,
        currentBatchSize: Int,
        metadata: ProxyMetadata,
        workloadTags: [String: RoutingTagValue] = [:]
    ) {
        self.maxBatchSize = maxBatchSize
        self.optimalBatchSize = optimalBatchSize
        self.currentBatchSize = currentBatchSize
        self.workloadTags = workloadTags
        self.metadata = metadata
    }

    public var description: String {
        """
        \(String(describing: Self.self))(
        maxBatchSize: \(self.maxBatchSize), \
        optimalBatchSize: \(self.optimalBatchSize), \
        currentBatchSize: \(self.currentBatchSize), \
        metadata: \(self.metadata)), \
        workloadTags: \(self.workloadTags))
        """
    }
}

/// PersistentService configuration for Service Discovery metadata
package struct PersistentServiceConfig: Codable, CustomStringConvertible, Sendable {
    package struct ServiceMetadata: Codable, CustomStringConvertible, Equatable, Sendable {
        /// Optional JSON string of service-defined metadata to publish via SD
        /// This is _untrusted_ so implementations need to provide a HPKE protected path
        /// for the same information
        package var serviceDefinedMetadata: String?

        /// Map of capability-name → per-capability Unit info. Capabilities are the
        /// coarse-grained identity of what a node serves (for trusted-filter
        /// today, the human-readable filterID). The pair `(capability, shardID)`
        /// is the *Unit* that loosely-coupled consumers (cb_bridged, ROPES)
        /// use to ask "how many healthy replicas of this Unit do we have?".
        ///
        /// Unset means "no capabilities advertised" — preserves pre-rollout
        /// behaviour for consumers that fall back to a single implicit unit
        /// per service.
        package var capabilities: [String: CapabilityInfo]?

        /// Per-capability Unit information published alongside the capability name.
        /// The struct exists so future fields (quorum target, revision, etc.)
        /// can land without a wire break.
        package struct CapabilityInfo: Codable, Equatable, Sendable {
            /// Opaque shard identifier for *this* instance's slice of the
            /// capability. Treated as text by consumers; nil or empty means the
            /// capability is unsharded.
            package var shardID: String?

            /// Full set of opaque shard identifiers that make up the capability,
            /// as advertised by *this* instance. Lets a consumer determine
            /// whether it has covered the entire capability (≥1 active replica
            /// per shardID in this set). Nil or empty means the capability is
            /// unsharded (single-replica, the capability itself is the unit).
            ///
            /// Different instances may legitimately advertise different sets
            /// during a rolling reconfiguration — consumers handle divergence
            /// by tracking each distinct configuration independently.
            package var allShardIDs: [String]?

            package init(shardID: String? = nil, allShardIDs: [String]? = nil) {
                self.shardID = shardID
                self.allShardIDs = allShardIDs
            }
        }

        /// Metadata to be provided to Service Discovery
        public init(
            serviceDefinedMetadata: String? = nil,
            capabilities: [String: CapabilityInfo]? = nil
        ) {
            self.serviceDefinedMetadata = serviceDefinedMetadata
            self.capabilities = capabilities
        }

        public var description: String {
            """
            \(String(describing: Self.self))(
            serviceDefinedMetadata: \(self.serviceDefinedMetadata ?? "nil"),
            capabilities: \(self.capabilities.map { String(describing: $0) } ?? "nil"))
            """
        }
    }

    /// Unique identifier for the persistent service (e.g. "trusted-filter")
    package var serviceId: String
    /// The mach service name used for XPC connections (e.g. "com.apple.cloudos.PrivateFilterController")
    package var machServiceName: String
    package var metadata: ServiceMetadata
    package var workloadTags: [String: RoutingTagValue]

    /// PersistentService configuration
    /// - Parameters:
    ///   - serviceId: Unique identifier for the persistent service
    ///   - machServiceName: The mach service name for XPC connections to this service's controller
    ///   - metadata: Metadata to be announced to Service Discovery under the "persistent-service" field
    ///   - workloadTags: Metadata to be announced to Service Discovery under the "workload" field
    package init(
        serviceId: String,
        machServiceName: String,
        metadata: ServiceMetadata,
        workloadTags: [String: RoutingTagValue] = [:]
    ) {
        self.serviceId = serviceId
        self.machServiceName = machServiceName
        self.workloadTags = workloadTags
        self.metadata = metadata
    }

    package var description: String {
        """
        \(String(describing: Self.self))(
        serviceId: \(self.serviceId), \
        machServiceName: \(self.machServiceName), \
        metadata: \(self.metadata)), \
        workloadTags: \(self.workloadTags))
        """
    }
}

public enum WorkloadControllerState: Codable, CustomStringConvertible, Sendable {
    case initializing
    case ready
    case busy
    /// Allows for providing a reason for the busy state. Must be a low-cardinality value.
    case busyWithReason(String)
    case error(message: String?)

    public var description: String {
        switch self {
        case .initializing:
            return "Initializing"
        case .ready:
            return "Ready"
        case .busy:
            return "Busy"
        case .busyWithReason(let reason):
            return "Busy (\(reason))"
        case .error(let message):
            if let message {
                return "Error: \(message)"
            } else {
                return "Error"
            }
        }
    }
}

extension WorkloadControllerState: Equatable {}

extension WorkloadControllerState: Hashable {}

public struct WorkloadControllerStatus: Codable, CustomStringConvertible, Sendable {
    public var state: WorkloadControllerState

    public init(state: WorkloadControllerState) {
        self.state = state
    }

    public var description: String {
        "\(String(describing: Self.self))(state: \(self.state))"
    }
}

package protocol CloudBoardControllerAPIClientToServerProtocol: Actor {
    func registerWorkload(config: InternalWorkloadConfig, properties: WorkloadProperties) async throws
    func updateHealthStatus(status: WorkloadControllerStatus) async throws
    func restartPrewarmedInstances() async throws
    /// Reports that the persistent service identified by `serviceId` has failed terminally and cannot recover
    /// without external re-convergence. Routed by `serviceId` (not connection identifier) so it works even when
    /// the failure happens before the service ever registered a workload.
    func reportPersistentServiceTerminalFailure(serviceId: String, reason: String) async throws
}

package protocol CloudBoardControllerAPIClientDelegateProtocol:
AnyObject, Sendable, CloudBoardControllerAPIServerToClientProtocol {
    func disconnected() async
}

package protocol CloudBoardControllerAPIClientProtocol:
CloudBoardControllerAPIClientToServerProtocol {
    func connect(delegate: CloudBoardControllerAPIClientDelegateProtocol) async
}
