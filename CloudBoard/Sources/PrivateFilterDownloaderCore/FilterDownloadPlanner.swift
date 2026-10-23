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
import os
import PrivateFilterCommon

/// Builds the per-filter fragment lists by reading filter metadata, constructing
/// download URLs, and slicing fragments for this node's shard.
struct FilterDownloadPlanner {
    private static let logger = Logger(
        subsystem: "com.apple.cloudos.cloudboard",
        category: String(describing: FilterDownloadPlanner.self)
    )

    struct Result {
        /// Fragments to download, keyed by filterID.
        var fragmentsByFilter: [FilterIDString: [FragmentMetadata]] = [:]
        /// Filters that failed during planning (metadata load errors, shard config errors).
        var failedFilters: [FilterIDString: DownloaderStatus.FilterStatus] = [:]
        /// The download source for each filter that passed planning.
        /// Used by the downloader to finalize filter.json after fragments are downloaded.
        var sourceByFilter: [FilterIDString: any FilterDownloadSource] = [:]
    }

    static func plan(config: PrivateFilterDownloaderConfiguration) -> Result {
        var result = Result()

        // Run discovery for all standard filters.
        let standardFilterIDs = Set(
            config.filterConfigs.filter { $0.value.source == .standard }.map(\.key)
        )
        let discoveryResult = FilterDiscovery.discoverFilters(
            recitationDataRoot: config.recitationDataRoot,
            filterIDs: standardFilterIDs
        )

        for (filterID, perFilterConfig) in config.filterConfigs {
            let shardConfig = perFilterConfig.shardConfig

            switch perFilterConfig.source {
            case .fakeRemote, .fakeLocal, .syntheticRemote, .syntheticLocal:
                Self.logger.log("""
                Skipping filter (source=\(perFilterConfig.source, privacy: .public)). \
                FilterID=\(filterID, privacy: .public)
                """)
                continue

            case .standard:
                guard let status = discoveryResult[filterID] else {
                    result.failedFilters[filterID] = DownloaderStatus.FilterStatus(
                        filterID: filterID, status: .error, revision: nil,
                        error: "Filter not found in discovery results"
                    )
                    continue
                }

                switch status {
                case .enabled(let locality, let path, let metadata):
                    switch locality {
                    case .local:
                        // Local filters have data in the cryptex — nothing to download.
                        Self.logger.log("""
                        Skipping local filter (data in cryptex). \
                        FilterID=\(filterID, privacy: .public) \
                        Path=\(path, privacy: .public)
                        """)
                        continue

                    case .remote:
                        guard let urlPrefix = config.urlPrefix else {
                            result.failedFilters[filterID] = DownloaderStatus.FilterStatus(
                                filterID: filterID,
                                status: .error,
                                revision: nil,
                                error: "urlPrefix not configured for remote filter"
                            )
                            continue
                        }
                        let filterDirectory = config.remoteRootPath.appendingPathComponent(filterID)
                        let standardSource = StandardFilterDownloadSource(
                            filterID: filterID,
                            urlPrefix: urlPrefix,
                            metadata: metadata,
                            sourceFilterJSON: path.appendingPathComponent("filter.json"),
                            urlFilterIDOverride: perFilterConfig.urlFilterIDOverride
                        )
                        switch standardSource.buildFragments(filterDirectory: filterDirectory) {
                        case .success(let allFragments):
                            Self.sliceAndRecord(
                                filterID: filterID,
                                allFragments: allFragments,
                                shardConfig: shardConfig,
                                source: standardSource,
                                result: &result
                            )
                        case .failure(let error):
                            Self.logger.error("""
                            Failed to build fragments metadata. \
                            FilterID=\(filterID, privacy: .public) \
                            Error=\(error, privacy: .public)
                            """)
                            result.failedFilters[filterID] = DownloaderStatus.FilterStatus(
                                filterID: filterID, status: .error, revision: nil, error: "\(error)"
                            )
                        }
                    }

                case .notFound:
                    Self.logger.error("""
                    Standard filter not found in data cryptex. \
                    FilterID=\(filterID, privacy: .public)
                    """)
                    result.failedFilters[filterID] = DownloaderStatus.FilterStatus(
                        filterID: filterID, status: .error, revision: nil,
                        error: "Filter not found in data cryptex"
                    )

                case .error(let discoveryError):
                    Self.logger.error("""
                    Discovery error for filter. \
                    FilterID=\(filterID, privacy: .public) \
                    Error=\(discoveryError, privacy: .public)
                    """)
                    result.failedFilters[filterID] = DownloaderStatus.FilterStatus(
                        filterID: filterID, status: .error, revision: nil, error: "\(discoveryError)"
                    )

                case .discoveredButNotEnabled:
                    // Should not happen for configured filters, but handle gracefully.
                    result.failedFilters[filterID] = DownloaderStatus.FilterStatus(
                        filterID: filterID, status: .error, revision: nil,
                        error: "Filter discovered but not enabled (unexpected)"
                    )
                }
            }
        }

        return result
    }

    /// Validate shard config, slice the fragment list, and add to the result.
    private static func sliceAndRecord(
        filterID: String,
        allFragments: [FragmentMetadata],
        shardConfig: FilterShardConfig,
        source: any FilterDownloadSource,
        result: inout Result
    ) {
        do {
            let range = try shardConfig.fragmentRange(totalFragments: allFragments.count)
            result.fragmentsByFilter[filterID] = Array(allFragments[range])
            result.sourceByFilter[filterID] = source

            if shardConfig.shardCount == 1 {
                Self.logger.log("""
                No sharding for filter, downloading all \(allFragments.count, privacy: .public) fragments. \
                FilterID=\(filterID, privacy: .public)
                """)
            } else {
                Self.logger.log("""
                Shard assignment. \
                FilterID=\(filterID, privacy: .public) \
                ShardIndex=\(shardConfig.shardIndex, privacy: .public) \
                ShardCount=\(shardConfig.shardCount, privacy: .public) \
                TotalFragments=\(allFragments.count, privacy: .public) \
                FragmentRange=\(range.lowerBound, privacy: .public)..<\(range.upperBound, privacy: .public)
                """)
            }
        } catch {
            self.logger.error("""
            Shard config error. \
            FilterID=\(filterID, privacy: .public) \
            Error=\(error, privacy: .public)
            """)
            result.failedFilters[filterID] = DownloaderStatus.FilterStatus(
                filterID: filterID, status: .error, revision: nil, error: "\(error)"
            )
        }
    }
}

enum FilterPlanError: Error, CustomStringConvertible {
    case invalidFragmentURL(String)
    case missingRevision(filterID: String)
    /// A fragment's `filter.json` entry declares no size. Remote download sizes
    /// each fragment from the explicit `file_size` (written for both families),
    /// falling back to `bloom_length + 4` for legacy bloom descriptors. This is
    /// raised only when neither is present.
    case missingFragmentSize(filterID: String, file: String)

    var description: String {
        switch self {
        case .invalidFragmentURL(let url):
            "Invalid fragment URL: \(url)"
        case .missingRevision(let filterID):
            "filter.json for '\(filterID)' has no version"
        case .missingFragmentSize(let filterID, let file):
            "filter.json for '\(filterID)' fragment '\(file)' declares no size "
                + "(neither file_size nor bloom_length); remote download requires one"
        }
    }
}

extension FilterPlanError: ReportableError {
    var publicDescription: String {
        switch self {
        case .invalidFragmentURL:
            "invalidFragmentURL"
        case .missingRevision:
            "missingRevision"
        case .missingFragmentSize:
            "missingFragmentSize"
        }
    }
}
