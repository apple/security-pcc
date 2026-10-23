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
import HealthServiceClient
import Logging
import OpenAPIRuntime
import ServiceLifecycle

actor DynamicConfigService: Service {
    typealias NodeStatus = HealthServiceClient.NodeStatus

    struct ConfigUpdate: Sendable {
        let version: String
        let timestamp: Date
        let config: [String: String]
    }

    /// Delivers a config update to a subscribed client and confirms whether the underlying write
    /// actually succeeded (throws on failure), rather than just handing it off.
    typealias ConfigUpdateListener = @Sendable (ConfigUpdate) async throws -> Void

    private let logger = Logger(label: "CPAgent.DynamicConfigService")
    private let commandPollInterval: TimeInterval = 30.0

    private let healthServiceClient: HealthServiceClient?
    private let checksum: String?
    private let renderedConfigDirectory: String
    private let bootServiceConfig: (any Sendable)?

    var currentNodeStatus = NodeStatus(
        agentStatus: Components.Schemas.AgentStatus(
            state: Components.Schemas.AgentStateDetail(
                observedAt: Date(),
                error: nil
            )
        ),
        serviceStatuses: [
            Components.Schemas.ServiceStatus(
                name: "com.apple.cloudassetdownloaderd",
                state: Components.Schemas.ServiceStateDetail(
                    observedAt: Date(),
                    error: nil,
                    value: .ACTIVATED
                ),
                propertyStatuses: []
            )
        ]
    )
    private var lastCommandEtag: String?

    // Map of service names to their active config update listener.
    // Only one listener (subscriber) is expected to be connected per service at a time.
    private var configListeners: [String: ConfigUpdateListener] = [:]

    // Map of service names to their running gRPC server tasks
    var gRPCServers: [String: Task<Void, Never>] = [:]

    // Map of service name -> property key -> in-flight retrying push task.
    // A new push for the same (service, key) cancels and replaces any prior one.
    private var pendingConfigPushes: [String: [String: Task<Void, Never>]] = [:]
    private let configPushRetryInterval: TimeInterval = 30.0

    private static func isValidServiceName(_ name: String) -> Bool {
        /// Service names must match this pattern (matches DynamicConfiguration server-side validation).
        let serviceNamePattern = /[A-Za-z0-9][A-Za-z0-9._-]{0,127}/
        return name.wholeMatch(of: serviceNamePattern) != nil
    }

    enum ServiceNameValidationError: Error, ReportableError {
        case invalidServiceName

        var publicDescription: String {
            "ServiceNameValidationError.invalidServiceName"
        }
    }

    init(
        healthServiceClient: HealthServiceClient?, checksum: String?,
        renderedConfigDirectory: String,
        bootServiceConfig: (any Sendable)?
    ) async {
        self.healthServiceClient = healthServiceClient
        self.checksum = checksum
        self.renderedConfigDirectory = renderedConfigDirectory
        self.bootServiceConfig = bootServiceConfig
        for serviceName in (currentNodeStatus.serviceStatuses ?? []).map(\.name) {
            registerService(name: serviceName)
        }

        // The boot-time serviceConfig (e.g. CAD's assetConfigsMap) reflects the state services
        // should already be in at cold boot, so it seeds currentNodeStatus and pushes each
        // property to the service's listener when available.
        if let mappedNodeStatus = mapBootServiceConfigToAgentServiceCurrentNodeStatus(
            bootServiceConfig)
        {
            for service in mappedNodeStatus.serviceStatuses ?? [] {
                for property in service.propertyStatuses {
                    updatePropertyStatus(
                        serviceName: service.name,
                        key: property.key,
                        value: property.value,
                        state: .APPLIED
                    )
                    pushConfigUpdateForService(
                        serviceName: service.name, key: property.key, value: property.value)
                }
            }
        }

    }

    /// Register the listener that will be called when config updates arrive for a service.
    /// There is at most one listener per service; a new subscription replaces any existing one.
    /// Starts a gRPC server for the service if this is the first listener.
    func addConfigListener(serviceName: String, listener: @escaping ConfigUpdateListener) throws {
        guard Self.isValidServiceName(serviceName) else {
            logger.warning(
                "Rejecting config listener for invalid service name",
                metadata: ["service": "\(serviceName)"])
            throw ServiceNameValidationError.invalidServiceName
        }

        if configListeners[serviceName] != nil {
            logger.warning(
                "Replacing existing config listener for service",
                metadata: ["service": "\(serviceName)"])
        }
        configListeners[serviceName] = listener

        logger.info(
            "Config listener added",
            metadata: ["service": "\(serviceName)"])
    }

    func removeConfigListener(serviceName: String) {
        guard configListeners.removeValue(forKey: serviceName) != nil else {
            return
        }

        logger.info(
            "Config listener removed",
            metadata: ["service": "\(serviceName)"])
    }

    /// Generate the socket path for a service's dynamic config gRPC server.
    private func socketPath(for serviceName: String) -> String {
        return "\(renderedConfigDirectory)/local/\(serviceName)/dynamic-config.sock"
    }

    /// Start a gRPC server for the specified service.
    private func startGRPCServer(for serviceName: String) {
        // Don't start if already running
        guard gRPCServers[serviceName] == nil else {
            logger.warning(
                "gRPC server already running for service",
                metadata: ["service": "\(serviceName)"])
            return
        }

        // Cap the number of running gRPC servers to the number of known services.
        let maxServers = currentNodeStatus.serviceStatuses?.count ?? 0
        guard gRPCServers.count + 1 <= maxServers else {
            logger.warning(
                "gRPC server limit reached; refusing to start server for service",
                metadata: [
                    "service": "\(serviceName)",
                    "limit": "\(maxServers)",
                ])
            return
        }

        let socketPath = socketPath(for: serviceName)
        let grpcService = DynamicConfigGRPCService(dynamicConfigService: self)
        let server = DynamicConfigGRPCServer(
            socketPath: socketPath,
            dynamicConfigGRPCService: grpcService)

        logger.info(
            "Starting gRPC server for service",
            metadata: [
                "service": "\(serviceName)",
                "socketPath": "\(socketPath)",
            ])

        // Spawn the server task
        let serverTask = Task {
            do {
                try await server.run()
            } catch {
                logger.error(
                    "gRPC server failed for service",
                    metadata: [
                        "service": "\(serviceName)",
                        "error": "\(String(reportable: error))",
                    ])
            }
        }

        gRPCServers[serviceName] = serverTask

        logger.info(
            "gRPC server started for service",
            metadata: ["service": "\(serviceName)"])
    }

    /// Stop the gRPC server for the specified service.
    private func stopGRPCServer(for serviceName: String) {
        guard let serverTask = gRPCServers[serviceName] else {
            logger.debug(
                "No gRPC server to stop for service",
                metadata: ["service": "\(serviceName)"])
            return
        }

        logger.info(
            "Stopping gRPC server for service",
            metadata: ["service": "\(serviceName)"])

        serverTask.cancel()
        gRPCServers.removeValue(forKey: serviceName)

        // Clean up socket file
        let socketPath = socketPath(for: serviceName)
        try? FileManager.default.removeItem(atPath: socketPath)

        logger.info(
            "gRPC server stopped for service",
            metadata: ["service": "\(serviceName)"])
    }

    func run() async throws {
        logger.info("Starting...")
        try await withGracefulShutdownHandler {
            guard let checksum else {
                logger.warning("Checksum unavailable; dynamic config service waiting for shutdown")
                await waitForShutdown()
                return
            }
            guard healthServiceClient != nil else {
                logger.warning("Health service client not initialized; skipping command polling")
                await waitForShutdown()
                return
            }
            try await pollCommands(checksum: checksum)
        } onGracefulShutdown: {
            Task {
                await self.shutdownAllGRPCServers()
                self.logger.info("Shutting down dynamic config service")
            }
        }
        logger.info("finished")
    }

    /// Shut down all running gRPC servers.
    private func shutdownAllGRPCServers() {
        let serviceNames = Array(gRPCServers.keys)

        logger.info(
            "Shutting down all gRPC servers",
            metadata: ["count": "\(serviceNames.count)"])

        for serviceName in serviceNames {
            stopGRPCServer(for: serviceName)
        }

        for tasks in pendingConfigPushes.values {
            for task in tasks.values {
                task.cancel()
            }
        }
        pendingConfigPushes.removeAll()
    }

    private func pollCommands(checksum: String) async throws {
        logger.debug(
            "Starting command polling with interval",
            metadata: ["interval": "\(commandPollInterval)s"])

        while !Task.isCancelled {
            do {
                logger.info("Calling Health Service Client for next command.")
                let (commands, etag) = try await healthServiceClient!.getNextCommands(
                    bootConfigCksum: checksum,
                    ifNoneMatch: lastCommandEtag,
                    nodeStatus: currentNodeStatus
                )

                if let etag {
                    lastCommandEtag = etag
                }

                if let commands {
                    await handleCommands(commands)
                }
            } catch {
                logger.error(
                    "Command poll failed", metadata: ["error": "\(String(reportable: error))"])
            }
            try await Task.sleep(for: .seconds(commandPollInterval))
        }
    }

    private func handleCommands(_ agentCommands: HealthServiceClient.AgentCommands) async {
        for command in agentCommands.commands {
            logger.debug("Received command", metadata: ["command": "\(command)"])

            // Get service name from serviceConfig
            let serviceName = command.serviceConfig.name

            logger.info(
                "Processing command for service",
                metadata: [
                    "serviceName": "\(serviceName)",
                    "commandType": "\(command._type)",
                ])

            switch command._type {
            case .INIT:
                logger.debug("Received .INIT command", metadata: ["service": "\(serviceName)"])
                break

            case .NO_OP:
                logger.debug("Received NO_OP command", metadata: ["service": "\(serviceName)"])
            // Converged or waiting - no action needed

            case .APPLY_PROPERTY:
                guard let key = command.serviceConfig.serviceProperty?.key,
                    let value = command.serviceConfig.serviceProperty?.value
                else {
                    logger.warning(
                        "APPLY_PROPERTY command missing key or value",
                        metadata: ["service": "\(serviceName)"])
                    break
                }

                logger.info(
                    "Received APPLY_PROPERTY command",
                    metadata: [
                        "service": "\(serviceName)",
                        "key": "\(key)",
                    ])

                // Optimistically mark as APPLYING; pushConfigUpdateForService flips it to
                // APPLIED once the update is actually delivered to a connected listener.

                // TODO: rdar://183149648 ([CPAgent]: Set property to APPLYING before calling pushConfigUpdateForService())
                // Change back to `APPLYING` once testing is complete. If state is stuck in .APPLYING
                // node will try and reboot. This is expected and correct behavior but we don't want to enforce it until
                // testing is complete.
                updatePropertyStatus(
                    serviceName: serviceName,
                    key: key,
                    value: value,
                    state: .APPLIED
                )

                pushConfigUpdateForService(serviceName: serviceName, key: key, value: value)

            case .DEACTIVATE:
                logger.info("Received DEACTIVATE command", metadata: ["service": "\(serviceName)"])
            // TODO: implement service deactivation

            case .ACTIVATE:
                logger.info("Received ACTIVATE command", metadata: ["service": "\(serviceName)"])
            // TODO: implement service activation
            }
        }

        logger.info(
            "Current node status:",
            metadata: ["currentNodeStatus": "\(self.currentNodeStatus)"])
    }

    /// Registers a service in currentNodeStatus as ACTIVATED with no properties.
    /// Called on INIT to signal to the CommandDispatcher that the agent has discovered this service.
    /// Starts a gRPC server for the service so clients can connect and subscribe.
    func registerService(name: String) {
        guard Self.isValidServiceName(name) else {
            logger.warning(
                "Rejecting registration for invalid service name", metadata: ["service": "\(name)"])
            return
        }

        var statuses = currentNodeStatus.serviceStatuses ?? []

        // Check if service already exists
        if let index = statuses.firstIndex(where: { $0.name == name }) {
            // Service exists - update it to ACTIVATED
            var service = statuses[index]
            service.state = .init(observedAt: Date(), value: .ACTIVATED)
            statuses[index] = service
            logger.info("Updated existing service to ACTIVATED", metadata: ["service": "\(name)"])
        } else {
            // Service doesn't exist - add new one as ACTIVATED
            statuses.append(
                .init(
                    name: name,
                    state: .init(observedAt: Date(), value: .ACTIVATED),
                    propertyStatuses: []))
            logger.info("Added new service as ACTIVATED", metadata: ["service": "\(name)"])
        }

        currentNodeStatus.serviceStatuses = statuses

        // Start gRPC server for this service so clients can connect
        startGRPCServer(for: name)
    }

    /// Updates the property status for a service in currentNodeStatus.
    func updatePropertyStatus(
        serviceName: String,
        key: String,
        value: String,
        state: Components.Schemas.ServicePropertyState
    ) {
        let propertyStatus = Components.Schemas.ServicePropertyStatus(
            key: key,
            value: value,
            state: .init(observedAt: Date(), value: state))

        var statuses = currentNodeStatus.serviceStatuses ?? []

        if let index = statuses.firstIndex(where: { $0.name == serviceName }) {
            var service = statuses[index]
            if let propIndex = service.propertyStatuses.firstIndex(where: { $0.key == key }) {
                service.propertyStatuses[propIndex] = propertyStatus
            } else {
                service.propertyStatuses.append(propertyStatus)
            }
            statuses[index] = service
        } else {
            statuses.append(
                .init(
                    name: serviceName,
                    state: .init(observedAt: Date(), value: .ACTIVATED),
                    propertyStatuses: [propertyStatus]))
        }

        currentNodeStatus.serviceStatuses = statuses
    }

    /// Builds a config update for the given key/value and delivers it to the service's listener.
    /// If no listener is currently connected, retries every `configPushRetryInterval` seconds in
    /// the background (without blocking the caller) until one connects. A new push for the same
    /// (service, key) supersedes and cancels any push already in flight for it.
    private func pushConfigUpdateForService(serviceName: String, key: String, value: String) {
        let configUpdate = ConfigUpdate(
            version: lastCommandEtag ?? "unknown",
            timestamp: Date(),
            config: [key: value]
        )

        pendingConfigPushes[serviceName]?[key]?.cancel()

        pendingConfigPushes[serviceName, default: [:]][key] = Task {
            await self.deliverConfigUpdate(configUpdate, serviceName: serviceName, key: key)
        }
    }

    /// Waits for a connected listener for `serviceName`, retrying on an interval, then delivers
    /// the update and marks the property APPLIED only once the listener confirms the write
    /// actually succeeded. Returns early without touching shared state if cancelled (i.e.
    /// superseded by a newer push for the same service/key, or on shutdown).
    private func deliverConfigUpdate(
        _ configUpdate: ConfigUpdate, serviceName: String, key: String
    ) async {
        while true {
            if Task.isCancelled {
                return
            }

            if let listener = configListeners[serviceName] {
                do {
                    try await listener(configUpdate)
                    updatePropertyStatus(
                        serviceName: serviceName,
                        key: key,
                        value: configUpdate.config[key] ?? "",
                        state: .APPLIED
                    )
                    logger.info(
                        "Config update pushed to service",
                        metadata: [
                            "service": "\(serviceName)",
                            "key": "\(key)",
                            "version": "\(configUpdate.version)",
                        ])
                    pendingConfigPushes[serviceName]?[key] = nil
                    return
                } catch {
                    logger.warning(
                        "Failed to deliver config update to service; retrying",
                        metadata: [
                            "service": "\(serviceName)",
                            "key": "\(key)",
                            "error": "\(String(reportable: error))",
                        ])
                }
            } else {
                logger.info(
                    "No listener connected for service; retrying push",
                    metadata: [
                        "service": "\(serviceName)",
                        "key": "\(key)",
                        "retryInterval": "\(configPushRetryInterval)s",
                    ])
            }

            try? await Task.sleep(for: .seconds(configPushRetryInterval))
        }
    }

    /// Maps the freeform boot-time `serviceConfig` JSON (keyed by service name, each holding
    /// key/value properties such as `assetConfigsMap`) into a `NodeStatus`. Values that aren't
    /// plain strings (e.g. nested objects/arrays) are JSON-encoded so they fit the
    /// `ServicePropertyStatus.value: String` schema. Returns nil if bootServiceConfig is nil.
    func mapBootServiceConfigToAgentServiceCurrentNodeStatus(
        _ bootServiceConfig: (any Sendable)?
    ) -> NodeStatus? {
        guard let bootServiceConfig else {
            return nil
        }

        guard let servicesByName = bootServiceConfig as? [String: (any Sendable)?] else {
            logger.warning("bootServiceConfig is not a JSON object; ignoring")
            return nil
        }

        var serviceStatuses: [Components.Schemas.ServiceStatus] = []

        for (serviceName, serviceConfig) in servicesByName {
            guard Self.isValidServiceName(serviceName) else {
                logger.warning(
                    "Skipping invalid service name in bootServiceConfig",
                    metadata: ["service": "\(serviceName)"])
                continue
            }

            guard let properties = serviceConfig as? [String: (any Sendable)?] else {
                continue
            }

            var propertyStatuses: [Components.Schemas.ServicePropertyStatus] = []
            for (key, value) in properties {
                guard let value, let stringValue = Self.jsonStringValue(value) else {
                    continue
                }
                propertyStatuses.append(
                    Components.Schemas.ServicePropertyStatus(
                        key: key,
                        value: stringValue,
                        state: .init(observedAt: Date(), value: .APPLIED)))
            }

            serviceStatuses.append(
                Components.Schemas.ServiceStatus(
                    name: serviceName,
                    state: .init(observedAt: Date(), value: .ACTIVATED),
                    propertyStatuses: propertyStatuses))
        }

        return NodeStatus(
            agentStatus: Components.Schemas.AgentStatus(
                state: Components.Schemas.AgentStateDetail(observedAt: Date(), error: nil)
            ),
            serviceStatuses: serviceStatuses)
    }

    /// Decodes a raw serviceConfig JSON string into the same `[String: (any Sendable)?]` shape
    /// that `bootServiceConfig` has when extracted from `NodeConfiguration.manifestDetails.secureConfig`.
    static func decodeBootServiceConfig(_ json: String) throws -> (any Sendable)? {
        let container = try JSONDecoder().decode(OpenAPIObjectContainer.self, from: Data(json.utf8))
        return container.value
    }

    /// Renders a freeform config value as a String: strings pass through as-is, everything
    /// else (nested objects/arrays) is JSON-encoded.
    private static func jsonStringValue(_ value: Any) -> String? {
        if let string = value as? String {
            return string
        }
        guard JSONSerialization.isValidJSONObject(value),
            let data = try? JSONSerialization.data(withJSONObject: value)
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func waitForShutdown() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(600))
        }
    }
}
