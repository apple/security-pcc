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
@_weakLinked import SecureConfigDB

/// Configuration shared by multiple PrivateFilter components.
package struct PrivateFilterServiceConfiguration {
    /// Path to the data cryptex root containing recitation filter data. Discovery
    /// traverses `<VARIANT>/<assetID>/<assetVersion>/filters/{local,remote}/`
    /// subdirectories to find filter metadata.
    ///
    /// Used by both the downloader (to plan fragment downloads for remote filters)
    /// and the controller (to discover and load local/inline filters directly).
    ///
    /// Read from `com.apple.privatefilter.service.recitationDataRoot`.
    /// Default: /private/var/MLModels/LLM/
    package let recitationDataRoot: URL

    /// Filesystem path where PrivateFilterDownloader writes completed remote filter
    /// downloads (fragments, copied filter.json, and status.json). The controller
    /// reads downloaded remote filters from here.
    ///
    /// Fake/synthetic filters are NOT stored here — they use a separate temporary
    /// directory managed by the controller.
    ///
    /// Read from `com.apple.privatefilter.service.remoteRootPath`.
    /// Default: /private/var/mobile/privatefilterdownloader/complete
    package let remoteRootPath: URL

    /// Parent directory of `remoteRootPath`. By convention `remoteRootPath` is
    /// `<cache-volume-mount>/complete`, so this is the cache volume's mount root: the
    /// directory PrivateFilterDownloaderHelper chowns to `mobile` at boot, and the one
    /// the downloader must be able to write into to create the `complete/` tree.
    package var remoteRootParent: URL {
        Self.remoteRootParent(of: self.remoteRootPath)
    }

    /// Derives ``remoteRootParent`` from a raw `remoteRootPath`. The single definition
    /// of the "remoteRootPath's parent is the cache volume root" convention, shared by
    /// this config and `PrivateFilterDownloaderConfiguration` so it is expressed — and
    /// depended on — in exactly one place.
    package static func remoteRootParent(of remoteRootPath: URL) -> URL {
        remoteRootPath.deletingLastPathComponent()
    }

    /// Per-filter configuration, keyed by filterID.
    package let filterConfigs: [FilterIDString: PerFilterConfig]

    /// When true, hashingID validation is disabled for all filters globally.
    /// Read from `com.apple.privatefilter.disableHashingIDValidation`.
    package let disableHashingIDValidation: Bool

    init(
        recitationDataRoot: URL?,
        remoteRootPath: URL?,
        filterConfigs: [FilterIDString: PerFilterConfig],
        disableHashingIDValidation: Bool
    ) {
        self
            .recitationDataRoot = recitationDataRoot ??
            URL(fileURLWithPath: "/private/var/MLModels/LLM/")
        self
            .remoteRootPath = remoteRootPath ??
            URL(fileURLWithPath: "/private/var/mobile/privatefilterdownloader/complete")
        self.filterConfigs = filterConfigs
        self.disableHashingIDValidation = disableHashingIDValidation
    }
}

extension PrivateFilterServiceConfiguration {
    private static let keyPrefix = "com.apple.privatefilter.service"

    /// Loads the shared service config from the on-device SecureConfigDB, or returns
    /// nil if the framework is unavailable or the parameters can't be read/parsed.
    /// Keeps the `SecureConfigDB` dependency contained here so lightweight callers
    /// (e.g. the ownership-fixup helper) need only link `PrivateFilterCommon`.
    package static func loadFromDevice() -> PrivateFilterServiceConfiguration? {
        guard #_hasSymbol(SecureConfigParameters.self) else { return nil }
        guard let parameters = try? SecureConfigParameters.loadContents() else { return nil }
        return try? self.fromSecureConfig(parameters: parameters)
    }

    package static func fromSecureConfig(
        parameters: SecureConfigParameters
    ) throws -> PrivateFilterServiceConfiguration {
        let recitationDataRootString: String? = try getUnvalidatedParameter(
            key: "\(keyPrefix).recitationDataRoot",
            from: parameters
        )
        let remoteRootPathString: String? = try getUnvalidatedParameter(
            key: "\(keyPrefix).remoteRootPath",
            from: parameters
        )
        let filterIDs: [FilterIDString] = try getUnvalidatedParameter(
            key: "\(keyPrefix).filterIDs",
            from: parameters
        ) ?? []

        var filterConfigs: [FilterIDString: PerFilterConfig] = [:]
        for filterID in filterIDs {
            filterConfigs[filterID] = try Self.loadPerFilterConfig(filterID: filterID, parameters: parameters)
        }
        return try .init(
            recitationDataRoot: recitationDataRootString.map { URL(fileURLWithPath: $0) },
            remoteRootPath: remoteRootPathString.map { URL(fileURLWithPath: $0) },
            filterConfigs: filterConfigs,
            // Default true until input_spec is landed in all callers.
            disableHashingIDValidation: getUnvalidatedParameter(
                key: "com.apple.privatefilter.disableHashingIDValidation",
                from: parameters
            ) ?? true
        )
    }

    private static func loadPerFilterConfig(
        filterID: FilterIDString,
        parameters: SecureConfigParameters
    ) throws -> PerFilterConfig {
        let filterKeyPrefix = "\(Self.keyPrefix).filter.\(filterID)"

        // Source
        let sourceString: String? = try getUnvalidatedParameter(
            key: "\(filterKeyPrefix).source",
            from: parameters
        )
        let source: FilterSource
        if let raw = sourceString {
            guard let parsed = FilterSource(rawValue: raw) else {
                throw PrivateFilterSecureConfigError.invalidParameter(
                    "\(filterKeyPrefix).source: unrecognized source value '\(raw)'"
                )
            }
            source = parsed
        } else {
            source = .standard
        }

        // Shard config
        let shardCount: Int? = try getUnvalidatedParameter(
            key: "\(filterKeyPrefix).shardCount",
            from: parameters
        )
        let shardIndex: Int? = try getUnvalidatedParameter(
            key: "\(filterKeyPrefix).shardIndex",
            from: parameters
        )

        let shardConfig: FilterShardConfig
        switch (shardCount, shardIndex) {
        case (.some(let count), .some(let index)):
            guard count > 0 else {
                throw PrivateFilterSecureConfigError.invalidParameter(
                    "\(filterKeyPrefix): invalid shardCount \(count)"
                )
            }
            guard index >= 0, index < count else {
                throw PrivateFilterSecureConfigError.invalidParameter(
                    "\(filterKeyPrefix): invalid shardIndex=\(index)"
                )
            }
            shardConfig = .init(shardCount: count, shardIndex: index)
        case (.none, .none):
            // no shard config for this filter, default to whole filter
            shardConfig = .init(shardCount: 1, shardIndex: 0)
        case (.some, .none):
            throw PrivateFilterSecureConfigError.missingRequiredParameter("\(filterKeyPrefix).shardIndex")
        case (.none, .some):
            throw PrivateFilterSecureConfigError.missingRequiredParameter("\(filterKeyPrefix).shardCount")
        }

        let hashingIDOverride: String? = try getUnvalidatedParameter(
            key: "\(filterKeyPrefix).hashingIDOverride",
            from: parameters
        )

        let queryAllowList: [String]? = try getUnvalidatedParameter(
            key: "\(filterKeyPrefix).queryAllowList",
            from: parameters
        )

        let urlFilterIDOverride: String? = try getUnvalidatedParameter(
            key: "\(filterKeyPrefix).urlFilterIDOverride",
            from: parameters
        )

        return PerFilterConfig(
            source: source,
            shardConfig: shardConfig,
            hashingIDOverride: hashingIDOverride,
            queryAllowList: queryAllowList,
            urlFilterIDOverride: urlFilterIDOverride
        )
    }
}
