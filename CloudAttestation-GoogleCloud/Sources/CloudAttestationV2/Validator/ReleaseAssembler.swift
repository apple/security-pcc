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
//  ReleaseAssembler.swift
//  CloudAttestationV2
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//

import Foundation
import GCPv1
import SwiftNVAttestation

/// Projects generated ``Claims`` into ``ReleaseV2`` manifests.
///
/// Shared by ``Validated/AttestationBundle`` (its `workloadRelease()`/`firmwareRelease()` methods)
/// and the GCPv1 claims pipeline, which derives release digests for transparency claims before a
/// full ``Validated/AttestationBundle`` exists. Reads only the cached claims — never re-runs a
/// claims generator.
extension ReleaseV2 {
    /// Returns a ``ReleaseV2`` manifest containing workload measurements.
    ///
    /// Projects from CCEL claims (boot measurements, kernel) and CEL claims (container image
    /// digest, NVIDIA driver version + driver-attributed SPDM blocks) into the release manifest
    /// structure. The bare-metal host's UKI comes from ``HostClaims`` (its PC Client boot log).
    /// VBIOS-attributed SPDM blocks live in ``firmware(bundle:claims:)``; OVMF lives here per-VM
    /// on Bowcaster and on ``firmware(bundle:claims:)`` on Vanguard.
    ///
    /// - Throws: ``DeviceIdentityManifestError/unsupportedBundleType`` if the bundle is not GCPv1.
    package static func workload(bundle: CloudAttestationV2.AttestationBundle, claims: Claims) throws -> ReleaseV2 {
        guard case .gcpv1AttestationBundle = bundle.proto.attestationBundle else {
            throw DeviceIdentityManifestError.unsupportedBundleType
        }
        return try workload(claims: claims)
    }

    /// Projects ``Claims`` into a workload ``ReleaseV2`` without a bundle to gate on.
    ///
    /// Same projection as ``workload(bundle:claims:)``, minus the GCPv1 bundle check. Callers that
    /// already know the claims describe a GCPv1 attestation — e.g. reconstructing releases from a
    /// logged claims dump where no bundle exists — use this directly.
    package static func workload(claims: Claims) throws -> ReleaseV2 {
        // All GPUs must run the same driver — verify agreement across every GPU's SPDM
        // measurement before trusting any one of them to represent the fleet.
        let nvidiaDriver = try homogeneousNvidiaGPUMeasurement(gpus: claims.workloadGPUs, kind: .driver)

        // The host boots directly into its UKI, so the boot-services applications measured into
        // the host TPM's PCR[21] must be exactly that single image. Only the first digest is
        // projected as `hostMeasurements.ukiDigest`, and that projection is the sole content check
        // for host boot images (the transparency lookup and policy both see only what lands here),
        // so refuse to assemble a release when the log shows more than one image rather than
        // silently leaving the extras unattested. Its digest is SHA-256 (the only bank these hosts
        // use); the image-measurement flow matches it with a SHA-256 host UKI digest.
        let hostMeasurements: LinuxV1Measurements?
        if let bootApplicationDigests = claims.host?.bootApplicationDigests {
            guard bootApplicationDigests.count == 1 else {
                throw DeviceIdentityManifestError.ambiguousHostBootImages(count: bootApplicationDigests.count)
            }
            hostMeasurements = LinuxV1Measurements(ukiDigest: bootApplicationDigests[0])
        } else {
            hostMeasurements = nil
        }

        return ReleaseV2(
            gcpV1Workload: GCPv1Workload(
                workloadVMMeasurements: claims.workloadCCEL?.linuxMeasurements(
                    ovmfDigest: claims.workloadTDX?.mrtd,
                    nvidiaDriver: nvidiaDriver
                ),
                keyProtectionVMMeasurements: claims.keyProtectionCCEL?.linuxMeasurements(
                    ovmfDigest: claims.keyProtectionTDX?.mrtd
                ),
                hostMeasurements: hostMeasurements,
                containerImageDigest: claims.workloadCSEL?.containerImageDigest,
                variant: claims.workloadCSEL?.pccVariant
            )
        )
    }

    /// Returns a ``ReleaseV2`` manifest containing platform firmware measurements.
    ///
    /// Extracts Intel TDX platform identity from the TDX claims and VBIOS-attributed SPDM
    /// measurement blocks from the CEL launch event log, plus the bare-metal host's Titan (EK
    /// cert RW firmware hash), BMC, and BIOS firmware measurements. On Vanguard, the workload
    /// VM's MRTD is also surfaced here as ``GCPv1Platform/ovmfDigest``; on Bowcaster OVMF is
    /// reported per-VM in ``workload(bundle:claims:)`` and this field is left nil.
    ///
    /// - Throws: ``DeviceIdentityManifestError/unsupportedBundleType`` if the bundle is not GCPv1.
    package static func firmware(bundle: CloudAttestationV2.AttestationBundle, claims: Claims) throws -> ReleaseV2 {
        guard case .gcpv1AttestationBundle = bundle.proto.attestationBundle else {
            throw DeviceIdentityManifestError.unsupportedBundleType
        }
        return try firmware(claims: claims)
    }

    /// Projects ``Claims`` into a platform-firmware ``ReleaseV2`` without a bundle to gate on.
    ///
    /// Same projection as ``firmware(bundle:claims:)``, minus the GCPv1 bundle check. Callers that
    /// already know the claims describe a GCPv1 attestation — e.g. reconstructing releases from a
    /// logged claims dump where no bundle exists — use this directly.
    package static func firmware(claims: Claims) throws -> ReleaseV2 {
        let intelTDX: IntelTDXPlatform?
        if let tdx = claims.workloadTDX,
            let mrSeam = tdx.mrSeam,
            let mrSignerSeam = tdx.mrSignerSeam,
            let teeTcbSvn = tdx.teeTcbSvn,
            let qeMREnclave = tdx.qeMREnclave,
            let qeMRSigner = tdx.qeMRSigner,
            let qeISVProdId = tdx.qeISVProdId,
            let qeISVSVN = tdx.qeISVSVN,
            let fmspc = tdx.fmspc,
            let sgxTcbCompSvn = tdx.sgxTcbCompSvn,
            let pcesvn = tdx.pcesvn
        {
            intelTDX = IntelTDXPlatform(
                seamDigest: mrSeam,
                seamSigner: mrSignerSeam,
                seamVersion: Int(teeTcbSvn.first ?? 0),
                qeDigest: qeMREnclave,
                qeSigner: qeMRSigner,
                qeProductId: qeISVProdId,
                qeVersion: qeISVSVN,
                teeTcbSvn: teeTcbSvn,
                fmspc: fmspc,
                sgxTcbCompSvn: sgxTcbCompSvn,
                pcesvn: pcesvn
            )
        } else {
            intelTDX = nil
        }

        // All GPUs must run the same VBIOS — verify agreement across every GPU that reports
        // one before trusting any one of them to represent the fleet. A GPU without a VBIOS
        // leaves `vbiosMeasurement` nil and is skipped.
        let nvidiaGPU = try homogeneousNvidiaGPUMeasurement(gpus: claims.workloadGPUs, kind: .vbios)

        // Bowcaster records OVMF per-VM in the workload release; Vanguard records it
        // platform-wide. ``BootChain.platformOVMFDigest`` owns that placement rule. An
        // unrecognized boot chain falls through to nil — policy already rejects via
        // `workload_boot_chain_valid`.
        let platformOVMFDigest = claims.workloadCCEL?.bootChain?.platformOVMFDigest(candidate: claims.workloadTDX?.mrtd)

        // Bare-metal host platform firmware, extracted from the PC Client boot log as single
        // Google measurement events: BMC is the EV_EFI_HCRTM_EVENT digest at PCR[0], BIOS the
        // Google DRTM event digest at PCR[17]. Titan is the security chip's RW firmware hash
        // from its EK certificate. Mirror GCP's `GMESState` / EK cert `rwHash`; policy
        // reconciles them against reference RIMs.
        let titanMeasurement = claims.hostTPM?.titanFirmwareDigest
        let bmcMeasurement = claims.host?.bmcFirmwareDigest
        let biosMeasurement = claims.host?.biosDigest

        return ReleaseV2(
            gcpV1Platform: GCPv1Platform(
                titanMeasurement: titanMeasurement,
                bmcMeasurement: bmcMeasurement,
                biosMeasurement: biosMeasurement,
                intelTDX: intelTDX,
                nvidiaGPU: nvidiaGPU,
                ovmfDigest: platformOVMFDigest
            )
        )
    }

    /// Verifies that every GPU's `kind` measurement (driver or VBIOS) agrees before returning
    /// it, so a single GPU's SPDM content can safely stand in for the fleet in the release
    /// manifest. Reads the measurements already surfaced on ``NvidiaGPUClaims`` (populated only
    /// for verified GPUs) rather than re-deriving them from the CSEL, and skips GPUs that carry
    /// no `kind` measurement. Returns `nil` when no GPU contributes one.
    ///
    /// - Throws: ``DeviceIdentityManifestError/heterogeneousGPUMeasurements(kind:divergentIndex:)``
    ///   if any GPU's measurement differs from the first.
    private static func homogeneousNvidiaGPUMeasurement(
        gpus: [NvidiaGPUClaims]?,
        kind: CSELClaims.GPU.NvidiaGPUComponent
    ) throws -> NvidiaGPUMeasurement? {
        let measurements = (gpus ?? []).compactMap { gpu in
            switch kind {
            case .driver: gpu.driverMeasurement
            case .vbios: gpu.vbiosMeasurement
            }
        }
        guard let first = measurements.first else { return nil }
        for (offset, measurement) in measurements.dropFirst().enumerated() {
            guard measurement == first else {
                throw DeviceIdentityManifestError.heterogeneousGPUMeasurements(kind: kind, divergentIndex: offset + 1)
            }
        }
        return first
    }
}

extension CSELClaims.GPU {
    public enum NvidiaGPUComponent: Sendable {
        case driver
        case vbios
    }

    /// Builds an ``NvidiaGPUMeasurement`` for this GPU's `kind` (driver or VBIOS), parsing its
    /// SPDM attestation report and selecting the SPDM blocks attributable to that component
    /// per ``NvidiaGPUMeasurement/driverSPDMIndices`` (and skipping ``NvidiaGPUMeasurement/excludedSPDMIndices``).
    func nvidiaGPUMeasurement(kind: NvidiaGPUComponent) throws -> NvidiaGPUMeasurement {
        let report = try Blackwell.AttestationReport(from: attestation)
        let blocks = report.measurementBlocks.compactMap { block -> NvidiaSPDMBlock? in
            let index = Int(block.index)
            guard !NvidiaGPUMeasurement.excludedSPDMIndices.contains(index) else { return nil }
            let isDriverIndex = NvidiaGPUMeasurement.driverSPDMIndices.contains(index)
            switch kind {
            case .driver: guard isDriverIndex else { return nil }
            case .vbios: guard !isDriverIndex else { return nil }
            }
            guard !block.digest.allSatisfy({ $0 == 0 }) else { return nil }
            return NvidiaSPDMBlock(index: index, digest: Data(block.digest))
        }
        return NvidiaGPUMeasurement(
            product: architecture.product,
            version: kind == .driver ? driverVersion : vbiosVersion,
            blocks: blocks
        )
    }
}

extension NvidiaGPUClaims.Generator {
    /// Verifies each GPU's SPDM evidence and, for those that verify, surfaces its
    /// driver/VBIOS measurement content — the CSEL-specific counterpart to
    /// ``generateClaims(for:)`` (which only has access to generic ``Evidence`` and
    /// can't build an ``NvidiaGPUMeasurement`` on its own).
    func generateClaims(forCSELGPUs gpus: [CSELClaims.GPU]) async throws -> [NvidiaGPUClaims] {
        var claims = try await generateClaims(for: gpus.map { Evidence($0) })
        for index in claims.indices where claims[index].verified == true {
            claims[index].driverMeasurement = try? gpus[index].nvidiaGPUMeasurement(kind: .driver)
            // A GPU that reports no VBIOS version leaves `vbiosMeasurement` nil, so the firmware
            // release omits it — matching the release's prior skip-empty-VBIOS behavior.
            if !gpus[index].vbiosVersion.isEmpty {
                claims[index].vbiosMeasurement = try? gpus[index].nvidiaGPUMeasurement(kind: .vbios)
            }
        }
        return claims
    }
}

extension CCELClaims {
    /// Projects boot claims into ``LinuxV1Measurements`` for the release manifest.
    ///
    /// `ovmfDigest` is the candidate OVMF measurement (the VM's MRTD) and is honored only on
    /// Bowcaster, where each VM carries its own OVMF in its `LinuxV1Measurements`. On Vanguard
    /// OVMF is platform-level and lives on ``GCPv1Platform/ovmfDigest`` instead, so the
    /// candidate is dropped here. ``CCELClaims/BootChain`` owns that placement decision.
    package func linuxMeasurements(
        ovmfDigest: Data? = nil,
        nvidiaDriver: NvidiaGPUMeasurement? = nil
    ) -> LinuxV1Measurements? {
        let ukiDigest = bootChain?.uki?.digest
        let shimDigest = bootChain?.shim?.digest
        let grubDigest = bootChain?.grub?.digest
        let projectedOVMFDigest = bootChain?.vmOVMFDigest(candidate: ovmfDigest)
        let vmlinuzDigest = kernel?.imageDigest
        let kernelCommandLine = kernel?.cmdline

        guard ukiDigest != nil || projectedOVMFDigest != nil || shimDigest != nil || grubDigest != nil || vmlinuzDigest != nil || kernelCommandLine != nil || nvidiaDriver != nil
        else {
            return nil
        }

        return LinuxV1Measurements(
            ukiDigest: ukiDigest,
            ovmfDigest: projectedOVMFDigest,
            nvidiaDriver: nvidiaDriver,
            shimDigest: shimDigest,
            grubDigest: grubDigest,
            vmlinuzDigest: vmlinuzDigest,
            kernelCommandLine: kernelCommandLine
        )
    }
}
