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

//  Copyright © 2024 Apple, Inc. All rights reserved.
//

import CryptoKit
@_spi(Private) import CloudAttestation
import Foundation

typealias SWReleaseMetadata = SWReleases.Release.Metadata

public extension SWReleases.Release {
    struct Metadata {
        typealias Asset = PrivateCloudCompute_ReleaseMetadata.Asset
        typealias AssetType = PrivateCloudCompute_ReleaseMetadata.AssetType
        typealias AssetVerifier = (URL) -> Bool

        // min/max schema version of metadata payload to process
        static let minSchemaVer = PrivateCloudCompute_ReleaseMetadata.SchemaVersion.v1
        static let maxSchemaVer = PrivateCloudCompute_ReleaseMetadata.SchemaVersion.v1

        let sourcePath: String? // set if loaded from a (json) file
        let metadata: PrivateCloudCompute_ReleaseMetadata

        var application: String? {
            if metadata.hasApplication {
                metadata.application.name
            } else {
                nil
            }
        }

        var timestamp: Date { return self.metadata.releaseCreation.date }
        var releaseHash: Data { return self.metadata.releaseDigest }
        var assets: [Asset] {
            guard let override = CLIDefaults.cdnHostnameOverride else {
                return self.metadata.assets
            }

            return self.metadata.assets.map {
                var asset = $0
                asset.url = asset.url.replacing(/https:\/\/[^\/]+/, with: "https://\(override)")
                return asset
            }
        }

        // darwinInitString contains attached darwin-init JSON document as a String
        var darwinInitString: String? {
            return try? self.metadata.darwinInit.jsonString()
        }

        init(data: Data,
             index: UInt64? = nil,
             releaseHash: Data? = nil // add releaseHash if unset
        ) throws {
            var indexPrefix = ""
            if let index {
                indexPrefix = "[\(index)]: "
            }

            guard !data.isEmpty else {
                throw TransparencyLogError("\(indexPrefix)no metadata payload")
            }

            guard var metadata = try? PrivateCloudCompute_ReleaseMetadata(serializedBytes: data) else {
                throw TransparencyLogError("\(indexPrefix)failed to parse metadata payload")
            }

            if metadata.releaseDigest.isEmpty, let releaseHash {
                metadata.releaseDigest = releaseHash
            }

            self.sourcePath = nil
            self.metadata = metadata

            if let mdjson = try? self.jsonString() {
                SWReleases.logger.debug("\(indexPrefix)metadata payload: \(mdjson, privacy: .public)")
            }
        }

        init(leaf: TransparencyLog.ATLeaf) throws {
            try self.init(data: leaf.metadata,
                          index: leaf.index,
                          releaseHash: leaf.nodeData.dataHash)
        }

        init(from: URL) throws {
            do {
                let jsonBlob = try Self.normalizeMetadataJson(Data(contentsOf: from))
                self.metadata = try PrivateCloudCompute_ReleaseMetadata(jsonUTF8Data: jsonBlob)
            } catch {
                throw TransparencyLogError("failed to parse metadata json - \(error)")
            }
            self.sourcePath = from.path
        }

        static func normalizeMetadataJson(_ json: Data) throws -> Data {
            // pccvre used to have a copy of ReleaseMetadata.protobuf with slightly different JSON field and enum names.
            // We need to support that old JSON format for three use-cases:
            // * `pccvre release download` saved JSON on an old build, new pccvre is now creating an instance from it.
            // * Internal helper tool crafts release-metadata.json in the old format.
            // * VRE TA test harness crafts release-metadata.json in the old format.
            guard var dict = try JSONSerialization.jsonObject(with: json, options: []) as? [String: Any] else {
                throw TransparencyLogError("failed to parse metadata json as a dictionary")
            }
            if dict["schemaVersion"] as? String == "V1" {
                dict["schemaVersion"] = "SCHEMA_VERSION_V1"
            }
            if let timestamp = dict["timestamp"] {
                dict["releaseCreation"] = timestamp
                dict["timestamp"] = nil
            }
            if let digest = dict["releaseHash"] {
                dict["releaseDigest"] = digest
                dict["releaseHash"] = nil
            }
            return try JSONSerialization.data(withJSONObject: dict as NSDictionary,
                                              options: [.fragmentsAllowed, .withoutEscapingSlashes])
        }

        func jsonString() throws -> String {
            return try self.metadata.jsonString()
        }

        // assetsByType returns the set of Assets matching assetType
        func assetsByType(_ assetType: AssetType) -> [Asset]? {
            let assets = self.assets.filter { $0.type == assetType }
            return assets.count > 0 ? assets : nil
        }

        // osAsset returns -first- Asset of type AssetType.os
        func osAsset() -> Asset? {
            guard let osAssets = assetsByType(.os) else {
                return nil
            }

            return osAssets[0]
        }

        // cryptexAssets returns all Assets that are not OS or host tools
        func cryptexAssets() -> [Asset] {
            self.assets.filter { ![AssetType.os, AssetType.hostTools].contains($0.type) }
        }

        // hostToolAssets returns -first- Asset of type AssetType.hostTools
        func hostToolsAsset() -> Asset? {
            guard let hostTools = assetsByType(.hostTools) else {
                return nil
            }

            return hostTools[0]
        }

        var isDownloadable: Bool {
            get async throws {
                guard self.assets.count > 0 else {
                    return false
                }

                return await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
                    for asset in self.assets {
                        guard let url = URL(string: asset.url) else {
                            return false
                        }

                        group.addTask {
                            await url.exists
                        }
                    }

                    for await exists in group {
                        if !exists {
                            return false
                        }
                    }

                    return true
                }
            }
        }

        // assetURL returns a parsed URL for the asset
        func assetURL(_ asset: Asset) -> URL? {
            return URL(string: asset.url)
        }

        // assetVariant returns the variant field of asset
        func assetVariant(_ asset: Asset) -> String {
            return asset.variant
        }

        // assetTicket returns the ticket field of asset (if available)
        func assetTicket(_ asset: Asset) -> Data? {
            return asset.ticket.isEmpty ? nil : asset.ticket
        }

        // assetVerifier returns a callback function to verify digest of retrieved asset
        //  against the one published in the metadata record. When the metadata omits the
        //  digest field, returns a permissive verifier that only checks the file exists
        //  so releases can reference assets (e.g. content-addressed exported container
        //  images) without the publisher having to compute and attach a digest for every
        //  build; the publisher populates the digest field when they have one.
        static func assetVerifier(_ asset: Asset) throws -> AssetVerifier {
            guard asset.hasDigest else {
                return { url in FileManager.isRegularFile(url) }
            }

            let assetDigest = asset.digest

            let hashFunc: any HashFunction.Type = switch assetDigest.digestAlg {
            case .sha256: SHA256.self
            case .sha384: SHA384.self
            default: throw TransparencyLogError("asset has unknown digest type (\(assetDigest.digestAlg.rawValue))")
            }

            return { url in
                guard let compDigest = try? computeDigest(at: url, using: hashFunc) else {
                    return false
                }

                let expectedHash = assetDigest.value
                return expectedHash.elementsEqual(compDigest)
            }
        }
    }
}

extension PrivateCloudCompute_ReleaseMetadata.FileType {
    // assetFileType returns AssetHelper.FileType associated with TxPB_ReleaseMetadata.FileType
    var assetFileType: AssetHelper.FileType? {
        return switch self {
        case .ipsw: .ipsw
        case .diskimage: .dmg
        case .applearchive: .aar
        default: nil
        }
    }
}

extension PrivateCloudCompute_ReleaseMetadata.AssetType {
    private static let labels: [PrivateCloudCompute_ReleaseMetadata.AssetType: String] = [
        .unspecified: "ASSET_TYPE_UNSPECIFIED",
        .os: "ASSET_TYPE_OS",
        .pcs: "ASSET_TYPE_PCS",
        .model: "ASSET_TYPE_MODEL",
        .hostTools: "ASSET_TYPE_HOST_TOOLS",
        .debugShell: "ASSET_TYPE_DEBUG_SHELL"
    ]

    var label: String { PrivateCloudCompute_ReleaseMetadata.AssetType.labels[self] ?? "ASSET_TYPE_UNKNOWN" }

    init?(label: String) {
        guard let atype = PrivateCloudCompute_ReleaseMetadata.AssetType.labels.first(where: { $0.value == label }) else {
            return nil
        }

        self = atype.key
    }
}
