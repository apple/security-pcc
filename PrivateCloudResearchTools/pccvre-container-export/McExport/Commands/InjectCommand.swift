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
import CryptoKit
import Foundation

struct InjectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inject",
        abstract: "Append a modified service image to a megacontainer image.",
        discussion: """
            Appends a new outer layer to the megacontainer that overlays the
            target service's blobs with the replacement image's content.
            At next boot, the megacontainer's own scripts pick up the change.

            All three references (--image, replacement, --output) must use
            the apple-container: prefix.
            """
    )

    @OptionGroup var global: GlobalOptions

    @OptionGroup var imageOption: ImageOption

    @Argument(help: "Name of the embedded service being replaced.")
    var service: String

    @Argument(help: "Replacement image reference (apple-container:).")
    var replacement: String

    @Option(
        name: [.customShort("o"), .long],
        help: "Destination reference for the modified megacontainer."
    )
    var output: String

    func run() async throws {
        let rawRef = imageOption.image
        for (label, r) in [("--image", rawRef), ("<replacement>", replacement), ("--output", output)] {
            guard isAppleContainerRef(r) else {
                throw ValidationError(
                    "\(label) must use apple-container: prefix (got \"\(r)\")"
                )
            }
        }
        let outerBare = stripAppleContainerPrefix(rawRef)
        let replBare = stripAppleContainerPrefix(replacement)
        let outputBare = stripAppleContainerPrefix(output)

        let store = try AppleContainerStore.open()
        let outerImage = try await load(store: store, ref: outerBare, label: "outer megacontainer")
        let replImage  = try await load(store: store, ref: replBare, label: "replacement image")

        let platform = Platform(arch: global.arch, os: global.os)

        // Guardrail 1: target service exists in outer.
        stderr("scanning outer megacontainer to verify service \"\(service)\"...")
        let cat = try await Catalogue.scan(image: outerImage, platform: platform) { i, count, _ in
            if i == 1 || i == count || i % 10 == 0 {
                stderr("  scanning layer \(i)/\(count)...")
            }
        }
        guard cat.manifestFor[service] != nil else {
            let known = cat.manifestFor.keys.sorted().joined(separator: ", ")
            throw McExportError("service \"\(service)\" not found in outer image (known: \(known))")
        }

        // Guardrail 2: arch/os parity between replacement and outer.
        // These end up as the platform in the new image's OCI index, so a
        // missing value is a hard error rather than a "?" placeholder —
        // two unknowns would otherwise compare equal, pass this guard, and
        // write a non-compliant index.
        let outerCfgBytes = try await readRawOuterConfig(image: outerImage, platform: platform)
        let outerCfg = try decodeOuterConfig(outerCfgBytes)
        let replCfgBytes = try await readRawOuterConfig(image: replImage, platform: platform)
        let replCfg = try decodeOuterConfig(replCfgBytes)
        guard let outerArch = outerCfg.architecture, let outerOS = outerCfg.os else {
            throw McExportError(
                "outer image \"\(outerBare)\" config is missing architecture and/or os"
            )
        }
        guard let replArch = replCfg.architecture, let replOS = replCfg.os else {
            throw McExportError(
                "replacement image \"\(replBare)\" config is missing architecture and/or os"
            )
        }
        guard outerArch == replArch, outerOS == replOS else {
            throw McExportError(
                "arch/os mismatch: outer is \(outerOS)/\(outerArch), " +
                "replacement is \(replOS)/\(replArch)"
            )
        }
        stderr("arch/os OK: both are \(outerOS)/\(outerArch)")

        // Gather replacement's raw manifest and its layer blobs.
        let replDesc = try await replImage.descriptor(for: platform)
        let replManifestBytes = try await fetchBytes(image: replImage, digest: replDesc.digest)
        let replManifest = try await replImage.manifest(for: platform)

        // Diff IDs come from config's rootfs.diff_ids[], in the same order
        // as manifest.layers[].
        struct RawCfgDiff: Decodable {
            struct Rootfs: Decodable { let diff_ids: [String] }
            let rootfs: Rootfs
        }
        let replDiff = try JSONDecoder().decode(RawCfgDiff.self, from: replCfgBytes)
        guard replDiff.rootfs.diff_ids.count == replManifest.layers.count else {
            throw McExportError(
                "replacement inconsistent: \(replManifest.layers.count) layers vs " +
                "\(replDiff.rootfs.diff_ids.count) diff_ids"
            )
        }
        var replacementLayers: [(digestHex: String, diffIDHex: String, compressed: Data)] = []
        for (i, layer) in replManifest.layers.enumerated() {
            let blob = try await fetchBytes(image: replImage, digest: layer.digest)
            replacementLayers.append((
                digestHex: digestHexPart(layer.digest),
                diffIDHex: digestHexPart(replDiff.rootfs.diff_ids[i]),
                compressed: blob
            ))
        }

        // Outer descriptor + manifest type; needed to build a compatible layer.
        let outerDesc = try await outerImage.descriptor(for: platform)
        let outerManifestBytes = try await fetchBytes(image: outerImage, digest: outerDesc.digest)

        // Build the injected layer tar.
        stderr("building overlay layer for service \"\(service)\"...")
        let layer = try buildInjectedLayerTar(
            service: service,
            replacementManifestBytes: replManifestBytes,
            replacementManifestMediaType: replDesc.mediaType,
            replacementConfigBytes: replCfgBytes,
            replacementLayers: replacementLayers,
            outerManifestType: outerDesc.mediaType
        )
        stderr("  layer digest: \(layer.digest) (\(layer.size) bytes)")
        stderr("  layer diff_id: \(layer.diffID)")

        // Mutate outer config: append diff_id + history entry.
        let newOuterCfgBytes = try appendDiffIDToOuterConfig(
            configBytes: outerCfgBytes,
            newDiffID: layer.diffID,
            service: service
        )
        let newOuterCfgDigest = "sha256:" + sha256Hex(newOuterCfgBytes)

        // Mutate outer manifest: append layer + repoint config descriptor.
        let newOuterManifestBytes = try appendLayerToOuterManifest(
            manifestBytes: outerManifestBytes,
            newLayer: LayerDescriptor(
                digest: layer.digest,
                size: layer.size,
                mediaType: layer.mediaType
            ),
            newConfigDigest: newOuterCfgDigest,
            newConfigSize: newOuterCfgBytes.count
        )
        let newOuterManifestDigest = "sha256:" + sha256Hex(newOuterManifestBytes)

        // Wrap in a one-instance index. apple/container tags all its
        // images at index level (see state.json — every entry has
        // mediaType application/vnd.oci.image.index.v1+json).
        let newIndexBytes = try buildOCIIndex(
            manifestDigest: newOuterManifestDigest,
            manifestSize: newOuterManifestBytes.count,
            manifestMediaType: outerDesc.mediaType,
            platform: (arch: outerArch, os: outerOS),
            refName: outputBare
        )
        let newIndexDigest = "sha256:" + sha256Hex(newIndexBytes)

        // Ingest the four new blobs into apple/container's shared content
        // store. Existing outer image blobs stay in place — untouched.
        stderr("ingesting new blobs into content store...")
        let contentStore = try LocalContentStore(
            path: try AppleContainerStore.resolveDefaultRoot()
                .appendingPathComponent("content")
        )
        try await ingestBlob(store: contentStore, bytes: layer.compressed,
                             expectedDigest: layer.digest)
        try await ingestBlob(store: contentStore, bytes: newOuterCfgBytes,
                             expectedDigest: newOuterCfgDigest)
        try await ingestBlob(store: contentStore, bytes: newOuterManifestBytes,
                             expectedDigest: newOuterManifestDigest)
        try await ingestBlob(store: contentStore, bytes: newIndexBytes,
                             expectedDigest: newIndexDigest)

        // Register the new image via ImageStore.create.
        let description = Image.Description(
            reference: outputBare,
            descriptor: Descriptor(
                mediaType: "application/vnd.oci.image.index.v1+json",
                digest: newIndexDigest,
                size: Int64(newIndexBytes.count)
            )
        )
        _ = try await store.create(description: description)
        stderr("done: \(output)")
    }

    // MARK: Helpers

    private func load(store: ImageStore, ref: String, label: String) async throws -> Containerization.Image {
        do {
            return try await store.get(reference: ref, pull: false)
        } catch {
            throw McExportError("\(label) \"\(ref)\" not found in local store (\(error))")
        }
    }

    private func fetchBytes(image: Containerization.Image, digest: String) async throws -> Data {
        let content = try await image.getContent(digest: digest)
        return try content.data()
    }

    private func ingestBlob(
        store: LocalContentStore,
        bytes: Data,
        expectedDigest: String
    ) async throws {
        // Skip if already present — content store dedupes by digest anyway.
        if try await store.get(digest: expectedDigest) != nil { return }

        try await store.ingest { tmpDir in
            let hex = digestHexPart(expectedDigest)
            let out = tmpDir.appendingPathComponent(hex)
            try bytes.write(to: out)
        }
    }

    // stderr() lives in McExportCore.CLIHelpers.
}
