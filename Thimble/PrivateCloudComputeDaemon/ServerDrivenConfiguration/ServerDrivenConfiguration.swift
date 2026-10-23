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

//
//  ServerDrivenConfiguration.swift
//  PrivateCloudCompute
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

import Foundation
import OSLog
import PrivateCloudCompute
import Synchronization

private let logger = Logger(for: .serverDrivenConfiguration)

protocol ServerDrivenConfigurationProtocol: Sendable {
    func updateJsonModel(_ data: Data) async

    var isOutdated: Bool { get }

    var liveOnProdSpillover: Double? { get }
    var prewarmAttestationsValidityInSeconds: Double? { get }
    var blockedBundleIds: [String] { get }
    var maxPrefetchWorkloadCount: Int? { get }
    var maxPrefetchWorkloadAgeSeconds: Int? { get }
    var trustedProxyDefaultTotalAttestations: Int? { get }
    var trustedProxyMaxPrefetchBatches: Int? { get }
    var trustedProxyMaxCachedAttestations: Int? { get }
    var trustedProxyMaxPrefetchedAttestations: Int? { get }
    var antiTargetabilityExpectedPrefetchedAttestations: Int? { get }
    var antiTargetabilityExpectedInlineAttestations: Int? { get }
    var waitlistIssuer: String? { get }

    /// Returns issuer name to use when fetching OTT.
    func issuer(workloadType: WorkloadType, featureId: String, environment: TC2Environment) -> String?

    /// Returns issuer name to use for reputation tokens.
    func reputationIssuer(ottIssuer: String, featureId: String, inferenceId: String) -> String?

    func inactivityTimeout(workloadType: WorkloadType) -> Duration?
}

final class ServerDrivenConfiguration: ServerDrivenConfigurationProtocol {

    struct JsonModel: Codable, Sendable {
        var liveOnProdSpillover: Double?
        var prewarmAttestationsValidityInSeconds: Double?
        var blockedBundleIds: [String]?
        var maxPrefetchWorkloadCount: Int?
        var maxPrefetchWorkloadAgeSeconds: Int?
        var trustedProxyDefaultTotalAttestations: Int?
        /// Controls the max number of cached proxy attestations used during an invoke request.
        var trustedProxyMaxCachedAttestations: Int?
        var trustedProxyMaxPrefetchBatches: Int?
        /// Controls the max number of trusted proxy attestations we request during a prefetch.
        var trustedProxyMaxPrefetchedAttestations: Int?
        var featureIdMappings: [FeatureIdMapping]?
        /// Controls the minimum number of prefetched attestations required for anti-targetability protection.
        var antiTargetabilityExpectedPrefetchedAttestations: Int?
        /// Controls the minimum number of inline attestations required for anti-targetability protection.
        var antiTargetabilityExpectedInlineAttestations: Int?

        /// [OTTIssuerName: ReputationMapping]
        var reputationMappings: [String: ReputationMapping]?

        var waitlistIssuer: String?

        /// Configuration to use for inactivity watchdog on the invoke request path.
        var inactivityTimeout: InactivityTimeout?

        enum CodingKeys: String, CodingKey {
            case liveOnProdSpillover = "LiveOnProdSpillover3"
            case prewarmAttestationsValidityInSeconds = "PrewarmAttestationsValidityInSeconds"
            case blockedBundleIds = "BlockedBundleIds"
            case maxPrefetchWorkloadCount = "MaxPrefetchWorkloadCount"
            case maxPrefetchWorkloadAgeSeconds = "MaxPrefetchWorkloadAgeSeconds"
            case trustedProxyDefaultTotalAttestations = "TrustedProxyDefaultTotalAttestations"
            case trustedProxyMaxCachedAttestations = "TrustedProxyMaxCachedAttestations"
            case trustedProxyMaxPrefetchBatches = "TrustedProxyMaxPrefetchBatches"
            case trustedProxyMaxPrefetchedAttestations = "TrustedProxyMaxPrefetchedAttestations"
            case antiTargetabilityExpectedPrefetchedAttestations = "AntiTargetabilityExpectedPrefetchedAttestations"
            case antiTargetabilityExpectedInlineAttestations = "AntiTargetabilityExpectedInlineAttestations"
            case featureIdMappings = "FeatureIdMappings"
            case reputationMappings = "ReputationMappings"
            case waitlistIssuer = "WaitlistIssuer"
            case inactivityTimeout = "InactivityTimeout"
        }

        struct FeatureIdMapping: Codable, Sendable {
            typealias Issuer = String
            typealias FeatureId = String

            var workloadType: String
            var defaultIssuer: Issuer
            var scopedIssuers: [Issuer: [FeatureId]]

            enum CodingKeys: String, CodingKey {
                case workloadType = "WorkloadType"
                case defaultIssuer = "DefaultIssuer"
                case scopedIssuers = "ScopedIssuers"
            }
        }

        struct ReputationMapping: Codable, Sendable {
            var reputationTokenIssuer: String
            var featureIds: [String]?
            var inferenceIds: [String]?
            var allRequests: Bool?

            enum CodingKeys: String, CodingKey {
                case reputationTokenIssuer = "ReputationTokenIssuer"
                case featureIds = "FeatureIds"
                case inferenceIds = "InferenceIds"
                case allRequests = "AllRequests"
            }
        }

        struct InactivityTimeout: Codable, Sendable {
            struct ScopedTimeout: Codable, Sendable {
                /// In seconds. Value of `0` means the should be no timeout.
                var timeout: Int
                var workloadType: String

                enum CodingKeys: String, CodingKey {
                    case timeout = "Timeout"
                    case workloadType = "WorkloadType"
                }
            }

            /// In seconds. Value of `0` means the should be no timeout.
            var defaultTimeout: Int
            var scopedTimeouts: [ScopedTimeout]?

            enum CodingKeys: String, CodingKey {
                case defaultTimeout = "DefaultTimeout"
                case scopedTimeouts = "ScopedTimeouts"
            }
        }
    }

    // This should be a project resource or something, I'm
    // so sorry, let's make this feel better at some point.
    private static let defaultJson = """
            {
                "MaxPrefetchWorkloadAgeSeconds": 691200,
                "MaxPrefetchWorkloadCount": 10,
                "TrustedProxyDefaultTotalAttestations": 4,
                "TrustedProxyMaxCachedAttestations": 2,
                "TrustedProxyMaxPrefetchedAttestations": 12,
                "AntiTargetabilityExpectedPrefetchedAttestations": 0,
                "AntiTargetabilityExpectedInlineAttestations": 0,
                "ReputationMappings": {
                    "inference.issuer.apple.com": {
                        "ReputationTokenIssuer": "reputation.issuer.apple.com",
                        "InferenceIds": [
                            "com.apple.fm.language.instruct_server_v2.fm_api"
                        ]
                    }
                },
                "WaitlistIssuer": "waitlist.issuer.apple.com"
            }
        """.data(using: .utf8)!

    static let filename = "serverdrivenconfiguration.json"
    private let decoder = tc2JSONDecoder()
    private let file: URL
    private let _jsonModel: Mutex<JsonModel>

    init(from url: URL) {
        let file = url.appending(path: Self.filename)
        self.file = file

        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            logger.log("persistence does not yet exist, or unable to read persisted server driven configuration, file=\(file), error=\(error)")
            data = Self.defaultJson
        }

        self._jsonModel = Mutex(Self.load(data, decoder: self.decoder))

        logger.debug("initialized server driven configuration, file=\(file)")
    }

    private static func load(_ data: Data, decoder: JSONDecoder) -> JsonModel {
        let model: JsonModel
        do {
            model = try decoder.decode(JsonModel.self, from: data)
        } catch {
            logger.error("unable to decode server driven configuration, error=\(error)")
            model = JsonModel()
        }
        return model
    }

    func updateJsonModel(_ data: Data) async {
        let save: Bool
        do {
            try self._jsonModel.withLock {
                $0 = try self.decoder.decode(JsonModel.self, from: data)
            }
            save = true
        } catch {
            logger.error("unable to update persisted server driven configuration, error=\(error)")
            save = false
        }

        if save {
            do {
                try await doThrowingBlockingIOWork { try data.write(to: self.file) }
            } catch {
                logger.error("unable to write persisted server driven configuration, file=\(self.file), error=\(error)")
            }

            logger.debug("wrote persisted server driven configuration, file=\(self.file)")
        }
    }

    var jsonModel: JsonModel {
        return self._jsonModel.withLock { $0 }
    }

    var isOutdated: Bool {
        guard let persistenceModifiedAt else {
            return true
        }

        return persistenceModifiedAt.timeIntervalSinceNow < .hours(-36)
    }

    /// Returns a date when the persistent storage has been last modified. It should correspond with when the config has
    /// been fetched from the server last and store in the persistent storage.
    private var persistenceModifiedAt: Date? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: self.file.path())
            if let date = attributes[.modificationDate] as? Date {
                return date
            }
            logger.log("can not read modificationDate of persisted server driven configuration, file=\(self.file)")
        } catch {
            logger.log("can not read attributes of persisted server driven configuration, file=\(self.file), error=\(error)")
        }

        return nil
    }

    var liveOnProdSpillover: Double? {
        let liveOnProdSpillover = self.jsonModel.liveOnProdSpillover
        logger.info("liveOnProdSpillover: \(String(describing: liveOnProdSpillover))")
        return liveOnProdSpillover
    }

    var prewarmAttestationsValidityInSeconds: Double? {
        let prewarmAttestationsValidityInSeconds = self.jsonModel.prewarmAttestationsValidityInSeconds
        logger.info("prewarmAttestationsValidityInSeconds: \(String(describing: prewarmAttestationsValidityInSeconds))")
        return prewarmAttestationsValidityInSeconds
    }

    var blockedBundleIds: [String] {
        let blockedBundleIds = self.jsonModel.blockedBundleIds
        logger.info("blockedBundleIds: \(String(describing: blockedBundleIds))")
        return blockedBundleIds ?? []
    }

    var maxPrefetchWorkloadCount: Int? {
        let maxPrefetchWorkloadCount = self.jsonModel.maxPrefetchWorkloadCount
        logger.info("maxPrefetchWorkloadCount: \(String(describing: maxPrefetchWorkloadCount))")
        return maxPrefetchWorkloadCount
    }

    var maxPrefetchWorkloadAgeSeconds: Int? {
        let maxPrefetchWorkloadAgeSeconds = self.jsonModel.maxPrefetchWorkloadAgeSeconds
        logger.info("maxPrefetchWorkloadAgeSeconds: \(String(describing: maxPrefetchWorkloadAgeSeconds))")
        return maxPrefetchWorkloadAgeSeconds
    }

    var trustedProxyDefaultTotalAttestations: Int? {
        let value = self.jsonModel.trustedProxyDefaultTotalAttestations
        logger.info("trustedProxyDefaultTotalAttestations: \(String(describing: value))")
        return value
    }

    var trustedProxyMaxPrefetchBatches: Int? {
        let value = self.jsonModel.trustedProxyMaxPrefetchBatches
        logger.info("trustedProxyMaxPrefetchBatches: \(String(describing: value))")
        return value
    }

    var trustedProxyMaxCachedAttestations: Int? {
        let value = self.jsonModel.trustedProxyMaxCachedAttestations
        logger.info("trustedProxyMaxCachedAttestations: \(String(describing: value))")
        return value
    }

    var trustedProxyMaxPrefetchedAttestations: Int? {
        let value = self.jsonModel.trustedProxyMaxPrefetchedAttestations
        logger.info("trustedProxyMaxPrefetchedAttestations: \(String(describing: value))")
        return value
    }

    /// The expected number of prefetched attestations. Prefetch fails if we received fewer.
    var antiTargetabilityExpectedPrefetchedAttestations: Int? {
        let value = self.jsonModel.antiTargetabilityExpectedPrefetchedAttestations
        logger.info("antiTargetabilityExpectedPrefetchedAttestations: \(String(describing: value))")
        return value
    }

    var antiTargetabilityExpectedInlineAttestations: Int? {
        let value = self.jsonModel.antiTargetabilityExpectedInlineAttestations
        logger.info("antiTargetabilityExpectedInlineAttestations: \(String(describing: value))")
        return value
    }

    var waitlistIssuer: String? {
        let issuer = self.jsonModel.waitlistIssuer
        logger.info("waitlistIssuer: \(String(describing: issuer))")
        return issuer
    }

    func issuer(workloadType: WorkloadType, featureId: String, environment: TC2Environment) -> String? {
        logger.info("determining an issuer, workloadType=\(workloadType), featureId=\(featureId), environment=\(environment.name)")
        if let mappingsFromServer = self.jsonModel.featureIdMappings {
            logger.info("featureIdMappings (from server): \(String(describing: mappingsFromServer))")
            if let issuer = mappingsFromServer.issuer(workloadType: workloadType, featureId: featureId) {
                logger.info("issuer determined (from server), issuer=\(String(describing: issuer))")
                return issuer
            }
        }

        // No match from the server config, try local defaults
        let mappings = self.defaultFeatureIdMappings
        logger.info("featureIdMappings (default): \(String(describing: mappings))")
        if let issuer = mappings.issuer(workloadType: workloadType, featureId: featureId) {
            logger.info("issuer determined (default), issuer=\(String(describing: issuer))")
            return issuer
        }

        // No match in the local defaults either.
        if environment == .production || environment == .carry {
            logger.info("issuer can not be determined")
            return nil
        } else {
            let issuer = "inference.issuer.apple.com"
            logger.info("issuer can not be determined, using a fallback, issuer=\(String(describing: issuer))")
            return issuer
        }
    }

    private let loadedDefaultFeatureIdMappings: Mutex<[JsonModel.FeatureIdMapping]?> = .init(nil)

    private var defaultFeatureIdMappings: [JsonModel.FeatureIdMapping] {
        self.loadedDefaultFeatureIdMappings.withLock {
            if let loaded = $0 {
                return loaded
            } else {
                // We haven't loaded it from the disk yet.
                let loaded: [JsonModel.FeatureIdMapping] = Self.loadAndDecodeBundleResource(named: "DefaultFeatureIdMappings") ?? []
                $0 = loaded
                return loaded
            }
        }
    }

    private static func loadAndDecodeBundleResource<T: Decodable>(named name: String) -> T? {
        logger.info("loading bundle resource, name=\(name, privacy: .public)")
        guard let file = Bundle(for: Self.self).url(forResource: name, withExtension: "json") else {
            logger.error("can not create URL for \(name, privacy: .public).json")
            return nil
        }
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            logger.error("error loading bundle resource, name=\(name, privacy: .public), error=\(error), file=\(file)")
            return nil
        }

        let decoder = tc2JSONDecoder()
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            logger.error("error decoding bundle resource, name=\(name, privacy: .public), error=\(error), file=\(file), data.count=\(data.count)")
            return nil
        }
    }

    func reputationIssuer(ottIssuer: String, featureId: String, inferenceId: String) -> String? {
        logger.info("determining a reputation issuer, ottIssuer=\(ottIssuer), featureId=\(featureId), inferenceId=\(inferenceId)")
        let mappings = self.jsonModel.reputationMappings ?? [:]
        logger.info("reputationMappings: \(String(describing: mappings))")

        if let mapping = mappings[ottIssuer] {
            let issuer = mapping.reputationIssuer(featureId: featureId, inferenceId: inferenceId)
            logger.info("reputation issuer determined, issuer=\(String(describing: issuer)), ottIssuer=\(ottIssuer), featureId=\(featureId), inferenceId=\(inferenceId)")
            return issuer
        } else {
            logger.info("no reputation issuer, ottIssuer=\(ottIssuer), featureId=\(featureId), inferenceId=\(inferenceId)")
            return nil
        }
    }

    func inactivityTimeout(workloadType: WorkloadType) -> Duration? {
        logger.info("determining inactivity timeout, workloadType=\(workloadType)")
        let config = self.jsonModel.inactivityTimeout
        logger.info("inactivityTimeout: \(String(describing: config))")

        guard let config else {
            // If server config doesn't have the config at all, use default.
            return .seconds(45)
        }

        if let scoped = config.scopedTimeouts?.first(where: { $0.workloadType == workloadType }) {
            // If there is a scoped value for the given workload, use that.
            let timeout = scoped.timeout
            return timeout == 0 ? nil : .seconds(timeout)
        }

        // Otherwise, use default value from the config.
        let timeout = config.defaultTimeout
        return timeout == 0 ? nil : .seconds(timeout)
    }
}

extension Collection where Element == ServerDrivenConfiguration.JsonModel.FeatureIdMapping {
    fileprivate func issuer(workloadType: WorkloadType, featureId: String) -> String? {
        guard let mapping = self.first(where: { $0.workloadType == workloadType }) else {
            return nil
        }
        return mapping.issuer(featureId: featureId)
    }
}

extension ServerDrivenConfiguration.JsonModel.FeatureIdMapping {
    fileprivate func issuer(featureId: String) -> String {
        self.scopedIssuers.first { _, patterns in
            patterns.contains {
                FeatureIdPattern($0) ~= featureId
            }
        }?.key ?? self.defaultIssuer
    }
}

extension ServerDrivenConfiguration.JsonModel.ReputationMapping {
    /// Returns the reputation token issuer if the given request is in scope for this mapping, otherwise `nil`.
    fileprivate func reputationIssuer(featureId: String, inferenceId: String) -> String? {
        if self.allRequests == true {
            return self.reputationTokenIssuer
        }
        // Feature ids match on a dot-separated prefix basis.
        if let featureIds = self.featureIds, featureIds.contains(where: { FeatureIdPattern($0) ~= featureId }) {
            return self.reputationTokenIssuer
        }
        // Inference ids match 1:1.
        if let inferenceIds = self.inferenceIds, inferenceIds.contains(inferenceId) {
            return self.reputationTokenIssuer
        }
        return nil
    }
}
