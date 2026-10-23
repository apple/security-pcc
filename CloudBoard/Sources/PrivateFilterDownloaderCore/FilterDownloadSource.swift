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

protocol FilterDownloadSource: Sendable {
    func buildFragments(filterDirectory: URL) -> Swift.Result<[FragmentMetadata], Error>
    /// Publish the filter descriptor (`filter.json`, carrying the HMAC key) to
    /// `destinationURL`. The descriptor lives separately from the fragment files.
    func finalizeDescriptor(to destinationURL: URL) throws
}

// MARK: - Standard (cryptex-discovered) filters

struct StandardFilterDownloadSource: FilterDownloadSource {
    private static let logger = Logger(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "StandardFilterDownloadSource"
    )

    let filterID: FilterIDString
    let urlPrefix: String
    let metadata: DiscoveredFilterMetadata
    let sourceFilterJSON: URL
    /// When set, used as the filterID path segment of the fragment download URL in
    /// place of `filterID` (for filters whose CDN path differs from their filterID).
    /// Only the URL is affected; `filterID` still drives the cache dir and descriptor.
    var urlFilterIDOverride: String? = nil

    func buildFragments(filterDirectory: URL) -> Swift.Result<[FragmentMetadata], Error> {
        guard !self.metadata.version.isEmpty else {
            return .failure(FilterPlanError.missingRevision(filterID: self.filterID))
        }
        let revision = self.metadata.version
        var fragments: [FragmentMetadata] = []
        for entry in self.metadata.fragments.sorted(by: { $0.prefixValue < $1.prefixValue }) {
            // Treat a blank override as unset so a fat-fingered empty value falls back
            // to the real filterID rather than producing a `<urlPrefix>//<rev>/…` path.
            let urlFilterID = self.urlFilterIDOverride.flatMap { $0.isEmpty ? nil : $0 } ?? self.filterID
            let urlString = "\(self.urlPrefix)/\(urlFilterID)/\(revision)/\(entry.file)"
            guard let sourceURL = URL(string: urlString) else {
                return .failure(FilterPlanError.invalidFragmentURL(urlString))
            }
            // Prefer the explicit on-disk `file_size` (written for both families;
            // ribbon always carries it). Fall back to the bloom convention of
            // `bloom_length + 4` for legacy bloom descriptors that predate it.
            guard let fileSize = entry.fileSize ?? entry.bloomLength.map({ $0 + 4 }) else {
                return .failure(FilterPlanError.missingFragmentSize(
                    filterID: self.filterID, file: entry.file
                ))
            }
            fragments.append(
                FragmentMetadata(
                    id: entry.file,
                    source: sourceURL,
                    destination: filterDirectory.appendingPathComponent(entry.file),
                    sha256: entry.checksum,
                    fileSize: fileSize
                )
            )
        }
        return .success(fragments)
    }

    func finalizeDescriptor(to destinationURL: URL) throws {
        // The descriptor lives next to status.json (ephemeral data volume), NOT in
        // the fragments directory (which may be a persistent cache volume), so the
        // HMAC key is re-sourced from the signed cryptex each boot.
        let fm = FileManager.default
        try fm.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destinationURL.path) {
            try fm.removeItem(at: destinationURL)
        }
        try fm.copyItem(at: self.sourceFilterJSON, to: destinationURL)
        Self.logger.log("""
        Copied filter descriptor. \
        FilterID=\(self.filterID, privacy: .public) \
        Destination=\(destinationURL.path, privacy: .public)
        """)
    }
}
