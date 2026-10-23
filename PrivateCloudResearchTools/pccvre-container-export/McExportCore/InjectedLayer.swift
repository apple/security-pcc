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

import ContainerizationArchive
import ContainerizationOCI
import CryptoKit
import Foundation

/// Bytes and metadata of a new outer-image layer built to overlay a
/// replaced embedded service on the megacontainer.
public struct InjectedLayer: Sendable {
    /// Gzipped tar bytes, ready to be stored as an OCI layer blob.
    public let compressed: Data
    /// sha256 of the compressed bytes ("sha256:...").
    public let digest: String
    /// Size of `compressed` in bytes.
    public let size: Int
    /// sha256 of the uncompressed tar ("sha256:..."), i.e. rootfs.diff_id.
    public let diffID: String
    /// Media type of the compressed layer.
    public let mediaType: String
}

/// Build a single-manifest OCI index.
///
/// Every value here can carry caller-supplied text — service names and
/// `--output` references come straight from argv, and media types are
/// parsed out of untrusted blob content. Serializing through
/// `JSONSerialization` rather than string interpolation means a quote or
/// backslash in any of them produces correctly escaped JSON instead of a
/// malformed document that fails cryptically at import time.
///
/// `platform` and `refName` are omitted from the output when nil, matching
/// what each caller needs: the embedded-service index carries a ref name
/// but no platform, the export index the same, and the outer index both.
public func buildOCIIndex(
    manifestDigest: String,
    manifestSize: Int,
    manifestMediaType: String,
    platform: (arch: String, os: String)? = nil,
    refName: String? = nil
) throws -> Data {
    var descriptor: [String: Any] = [
        "mediaType": manifestMediaType,
        "digest": manifestDigest,
        "size": manifestSize,
    ]
    if let platform {
        descriptor["platform"] = [
            "architecture": platform.arch,
            "os": platform.os,
        ]
    }
    if let refName {
        descriptor["annotations"] = [
            "org.opencontainers.image.ref.name": refName
        ]
    }
    let index: [String: Any] = [
        "schemaVersion": 2,
        "mediaType": "application/vnd.oci.image.index.v1+json",
        "manifests": [descriptor],
    ]
    return try JSONMut.encode(index)
}

/// Bytes we plan to place under `var/lib/containers/images/<svc>/index.json`.
/// A minimal one-manifest OCI index annotated with the service name.
public func buildEmbeddedServiceIndex(
    service: String,
    manifestDigest: String,
    manifestSize: Int,
    manifestMediaType: String
) throws -> Data {
    try buildOCIIndex(
        manifestDigest: manifestDigest,
        manifestSize: manifestSize,
        manifestMediaType: manifestMediaType,
        refName: "\(service):latest"
    )
}

/// Build the new outer layer tar for an inject.
///
/// Layout matches what `megacontainer-load-image` produces at build time:
///
///   var/lib/containers/blobs/sha256/<manifest-hash>   (regular file, manifest bytes)
///   var/lib/containers/blobs/sha256/<config-hash>     (regular file, config bytes)
///   var/lib/containers/blobs/sha256/<layer-hash>...   (regular files, one per layer)
///   var/lib/containers/blobs/diffid/<diff-id>         (symlink → ../../blobs/sha256/<layer-hash>)
///   var/lib/containers/images/<svc>/manifest.json     (symlink → ../../blobs/sha256/<manifest-hash>)
///   var/lib/containers/images/<svc>/config.json       (symlink → ../../blobs/sha256/<config-hash>)
///   var/lib/containers/images/<svc>/index.json        (regular file)
///
/// - Parameters:
///   - service: Name of the embedded service being replaced.
///   - replacementManifestBytes: Raw manifest.json JSON of the replacement image.
///   - replacementConfigBytes: Raw config JSON.
///   - replacementLayers: (blobDigestHex, diffIDHex, compressedBytes) triples,
///                        ordered bottom-to-top.
///   - outerManifestType: Media type of the OUTER manifest. Selects docker
///                        vs OCI media type for our new layer to match.
public func buildInjectedLayerTar(
    service: String,
    replacementManifestBytes: Data,
    replacementManifestMediaType: String,
    replacementConfigBytes: Data,
    replacementLayers: [(digestHex: String, diffIDHex: String, compressed: Data)],
    outerManifestType: String
) throws -> InjectedLayer {
    let manifestHex = sha256Hex(replacementManifestBytes)
    let configHex = sha256Hex(replacementConfigBytes)

    // Write tar to a tmp file — libarchive-backed writer needs a
    // filehandle/URL; there's no in-memory writer at present.
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("mcexport-layer-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let uncompressedTarURL = tmpDir.appendingPathComponent("layer.tar")

    // Write plain (uncompressed) tar first — we need the uncompressed
    // sha256 as the diff_id.
    let writer = try ArchiveWriter(
        format: .paxRestricted,
        filter: .none,
        file: uncompressedTarURL
    )

    let svcDir = "var/lib/containers/images/\(service)/"

    // Directory entries. Order-of-mkdir doesn't matter for tar readers,
    // but we emit them anyway for portability.
    for dir in [
        "var/",
        "var/lib/",
        "var/lib/containers/",
        "var/lib/containers/blobs/",
        "var/lib/containers/blobs/sha256/",
        "var/lib/containers/blobs/diffid/",
        "var/lib/containers/images/",
        svcDir,
    ] {
        let e = WriteEntry()
        e.pathUtf8 = dir
        e.fileType = .directory
        e.permissions = mode_t(0o755)
        try writer.writeEntry(entry: e, data: nil)
    }

    // Emit blob files.
    func emitFile(path: String, data: Data) throws {
        let e = WriteEntry()
        e.pathUtf8 = path
        e.fileType = .regular
        e.permissions = mode_t(0o644)
        e.size = Int64(data.count)
        try writer.writeEntry(entry: e, data: data)
    }
    try emitFile(path: "var/lib/containers/blobs/sha256/\(manifestHex)", data: replacementManifestBytes)
    try emitFile(path: "var/lib/containers/blobs/sha256/\(configHex)", data: replacementConfigBytes)
    for (digestHex, _, blob) in replacementLayers {
        try emitFile(path: "var/lib/containers/blobs/sha256/\(digestHex)", data: blob)
    }

    // Emit diffid symlinks pointing at layer blobs.
    for (digestHex, diffIDHex, _) in replacementLayers {
        let e = WriteEntry()
        e.pathUtf8 = "var/lib/containers/blobs/diffid/\(diffIDHex)"
        e.fileType = .symbolicLink
        e.symlinkTarget = "../../blobs/sha256/\(digestHex)"
        e.permissions = mode_t(0o777)
        try writer.writeEntry(entry: e, data: nil)
    }

    // images/<svc>/manifest.json symlink.
    do {
        let e = WriteEntry()
        e.pathUtf8 = "\(svcDir)manifest.json"
        e.fileType = .symbolicLink
        e.symlinkTarget = "../../blobs/sha256/\(manifestHex)"
        e.permissions = mode_t(0o777)
        try writer.writeEntry(entry: e, data: nil)
    }
    // images/<svc>/config.json symlink.
    do {
        let e = WriteEntry()
        e.pathUtf8 = "\(svcDir)config.json"
        e.fileType = .symbolicLink
        e.symlinkTarget = "../../blobs/sha256/\(configHex)"
        e.permissions = mode_t(0o777)
        try writer.writeEntry(entry: e, data: nil)
    }
    // images/<svc>/index.json regular file.
    let idx = try buildEmbeddedServiceIndex(
        service: service,
        manifestDigest: "sha256:\(manifestHex)",
        manifestSize: replacementManifestBytes.count,
        manifestMediaType: replacementManifestMediaType
    )
    try emitFile(path: "\(svcDir)index.json", data: idx)

    try writer.finishEncoding()

    // Read the uncompressed tar to compute diff_id, then gzip it.
    let uncompressedBytes = try Data(contentsOf: uncompressedTarURL)
    let diffIDHex = sha256Hex(uncompressedBytes)

    let gzURL = tmpDir.appendingPathComponent("layer.tar.gz")
    try gzip(uncompressedURL: uncompressedTarURL, outURL: gzURL)
    let gzBytes = try Data(contentsOf: gzURL)
    let blobHex = sha256Hex(gzBytes)

    return InjectedLayer(
        compressed: gzBytes,
        digest: "sha256:\(blobHex)",
        size: gzBytes.count,
        diffID: "sha256:\(diffIDHex)",
        mediaType: layerMediaType(forOuter: outerManifestType)
    )
}

/// Docker schema-2 outer manifests demand docker layer media types;
/// OCI outers accept OCI layer media types. Match the outer's family.
public func layerMediaType(forOuter outerManifestType: String) -> String {
    switch outerManifestType {
    case "application/vnd.docker.distribution.manifest.v2+json",
         "application/vnd.docker.distribution.manifest.v1+json",
         "application/vnd.docker.distribution.manifest.v1+prettyjws":
        return "application/vnd.docker.image.rootfs.diff.tar.gzip"
    default:
        return "application/vnd.oci.image.layer.v1.tar+gzip"
    }
}

/// Hex sha256 of raw bytes. Uses swift-crypto's SHA256.
public func sha256Hex(_ data: Data) -> String {
    let h = SHA256.hash(data: data)
    return h.map { String(format: "%02x", $0) }.joined()
}

/// Gzip a file at `uncompressedURL` to `outURL`. Shells out to
/// /usr/bin/gzip — simplest correct path on macOS, and avoids pulling in
/// a full-blown compression dependency for this one operation. Cost of
/// this choice: the tool depends on a system binary being present, which
/// it is on every stock macOS install.
private func gzip(uncompressedURL: URL, outURL: URL) throws {
    // Create/truncate the output file so gzip can open it for write.
    FileManager.default.createFile(atPath: outURL.path, contents: nil)
    let outHandle = try FileHandle(forWritingTo: outURL)
    defer { try? outHandle.close() }

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
    proc.arguments = ["-c", uncompressedURL.path]
    proc.standardOutput = outHandle
    try proc.run()
    proc.waitUntilExit()
    if proc.terminationStatus != 0 {
        throw McExportError("gzip exited with status \(proc.terminationStatus)")
    }
}
