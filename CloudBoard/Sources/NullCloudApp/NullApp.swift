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

import CloudBoardCommon
import CloudBoardJob
import CloudBoardLogging
import CloudBoardMetrics
import os

// Warning: If someone is looking to implement a CloudApp and using this as a template *don't*
// This app is unusual in several respects:
// - It uses package level APIs in CloudBoard not shared in the SDK
// - It does operations that a "reasonable" cloud app wouldn't do like crashing, ignoring input
// This is a testing tool, but still entirely safe and private as a CloudApp should be.
// it's not a template to base your real use case on.

/// This is an exhaustive list, there is no dynamic registration
/// for legacy reasons this is "service name" not "role" and the
/// string forms are suffixed "App" not role
enum NullAppServiceName: String {
    /// used only in failure scenarios
    case unknown

    // MARK: Compute Roles

    case testApp = "TestApp"
    case echoApp = "EchoApp"

    // MARK: Proxy Roles

    case proxyApp = "ProxyApp"
    case proxyScriptApp = "ProxyScriptApp"
    case multiNodeProxyApp = "MultiNodeProxyApp"
}

/// The NullCloudApp serves as the 'host' for a single ``NullAppRole`` which may not be known till the
/// point it runs.
/// Note: work a bit harder here to give good error messages - this app is used heavily in testing the extra
/// information provided will save time in the long run
@main
actor NullCloudApp: CloudBoardApp {
    static let metricsClientName = "cloudboard_null_app"

    /// Allows request specific control of the mode for the compute node,
    /// either the direct mode initial request, or the makePCCRequests of the proxy will state it
    static let workloadComputeModeKey: StaticString = "nullapp-compute-mode"
    /// Allows request specific control of the mode for the proxy node,
    /// Only legal on the initial request to the proxy nodes
    static let workloadProxyModeKey: StaticString = "nullapp-proxy-mode"

    /// This is passed to the NullAppRoles where required so that the logging in the null
    /// app is from a consistent source. this makes it easier to diagnose issues for users
    private static let log: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "CloudBoardNullApp"
    )

    var _config: NullCloudAppConfig?
    var config: NullCloudAppConfig {
        guard let config = self._config else {
            fatalError("attempt to reference config before a successful warmup")
        }
        return config
    }

    let metrics: any MetricsSystem
    let isProxy: Bool

    /// The instantiated role from the main run method, available for sub-requests
    private var currentRole: (any NullAppRole)?

    init() {
        self.metrics = CloudMetricsSystem(clientName: Self.metricsClientName)

        // The null app is not used in mocks which lets us make a simple and safe decisions on secure config
        // that it is always the real config
        // Failure to read it is terminal because we rely on it to determine if we are a proxy or not
        do {
            Self.log.debug("Loading secure config from SecureConfigDB")
            let secureConfig = try SecureConfigLoader.real.load()
            self.isProxy = secureConfig.isProxy
        } catch {
            fatalError("Error loading secure config: \(String(unredacted: error))")
        }
    }

    func warmup() throws {
        Self.log.log("NullCloudApp warmup invoked")
        self._config = try NullCloudAppConfig.fromPreferences(logger: Self.log)
        Self.log.log("NullCloudApp preferences loaded")

        // Warmup can only ever know about the configuredRole role (if configured)
        // this is a very specific edge case just for development testing so it's not a problem
        if case .some("crashInWarmup") = self.config.nullAppRole {
            Self.log.log("Crashing as instructed during warmup")
            fatalError("Crashing as instructed during warmup")
        }
    }

    /// This returns the final role names
    /// Full validation they are _legal_ based on the proxy state is dealt with later
    /// but some illegal values will result in ``NullCloudAppRoleError``
    /// It can only be called once the config is loaded
    private func determineRoleNames(
        workloadParameters: [String: [String]]
    ) throws -> (ownRoleName: String, makePCCRequestRoleName: String?) {
        func getRoleNameFromWorkload(_ name: StaticString) throws -> String? {
            let roleParameter = workloadParameters[name.description]
            guard let roleParameter else {
                return nil
            }
            // Don't allow an empty/multi values array, this is almost certainly a screw up so fail fast
            if roleParameter.count == 0 {
                throw NullCloudAppRoleError.workloadParameterMalformed(
                    parameterName: name,
                    reason: "empty array not legal, don't specify it"
                )
            }
            if roleParameter.count != 1 {
                throw NullCloudAppRoleError.workloadParameterMalformed(
                    parameterName: name,
                    reason: "multiple values not legal"
                )
            }
            return roleParameter[0]
        }
        let defaultRole: String = if let fromConfig = self.config.nullAppRole {
            fromConfig
        } else {
            // Note: before the addition of runtime selectable roles the default for compute nodes was "echo"
            // The default is "test" as that's what the tooling using the nulll app for health probes expects
            // and is likely what most developers/users desire
            self.isProxy ? "proxy" : "test"
        }

        let proxyRoleFromWorkload = try getRoleNameFromWorkload(Self.workloadProxyModeKey)
        let computeRoleFromWorkload = try getRoleNameFromWorkload(Self.workloadComputeModeKey)

        if self.isProxy {
            guard let proxyRoleFromWorkload else {
                return (defaultRole, computeRoleFromWorkload)
            }
            return (proxyRoleFromWorkload, computeRoleFromWorkload)
        }
        guard proxyRoleFromWorkload == nil else {
            throw NullCloudAppRoleError.specifiedProxyRoleToComputeNode
        }
        // compute nodes never make PCC requests
        let makePCCRequestRoleName: String? = nil
        guard let computeRoleFromWorkload else {
            return (defaultRole, makePCCRequestRoleName)
        }
        return (computeRoleFromWorkload, makePCCRequestRoleName)
    }

    /// This knows all possible roles - there is no dynamic loading here - just a simple map from strings
    /// to constructors.
    /// This is the final check on legality - if a role is not reasonable to run for some reason this will throw
    private func instantiateRole(
        roleName: String,
        environment: CloudBoardJobCore.CloudAppEnvironment,
        makePCCRequestRoleName: String?
    ) throws -> (any NullAppRole, NullAppRole.Type) {
        let roleType: NullAppRole.Type
        switch roleName {
        case "echo":
            roleType = EchoApp.self
        case "test":
            roleType = TestApp.self
        case "proxy":
            roleType = ProxyApp.self
        case "proxy-script":
            roleType = ScriptedProxy.self
        case "proxy-multi-node":
            roleType = MultiNodeProxyApp.self
        default:
            roleType = InvalidRole.self
            Self.log
                .error(
                    "Unknown role \(roleName, privacy: .public) - mapping to \(roleType.serviceName.rawValue, privacy: .public) for metrics"
                )
        }
        let serviceName = roleType.serviceName
        self.metrics.emit(Metrics.LaunchCounter(action: .increment, serviceName: serviceName))
        func mustBeProxy() throws -> PCCRequestSemantics {
            guard self.isProxy else {
                throw NullCloudAppRoleError.notLegalForProxy(role: roleName)
            }
            return PCCRequestSemantics(
                configuration: self.config.proxyConfiguration,
                environment: environment,
                requestSpecificComputeWorkload: makePCCRequestRoleName
            )
        }
        func mustBeCompute() throws {
            guard !self.isProxy else {
                throw NullCloudAppRoleError.notLegalForCompute(role: roleName)
            }
        }
        // Switch again because the constructors are different
        // This is nicer than pushing _everything_ through run, and lets the roles themselves
        // be relatively clean types with well structured init and state
        let role: any NullAppRole
        do {
            switch roleName {
            // MARK: compute specific

            case "echo":
                try mustBeCompute()
                role = EchoApp(log: Self.log)
            case "test":
                try mustBeCompute()
                role = TestApp(log: Self.log)

            // MARK: proxy specific
            case "proxy":
                let semantics = try mustBeProxy()
                role = ProxyApp(log: Self.log, semantics: semantics)
            case "proxy-script":
                let semantics = try mustBeProxy()
                role = ScriptedProxy(log: Self.log, semantics: semantics)
            case "proxy-multi-node":
                let semantics = try mustBeProxy()
                role = MultiNodeProxyApp(log: Self.log, semantics: semantics)
            default:
                // role came form config, workload parameter or a static string it's fine to pass back
                throw NullCloudAppRoleError.unknownRole(role: roleName)
            }
            return (role, roleType)
        } catch {
            self.metrics.emit(Metrics.OverallErrorCounter.Factory().make(error))
            // we rethrow any errors - including RequestedCrashError
            throw error
        }
    }

    func run(
        input: CloudBoardJobCore.InputData,
        responder: CloudBoardJobCore.ResponseWriter,
        environment: CloudBoardJobCore.CloudAppEnvironment
    ) async throws {
        let (ownRoleName, makePCCRequestRoleName) = try self.determineRoleNames(
            workloadParameters: environment.plaintextMetadata.workloadParameters
        )
        let (role, roleType) = try self.instantiateRole(
            roleName: ownRoleName,
            environment: environment,
            makePCCRequestRoleName: makePCCRequestRoleName
        )

        // Store the role for potential use in sub-requests
        self.currentRole = role

        let spanID: UInt64 = TraceContextCache.singletonCache.generateNewSpanID()
        try await NullAppRequestSummary(
            app: roleType.serviceName,
            from: environment,
            spanID: spanID
        ).loggingRequestSummary(logger: Self.log) {
            do {
                try await role.run(input: input, responder: responder, environment: environment, spanID: spanID)
            } catch {
                self.metrics.emit(Metrics.OverallErrorCounter.Factory().make(error))
                // The semantcs of the current implementation is that all errors in the "run" are swallowed
                // except for RequestedCrashError (The RequestSummary would still log the errors)
                // This replicates the semantics of some real cloud apps, which would communicate errors
                // via the pcc layer/ application layer - generally they should not then throw an error though
                if error is RequestedCrashError {
                    // Rethrow
                    throw error
                } else {
                    // It is unlikely the role reported it either, but it's definitely not in the PCC layer now
                    Self.log.warning("Unhandled error \(error) - not being reported back at PCC layer")
                }
            }
        }
    }

    func teardown() throws {
        Self.log.log("NullCloudApp teardown invoked, exiting")
        exit(0)
    }
}

enum NullCloudAppRoleError: ReportableError {
    case unknownRole(role: String)
    case notLegalForProxy(role: String)
    case notLegalForCompute(role: String)
    case workloadParameterMalformed(parameterName: StaticString, reason: StaticString)
    case specifiedProxyRoleToComputeNode
    case subrequestUnsupportedForRole(role: String)

    var publicDescription: String {
        switch self {
        case .unknownRole(let role):
            return "Unknown role \(role)"
        case .notLegalForProxy(let role):
            return "Role \(role) is not legal for proxy"
        case .notLegalForCompute(let role):
            return "Role \(role) is not legal for compute"
        case .workloadParameterMalformed(let parameterName, let reason):
            return "Role cannot be parsed from  \(parameterName.description) due to \(reason.description)"
        case .specifiedProxyRoleToComputeNode:
            // It's legal for proxy to be _told_ the compute role - it passes that on in the makeRequest calls
            // the other way round strongly implies an error so fail fast
            return "The compute node should never get a proxy role sepcified in the workload parameters"
        case .subrequestUnsupportedForRole(let role):
            return "Subrequests are not supported for role \(role)"
        }
    }
}
