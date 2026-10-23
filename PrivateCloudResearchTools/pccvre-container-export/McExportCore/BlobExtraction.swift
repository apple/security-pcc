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
import CryptoKit
import Foundation

/// Default ceiling on a single extracted tar entry, overridable per-run
/// via `mcexport export --max-entry-size`.
///
/// Entries stream to disk a chunk at a time and are never held in memory
/// whole, so this is a disk-fill guard rather than a memory bound: it
/// stops a hostile or corrupt header from filling the volume before the
/// digest check can reject the content. 8 GB sits well above realistic
/// megacontainer blobs (a service shipping model weights, say) while
/// still bounding the damage. Pass `--max-entry-size unlimited` to opt
/// out entirely.
public let defaultMaxExtractedEntrySize: Int64 = 8 * 1024 * 1024 * 1024

/// Parse a byte-size option value: a plain byte count ("1048576"), or a
/// number with a unit suffix ("512MB", "8GB", "2 GiB"). Returns nil for
/// "unlimited" / "none" / "0", meaning no cap.
///
/// Suffixes are binary multiples — 1 GB here means 1024 MB, and the "GiB"
/// spelling is accepted as a synonym. Sizes this guards are memory- and
/// disk-shaped rather than marketing-shaped, so powers of two are the
/// useful reading.
public func parseByteSize(_ raw: String) throws -> Int64? {
    let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
    guard !s.isEmpty else {
        throw McExportError("expected a byte size, got an empty value")
    }
    if s == "unlimited" || s == "none" { return nil }

    let digits = s.prefix { $0.isNumber }
    let suffix = s.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
    guard !digits.isEmpty, let value = Int64(digits) else {
        throw McExportError(
            "could not parse \"\(raw)\" as a byte size " +
            "(expected e.g. 8GB, 512MB, 1048576, or unlimited)"
        )
    }

    let multiplier: Int64
    switch suffix {
    case "", "b":          multiplier = 1
    case "k", "kb", "kib": multiplier = 1024
    case "m", "mb", "mib": multiplier = 1024 * 1024
    case "g", "gb", "gib": multiplier = 1024 * 1024 * 1024
    case "t", "tb", "tib": multiplier = 1024 * 1024 * 1024 * 1024
    default:
        throw McExportError(
            "unrecognized size suffix \"\(suffix)\" in \"\(raw)\" " +
            "(expected B, KB, MB, GB, or TB)"
        )
    }

    if value == 0 { return nil }
    let (product, overflowed) = value.multipliedReportingOverflow(by: multiplier)
    guard !overflowed else {
        throw McExportError("byte size \"\(raw)\" is too large to represent")
    }
    return product
}

/// Regex-equivalent guard: does the string look like a lowercase hex
/// sha256 (exactly 64 chars of [0-9a-f])?
///
/// Used to defend the extraction sink from path-traversal attacks where
/// a hostile embedded manifest could declare digests like
/// "sha256:../../../etc/passwd". We reject at parse time.
@inlinable
public func isValidSha256Hex(_ s: String) -> Bool {
    guard s.count == 64 else { return false }
    for ch in s.utf8 {
        switch ch {
        case 0x30...0x39, 0x61...0x66:  // '0'-'9' or 'a'-'f'
            continue
        default:
            return false
        }
    }
    return true
}

/// Stream one tar entry to `destination`, hashing as we go, without ever
/// holding the whole entry in memory.
///
/// Two properties matter here and they pull against each other: the entry
/// may be arbitrarily large (so it must not be buffered), and its bytes
/// must not be trusted until the digest checks out (so they must not
/// appear at their final path unverified). Writing to a caller-supplied
/// temporary path and hashing each chunk on the way satisfies both — the
/// caller renames into place only once `expectedHex` matches.
///
/// Returns the number of bytes written and their sha256 hex.
///
/// `limit` is a disk-fill guard: nil means no ceiling, otherwise we stop
/// and throw as soon as the running total exceeds it, which also catches
/// a header that under-declares its size.
@discardableResult
func streamEntry(
    _ reader: ArchiveEntryReader,
    name: String,
    to destination: URL,
    limit: Int64?
) throws -> (bytes: Int64, sha256Hex: String) {
    let chunkSize = 1 << 20  // 1 MiB
    let fm = FileManager.default
    guard fm.createFile(atPath: destination.path, contents: nil) else {
        throw McExportError("could not create \(destination.path) while extracting \(name)")
    }
    let handle = try FileHandle(forWritingTo: destination)
    defer { try? handle.close() }

    var hasher = SHA256()
    var total: Int64 = 0
    var buf = [UInt8](repeating: 0, count: chunkSize)

    while true {
        let n = buf.withUnsafeMutableBufferPointer { p -> Int in
            guard let base = p.baseAddress else { return -1 }
            return reader.read(base, maxLength: chunkSize)
        }
        if n == 0 { break }
        guard n > 0 else {
            throw McExportError("read error while extracting \(name)")
        }
        total += Int64(n)
        if let limit, total > limit {
            throw McExportError(
                "refusing to extract \(name): content exceeds \(limit)-byte cap " +
                "(header may under-declare its size)"
            )
        }
        try buf.withUnsafeBytes { raw in
            let chunk = UnsafeRawBufferPointer(rebasing: raw[0..<n])
            hasher.update(bufferPointer: chunk)
            try handle.write(contentsOf: Data(chunk))
        }
    }

    try handle.synchronize()
    let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    return (total, hex)
}

/// Read a small tar entry fully into memory, refusing to exceed `limit`.
///
/// For the catalogue's manifest/config blobs, which are known-small and
/// wanted as bytes. The limit still applies: the header's declared size
/// is what selected this entry, and a header can lie, so we stop if the
/// actual content runs past what was promised.
func readSmallEntry(
    _ reader: ArchiveEntryReader,
    name: String,
    limit: Int64
) throws -> Data {
    let chunkSize = 64 * 1024
    var out = Data()
    var buf = [UInt8](repeating: 0, count: chunkSize)
    while true {
        let n = buf.withUnsafeMutableBufferPointer { p -> Int in
            guard let base = p.baseAddress else { return -1 }
            return reader.read(base, maxLength: chunkSize)
        }
        if n == 0 { break }
        guard n > 0 else {
            throw McExportError("read error while scanning \(name)")
        }
        guard Int64(out.count) + Int64(n) <= limit else {
            throw McExportError(
                "refusing to cache \(name): content exceeds \(limit)-byte " +
                "small-blob cap (header under-declared its size)"
            )
        }
        out.append(contentsOf: buf[0..<n])
    }
    return out
}

/// Extracts specific blob files from a megacontainer's outer layers into
/// a destination directory. Used by `export` to pull one service's
/// blobs out without materializing the entire outer image.
///
/// `wantedTarPaths` is the set of tar-relative paths to extract, e.g.
/// `["var/lib/containers/blobs/sha256/<manifest-hash>",
///   "var/lib/containers/blobs/sha256/<config-hash>",
///   "var/lib/containers/blobs/sha256/<layer-hash>", ...]`.
///
/// Each extracted file is written to `destDir/<tar-relative-path>`.
/// Later-layer wins on duplicates (mirrors overlayfs semantics), though
/// blobs in the megacontainer are unique so this rarely comes up.
///
/// Security posture: we treat the outer image as UNTRUSTED. Two defenses:
///   1. Each entry's normalized destination must resolve inside destDir —
///      guards path-traversal (../../etc/passwd) writes.
///   2. Each written blob's sha256 is verified against the digest baked
///      into the tar path — guards content tampering.
///
/// A crafted manifest that requests a blob outside destDir causes the
/// extraction to abort before any bytes are read. Content is streamed to a
/// temporary name and hashed as it goes, so a blob whose bytes don't match
/// its declared digest is unlinked and the extraction aborts — nothing
/// unverified ever appears at a real blob path.
///
/// `maxEntrySize` caps a single entry as a disk-fill guard; nil disables it.
///
/// Returns the count of paths successfully extracted.
public func extractBlobsFromLayers(
    image: Containerization.Image,
    platform: Platform,
    wantedTarPaths: Set<String>,
    destDir: URL,
    maxEntrySize: Int64? = defaultMaxExtractedEntrySize,
    progress: ((Int, Int, String) -> Void)? = nil
) async throws -> Int {
    let manifest = try await image.manifest(for: platform)
    var written: Set<String> = []
    let fm = FileManager.default
    // Resolve symlinks on the destination root too, not just on each
    // candidate path: on macOS the temp dir sits under /var, which is
    // itself a symlink to /private/var, so comparing a resolved path
    // against an unresolved root would reject every legitimate write.
    let destDirResolved = destDir.resolvingSymlinksInPath()
        .standardizedFileURL.path

    for (i, layerDesc) in manifest.layers.enumerated() {
        progress?(i + 1, manifest.layers.count, layerDesc.digest)
        let content = try await image.getContent(digest: layerDesc.digest)
        let reader = try ArchiveReader(file: content.path)
        // Streaming iterator: the header is inspected before any of the
        // entry's bytes are read, and entries we don't want cost nothing
        // but a header parse because libarchive skips unconsumed data.
        var it = reader.makeStreamingIterator()
        while let (entry, entryReader) = it.next() {
            guard let rawPath = entry.pathUtf8 ?? entry.path else { continue }
            let name = normalizeTarPath(rawPath)
            guard wantedTarPaths.contains(name), entry.fileType == .regular else {
                continue
            }

            // Size guard. A declared size over the cap is rejected before
            // we read a byte; a missing or under-declared size is caught
            // mid-stream by streamEntry.
            if let maxEntrySize, let size = entry.size, size > maxEntrySize {
                throw McExportError(
                    "refusing to extract \(name): declared size \(size) exceeds " +
                    "\(maxEntrySize)-byte cap"
                )
            }

            // Path-traversal guard. `destDir.appendingPathComponent(name)`
            // will happily produce a path ABOVE destDir if `name` contains
            // "../". Standardizing resolves those segments; resolving
            // symlinks additionally catches the case where a directory
            // component under destDir links somewhere else entirely, which
            // lexical normalization alone would miss.
            let out = destDir.appendingPathComponent(name)
            let outResolved = out.resolvingSymlinksInPath()
                .standardizedFileURL.path
            guard outResolved == destDirResolved
                || outResolved.hasPrefix(destDirResolved + "/") else {
                throw McExportError(
                    "refusing to extract \(name): resolves to \(outResolved), " +
                    "which is outside destination \(destDirResolved)"
                )
            }

            // If the tar path is a blob-store entry
            // ("var/lib/containers/blobs/sha256/<hash>"), its bytes must
            // hash to <hash>. Otherwise the outer image lied about the
            // content and downstream consumers would trust malicious bytes
            // as authentic OCI blobs. Reject the filename shape up front so
            // a bogus digest costs nothing to detect.
            var claimedHex: String?
            if name.hasPrefix(CataloguePaths.blobsPrefix) {
                let hex = String(name.dropFirst(CataloguePaths.blobsPrefix.count))
                guard isValidSha256Hex(hex) else {
                    throw McExportError(
                        "refusing to extract \(name): filename is not a valid " +
                        "sha256 hex digest"
                    )
                }
                claimedHex = hex
            }

            try fm.createDirectory(
                at: out.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            // Stream to a sibling temp name, then promote by rename only
            // once the digest matches. Nothing unverified is ever visible
            // at the real blob path, and nothing is buffered in memory.
            let staging = out.deletingLastPathComponent()
                .appendingPathComponent(".mcexport-staging-\(UUID().uuidString)")
            var promoted = false
            defer { if !promoted { try? fm.removeItem(at: staging) } }

            let result = try streamEntry(
                entryReader,
                name: name,
                to: staging,
                limit: maxEntrySize
            )
            if let claimedHex, result.sha256Hex != claimedHex {
                throw McExportError(
                    "digest mismatch on \(name): declared \(claimedHex), " +
                    "actual \(result.sha256Hex)"
                )
            }

            if fm.fileExists(atPath: out.path) {
                try fm.removeItem(at: out)
            }
            try fm.moveItem(at: staging, to: out)
            promoted = true
            written.insert(name)
        }
    }
    return written.count
}

/// Given a service's manifest bytes, returns the set of tar-relative
/// blob paths that make up that service inside the megacontainer:
///   * the manifest blob itself
///   * the config blob
///   * every layer blob
///
/// Any digest that fails hex-format validation is rejected — this
/// prevents a hostile manifest from smuggling path-traversal payloads
/// through digest strings ("sha256:../../pwn").
public func targetServiceBlobPaths(
    manifestPath: String,
    manifestBytes: Data
) throws -> Set<String> {
    let parsed = try JSONDecoder().decode(EmbeddedManifest.self, from: manifestBytes)
    var paths: Set<String> = [manifestPath]

    func requireHex(_ digest: String, label: String) throws -> String {
        let hex = digestHexPart(digest)
        guard isValidSha256Hex(hex) else {
            throw McExportError("\(label) digest \"\(digest)\" is not a valid sha256")
        }
        return hex
    }

    if let cfg = parsed.config {
        let hex = try requireHex(cfg.digest, label: "config")
        paths.insert(CataloguePaths.blobsPrefix + hex)
    }
    for layer in parsed.layers {
        let hex = try requireHex(layer.digest, label: "layer")
        paths.insert(CataloguePaths.blobsPrefix + hex)
    }
    return paths
}

/// "sha256:abc..." → "abc..." (strips the "sha256:" prefix). Returns the
/// input verbatim if no colon is present — the caller is expected to
/// hex-validate the result before trusting it in a filesystem path.
public func digestHexPart(_ digest: String) -> String {
    guard let colon = digest.firstIndex(of: ":") else { return digest }
    return String(digest[digest.index(after: colon)...])
}

/// Recover the sha256 hex of a blob from its tar-relative path
/// ("var/lib/containers/blobs/sha256/<hash>" → "<hash>").
///
/// Stripping the prefix with `dropFirst` cannot fail loudly on its own: a
/// path shorter than the prefix yields an empty Substring, which would go
/// on to produce the invalid digest "sha256:" in a generated index.json
/// and a cryptic failure at import. Validate the shape instead.
public func blobHash(fromTarPath path: String) throws -> String {
    guard path.hasPrefix(CataloguePaths.blobsPrefix) else {
        throw McExportError(
            "could not derive a sha256 hash from blob path \(path): " +
            "expected it to start with \(CataloguePaths.blobsPrefix)"
        )
    }
    let hex = String(path.dropFirst(CataloguePaths.blobsPrefix.count))
    guard isValidSha256Hex(hex) else {
        throw McExportError(
            "could not derive a sha256 hash from blob path \(path): " +
            "\"\(hex)\" is not a valid sha256 hex digest"
        )
    }
    return hex
}

/// Reject a value that would span more than one line.
///
/// Used for text interpolated into line-oriented formats (a generated
/// Dockerfile), where an embedded newline ends the current instruction
/// early and turns the remainder into instructions of its own.
public func requireSingleLine(_ value: String, label: String) throws {
    guard !value.contains(where: \.isNewline) else {
        throw McExportError("\(label) value \"\(value)\" contains a newline")
    }
}
