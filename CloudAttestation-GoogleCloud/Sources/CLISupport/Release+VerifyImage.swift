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
//  Release+VerifyImage.swift
//  CloudAttestationV2
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//

import ArgumentParser
import CloudAttestationV2
import Common
import FirmwareMeasurement
import Foundation
import ImageMeasurement
import SwiftASN1

extension Release {
    /// Re-measure the boot artifacts of an OS image on disk and compare them
    /// against the workload measurements in a published `ReleaseV2` manifest.
    ///
    /// Only fields that can be derived from local artifacts (or from public
    /// reference services) are checked:
    ///   - UKI/OVMF digests for host images; shim/grub/vmlinuz/cmdline for
    ///     VM images — re-derived from `--image`.
    ///   - NVIDIA driver SPDM blocks — when `--verify-nvidia-driver` is set,
    ///     the driver version found in the image's OEM partition is used to
    ///     fetch the corresponding RIM from NVIDIA's public RIM service and
    ///     the resulting blocks are compared block-by-block.
    ///   - Container image digest — when `--container-image-layout` points at
    ///     an OCI image layout (unpacked directory or `.tar.gz` archive), the
    ///     manifest blob is re-hashed.
    /// Anything else (variant) is reported as informational only.
    ///
    /// `pccvre release verify` (in srd_tools) shells out to this for v2-format
    /// releases after downloading the OS image and (optionally) the container
    /// image.
    public struct VerifyImage: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "verify-image",
            abstract: "Re-measure an OS disk image and compare against a published ReleaseV2 manifest."
        )

        public init() {}

        @Option(
            name: .long,
            help:
                "Path to the OS image. Either the raw GPT disk image (.img/.raw) or the published .tar.gz/.tar bundle — the disk image is extracted automatically in the latter case."
        )
        public var image: String

        @Option(name: .long, help: "Path to the file containing the published ReleaseV2 DER bytes, or - for stdin.")
        public var release: String

        @Flag(name: .long, help: "Treat --release input as base64-encoded DER bytes.")
        public var releaseBase64: Bool = false

        @Option(
            name: .long,
            help:
                "Whether to measure the image as a host image (UKI digests, embedded guest VMs) or a VM image (shim/grub/vmlinuz boot chain). `auto` (default) opens the EFI-SYSTEM partition and decides structurally; pass `host` or `vm` to override."
        )
        public var imageKind: ImageKind = .auto

        @Flag(name: .long, help: "Deprecated alias for `--image-kind host`.")
        public var host: Bool = false

        @Option(name: .long, help: "Architecture for VM images.")
        public var arch: Architecture = .x86_64

        @Flag(
            name: .long,
            help:
                "Re-derive the NVIDIA driver SPDM blocks: read the driver version from the image's OEM partition, fetch the matching RIM from rim.attestation.nvidia.com, and compare blocks against the published release. Requires network access."
        )
        public var verifyNvidiaDriver: Bool = false

        @Option(name: .long, help: "GPU product code for constructing the driver RIM name (default GB100).")
        public var gpuProduct: String = "GB100"

        @Option(
            name: .long,
            help:
                "Path to an OCI image layout: either an unpacked directory (e.g. `skopeo copy docker://<ref> oci:<dir>`) or a .tar / .tar.gz oci-archive of one. The manifest blob is re-hashed and compared against the published containerImageDigest."
        )
        public var containerImageLayout: String?

        @Option(
            name: [.long, .customShort("f")],
            help: "Output format: text (human-readable comparison table) or json (SubprocessEnvelope wrapping a VerifyImageReport)."
        )
        public var outputFormat: OutputOptions.OutputFormat = .text

        private var json: Bool { outputFormat == .json }

        public func validate() throws {
            if host, imageKind != .auto {
                throw ValidationError("--host is a deprecated alias for --image-kind host; do not combine it with --image-kind.")
            }
        }

        public func run() async throws {
            let expected = try loadExpectedRelease()
            guard let workload = expected.gcpV1Workload else {
                throw ValidationError("Supplied ReleaseV2 has no workload measurements; nothing to verify against.")
            }

            let imageURL = try resolveDiskImage()
            let resolvedKind = try resolveImageKind(at: imageURL)

            var rows: [FieldComparison]
            let driverVersion: String?
            switch resolvedKind {
            case .host:
                let measured = try HostImage(url: imageURL).measure()
                driverVersion = measured.nvidiaDriverVersion
                rows = compareHostImage(measured, against: workload)
            case .vm:
                let measured = try VMImage(url: imageURL, architecture: arch).measure()
                driverVersion = measured.nvidiaDriverVersion
                rows = compareVMImage(measured, against: workload)
            }

            try await rows.append(contentsOf: compareNvidiaDriver(driverVersion: driverVersion, against: workload))
            try rows.append(contentsOf: compareContainerImage(against: workload))
            rows.append(.info("variant", note: workload.variant.map { "\($0) (not re-derived from image)" }))

            try emit(rows, expected: expected)
        }

        // MARK: - Input resolution

        /// Returns a URL to the raw GPT disk image. If `--image` points at a
        /// `.tar.gz`/`.tgz`/`.tar` archive, the first `.img`/`.raw` entry is
        /// extracted to a temporary directory and that path is returned.
        private func resolveDiskImage() throws -> URL {
            let url = URL(fileURLWithPath: image)
            let lower = image.lowercased()
            if lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz") || lower.hasSuffix(".tar") {
                if !json {
                    FileHandle.standardError.write(Data("Extracting disk image from \(url.lastPathComponent)...\n".utf8))
                }
                return try extractDiskImage(fromTarball: url)
            }
            return url
        }

        /// User-facing image-kind selector. `auto` defers to
        /// ``ImageMeasurement/detectDiskImageKind(at:)``; the explicit cases
        /// override it.
        public enum ImageKind: String, ExpressibleByArgument, Sendable {
            case auto
            case host
            case vm
        }

        private func resolveImageKind(at url: URL) throws -> DiskImageKind {
            // --host predates --image-kind; honour it for back-compat with
            // existing callers (CloudAttestationV2Internal's release image
            // command, older pccvre-attestation-helper invocations).
            if host { return .host }
            switch imageKind {
            case .host: return .host
            case .vm: return .vm
            case .auto:
                let detected = try DiskImageKind.detect(at: url)
                if !json {
                    FileHandle.standardError.write(Data("Detected \(detected.rawValue) image (use --image-kind to override)\n".utf8))
                }
                return detected
            }
        }

        private func loadExpectedRelease() throws -> ReleaseV2 {
            var data = try readInputData(at: release)
            if releaseBase64 {
                guard let trimmed = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                    let decoded = Data(base64Encoded: trimmed)
                else {
                    throw ValidationError("--release input is not valid base64-encoded data.")
                }
                data = decoded
            }
            do {
                return try ReleaseV2(derEncoded: Array(data))
            } catch {
                throw ValidationError("Failed to decode ReleaseV2: \(error)")
            }
        }

        // MARK: - OS boot chain comparison

        private func compareVMImage(_ measured: ImageMeasurements, against workload: GCPv1Workload) -> [FieldComparison] {
            var rows: [FieldComparison] = []
            if let vm = workload.workloadVMMeasurements {
                rows.append(.digest("workload.shim", expected: vm.shimDigest, measured: measured.shim))
                rows.append(.digest("workload.grub", expected: vm.grubDigest, measured: measured.grub))
                rows.append(.digest("workload.vmlinuz", expected: vm.vmlinuzDigest, measured: measured.vmlinuzB ?? measured.vmlinuzA))
                rows.append(.string("workload.cmdline", expected: vm.kernelCommandLine, measured: measured.kernelCmdlineB))
            }
            if let kp = workload.keyProtectionVMMeasurements {
                rows.append(.digest("keyProtection.shim", expected: kp.shimDigest, measured: measured.shim))
                rows.append(.digest("keyProtection.grub", expected: kp.grubDigest, measured: measured.grub))
                rows.append(.digest("keyProtection.vmlinuz", expected: kp.vmlinuzDigest, measured: measured.vmlinuzB ?? measured.vmlinuzA))
                rows.append(.string("keyProtection.cmdline", expected: kp.kernelCommandLine, measured: measured.kernelCmdlineB))
            }
            return rows
        }

        private func compareHostImage(_ measured: HostImageMeasurements, against workload: GCPv1Workload) -> [FieldComparison] {
            var rows: [FieldComparison] = []
            if let vm = workload.workloadVMMeasurements {
                rows.append(.digest("workload.uki", expected: vm.ukiDigest, measured: measured.workloadUKIDigest))
                rows.append(.digest("workload.ovmf", expected: vm.ovmfDigest, measured: measured.workloadOVMFDigest))
            }
            if let kp = workload.keyProtectionVMMeasurements {
                rows.append(.digest("keyProtection.uki", expected: kp.ukiDigest, measured: measured.keyProtectionUKIDigest))
                rows.append(.digest("keyProtection.ovmf", expected: kp.ovmfDigest, measured: measured.keyProtectionOVMFDigest))
            }
            if let host = workload.hostMeasurements {
                rows.append(.digest("host.uki", expected: host.ukiDigest, measured: measured.hostUKIDigest))
            }
            return rows
        }

        // MARK: - NVIDIA driver comparison

        private func compareNvidiaDriver(driverVersion: String?, against workload: GCPv1Workload) async throws -> [FieldComparison] {
            let expected = workload.workloadVMMeasurements?.nvidiaDriver

            guard verifyNvidiaDriver else {
                let note =
                    expected.map {
                        "\($0.product) \($0.version), \($0.blocks.count) blocks (use --verify-nvidia-driver to re-derive)"
                    } ?? "(not in published release)"
                return [.info("workload.nvidiaDriver", note: note)]
            }

            guard let driverVersion else {
                return [.info("workload.nvidiaDriver", note: "no driver version found in image OEM partition; cannot re-derive")]
            }

            let rimName = "NV_GPU_CC_DRIVER_\(gpuProduct)_\(driverVersion)"
            if !json {
                FileHandle.standardError.write(Data("Fetching NVIDIA RIM \(rimName)...\n".utf8))
            }
            let (rim, _) = try await fetchNvidiaRIM(name: rimName)
            let measured = NvidiaGPUMeasurement(driverRIM: rim)

            var rows: [FieldComparison] = [
                .string("workload.nvidiaDriver.product", expected: expected?.product, measured: measured.product),
                .string("workload.nvidiaDriver.version", expected: expected?.version, measured: measured.version),
            ]

            let expectedBlocks = Dictionary(uniqueKeysWithValues: (expected?.blocks ?? []).map { ($0.index, $0.digest) })
            let measuredBlocks = Dictionary(uniqueKeysWithValues: measured.blocks.map { ($0.index, $0.digest) })
            for index in Set(expectedBlocks.keys).union(measuredBlocks.keys).sorted() {
                rows.append(
                    .digest(
                        "workload.nvidiaDriver.block[\(index)]",
                        expected: expectedBlocks[index],
                        measured: measuredBlocks[index]
                    )
                )
            }
            return rows
        }

        // MARK: - Container image comparison

        private func compareContainerImage(against workload: GCPv1Workload) throws -> [FieldComparison] {
            guard let containerImageLayout else {
                let note =
                    workload.containerImageDigest.map { "\($0) (use --container-image-layout to re-derive)" }
                    ?? "(not in published release)"
                return [.info("containerImageDigest", note: note)]
            }

            let layout = OCIImageLayout(url: URL(fileURLWithPath: containerImageLayout))
            let measured = try layout.manifestDigest()
            return [.string("containerImageDigest", expected: workload.containerImageDigest, measured: measured)]
        }

        // MARK: - Output

        private func emit(_ rows: [FieldComparison], expected: ReleaseV2) throws {
            let mismatches = rows.filter { $0.status == .mismatch }
            let releaseDigest = (try? Data(expected.digest()).hexString) ?? ""

            if json {
                let report = VerifyImageReport(
                    releaseDigest: releaseDigest,
                    matched: mismatches.isEmpty,
                    fields: rows
                )
                let matchedCount = rows.filter { $0.status == .match }.count
                let summary =
                    mismatches.isEmpty
                    ? "verified: \(matchedCount) field(s) matched"
                    : "MISMATCH: \(mismatches.count) field(s) differ (\(mismatches.map(\.field).joined(separator: ", ")))"
                try SubprocessEnvelope(
                    ok: mismatches.isEmpty,
                    errorKind: mismatches.isEmpty ? nil : .domainFailure,
                    summary: summary,
                    digest: releaseDigest,
                    detail: report
                ).print()
            } else {
                print("--- Release Verify (\(releaseDigest.isEmpty ? "?" : releaseDigest)) ---")
                for row in rows {
                    print("  \(row.textLine)")
                }
                print()
                if mismatches.isEmpty {
                    print("✅ All re-measurable fields match the published release.")
                } else {
                    print("❌ \(mismatches.count) field(s) do not match the published release.")
                }
            }

            if !mismatches.isEmpty {
                throw ExitCode(1)
            }
        }
    }
}

/// One row of the verify-image comparison table.
struct FieldComparison: Encodable {
    enum Status: String, Encodable {
        case match
        case mismatch
        case missingExpected
        case info
    }

    let field: String
    let status: Status
    let expected: String?
    let measured: String?
    let note: String?

    static func digest(_ field: String, expected: Data?, measured: Data?) -> Self {
        compare(field, expected: expected?.hexString, measured: measured?.hexString)
    }

    static func string(_ field: String, expected: String?, measured: String?) -> Self {
        compare(field, expected: expected, measured: measured)
    }

    static func info(_ field: String, note: String?) -> Self {
        Self(field: field, status: .info, expected: nil, measured: nil, note: note)
    }

    private static func compare(_ field: String, expected: String?, measured: String?) -> Self {
        guard let expected else {
            return Self(field: field, status: .missingExpected, expected: nil, measured: measured, note: nil)
        }
        let status: Status = expected == measured ? .match : .mismatch
        return Self(field: field, status: status, expected: expected, measured: measured, note: nil)
    }

    var textLine: String {
        switch status {
        case .match:
            return "✅ \(field): \(expected ?? "")"
        case .mismatch:
            return "❌ \(field):\n       expected \(expected ?? "(nil)")\n       measured \(measured ?? "(nil)")"
        case .missingExpected:
            return "⚪️ \(field): not in published release (measured \(measured ?? "(nil)"))"
        case .info:
            return "ℹ️  \(field): \(note ?? "(none)")"
        }
    }
}

struct VerifyImageReport: Encodable {
    let releaseDigest: String
    let matched: Bool
    let fields: [FieldComparison]
}
