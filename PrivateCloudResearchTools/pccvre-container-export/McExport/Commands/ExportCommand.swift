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

import ArgumentParser
import Containerization
import ContainerizationOCI
import Foundation

struct ExportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export an embedded service as a standalone container image.",
        discussion: """
            Extracts a specific embedded service (blobs + manifest + config)
            from the outer megacontainer and imports it as a new tagged image
            in apple/container's local store, using the reference you provide
            via --output verbatim.
            """
    )

    @OptionGroup var global: GlobalOptions

    @OptionGroup var imageOption: ImageOption

    @Argument(help: "Name of the embedded service to export.")
    var service: String

    @Option(
        name: [.customShort("o"), .long],
        help: "Destination image reference (apple-container: prefix required)."
    )
    var output: String

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Ceiling on a single extracted blob, as a byte count or with a " +
            "unit suffix (512MB, 8GB). Pass \"unlimited\" to disable.",
            valueName: "size"
        )
    )
    var maxEntrySize: String = "8GB"

    func run() async throws {
        let maxEntryBytes = try parseByteSize(maxEntrySize)
        let rawRef = imageOption.image
        guard isAppleContainerRef(rawRef) else {
            throw ValidationError(
                "--image must use apple-container: prefix (got \"\(rawRef)\")"
            )
        }
        guard isAppleContainerRef(output) else {
            throw ValidationError(
                "--output must use apple-container: prefix (got \"\(output)\")"
            )
        }
        let sourceBare = stripAppleContainerPrefix(rawRef)
        let outputBare = stripAppleContainerPrefix(output)

        let store = try AppleContainerStore.open()
        let outerImage: Containerization.Image
        do {
            outerImage = try await store.get(reference: sourceBare, pull: false)
        } catch {
            throw McExportError("image \"\(sourceBare)\" not found in local store (\(error))")
        }

        let platform = Platform(arch: global.arch, os: global.os)
        let manifest = try await outerImage.manifest(for: platform)

        // Pass 1: catalogue scan.
        stderr("\(rawRef) — scanning \(manifest.layers.count) layers")
        let cat = try await Catalogue.scan(image: outerImage, platform: platform) { i, count, digest in
            stderr("  scanning layer \(i)/\(count) \(shortenDigest(digest))...")
        }
        guard let svcManifestPath = cat.manifestFor[service], !svcManifestPath.isEmpty else {
            let known = cat.manifestFor.keys.sorted().joined(separator: ", ")
            throw McExportError(
                "service \"\(service)\" not found in outer image (known: \(known))"
            )
        }
        guard let svcManifestBytes = cat.smallBlobs[svcManifestPath] else {
            throw McExportError(
                "manifest blob \(svcManifestPath) missing from catalogue " +
                "(may be over the small-blob cache size)"
            )
        }

        let wanted = try targetServiceBlobPaths(
            manifestPath: svcManifestPath,
            manifestBytes: svcManifestBytes
        )
        stderr("\(service): extracting \(wanted.count) blob(s)")

        // Pass 2: targeted extraction into a scratch OCI layout.
        let tmpDir = try makeMcexportTempDir(prefix: "export")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let extracted = try await extractBlobsFromLayers(
            image: outerImage,
            platform: platform,
            wantedTarPaths: wanted,
            destDir: tmpDir,
            maxEntrySize: maxEntryBytes
        ) { i, count, digest in
            stderr("  extracting from layer \(i)/\(count) \(shortenDigest(digest))...")
        }
        guard extracted == wanted.count else {
            let existingDir = tmpDir.appendingPathComponent(CataloguePaths.blobsPrefix)
            let missing = wanted.filter {
                !FileManager.default.fileExists(
                    atPath: existingDir.appendingPathComponent(
                        String($0.dropFirst(CataloguePaths.blobsPrefix.count))
                    ).path
                )
            }
            throw McExportError(
                "expected \(wanted.count) blob(s), extracted \(extracted); " +
                "missing: \(missing.sorted().joined(separator: ", "))"
            )
        }

        // Reshape extracted files into a valid OCI layout at the top of
        // tmpDir. Extractor put them under `var/lib/containers/blobs/sha256/`;
        // OCI layout expects them at `blobs/sha256/` at the layout root.
        let ociBlobs = tmpDir.appendingPathComponent("blobs/sha256")
        try FileManager.default.createDirectory(at: ociBlobs, withIntermediateDirectories: true)
        let extractedBlobs = tmpDir.appendingPathComponent(CataloguePaths.blobsPrefix)
        for f in try FileManager.default.contentsOfDirectory(atPath: extractedBlobs.path) {
            try FileManager.default.moveItem(
                at: extractedBlobs.appendingPathComponent(f),
                to: ociBlobs.appendingPathComponent(f)
            )
        }
        // Clean up the emptied var/lib/... tree.
        try? FileManager.default.removeItem(at: tmpDir.appendingPathComponent("var"))

        // oci-layout marker.
        try Data(#"{"imageLayoutVersion":"1.0.0"}"#.utf8)
            .write(to: tmpDir.appendingPathComponent("oci-layout"))

        // index.json pointing at the service's manifest. We annotate with
        // outputBare directly so apple/container tags the imported image
        // with the exact name the caller asked for — no re-tag round trip.
        let svcManifestHash = try blobHash(fromTarPath: svcManifestPath)
        let index = try buildOCIIndex(
            manifestDigest: "sha256:\(svcManifestHash)",
            manifestSize: svcManifestBytes.count,
            manifestMediaType: parseMediaType(svcManifestBytes)
                ?? "application/vnd.oci.image.manifest.v1+json",
            refName: outputBare
        )
        try index.write(to: tmpDir.appendingPathComponent("index.json"))

        // Hand to Containerization's OCI layout importer.
        stderr("importing as \(outputBare)")
        let loaded = try await store.load(from: tmpDir)
        guard let firstLoaded = loaded.first else {
            throw McExportError("ImageStore.load produced no images")
        }
        // Containerization may normalize the reference on ingest; if the
        // resulting name doesn't match what the caller asked for, retag.
        // In practice this is a no-op for well-formed apple-container:
        // refs but the guard is cheap.
        if firstLoaded.reference != outputBare {
            _ = try await store.tag(existing: firstLoaded.reference, new: outputBare)
        }
        stderr("done: \(output)")
    }

    // MARK: - Helpers

    private func parseMediaType(_ bytes: Data) -> String? {
        struct Peek: Decodable { let mediaType: String? }
        return try? JSONDecoder().decode(Peek.self, from: bytes).mediaType
    }
}
