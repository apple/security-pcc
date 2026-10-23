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

import Containerization
import ContainerizationArchive
import ContainerizationOCI
import Foundation

/// Result of walking a megacontainer's outer layers for embedded-service data.
///
/// Mirrors the Go implementation's catalogue (see cmd/mcexport/catalogue.go).
/// Populated by `Catalogue.scan(image:platform:)`, which iterates each
/// resolved layer's tar entries and captures:
///
///   * manifestFor[svc] — final `manifest.json` symlink target under
///     `var/lib/containers/images/<svc>/`, last-write-wins.
///   * smallBlobs[<path>] — cached bytes of any `blobs/sha256/<hash>`
///     entry small enough to be a manifest or config (< smallBlobMax).
///
/// The scan is single-pass, streaming: each layer is opened as a tar
/// stream via libarchive-backed `ArchiveReader`; only the entries we
/// care about are retained.
public struct Catalogue: Sendable {
    /// Service name → path to the manifest.json blob it resolves to,
    /// in tar-relative form ("var/lib/containers/blobs/sha256/<hash>").
    public var manifestFor: [String: String] = [:]
    /// Cache of small OCI blob contents keyed by tar-relative path.
    /// Used to parse manifest and config JSON without a second pass.
    public var smallBlobs: [String: Data] = [:]
}

/// Paths mcexport recognizes inside each outer layer's tar.
public enum CataloguePaths {
    public static let imagesPrefix  = "var/lib/containers/images/"
    public static let blobsPrefix   = "var/lib/containers/blobs/sha256/"
    /// Only cache blobs below this size — anything larger is a layer
    /// tarball, not a manifest or config. Matches Go's smallBlobMax.
    public static let smallBlobMax: Int64 = 512 * 1024
}

extension Catalogue {
    /// Scan the outer image's layers, populating a catalogue.
    ///
    /// Streams each layer from the local content store (no data() copy
    /// into Swift memory — `Content.path` lets libarchive read direct).
    /// `progress` is called once per layer with `(index, count, digest)`.
    public static func scan(
        image: Containerization.Image,
        platform: Platform,
        progress: ((Int, Int, String) -> Void)? = nil
    ) async throws -> Catalogue {
        let manifest = try await image.manifest(for: platform)
        var cat = Catalogue()

        for (i, layerDesc) in manifest.layers.enumerated() {
            progress?(i + 1, manifest.layers.count, layerDesc.digest)
            let content = try await image.getContent(digest: layerDesc.digest)
            try cat.scanLayer(at: content.path)
        }
        return cat
    }

    /// Walk one tar layer at `url` and merge its interesting entries into
    /// the catalogue. Layer blobs are gzip tar in practice, but the OCI
    /// spec also permits zstd and plain tar, so we let libarchive sniff
    /// the format and filter rather than hardcoding `.gzip` — a non-gzip
    /// layer would otherwise fail the whole scan.
    ///
    /// Uses the streaming iterator so entry bytes are read only for the
    /// small blobs we actually cache. The non-streaming iterator
    /// materializes every entry before the caller sees the header, which
    /// meant a scan allocated the full size of the largest embedded
    /// service blob — potentially many GB — and then discarded it.
    /// libarchive skips to the next header when the data goes unread, so
    /// large entries now cost a header parse and nothing more.
    mutating func scanLayer(at url: URL) throws {
        let reader = try ArchiveReader(file: url)
        var it = reader.makeStreamingIterator()
        while let (entry, entryReader) = it.next() {
            guard let rawPath = entry.pathUtf8 ?? entry.path else { continue }
            let name = normalizeTarPath(rawPath)

            // images/<svc>/... entries.
            if name.hasPrefix(CataloguePaths.imagesPrefix) {
                let rest = String(name.dropFirst(CataloguePaths.imagesPrefix.count))
                guard let slashIdx = rest.firstIndex(of: "/") else { continue }
                let svc = String(rest[..<slashIdx])
                if svc.isEmpty { continue }

                if manifestFor[svc] == nil {
                    manifestFor[svc] = ""
                }

                let sub = String(rest[rest.index(after: slashIdx)...])
                if sub == "manifest.json",
                   entry.fileType == .symbolicLink,
                   let target = entry.symlinkTarget
                {
                    // Resolve "../../blobs/sha256/<hash>" relative to
                    // "var/lib/containers/images/<svc>/manifest.json".
                    let dir = (name as NSString).deletingLastPathComponent
                    manifestFor[svc] = tarNormalize(
                        joining: dir, and: target
                    )
                }
                continue
            }

            // Small blobs under blobs/sha256/. The size check comes from
            // the header, so oversized entries are skipped without their
            // bytes ever being read.
            if name.hasPrefix(CataloguePaths.blobsPrefix),
               entry.fileType == .regular,
               let size = entry.size,
               size > 0, size < CataloguePaths.smallBlobMax
            {
                smallBlobs[name] = try readSmallEntry(
                    entryReader,
                    name: name,
                    limit: CataloguePaths.smallBlobMax
                )
            }
        }
    }
}

/// Clean a tar-entry path: strip any leading "./" and collapse duplicate
/// slashes. Does NOT interpret ".." — the extraction sink handles that
/// via post-hoc destDir containment checks. See extractBlobsFromLayers.
///
/// Swift's `URL.standardized` won't do string-level normalization for us,
/// so a small hand-rolled normalizer suffices.
func normalizeTarPath(_ path: String) -> String {
    var s = path
    while s.hasPrefix("./") { s.removeFirst(2) }
    // Collapse runs of `/`.
    while s.contains("//") { s = s.replacingOccurrences(of: "//", with: "/") }
    return s
}

/// Join a directory path with a possibly-relative link target,
/// interpreting "../" segments. Used for resolving OCI-style symlinks
/// like `manifest.json → ../../blobs/sha256/<hash>`.
func tarNormalize(joining dir: String, and target: String) -> String {
    // Fast path: absolute target.
    if target.hasPrefix("/") {
        return normalizeTarPath(String(target.dropFirst()))
    }
    var components = dir.split(separator: "/").map(String.init)
    for part in target.split(separator: "/") {
        switch part {
        case ".":
            continue
        case "..":
            if !components.isEmpty { components.removeLast() }
        default:
            components.append(String(part))
        }
    }
    return components.joined(separator: "/")
}
