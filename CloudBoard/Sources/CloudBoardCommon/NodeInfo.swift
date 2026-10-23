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

#if RC_IS_CLOUDOS_ENABLED && os(iOS)
import AppleComputeEnsembler
#elseif canImport(AppleComputeEnsembler)
@_weakLinked import AppleComputeEnsembler
#else
#warning("AppleComputeEnsembler not available at compile time")
#endif

#if RC_IS_CLOUDOS_ENABLED && os(iOS)
import cloudOSInfo
#elseif canImport(cloudOSInfo)
@_weakLinked import cloudOSInfo
#else
#warning("cloudOSInfo not available at compile time")
#endif

import CloudBoardLogging
import Foundation
import os

/// Information about the current node.
public struct NodeInfo: Sendable {
    private static let logger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "NodeInfo"
    )

    private let cloudOSNodeInfo: CloudOSNodeInfo?
    private let ensembleNodeInfo: EnsembleNodeInfo?

    /// The local cloudOS version.
    public var cloudOSBuildVersion: String? {
        self.cloudOSNodeInfo?.cloudOSBuildVersion
    }

    /// The local cloudOS release type.
    public var cloudOSReleaseType: String? {
        self.cloudOSNodeInfo?.cloudOSReleaseType
    }

    /// The local serverOS release type.
    public var serverOSReleaseType: String? {
        self.cloudOSNodeInfo?.serverOSReleaseType
    }

    /// The local serverOS version.
    public var serverOSBuildVersion: String? {
        self.cloudOSNodeInfo?.serverOSBuildVersion
    }

    /// Whether the workload is enabled.
    public var workloadEnabled: Bool? {
        self.cloudOSNodeInfo?.workloadEnabled
    }

    /// The local host/machine name.
    public var machineName: String? {
        self.ensembleNodeInfo?.machineName
    }

    /// The local ensemble ID.
    public var ensembleID: String? {
        self.ensembleNodeInfo?.ensembleID
    }

    /// The rack location.
    public var rackID: String?

    /// If the node is a leader in an ensemble.
    public var isLeader: Bool? {
        self.ensembleNodeInfo?.isLeader
    }

    public var cloudOSDevice: String? {
        self.cloudOSNodeInfo?.cloudOSDevice
    }

    /// Exposed to allow testing - changing this has no impact on customer paths.
    /// Force in memory (test only) attestations to use this as their hardware identifier
    /// Ignored on all cutomer paths
    package let testOnlyHardwareID: String

    /// Creates a new node info.
    /// - Parameters:
    ///   - cloudOSBuildVersion: The local cloudOS version.
    ///   - cloudOSReleaseType: The local cloudOS release type.
    ///   - serverOSBuildVersion: The local serverOS version.
    ///   - serverOSReleaseType: The local serverOS release type.
    ///   - workloadEnabled: Whether the workload is enabled.
    ///   - machineName: The local host/machine name.
    ///   - ensembleID: The local ensemble ID.
    ///   - isLeader: If the node is a leader in an ensemble.
    ///   - cloudOSDevice: The local hardware type.
    public init(
        cloudOSBuildVersion: String,
        cloudOSReleaseType: String,
        serverOSBuildVersion: String,
        serverOSReleaseType: String,
        rackID: String?,
        workloadEnabled: Bool,
        machineName: String,
        ensembleID: String,
        isLeader: Bool,
        cloudOSDevice: String,
        testOnlyHardwareID: String? = nil
    ) {
        self.cloudOSNodeInfo = .init(
            cloudOSBuildVersion: cloudOSBuildVersion,
            cloudOSReleaseType: cloudOSReleaseType,
            serverOSReleaseType: serverOSReleaseType,
            serverOSBuildVersion: serverOSBuildVersion,
            workloadEnabled: workloadEnabled,
            cloudOSDevice: cloudOSDevice
        )
        self.ensembleNodeInfo = .init(
            machineName: machineName,
            ensembleID: ensembleID,
            isLeader: isLeader
        )
        self.rackID = rackID
        self.testOnlyHardwareID = testOnlyHardwareID ?? UUID().uuidString
    }

    init(
        cloudOSNodeInfo: CloudOSNodeInfo?,
        ensembleNodeInfo: EnsembleNodeInfo?,
        rackID: String?,
        testOnlyHardwareID: String? = nil
    ) {
        self.cloudOSNodeInfo = cloudOSNodeInfo
        self.ensembleNodeInfo = ensembleNodeInfo
        self.rackID = rackID
        self.testOnlyHardwareID = testOnlyHardwareID ?? UUID().uuidString
    }
}

struct CloudOSNodeInfo {
    /// The local cloudOS version.
    let cloudOSBuildVersion: String

    /// The local cloudOS release type.
    let cloudOSReleaseType: String

    /// The local serverOS release type.
    var serverOSReleaseType: String

    /// The local serverOS version.
    let serverOSBuildVersion: String

    /// Whether the workload is enabled.
    let workloadEnabled: Bool

    /// The local hardware type.
    let cloudOSDevice: String
}

extension CloudOSNodeInfo: CustomStringConvertible {
    public var description: String {
        "cloudOSBuildVersion: \(self.cloudOSBuildVersion), cloudOSReleaseType: \(self.cloudOSReleaseType), serverOSBuildVersion: \(self.serverOSBuildVersion), serverOSReleaseType: \(self.serverOSReleaseType), workloadEnabled: \(self.workloadEnabled), cloudOSDevice: \(self.cloudOSDevice)"
    }
}

struct EnsembleNodeInfo {
    /// The local host/machine name.
    let machineName: String?

    /// The local ensemble ID.
    let ensembleID: String?

    /// If the node is a leader in an ensemble.
    let isLeader: Bool
}

extension EnsembleNodeInfo: CustomStringConvertible {
    /// used when AppleComputeEnsembler framework doesn't provide us with a host name
    private static let defaultHostName = "[unknown]"

    /// used when AppleComputeEnsembler framework doesn't provide us with an ensemble ID
    private static let defaultEnsembleID = "[unknown]"

    public var description: String {
        "machineName: \(self.machineName ?? EnsembleNodeInfo.defaultHostName), ensembleID: \(self.ensembleID ?? EnsembleNodeInfo.defaultEnsembleID), isLeader: \(self.isLeader)"
    }
}

extension NodeInfo: CustomStringConvertible {
    public var description: String {
        var result = "rackID: \(String(describing: self.rackID))"
        if let details = self.cloudOSNodeInfo?.description {
            result = "\(result), " + details
        }
        if let details = self.ensembleNodeInfo?.description {
            result = "\(result), " + details
        }
        return result
    }
}

extension NodeInfo {
    /// Returns the node info loaded from the system.
    ///
    /// Load this once at process start, the info does not change.
    public static func load(secureConfig: SecureConfig) -> NodeInfo {
        let cloudOSNodeInfo = Self.loadCloudOSConfiguration()
        let ensembleNodeInfo = Self.loadEnsembleNodeInfo()

        return NodeInfo(
            cloudOSNodeInfo: cloudOSNodeInfo,
            ensembleNodeInfo: ensembleNodeInfo,
            // RackID comes from an attested secure config key even if other places expose it
            rackID: secureConfig.parameters.rackID
        )
    }

    /// Fast path to determine if a leader or not
    public static func isLeader() -> Bool? {
        return self.loadEnsembleNodeInfo()?.isLeader
    }

    /// Returns the node info loaded from CloudOSInfoProvider.
    ///
    /// Load this once at process start, the info does not change.
    private static func loadCloudOSConfiguration() -> CloudOSNodeInfo? {
        #if canImport(cloudOSInfo)
        if #_hasSymbol(CloudOSInfoProvider.self) {
            do {
                let cloudOSConfiguration = try CloudOSInfoProvider().cloudOSConfiguration()
                let cloudOSNodeInfo = CloudOSNodeInfo(
                    cloudOSBuildVersion: cloudOSConfiguration.cloudOSBuildVersion,
                    cloudOSReleaseType: cloudOSConfiguration.cloudOSReleaseType,
                    serverOSReleaseType: cloudOSConfiguration.serverOSReleaseType,
                    serverOSBuildVersion: cloudOSConfiguration.serverOSBuildVersion,
                    workloadEnabled: cloudOSConfiguration.tieEnabled,
                    cloudOSDevice: cloudOSConfiguration.cloudOSDevice
                )
                self.logger.debug("""
                Successfully loaded cloudOS node info: \
                \(cloudOSNodeInfo.description, privacy: .public)
                """)
                return cloudOSNodeInfo
            } catch {
                self.logger
                    .error(
                        "cloudOSInfo threw an error (will return a nil CloudOSNodeInfo): \(String(reportable: error), privacy: .public) (\(error))"
                    )
                return nil
            }
        } else {
            self.logger.error("CloudOSInfoProvider not available, returning nil CloudOSNodeInfo.")
            return nil
        }
        #else
        self.logger.error("cloudOSInfo framework not available, returning nil CloudOSNodeInfo.")
        return nil
        #endif
    }

    /// Returns the node info loaded from AppleComputeEnsembler framework.
    ///
    /// Load this once at process start, the info does not change.
    private static func loadEnsembleNodeInfo() -> EnsembleNodeInfo? {
        #if canImport(AppleComputeEnsembler)
        if #_hasSymbol(EnsemblerSession.self) {
            do {
                let ensemblerSession = try EnsemblerSession()
                let nodeInfo = try ensemblerSession.getNodeInfo()
                let isLeader = try ensemblerSession.isLeader()
                let ensembleID = try ensemblerSession.getEnsembleID()
                let ensembleNodeInfo = EnsembleNodeInfo(
                    machineName: nodeInfo.hostName,
                    ensembleID: ensembleID,
                    isLeader: isLeader
                )
                self.logger.debug("""
                Successfully loaded ensemble node info: \
                \(ensembleNodeInfo.description, privacy: .public)
                """)
                return ensembleNodeInfo
            } catch {
                self.logger
                    .error(
                        "EnsemblerSession threw an error (will return a nil EnsembleNodeInfo): \(String(reportable: error), privacy: .public) (\(error))"
                    )
                return nil
            }
        } else {
            self.logger.error("EnsemblerSession not available, returning nil EnsembleNodeInfo.")
            return nil
        }
        #else
        self.logger.error("AppleComputeEnsembler framework not available, returning nil EnsembleNodeInfo.")
        return nil
        #endif
    }
}
