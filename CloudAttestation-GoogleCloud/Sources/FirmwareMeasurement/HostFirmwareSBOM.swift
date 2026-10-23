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
//  HostFirmwareSBOM.swift
//  CloudAttestationV2
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//

import Common
import Foundation

/// Host platform-firmware measurements parsed from the JSON emitted by
/// `gcloud compute reservations hosts get-version` (the
/// `inlineSbomInfo.targetComponentVersions` map).
///
/// The map carries one Reference Integrity Manifest per component. This type
/// projects them into the same measurements a live host attestation reports, so
/// they can be dropped straight into ``GCPv1Platform``:
///
/// - ``titanSlots`` — the Titan security chip's RW firmware hashes, one per
///   firmware slot (`fwHashA`, `fwHashB`, …), taken directly from the `tpmRIM`
///   (matches the EK certificate `rwHash` / `TPMClaims.titanFirmwareDigest`).
/// - ``bmcMeasurement`` — `sha256(descriptorHash)` of the `bmcRIM`, matching the
///   single `EV_EFI_HCRTM_EVENT` digest at PCR[0] (GCP `GMESState.BmcFirmwareDigest`).
/// - ``biosMeasurement`` — `sha256(descriptorHash)` of the `biosRIM`, matching the
///   single Google DRTM event digest at PCR[17] (GCP `GMESState.BiosDigest`).
/// - ``nvidiaVBIOSRIMName`` — the `nvidiaVBIOSRIM` identifier (e.g.
///   `NV_GPU_VBIOS_G525_0220_886_9700FA0009`), fetched from
///   `rim.attestation.nvidia.com` to build the GPU firmware measurements.
public struct HostFirmwareSBOM: Sendable {
    /// A single Titan RW firmware slot. A Titan carries A/B slots for updates and
    /// the running host reports whichever is active, so each slot yields a distinct
    /// release.
    public struct TitanSlot: Sendable {
        /// Slot name — the suffix of the RIM measurement (`fwHashA` → `A`).
        public let name: String
        /// The slot's RW firmware hash, used directly as ``GCPv1Platform/titanMeasurement``.
        public let measurement: Data

        public init(name: String, measurement: Data) {
            self.name = name
            self.measurement = measurement
        }
    }

    public let titanSlots: [TitanSlot]
    public let bmcMeasurement: Data
    public let biosMeasurement: Data
    public let nvidiaVBIOSRIMName: String?

    /// Each component RIM's `<SoftwareIdentity version>` — a SHA-256 hex string for the Google
    /// Platforms RIMs. This is the `sw_version` the published firmware artifacts are keyed by,
    /// so it is what researcher-facing asset URLs are built from.
    public let titanVersion: String?
    public let bmcVersion: String?
    public let biosVersion: String?

    public init(jsonData: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw HostFirmwareSBOMError.invalidJSON
        }

        // `gcloud … reservations hosts get-version --format json` nests the component map here.
        guard let inline = root["inlineSbomInfo"] as? [String: Any],
            let components = inline["targetComponentVersions"] as? [String: Any]
        else {
            throw HostFirmwareSBOMError.missingComponent("inlineSbomInfo.targetComponentVersions")
        }

        // Titan RW firmware hashes are used directly (no re-hashing). A Titan carries A/B
        // firmware slots; the running host reports whichever is active, so we surface every
        // `fwHash*` slot and let the caller emit one release per slot.
        let tpm = try Self.swidComponent(components, key: "tpmRIM")
        let slots =
            tpm.measurements.keys
            .filter { $0.hasPrefix("fwHash") }
            .sorted()
            .map { TitanSlot(name: String($0.dropFirst("fwHash".count)), measurement: Data(tpm.measurements[$0]!)) }
        guard !slots.isEmpty else {
            throw HostFirmwareSBOMError.missingMeasurement(component: "tpmRIM", name: "fwHash*")
        }
        self.titanSlots = slots
        self.titanVersion = tpm.softwareVersion

        // BMC/BIOS measured PCR event digests: sha256(descriptorHash).
        let bmc = try Self.swidComponent(components, key: "bmcRIM")
        let bios = try Self.swidComponent(components, key: "biosRIM")
        self.bmcMeasurement = try Self.descriptorMeasurement(bmc, key: "bmcRIM")
        self.biosMeasurement = try Self.descriptorMeasurement(bios, key: "biosRIM")
        self.bmcVersion = bmc.softwareVersion
        self.biosVersion = bios.softwareVersion

        self.nvidiaVBIOSRIMName = try Self.componentData(components, key: "nvidiaVBIOSRIM", format: "NVIDIA_RIM_ID_V1")
    }

    // MARK: - Component decoding

    /// Each `targetComponentVersions` value is itself a JSON string holding an array of
    /// `{data, format}` entries. Returns the first entry's `data` after validating its
    /// `format`, or `nil` when the component is absent.
    private static func componentData(_ components: [String: Any], key: String, format expectedFormat: String) throws -> String? {
        guard let raw = components[key] as? String else { return nil }
        guard let rawData = raw.data(using: .utf8),
            let entries = try? JSONSerialization.jsonObject(with: rawData) as? [[String: Any]],
            let first = entries.first,
            let data = first["data"] as? String,
            let format = first["format"] as? String
        else {
            throw HostFirmwareSBOMError.malformedComponent(key)
        }
        guard format == expectedFormat else {
            throw HostFirmwareSBOMError.unexpectedFormat(component: key, format: format)
        }
        return data
    }

    /// A decoded SWID component: its measurement hashes keyed by `name` (e.g. `descriptorHash`,
    /// `fwHashA`), plus the tag's `<SoftwareIdentity version>`.
    private struct SWIDComponent {
        let measurements: [String: [UInt8]]
        let softwareVersion: String?
    }

    /// Decodes a base64 SWID (`SWID_XML_V1`) component.
    ///
    /// The Google Platforms RIMs omit the `index` / `colloquialVersion` attributes NVIDIA RIMs
    /// carry and use namespaced `SHA256:hash` attributes, so they're parsed with the lenient
    /// ``RIMXMLParser`` and looked up by measurement name.
    private static func swidComponent(_ components: [String: Any], key: String) throws -> SWIDComponent {
        guard let data = try componentData(components, key: key, format: "SWID_XML_V1") else {
            throw HostFirmwareSBOMError.missingComponent(key)
        }
        guard let xml = Data(base64Encoded: data) else {
            throw HostFirmwareSBOMError.invalidBase64(key)
        }
        let parsed = try RIMXMLParser(lenient: true).parse(xml)
        return SWIDComponent(
            measurements: Dictionary(
                parsed.measurements.compactMap { measurement in
                    measurement.alternatives.first.map { (measurement.name, $0) }
                },
                uniquingKeysWith: { first, _ in first }
            ),
            softwareVersion: parsed.softwareVersion
        )
    }

    /// The measured PCR event digest for a single-`descriptorHash` SWID component:
    /// `sha256(descriptorHash)`, mirroring GCP's `extract.GMESState` /
    /// `HostClaims.googleMeasurementDigest`.
    private static func descriptorMeasurement(_ component: SWIDComponent, key: String) throws -> Data {
        guard let descriptor = component.measurements["descriptorHash"] else {
            throw HostFirmwareSBOMError.missingMeasurement(component: key, name: "descriptorHash")
        }
        return Data(Data(descriptor).digest())
    }
}

// MARK: - Errors

public enum HostFirmwareSBOMError: Error {
    case invalidJSON
    case missingComponent(String)
    case malformedComponent(String)
    case unexpectedFormat(component: String, format: String)
    case invalidBase64(String)
    case missingMeasurement(component: String, name: String)
}
