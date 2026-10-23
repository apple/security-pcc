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

import CFPreferenceCoder
internal import CloudBoardCommon
internal import CloudBoardLogging
import Foundation
import os

extension CFPreferences {
    static var cloudBoardWorkloadControllerPreferencesDomain: String? {
        Bundle.main.bundleIdentifier
    }
}

public enum CloudBoardWorkloadControllerPrefsError: Error {
    case preferencesDomainUnavailable
}

public struct CloudBoardWorkloadControllerPrefs: Codable, Hashable, Sendable {
    enum CodingKeys: String, CodingKey {
        case _enabled = "Enabled"
        case _enforceMaxBatchSize = "EnforceMaxBatchSize"
        @available(*, deprecated, message: "Use 'WorkloadTags' instead")
        case _tags = "Tags"
        @available(*, deprecated, message: "Use 'WorkloadTags' instead")
        case _routingTags = "RoutingTags"
        case _workloadTags = "WorkloadTags"
        case maxBatchSize = "MaxBatchSize"
        case optimalBatchSize = "OptimalBatchSize"
        case serviceName = "ServiceName"
        case appRoutingKeys = "AppRoutingKeys"
    }

    public enum WorkloadTagDecodingError: Error {
        case unknownType(String)
    }

    public enum WorkloadTagValue: Codable, Hashable, Sendable {
        case string(String)
        case stringList([String])

        private enum CodingKeys: String, CodingKey {
            case type
            case value
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let typeKey = try container.decode(String.self, forKey: .type)
            switch typeKey {
            case "string":
                let value = try container.decode(String.self, forKey: .value)
                self = .string(value)
            case "stringList":
                let value = try container.decode([String].self, forKey: .value)
                self = .stringList(value)
            default:
                throw WorkloadTagDecodingError.unknownType(typeKey)
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .string(let value):
                try container.encode("string", forKey: .type)
                try container.encode(value, forKey: .value)
            case .stringList(let value):
                try container.encode("stringList", forKey: .type)
                try container.encode(value, forKey: .value)
            }
        }
    }

    private var _enabled: Bool?
    private var _enforceMaxBatchSize: Bool?

    private var _tags: [String: String]?
    private var _routingTags: [String: [String]]?
    private var _workloadTags: [String: WorkloadTagValue]?

    public var maxBatchSize: Int?
    public var optimalBatchSize: Int?
    public var serviceName: String?
    public var appRoutingKeys: [String]?

    public var enabled: Bool {
        self._enabled ?? false
    }

    public var enforceMaxBatchSize: Bool {
        self._enforceMaxBatchSize ?? false
    }

    public var workloadTags: [String: WorkloadTagValue] {
        // Merge tags specified via Tags, RoutingTags, and WorkloadTags preferences, preferring RoutingTags over Tags
        // and WorkloadTags over RoutingTags for conflicting keys
        let tags = self._tags?.mapValues { WorkloadTagValue.stringList([$0]) } ?? [:]
        let routingTags = self._routingTags?.mapValues { WorkloadTagValue.stringList($0) } ?? [:]
        return tags
            .merging(routingTags, uniquingKeysWith: { $1 })
            .merging(self._workloadTags ?? [:], uniquingKeysWith: { $1 })
    }

    static func fromPreferences() throws -> CloudBoardWorkloadControllerPrefs {
        guard let domain = CFPreferences.cloudBoardWorkloadControllerPreferencesDomain else {
            CloudBoardWorkloadController.log.error(
                "Cannot load preferences: preferences domain not available"
            )
            throw CloudBoardWorkloadControllerPrefsError.preferencesDomainUnavailable
        }
        CloudBoardWorkloadController.log
            .info("Loading configuration from preferences \(domain, privacy: .public)")
        let preferences = CFPreferences(domain: domain)
        do {
            return try .fromPreferences(preferences)
        } catch {
            CloudBoardWorkloadController.log.error(
                "Error loading configuration from preferences: \(String(reportable: error), privacy: .public) (\(error))"
            )
            throw error
        }
    }

    static func fromPreferences(_ preferences: CFPreferences) throws -> CloudBoardWorkloadControllerPrefs {
        let decoder = CFPreferenceDecoder()
        return try decoder.decode(
            CloudBoardWorkloadControllerPrefs.self,
            from: preferences
        )
    }

    /// Equivalent to ``fromPreferences()`` but driven from SecureConfig for consistency.
    /// This only loads information that the CloudBoard layers want to know about and almost all of
    /// ``CloudBoardWorkloadControllerPrefs`` is irrelevant to PersistentServices
    /// This only functions from real Secureconfig, it is not mockable, it's designed to configure
    /// a controller from the main functions.
    static func persistentServiceFromSecureConfig(
        persistentServiceID: String
    ) throws -> CloudBoardWorkloadControllerPrefs {
        CloudBoardWorkloadController.log
            .info(
                "Loading cloudboard specific configuration for \(persistentServiceID, privacy: .public) from SecureConfig"
            )
        let secureconfig = try SecureConfigLoader.real.load()
        var prefs = CloudBoardWorkloadControllerPrefs()
        if secureconfig.persistentServices.contains(persistentServiceID) {
            prefs._enabled = true
        }
        return prefs
    }
}
