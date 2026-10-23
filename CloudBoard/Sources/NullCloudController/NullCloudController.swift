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

import CloudBoardCommon
import CloudBoardController
import CloudBoardLogging
import Foundation
import NullCloudControllerAPI
import os

actor NullCloudController {
    static let log: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "NullCloudController"
    )

    private let controller: CloudBoardWorkloadController
    private let config: NullCloudControllerConfiguration
    private var connectionID = 0
    private let xpcServer: NullCloudControllerAPIXPCServer
    private let reregisterEvery: TimeInterval

    public init() async throws {
        self.config = try NullCloudControllerConfiguration.fromPreferences()
        self.reregisterEvery = TimeInterval((self.config.reregisterMinutes ?? 60) * 60)
        self.xpcServer = .init()
        self.controller = try await CloudBoardWorkloadController()
        await self.controller.onShutdown {
            Self.log.log("Handling shutdown from cloudboardd")
        }
        await self.controller.onDisconnect { @Sendable in
            Self.log.warning("Handling disconnect from cloudboardd")
            await self.incrementConnectionID()
        }
    }

    func run() async throws {
        Self.log.log("Hello from NullCloudController")

        guard await self.controller.prefs.enabled == true else {
            Self.log.log("NullCloudController not enabled, exiting")
            return
        }

        // Determine if this node is a proxy node
        let isProxy: Bool
        do {
            Self.log.info("Loading secure config from SecureConfigDB")
            let secureConfig = try SecureConfigLoader.real.load()
            isProxy = secureConfig.isProxy
        } catch {
            Self.log.error(
                "Error loading secure config: \(String(unredacted: error), privacy: .public). Assuming node is not a proxy."
            )
            isProxy = false
        }

        /// Needed for backward compatibility
        let cloudAppName = self.config.cloudAppName ?? (isProxy ? "TIEProxyApp" : "NullCloudApp")
        let maxBatchSize = await self.controller.prefs.maxBatchSize ?? (isProxy ? 25 : 1000)

        let workloadTags = await self.controller.prefs.workloadTags.mapValues {
            switch $0 {
            case .string(let value): RoutingTagValue.string(value)
            case .stringList(let value): RoutingTagValue.stringList(value)
            }
        }

        let properties = await WorkloadProperties(
            // Default to the TIE service name as this has traditionally been used for the null app as well
            workloadName: self.controller.prefs.serviceName ?? "tie-cloudboard-apple-com",
            cloudAppName: cloudAppName
        )

        while true {
            let connectionID = self.connectionID
            await self.controller.connect()
            await self.xpcServer.start(delegate: self)

            Self.log.log("Sending RegisterWorkload...")
            if isProxy {
                try await self.registerAsProxyWorkload(
                    workloadTags: workloadTags,
                    maxBatchSize: maxBatchSize,
                    properties: properties
                )
            } else {
                try await self.registerAsComputeWorkload(
                    workloadTags: workloadTags,
                    maxBatchSize: maxBatchSize,
                    properties: properties,
                    appRoutingKeys: self.controller.prefs.appRoutingKeys ?? []
                )
            }
            let lastRegister = Date.now

            Self.log.log("Sending ready status...")
            try await self.controller.updateHealthStatus(
                status: WorkloadControllerStatus(
                    state: .ready
                )
            )

            while self.connectionID == connectionID {
                // always wait at least 5 seconds, regardless of how tight reregister is set to
                try await Task.sleep(for: .seconds(5))
                if Date.now.timeIntervalSince(lastRegister) > self.reregisterEvery {
                    Self.log.warning("Scheduled refresh time reached, re-registering")
                    break
                }
            }
            if self.connectionID != connectionID {
                Self.log.warning("Detected cloudboardd disconnect, re-registering")
            }
        }
    }

    func registerAsProxyWorkload(
        workloadTags: [String: RoutingTagValue],
        maxBatchSize: Int,
        properties: WorkloadProperties
    ) async throws {
        var workloadTags = workloadTags
        // For backward compatibility, we need to extract configured services from the configured workload tags
        let services = if let configuredServices = workloadTags["services"] {
            switch configuredServices {
            case .string(let serviceName): [serviceName]
            case .stringList(let serviceNames): serviceNames
            }
        } else {
            [String]()
        }

        workloadTags.removeValue(forKey: "services")

        // For backward compatibility, we need to read the routingGroupAliases from CFPrefs because it's possible
        // that the RGAs are only specified in the CFPrefs and not in secure-config (for which cloudboardd reads and
        // provides them to Service Discovery directly).
        let routingGroupAliases: [String]? = if let configuredRGAs = workloadTags["routingGroupAliases"] {
            switch configuredRGAs {
            case .string(let rga): [rga]
            case .stringList(let rgas): rgas
            }
        } else {
            nil
        }
        workloadTags.removeValue(forKey: "routingGroupAliases")

        try await self.controller.registerProxyWorkload(
            config: .init(
                maxBatchSize: maxBatchSize,
                optimalBatchSize: self.controller.prefs.optimalBatchSize ?? maxBatchSize,
                currentBatchSize: 0,
                metadata: .init(services: services, routingGroupAliasOverrides: routingGroupAliases),
                workloadTags: workloadTags
            ),
            properties: properties
        )
    }

    func registerAsComputeWorkload(
        workloadTags: [String: RoutingTagValue],
        maxBatchSize: Int,
        properties: WorkloadProperties,
        appRoutingKeys: [String]
    ) async throws {
        try await self.controller.registerComputeWorkload(
            config: .init(
                maxBatchSize: maxBatchSize,
                optimalBatchSize: self.controller.prefs.optimalBatchSize ?? maxBatchSize,
                currentBatchSize: 0,
                workloadTags: workloadTags,
                appRoutingKeys: appRoutingKeys
            ),
            properties: properties
        )
    }

    private func incrementConnectionID() {
        self.connectionID += 1
    }
}

extension NullCloudController: NullCloudControllerAPIServerDelegateProtocol {
    func updateState(state: WorkloadControllerState) async throws -> String {
        try await self.controller.updateHealthStatus(status: .init(state: state))
        return "Updated state to: \(state)"
    }

    func restartPrewarmedInstances() async throws {
        try await self.controller.restartPrewarmedInstances()
    }
}
