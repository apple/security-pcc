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

import FilterCore
import Foundation
import os

/// Whether a filter's data was found in the `local/` or `remote/` subtree
/// of the data cryptex.
///
/// - `local`: Fragment data is co-located with `filter.json` in the cryptex.
///   The controller can load the filter directly without the downloader.
/// - `remote`: Only `filter.json` is present. Fragment data must be downloaded
///   from the CDN by the downloader before the controller can load it.
package enum FilterLocality: Sendable, CustomStringConvertible {
    case local
    case remote

    package var description: String {
        switch self {
        case .local: "local"
        case .remote: "remote"
        }
    }
}

/// Subset of `filter.json` fields needed by both the downloader and controller
/// during discovery. The full `FilterDescriptor` (from BloomFilter) is read
/// separately at load time when all fields are required.
package struct DiscoveredFilterMetadata: Codable, Sendable {
    /// The filter revision identifier. Used to construct CDN URLs for remote
    /// fragment downloads and for status reporting. Referred to as "revision"
    /// to distinguish from the broader model version.
    package let version: String

    /// Optional model version string for logging/diagnostics.
    package let modelVersion: String?

    /// Optional input spec string for logging/diagnostics.
    package let inputSpec: String?

    /// Filter family discriminator from `filter_type` (`bloom`/`ribbon`). Absent
    /// in legacy files written before the field existed; `nil` there. Loaders
    /// dispatch on the authoritative `FilterKind.peek(jsonPath:)`, so this is for
    /// discovery-time logging and coarse routing decisions only.
    package let filterType: FilterKind?

    package let totalFragments: Int
    package let fragments: [FragmentInfo]

    package struct FragmentInfo: Codable, Sendable {
        /// Filename of the fragment (e.g. `"fragment_003.bloom"`).
        /// Must be a bare filename with no path components — no `/` or `..` allowed.
        package let file: String
        package let prefixValue: UInt
        /// Hex-encoded SHA-256 digest of the fragment file contents.
        package let checksum: String
        /// Size of the bloom data in bytes (excludes magic trailer).
        /// The on-disk file size is `bloomLength + 4` (magic trailer).
        /// Bloom only — ribbon fragments carry no length here (a ribbon file is
        /// self-sizing from its `RibbonHeader`), so this is `nil` for ribbon.
        package let bloomLength: UInt64?
        /// Total on-disk size of the fragment file in bytes. Written by the
        /// builder for both families; authoritative when present. Ribbon requires
        /// it (its `filter.json` always carries it); bloom may omit it in legacy
        /// files, where the size falls back to `bloomLength + 4`.
        package let fileSize: UInt64?

        enum CodingKeys: String, CodingKey {
            case file
            case prefixValue = "prefix_value"
            case checksum
            case bloomLength = "bloom_length"
            case fileSize = "file_size"
        }
    }

    enum CodingKeys: String, CodingKey {
        case version
        case modelVersion = "model_version"
        case inputSpec = "input_spec"
        case filterType = "filter_type"
        case totalFragments = "total_fragments"
        case fragments
    }
}

/// The outcome of discovery for a single filter ID.
package enum FilterDiscoveryStatus: Sendable {
    /// Filter found and matched against configured filterIDs.
    case enabled(locality: FilterLocality, path: URL, metadata: DiscoveredFilterMetadata)

    /// Filter found in the cryptex but not in the configured filterIDs for this node.
    /// Logged for visibility but not loaded.
    case discoveredButNotEnabled(locality: FilterLocality, path: URL)

    /// Filter was in the configured filterIDs but not found in any cryptex path.
    case notFound

    /// Filter found but filter.json was invalid, unreadable, or duplicated.
    case error(FilterDiscoveryError)
}

package enum FilterDiscoveryError: Error, CustomStringConvertible {
    case filterJSONNotFound(path: URL)
    case filterJSONUnreadable(path: URL, underlying: any Error)
    case fragmentCountMismatch(filterID: FilterIDString, declared: Int, actual: Int)
    case missingVersion(filterID: FilterIDString)
    case invalidFragmentFilename(filterID: FilterIDString, file: String)
    case duplicateFilterID(filterID: FilterIDString, paths: [URL])

    package var description: String {
        switch self {
        case .filterJSONNotFound(let path):
            "filter.json not found at \(path)"
        case .filterJSONUnreadable(let path, let underlying):
            "filter.json unreadable at \(path): \(underlying)"
        case .fragmentCountMismatch(let filterID, let declared, let actual):
            "filter.json for '\(filterID)' totalFragments (\(declared)) does not match fragment array count (\(actual))"
        case .missingVersion(let filterID):
            "filter.json for '\(filterID)' has no version"
        case .invalidFragmentFilename(let filterID, let file):
            "filter.json for '\(filterID)' contains invalid fragment filename '\(file)' — must be a bare filename with no path components"
        case .duplicateFilterID(let filterID, let paths):
            "filter '\(filterID)' found in multiple locations: \(paths.map(\.path).joined(separator: ", "))"
        }
    }
}

/// Discovers filters in the data cryptex by traversing the directory structure.
///
/// The cryptex is organized as:
/// ```
/// {recitationDataRoot}/
///   <VARIANT>/<assetIdentifier>/<assetVersion>/
///     filters/
///       local/<filterID>/filter.json   (+ fragment data)
///       remote/<filterID>/filter.json  (metadata only)
/// ```
package enum FilterDiscovery {
    private static let logger = Logger(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "FilterDiscovery"
    )

    /// Discover filters in the data cryptex.
    ///
    /// Traverses `{recitationDataRoot}/<VARIANT>/<assetID>/<assetVersion>/filters/{local,remote}/`
    /// to find filter directories containing `filter.json`.
    ///
    /// - Parameters:
    ///   - recitationDataRoot: Root path of the data cryptex tree.
    ///   - filterIDs: The set of filter IDs configured for this node. Filters found
    ///     in the cryptex but not in this set are reported as `.discoveredButNotEnabled`.
    /// - Returns: A map from filterID to its discovery status.
    package static func discoverFilters(
        recitationDataRoot: URL,
        filterIDs: Set<FilterIDString>
    ) -> [FilterIDString: FilterDiscoveryStatus] {
        var result: [FilterIDString: FilterDiscoveryStatus] = [:]

        // Track all locations where each filterID is found, to detect duplicates.
        var locationsByFilterID: [FilterIDString: [(locality: FilterLocality, path: URL)]] = [:]

        let fm = FileManager.default

        // Traverse: <VARIANT>/<assetID>/<assetVersion>/filters/{local,remote}/<filterID>/
        guard let variants = Self.subdirectories(of: recitationDataRoot, fm: fm) else {
            Self.logger.warning(
                "Cannot read recitationDataRoot at \(recitationDataRoot.path, privacy: .public)"
            )
            // Mark all configured filterIDs as not found.
            for filterID in filterIDs {
                result[filterID] = .notFound
            }
            return result
        }

        for variantURL in variants {
            guard let assetIDs = Self.subdirectories(of: variantURL, fm: fm) else { continue }
            for assetIDURL in assetIDs {
                guard let assetVersions = Self.subdirectories(of: assetIDURL, fm: fm) else { continue }
                for assetVersionURL in assetVersions {
                    let filtersURL = assetVersionURL.appendingPathComponent("filters")
                    guard fm.fileExists(atPath: filtersURL.path) else { continue }

                    for (subdir, locality) in [("local", FilterLocality.local), ("remote", FilterLocality.remote)] {
                        let localityURL = filtersURL.appendingPathComponent(subdir)
                        guard let filterDirs = Self.subdirectories(of: localityURL, fm: fm) else { continue }

                        for filterDirURL in filterDirs {
                            let filterID = filterDirURL.lastPathComponent
                            let filterJSONURL = filterDirURL.appendingPathComponent("filter.json")

                            guard fm.fileExists(atPath: filterJSONURL.path) else { continue }

                            locationsByFilterID[filterID, default: []].append(
                                (locality: locality, path: filterDirURL)
                            )
                        }
                    }
                }
            }
        }

        // Process discovered filters.
        for (filterID, locations) in locationsByFilterID {
            let isEnabled = filterIDs.contains(filterID)

            if locations.count > 1 {
                let paths = locations.map(\.path)
                Self.logger.error(
                    "Filter \(filterID, privacy: .public) found in multiple locations: \(paths, privacy: .public)"
                )
                result[filterID] = .error(.duplicateFilterID(filterID: filterID, paths: paths))
                continue
            }

            let location = locations[0]

            if !isEnabled {
                Self.logger.log(
                    "Discovered filter \(filterID, privacy: .public) (\(location.locality, privacy: .public)) but not configured for this node"
                )
                result[filterID] = .discoveredButNotEnabled(
                    locality: location.locality,
                    path: location.path
                )
                continue
            }

            // Read and validate filter.json
            let filterJSONURL = location.path.appendingPathComponent("filter.json")
            let metadata: DiscoveredFilterMetadata
            do {
                let data = try Data(contentsOf: filterJSONURL)
                metadata = try JSONDecoder().decode(DiscoveredFilterMetadata.self, from: data)
            } catch {
                Self.logger.error(
                    "Failed to read filter.json for \(filterID, privacy: .public) at \(filterJSONURL.path, privacy: .public): \(error, privacy: .public)"
                )
                result[filterID] = .error(.filterJSONUnreadable(path: filterJSONURL, underlying: error))
                continue
            }

            guard metadata.totalFragments == metadata.fragments.count else {
                Self.logger.error(
                    "Fragment count mismatch for \(filterID, privacy: .public): declared=\(metadata.totalFragments, privacy: .public) actual=\(metadata.fragments.count, privacy: .public)"
                )
                result[filterID] = .error(.fragmentCountMismatch(
                    filterID: filterID,
                    declared: metadata.totalFragments,
                    actual: metadata.fragments.count
                ))
                continue
            }

            guard !metadata.version.isEmpty else {
                Self.logger.error(
                    "Missing version in filter.json for \(filterID, privacy: .public)"
                )
                result[filterID] = .error(.missingVersion(filterID: filterID))
                continue
            }

            // Validate that all fragment filenames are bare names (no path components).
            var hasInvalidFilename = false
            for fragment in metadata.fragments {
                if fragment.file.contains("/") || fragment.file.contains("\\") || fragment.file == ".." || fragment
                    .file == "." {
                    Self.logger.error(
                        "Invalid fragment filename '\(fragment.file, privacy: .public)' in filter \(filterID, privacy: .public) — must be a bare filename"
                    )
                    result[filterID] = .error(.invalidFragmentFilename(
                        filterID: filterID, file: fragment.file
                    ))
                    hasInvalidFilename = true
                    break
                }
            }
            if hasInvalidFilename { continue }

            Self.logger.log("""
            Discovered filter \(filterID, privacy: .public) (\(location.locality, privacy: .public)) \
            version=\(metadata.version, privacy: .public) \
            filterType=\(metadata.filterType?.rawValue ?? "unspecified", privacy: .public) \
            totalFragments=\(metadata.totalFragments, privacy: .public) \
            modelVersion=\(metadata.modelVersion ?? "none", privacy: .public) \
            inputSpec=\(metadata.inputSpec ?? "none", privacy: .public)
            """)
            result[filterID] = .enabled(
                locality: location.locality,
                path: location.path,
                metadata: metadata
            )
        }

        // Mark configured filterIDs that were not found anywhere.
        for filterID in filterIDs where result[filterID] == nil {
            Self.logger.warning(
                "Configured filter \(filterID, privacy: .public) not found in data cryptex at \(recitationDataRoot.path, privacy: .public)"
            )
            result[filterID] = .notFound
        }

        return result
    }

    /// Returns the immediate subdirectories of a directory, or nil if the directory
    /// cannot be read.
    private static func subdirectories(of url: URL, fm: FileManager) -> [URL]? {
        guard let contents = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        return contents.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
    }
}
