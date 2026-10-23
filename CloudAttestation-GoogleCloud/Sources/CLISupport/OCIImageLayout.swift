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
//  OCIImageLayout.swift
//  CloudAttestationV2
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//

import Crypto
import Foundation

/// Reads an OCI image layout (per the OCI Image Layout specification —
/// `oci-layout`, `index.json`, `blobs/sha256/<hex>`) and independently
/// re-derives the manifest digest by hashing the manifest blob. Used by
/// `release verify-image --container-image-layout` to verify that a
/// downloaded container image matches the `containerImageDigest` recorded in
/// a published `ReleaseV2`.
///
/// Accepts either a layout **directory** (e.g. produced by `skopeo copy
/// docker://<ref> oci:<dir>` or `crane pull --format=oci`) or a `.tar` /
/// `.tar.gz` **archive** of one (an `oci-archive`). In the archive case
/// `index.json` and the manifest blob are stream-extracted in two passes;
/// layer blobs are never decompressed past the manifest, so multi-gigabyte
/// containers stay cheap. We re-hash the manifest blob rather than trusting
/// `index.json`'s `digest` claim.
public struct OCIImageLayout {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// Re-derives the manifest digest by reading `index.json`, locating the
    /// manifest blob it references under `blobs/<alg>/<hex>`, and hashing it.
    /// If the index lists multiple manifests (a multi-arch image), the first
    /// is used; pass `architecture` to select by `platform.architecture` if
    /// the index carries platform descriptors.
    public func manifestDigest(architecture: String? = nil) throws -> String {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let backend: any LayoutBackend = isDirectory ? DirectoryBackend(root: url) : ArchiveBackend(archive: url)

        guard let indexData = try backend.read("index.json") else {
            throw OCIImageLayoutError.notAnOCILayout(path: url.path, underlying: "index.json not found")
        }
        let index = try JSONDecoder().decode(Index.self, from: indexData)
        let descriptor = try selectDescriptor(index, architecture: architecture)

        let parts = descriptor.digest.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            throw OCIImageLayoutError.malformedDigest(descriptor.digest)
        }
        let (alg, hex) = (parts[0], parts[1])

        guard let blob = try backend.read("blobs/\(alg)/\(hex)") else {
            throw OCIImageLayoutError.blobNotFound(path: "blobs/\(alg)/\(hex)")
        }
        return try "\(alg):\(hash(blob, algorithm: alg))"
    }

    private func selectDescriptor(_ index: Index, architecture: String?) throws -> ManifestDescriptor {
        if let architecture {
            guard let match = index.manifests.first(where: { $0.platform?.architecture == architecture }) else {
                throw OCIImageLayoutError.noMatchingManifest(reason: "no manifest with platform.architecture=\(architecture)")
            }
            return match
        }
        guard let first = index.manifests.first else {
            throw OCIImageLayoutError.noMatchingManifest(reason: "index.json has no manifests")
        }
        return first
    }

    private func hash(_ blob: Data, algorithm: String) throws -> String {
        switch algorithm {
        case "sha256":
            return Data(SHA256.hash(data: blob)).map { String(format: "%02x", $0) }.joined()
        case "sha512":
            return Data(SHA512.hash(data: blob)).map { String(format: "%02x", $0) }.joined()
        default:
            throw OCIImageLayoutError.unsupportedAlgorithm(algorithm)
        }
    }

    private struct Index: Decodable {
        let manifests: [ManifestDescriptor]
    }

    private struct ManifestDescriptor: Decodable {
        let digest: String
        let platform: Platform?

        struct Platform: Decodable {
            let architecture: String?
        }
    }
}

// MARK: - Backends

/// Abstracts "give me the bytes at relative path X within the layout" so the
/// digest logic above is identical for an unpacked directory and a (gzipped)
/// tar archive.
private protocol LayoutBackend {
    func read(_ relativePath: String) throws -> Data?
}

private struct DirectoryBackend: LayoutBackend {
    let root: URL
    func read(_ relativePath: String) throws -> Data? {
        let url = root.appending(path: relativePath)
        do { return try Data(contentsOf: url) } catch CocoaError.fileReadNoSuchFile { return nil }
    }
}

private struct ArchiveBackend: LayoutBackend {
    let archive: URL
    func read(_ relativePath: String) throws -> Data? {
        // oci-archive tarballs may root the layout at "." or under a single
        // top-level directory; match by suffix so either works. The blob path
        // includes the digest hex, so suffix-collision risk is negligible.
        try readTarballEntry(at: archive) { name in
            name == relativePath || name.hasSuffix("/\(relativePath)")
        }
    }
}

public enum OCIImageLayoutError: Error, CustomStringConvertible {
    case notAnOCILayout(path: String, underlying: String)
    case noMatchingManifest(reason: String)
    case malformedDigest(String)
    case blobNotFound(path: String)
    case unsupportedAlgorithm(String)

    public var description: String {
        switch self {
        case .notAnOCILayout(let path, let underlying):
            "\(path) is not an OCI image layout (\(underlying))"
        case .noMatchingManifest(let reason):
            "OCI index.json: \(reason)"
        case .malformedDigest(let d):
            "OCI manifest descriptor has malformed digest: \(d)"
        case .blobNotFound(let path):
            "OCI layout has no blob at \(path) (referenced by index.json)"
        case .unsupportedAlgorithm(let alg):
            "OCI manifest digest algorithm '\(alg)' is not supported"
        }
    }
}
