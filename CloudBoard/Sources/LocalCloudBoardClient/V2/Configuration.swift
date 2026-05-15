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

// Core public types for LocalCloudBoardClient V2
internal import CloudAttestation
import CryptoKit
import Foundation

// Namespaced to PCCHarness
extension PCCHarness {
    // MARK: - Endpoint Types

    /// Represents a proxy or compute app endpoint
    public protocol CloudAppEndpoint: Hashable, Sendable {
        var host: String { get }
        var port: Int { get }
    }

    internal enum CloudAppType: Hashable, Sendable, CustomStringConvertible {
        case compute
        case proxy

        var description: String {
            switch self {
            case .compute: return "compute"
            case .proxy: return "proxy"
            }
        }
    }

    internal protocol InternalAppEndpoint: CloudAppEndpoint {
        var appType: CloudAppType { get }
    }

    /// Represents a compute app endpoint. Cannot directly be initialized but is provided in response to registering
    /// the endpoint with a ``PCCHarness`` using ``registerComputeApp(host:port:serviceName:metadata:)``.
    public struct ComputeCloudAppEndpoint: InternalAppEndpoint {
        var appType: CloudAppType { .compute }

        public let host: String
        public let port: Int
        /// Name of the service served by the endpoint
        public let serviceName: String
        /// Associated service metadata, equivalent to workload metadata in Service Discovery
        public let metadata: [String: [String]]?
        /// Maximum concurrent requests this node can handle, or nil to use the default
        public let maxConcurrentRequests: Int?

        // Internal initializer. Should only be constructed by PCCHarness on endpoint registration to ensure that
        // compute nodes and proxy nodes cannot be mixed up in request invocations.
        internal init(
            host: String,
            port: Int,
            serviceName: String,
            metadata: [String: [String]]?,
            maxConcurrentRequests: Int? = nil
        ) {
            self.host = host
            self.port = port
            self.serviceName = serviceName
            self.metadata = metadata
            self.maxConcurrentRequests = maxConcurrentRequests
        }
    }

    /// Represents a proxy app endpoint. Cannot directly be initialized but is provided in response to registering
    /// the endpoint with a ``PCCHarness`` using ``registerProxyApp(host:port:)``.
    public struct ProxyCloudAppEndpoint: InternalAppEndpoint {
        var appType: CloudAppType { .proxy }

        public let host: String
        public let port: Int

        // Internal initializer. Should only be constructed by PCCHarness on endpoint registration to ensure that
        // compute nodes and proxy nodes cannot be mixed up in request invocations.
        internal init(host: String, port: Int) {
            self.host = host
            self.port = port
        }
    }

    // MARK: - Request Configuration

    /// This represents the information on the InvokeWorkloadRequest which is visible to ROPES
    /// Some of this is driven by the client itself, some would be populated by ROPES.
    /// The analogous type for this at the CloudApp API is `PlainTextMetaData`
    /// and where fields directly map to fields on that type they share identical names for consistency
    /// Where a field is not mapped we should indicate that and why not
    public struct InvokeWorkloadRequestMetadata: Sendable {
        /// Bundle identifier for the client application
        public var bundleID: String?
        /// Version of the client bundle
        public var bundleVersion: String?
        /// Feature identifier for the request
        public var featureID: String?
        /// Additional client information
        public var clientInfo: String?

        /// Passed through all the way to the cloud app
        public var workloadType: String = ""
        /// Passed through all the way to the cloud app
        public var workloadParameters: [String: [String]] = [:]

        /// Metadata associated with the request
        /// - Parameters:
        ///   - bundleID: Bundle identifier, identifying the client application bundle initiating the request
        ///   - bundleVersion: Version of the client application bundle
        ///   - featureID: Feature identifier
        ///   - clientInfo: Version information for the client device
        ///   - workloadType: Requested workload/service type
        ///   - workloadParameters: Additional workload/routing parameters
        public init(
            bundleID: String? = nil,
            bundleVersion: String? = nil,
            featureID: String? = nil,
            clientInfo: String? = nil,
            workloadType: String = "",
            workloadParameters: [String: [String]] = [:]
        ) {
            self.bundleID = bundleID
            self.bundleVersion = bundleVersion
            self.featureID = featureID
            self.clientInfo = clientInfo
            self.workloadType = workloadType
            self.workloadParameters = workloadParameters
        }
    }

    /// Request context including the unique request ID and workload metadata
    public struct RequestContext: Sendable {
        /// Unique request ID used to identify the request in logs. Also transformed to a trace ID for use in tracing.
        public var requestID: UUID
        /// Metadata associated with the request
        public var workloadMetadata: InvokeWorkloadRequestMetadata

        /// Creates a request context object
        /// - Parameters:
        ///   - requestID: Unique request ID. Generated automatically if not provided.
        ///   - workloadMetadata: Metadata associated with the request including workload/service type and
        ///   workload/routing parameters. Can be provided in case the application under test requires specific workload
        ///   parameters.
        public init(requestID: UUID = UUID(), workloadMetadata: InvokeWorkloadRequestMetadata = .init()) {
            self.requestID = requestID
            self.workloadMetadata = workloadMetadata
        }
    }

    /// Encapsulated DEK with associated
    struct EncapsulatedDataEncryptionKey: Sendable {
        var keyID: Data
        var dataEncryptionKey: Data
    }

    /// Internal request context with additional data
    package struct PCCGatewayInvokeWorkloadRequestContext: Sendable {
        internal let baseContext: RequestContext
        internal let perEndpointDataEncryptionKeys: [HostAndPort: EncapsulatedDataEncryptionKey]

        package var requestID: UUID { self.baseContext.requestID }
        package var workloadMetadata: InvokeWorkloadRequestMetadata { self.baseContext.workloadMetadata }

        init(baseContext: RequestContext, perEndpointDataEncryptionKeys: [HostAndPort: EncapsulatedDataEncryptionKey]) {
            self.baseContext = baseContext
            self.perEndpointDataEncryptionKeys = perEndpointDataEncryptionKeys
        }
    }

    /// Configuration for proxy requests
    public struct ProxyRequestConfiguration: Sendable {
        /// File URL to record PCC Gateway to proxy node messages to
        public var recordMessagesTo: URL?
        /// If true, application payload request chunks are buffered by the PCC Gateway and not forwarded to the proxy.
        /// The PCC Gateway directly forwards these request chunks to a compute node once requested by the proxy on the
        /// first outbound request
        public var useRequestBypass: Bool
        /// List of proxy endpoints to send NACK requests to
        public var nackEndpoints: [ProxyCloudAppEndpoint]
        /// Per-NACK-endpoint recording locations. Maps NACK endpoints to file URLs where their messages should be
        /// recorded. This allows users to record messages sent to each NACK endpoint separately, which can then be used
        /// as parametersOverrideURL to replay a request on a proxy node that previously NACK'd a request.
        public var recordNACKMessagesTo: [ProxyCloudAppEndpoint: URL]
        /// Enables chunking and set chunk size
        public var applicationDataChunkingConfiguration: ApplicationDataChunkingConfiguration

        /// Creates a proxy request configuration
        /// - Parameters:
        ///   - recordMessagesTo: If provided, all PCC Gateway to proxy messages are recorded to the provided file, and
        ///   can be reused to replay the request in order to test CloudBoard's anti-replay functionality.
        ///   - useRequestBypass: If true, application payload request chunks are buffered by the PCC Gateway and not
        ///   forwarded to the proxy. The PCC Gateway directly forwards these request chunks to a compute node once
        ///   requested by the proxy on the first outbound request.
        ///   - nackEndpoints: List of proxy endpoints to send NACK requests to.
        ///   - recordNACKMessagesTo: Optional per-NACK-endpoint recording locations. Maps NACK endpoints to file URLs
        ///   where their messages should be recorded. NACK endpoints not in this dictionary will not have their
        /// messages recorded.
        public init(
            recordMessagesTo: URL? = nil,
            useRequestBypass: Bool = false,
            nackEndpoints: [ProxyCloudAppEndpoint] = [],
            recordNACKMessagesTo: [ProxyCloudAppEndpoint: URL] = [:]
        ) {
            self.init(
                recordMessagesTo: recordMessagesTo,
                useRequestBypass: useRequestBypass,
                nackEndpoints: nackEndpoints,
                recordNACKMessagesTo: recordNACKMessagesTo,
                applicationDataChunkingConfiguration: .disabled
            )
        }

        /// Creates a proxy request configuration
        /// - Parameters:
        ///   - recordMessagesTo: If provided, all PCC Gateway to proxy messages are recorded to the provided file, and
        ///   can be reused to replay the request in order to test CloudBoard's anti-replay functionality.
        ///   - useRequestBypass: If true, application payload request chunks are buffered by the PCC Gateway and not
        ///   forwarded to the proxy. The PCC Gateway directly forwards these request chunks to a compute node once
        ///   requested by the proxy on the first outbound request.
        ///   - nackEndpoints: List of proxy endpoints to send NACK requests to.
        ///   - recordNACKMessagesTo: Optional per-NACK-endpoint recording locations. Maps NACK endpoints to file URLs
        ///   where their messages should be recorded. NACK endpoints not in this dictionary will not have their
        /// messages recorded.
        ///   - applicationDataChunkingConfiguration: Enables chunking and set chunk size
        public init(
            recordMessagesTo: URL? = nil,
            useRequestBypass: Bool = false,
            nackEndpoints: [ProxyCloudAppEndpoint] = [],
            recordNACKMessagesTo: [ProxyCloudAppEndpoint: URL] = [:],
            applicationDataChunkingConfiguration: ApplicationDataChunkingConfiguration = .disabled
        ) {
            self.useRequestBypass = useRequestBypass
            self.nackEndpoints = nackEndpoints
            self.recordMessagesTo = recordMessagesTo
            self.recordNACKMessagesTo = recordNACKMessagesTo
            self.applicationDataChunkingConfiguration = applicationDataChunkingConfiguration
        }
    }

    /// Configuration for compute requests
    public struct ComputeRequestConfiguration: Sendable {
        /// File URL to record PCC Gateway to compute node messages to
        public var recordMessagesTo: URL?
        /// Optional static Data Encryption Key that is going to be used for requests. By default, LocalCloudBoardClient
        /// generates an ephemeral key for every request.
        public var forcedDataEncryptionKey: SymmetricKey?
        /// Optional crypto material, sent to the node at the PCC protocol layer
        public var cryptoMaterial: [CryptoMaterial]?

        package var responseBypassMode: ResponseBypassMode
        package var useProxyInvokeOpen: Bool
        /// Enables chunking and set chunk size
        package var applicationDataChunkingConfiguration: ApplicationDataChunkingConfiguration

        /// Creates a compute request configuration
        /// - Parameters:
        ///   - recordMessagesTo: If provided, all PCC Gateway to compute messages are recorded to the provided file,
        ///   and can be reused to replay the request in order to test CloudBoard's anti-replay functionality.
        ///   - forcedDataEncryptionKey: Optional static Data Encryption Key that is going to be used for requests. If
        ///   not provided, LocalCloudBoardClient generates an ephemeral key for every request.
        ///   - cryptoMaterial: Optional crypto material, sent to the node at the PCC protocol layer
        public init(
            recordMessagesTo: URL? = nil,
            forcedDataEncryptionKey: SymmetricKey? = nil,
            cryptoMaterial: [CryptoMaterial]? = nil
        ) {
            self.init(
                recordMessagesTo: recordMessagesTo,
                forcedDataEncryptionKey: forcedDataEncryptionKey,
                cryptoMaterial: cryptoMaterial,
                responseBypassMode: .none,
                useProxyInvokeOpen: false
            )
        }

        package init(
            recordMessagesTo: URL? = nil,
            forcedDataEncryptionKey: SymmetricKey? = nil,
            cryptoMaterial: [CryptoMaterial]? = nil,
            responseBypassMode: ResponseBypassMode = .none,
            useProxyInvokeOpen: Bool = false
        ) {
            self.init(
                recordMessagesTo: recordMessagesTo,
                forcedDataEncryptionKey: forcedDataEncryptionKey,
                cryptoMaterial: cryptoMaterial,
                responseBypassMode: responseBypassMode,
                useProxyInvokeOpen: useProxyInvokeOpen,
                applicationDataChunkingConfiguration: .disabled
            )
        }

        package init(
            recordMessagesTo: URL? = nil,
            forcedDataEncryptionKey: SymmetricKey? = nil,
            cryptoMaterial: [CryptoMaterial]? = nil,
            responseBypassMode: ResponseBypassMode = .none,
            useProxyInvokeOpen: Bool = false,
            applicationDataChunkingConfiguration: ApplicationDataChunkingConfiguration = .disabled
        ) {
            self.recordMessagesTo = recordMessagesTo
            self.forcedDataEncryptionKey = forcedDataEncryptionKey
            self.cryptoMaterial = cryptoMaterial
            self.responseBypassMode = responseBypassMode
            self.useProxyInvokeOpen = useProxyInvokeOpen
            self.applicationDataChunkingConfiguration = applicationDataChunkingConfiguration
        }
    }

    // MARK: - Persistent Connection Configuration

    /// Configuration for persistent connections
    public struct PersistentConnectionConfiguration: Sendable {
        /// File URL to record PCC Gateway to proxy node messages to
        public var recordMessagesTo: URL?
        /// List of proxy endpoints to send NACK requests to
        public var nackEndpoints: [ProxyCloudAppEndpoint]
        /// Per-NACK-endpoint recording locations. Maps NACK endpoints to file URLs where their messages should be
        /// recorded. This allows users to record messages sent to each NACK endpoint separately, which can then be used
        /// as parametersOverrideURL to replay a request on a proxy node that previously NACK'd a request.
        public var recordNACKMessagesTo: [ProxyCloudAppEndpoint: URL]
        /// Enables chunking and set chunk size
        public var applicationDataChunkingConfiguration: ApplicationDataChunkingConfiguration

        /// Creates a configuration for persistent connections to a proxy node.
        /// - Parameters:
        ///   - recordMessagesTo: If provided, all PCC Gateway to proxy messages are recorded to the provided file, and
        ///   can be reused to replay the request in order to test CloudBoard's anti-replay functionality.
        ///   - nackEndpoints: List of proxy endpoints to send NACK requests to.
        ///   - recordNACKMessagesTo: Optional per-NACK-endpoint recording locations. Maps NACK endpoints to file URLs
        ///   where their messages should be recorded. NACK endpoints not in this dictionary will not have their
        /// messages recorded.
        public init(
            recordMessagesTo: URL? = nil,
            nackEndpoints: [ProxyCloudAppEndpoint] = [],
            recordNACKMessagesTo: [ProxyCloudAppEndpoint: URL] = [:]
        ) {
            self.init(
                recordMessagesTo: recordMessagesTo,
                nackEndpoints: nackEndpoints,
                recordNACKMessagesTo: recordNACKMessagesTo,
                applicationDataChunkingConfiguration: .disabled
            )
        }

        /// Creates a configuration for persistent connections to a proxy node.
        /// - Parameters:
        ///   - recordMessagesTo: If provided, all PCC Gateway to proxy messages are recorded to the provided file, and
        ///   can be reused to replay the request in order to test CloudBoard's anti-replay functionality.
        ///   - nackEndpoints: List of proxy endpoints to send NACK requests to.
        ///   - recordNACKMessagesTo: Optional per-NACK-endpoint recording locations. Maps NACK endpoints to file URLs
        ///   where their messages should be recorded. NACK endpoints not in this dictionary will not have their
        /// messages recorded.
        ///   - applicationDataChunkingConfiguration: Enables chunking and set chunk size
        public init(
            recordMessagesTo: URL? = nil,
            nackEndpoints: [ProxyCloudAppEndpoint] = [],
            recordNACKMessagesTo: [ProxyCloudAppEndpoint: URL] = [:],
            applicationDataChunkingConfiguration: ApplicationDataChunkingConfiguration = .disabled
        ) {
            self.recordMessagesTo = recordMessagesTo
            self.nackEndpoints = nackEndpoints
            self.recordNACKMessagesTo = recordNACKMessagesTo
            self.applicationDataChunkingConfiguration = applicationDataChunkingConfiguration
        }
    }

    /// Configuration for subrequests within a persistent connection to proxy nodes
    public struct SubrequestConfiguration: Sendable {
        /// Subrequest metadata, such as associated crypto material
        public var metadata: SubrequestMetadata

        /// Creates a configuration for subrequests within a persistent connection to a proxy node
        /// - Parameter metadata: Metadata for the subrequest, such as associated crypto material
        public init(metadata: SubrequestMetadata) {
            self.metadata = metadata
        }
    }

    /// Crypto material than can be sent alongside a subrequest
    public struct CryptoMaterial: Sendable {
        /// Identifies the crypto material. This is made visible to compute/proxy cloud apps.
        public let id: String
        /// Crypto material, only accessible to support apps on the PCC node
        public let material: Data

        /// Creates crypto material that can be sent alongside a subrequest
        /// - Parameters:
        ///   - id: Identifier for the crypto material. This is made visible to compute/proxy cloud apps.
        ///   - material: Crypto material, only accessible to support apps on the PCC node
        public init(id: String, material: Data) {
            self.id = id
            self.material = material
        }
    }

    /// Execution priority for subrequests
    public enum SubrequestExecutionPriority: Sendable {
        /// Default/unspecified priority
        case unspecified
        /// Request may be discarded by the PCC Gateway, for example due to high utilization
        case discardable
    }

    /// Metadata for subrequests
    public struct SubrequestMetadata: Sendable {
        /// Priority of the subrequest
        public let priority: SubrequestExecutionPriority
        /// Associated crypto material
        public let cryptoMaterial: [CryptoMaterial]

        /// Creates subrequest metadata
        /// - Parameters:
        ///   - priority: Priority of the subrequest, e.g. whether it is discardable
        ///   - cryptoMaterial: Crypto material associated with the subrequest. Is only made available to support apps
        ///   on the PCC node.
        public init(priority: SubrequestExecutionPriority = .unspecified, cryptoMaterial: [CryptoMaterial] = []) {
            self.priority = priority
            self.cryptoMaterial = cryptoMaterial
        }
    }

    // MARK: - Replay Configuration

    /// Configuration for replaying recorded requests
    public struct ReplayConfiguration: Sendable {
        public let messagesFileURL: URL
        public let parametersOverrideURL: URL?
        public let requestIDOverride: String?
        public let requestBypassOverride: Bool?
        public let metadataOverride: InvokeWorkloadRequestMetadata?

        public init(
            messagesFileURL: URL,
            parametersOverrideURL: URL? = nil,
            requestIDOverride: String? = nil,
            requestBypassOverride: Bool? = nil,
            metadataOverride: InvokeWorkloadRequestMetadata? = nil
        ) {
            self.messagesFileURL = messagesFileURL
            self.parametersOverrideURL = parametersOverrideURL
            self.requestIDOverride = requestIDOverride
            self.requestBypassOverride = requestBypassOverride
            self.metadataOverride = metadataOverride
        }
    }

    // MARK: - Environment Options

    /// Attestation environment for CloudAttestation validation
    public enum AttestationEnvironment: Sendable {
        case dev
        case ephemeral
        case perf
        case quarantine
        case qa
        case staging
        case uat
        case carry
        case liveon
        case production
        case qa2Primary
        case qa2Internal

        internal var toInternal: CloudAttestation.Environment {
            switch self {
            case .dev: return .dev
            case .ephemeral: return .ephemeral
            case .perf: return .perf
            case .quarantine: return .quarantine
            case .qa: return .qa
            case .staging: return .staging
            case .uat: return .uat
            case .carry: return .carry
            case .liveon: return .liveon
            case .production: return .production
            case .qa2Primary: return .qa2Primary
            case .qa2Internal: return .qa2Internal
            }
        }
    }

    /// Configuration options for creating an active environment
    public struct EnvironmentOptions: Sendable {
        public var attestationEnvironment: AttestationEnvironment

        public init(attestationEnvironment: AttestationEnvironment = .dev) {
            self.attestationEnvironment = attestationEnvironment
        }
    }
}

// Internal type to simplify host/port lookups
extension PCCHarness {
    internal struct HostAndPort: Hashable, Sendable, CustomStringConvertible {
        let host: String
        let port: Int

        var description: String { "\(self.host):\(self.port)" }
    }
}

extension PCCHarness.CloudAppEndpoint {
    internal var hostAndPort: PCCHarness.HostAndPort {
        return .init(host: self.host, port: self.port)
    }
}

extension PCCHarness {
    public enum ApplicationDataChunkingConfiguration: Sendable {
        case disabled
        case enabled(chunkSize: Int)
    }
}
