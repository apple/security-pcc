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

import CloudBoardControllerCore
import CloudBoardUtilities
import Configuration

enum ServiceDiscoveryConfigError: Error, Equatable {
    /// Thrown when service discovery is partially configured: some deployment-specific keys
    /// are set while others are missing. The associated value names a missing required key.
    case missingRequiredKey(String)
}

extension ServiceDiscoveryConfigError: ReportableError {
    var publicDescription: String {
        switch self {
        case .missingRequiredKey(let key):
            "ServiceDiscoveryConfigError.missingRequiredKey(\(key))"
        }
    }
}

/// Configuration for service discovery registration
struct ServiceDiscoveryConfiguration {
    let host: String
    let port: Int
    let region: String
    let cellID: String
    let cluster: String
    let environment: String
    let enableTLS: Bool
    let useMTLS: Bool
    let sniOverride: String
    let serviceName: String
    let routingGroupAliases: [String]?
    let hardwareType: String
    let releaseType: String
    let buildVersion: String
    let ensembleID: String?
    let workloadName: String?
    let workloadPurpose: String?
    let workloadApp: String?
    let workloadServesCustomers: String?
    let workloadTags: [String: WorkloadTagValue]
    let degradedGracePeriodSeconds: Int

    /// Initialises Service Discovery. Returns nil of Service Discovery is not configured at all. Throws if Service
    /// Discovery is partially configured.
    /// - Parameters:
    ///   - attestedConfigReader: Attested/measured config reader
    ///   - unattestedConfigReader: Unattested/unmeasured config reader
    ///   - controllerProvidedConfiguration: Workload controller provided configuration
    init?(
        attestedConfigReader: ConfigReader,
        unattestedConfigReader: ConfigReader,
        controllerProvidedConfiguration: ControllerProvidedConfiguration
    ) throws {
        // Service discovery is enabled by the *presence* of environment-specific config.
        // All five keys must be set together. Partial configuration throws.
        let host = unattestedConfigReader.string(forKey: "servicediscovery.host")
        let region = unattestedConfigReader.string(forKey: "servicediscovery.region")
        let cellID = unattestedConfigReader.string(forKey: "servicediscovery.cellid")
        let cluster = unattestedConfigReader.string(forKey: "servicediscovery.cluster")
        let environment = unattestedConfigReader.string(forKey: "servicediscovery.environment")

        let configValues: [(key: String, value: String?)] = [
            ("servicediscovery.host", host),
            ("servicediscovery.region", region),
            ("servicediscovery.cellid", cellID),
            ("servicediscovery.cluster", cluster),
            ("servicediscovery.environment", environment),
        ]
        let setCount = configValues.lazy.filter { $0.value != nil }.count

        if setCount == 0 {
            // Service discovery is fully unconfigured — disabled.
            return nil
        }
        if setCount != configValues.count {
            // Partial configuration. Surface the first missing key.
            for (key, value) in configValues where value == nil {
                throw ServiceDiscoveryConfigError.missingRequiredKey(key)
            }
        }
        self.host = host!
        self.region = region!
        self.cellID = cellID!
        self.cluster = cluster!
        self.environment = environment!

        self.port = unattestedConfigReader.int(forKey: "servicediscovery.port", default: 9500)
        self.enableTLS = attestedConfigReader.bool(forKey: "servicediscovery.tls.enabled", default: true)
        self.useMTLS = attestedConfigReader.bool(forKey: "servicediscovery.tls.mtls", default: true)
        self.sniOverride = unattestedConfigReader.string(
            forKey: "servicediscovery.tls.snioverride",
            default: "servicediscovery.amp.apple.com"
        )

        self.hardwareType = attestedConfigReader.string(forKey: "device", default: "a4")
        self.releaseType = attestedConfigReader.string(forKey: "scheme", default: "MW Development")
        self.buildVersion = attestedConfigReader.string(forKey: "version", default: "6AX000")

        self.ensembleID = unattestedConfigReader.string(forKey: "FLEET_NODE_ID")

        self.serviceName = controllerProvidedConfiguration.workloadProperties.workloadName
        self.routingGroupAliases = unattestedConfigReader.stringArray(forKey: "servicediscovery.routinggroupaliases")
        self.workloadName = unattestedConfigReader.string(forKey: "servicediscovery.workload_name")
        self.workloadPurpose = unattestedConfigReader.string(forKey: "servicediscovery.workload_purpose")
        self.workloadApp = unattestedConfigReader.string(forKey: "servicediscovery.workload_app")
        self.workloadServesCustomers = unattestedConfigReader.string(
            forKey: "servicediscovery.workload_serves_customers"
        )
        self.workloadTags = controllerProvidedConfiguration.computeWorkloadConfig.workloadTags.mapValues {
            $0.wrapped
        }
        self.degradedGracePeriodSeconds = unattestedConfigReader.int(
            forKey: "servicediscovery.degraded_grace_period_seconds",
            default: 300
        )
    }
}
