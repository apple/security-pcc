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
//  CLIDescriptions.swift
//  CloudAttestationV2
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//
//  Multi-line, indent-aware CLI rendering for attestation domain types. The conformances
//  live here (rather than alongside each type) so the `CLIDescribable` protocol stays a
//  concern of the CLI only.
//

import CloudAttestationV2
import Common
import Crypto
import Foundation
import PrivateCloudCompute
import SwiftEventLog
import SwiftNVAttestation
import SwiftTDX
import SwiftTPM

// MARK: - CloudAttestationV2

extension IntelTDXPlatform: CLIDescribable {
    public func cliDescription(indent: String = "") -> String {
        var lines = ["\(indent)Intel TDX:"]
        lines.append("\(indent)  SEAM Digest:     \(seamDigest.hexString)")
        lines.append("\(indent)  SEAM Signer:     \(seamSigner.hexString)")
        lines.append("\(indent)  SEAM Version:    \(seamVersion)")
        lines.append("\(indent)  QE Digest:       \(qeDigest.hexString)")
        lines.append("\(indent)  QE Signer:       \(qeSigner.hexString)")
        lines.append("\(indent)  QE Product ID:   \(qeProductId)")
        lines.append("\(indent)  QE Version:      \(qeVersion)")
        lines.append("\(indent)  TEE TCB SVN:     \(teeTcbSvn.hexString)")
        lines.append("\(indent)  FMSPC:           \(fmspc.hexString)")
        lines.append("\(indent)  SGX TCB Comp:    \(sgxTcbCompSvn.hexString)")
        lines.append("\(indent)  PCESVN:          \(pcesvn)")
        return lines.joined(separator: "\n")
    }
}

extension NvidiaGPUMeasurement: CLIDescribable {
    public func cliDescription(indent: String = "") -> String {
        var lines = ["\(indent)NVIDIA GPU (\(product) version=\(version)):"]
        lines.append("\(indent)  SPDM blocks (\(blocks.count)):")
        for b in blocks {
            lines.append("\(indent)    [\(b.index)] \(b.digest.hexString)")
        }
        return lines.joined(separator: "\n")
    }
}

extension GCPv1Platform: CLIDescribable {
    public func cliDescription(indent: String = "") -> String {
        var lines: [String] = []
        if let titanMeasurement {
            lines.append("\(indent)Titan:   \(titanMeasurement.hexString)")
        }
        if let bmcMeasurement {
            lines.append("\(indent)BMC:     \(bmcMeasurement.hexString)")
        }
        if let biosMeasurement {
            lines.append("\(indent)BIOS:    \(biosMeasurement.hexString)")
        }
        if let intelTDX {
            lines.append(intelTDX.cliDescription(indent: indent))
        }
        if let nvidiaGPU {
            lines.append(nvidiaGPU.cliDescription(indent: indent))
        }
        if let ovmfDigest {
            lines.append("\(indent)OVMF:    \(ovmfDigest.hexString)")
        }
        return lines.isEmpty ? "\(indent)(empty)" : lines.joined(separator: "\n")
    }
}

extension LinuxV1Measurements: CLIDescribable {
    public func cliDescription(indent: String = "") -> String {
        var lines: [String] = []
        if let d = ukiDigest { lines.append("\(indent)UKI:     \(d.hexString)") }
        if let d = ovmfDigest { lines.append("\(indent)OVMF:    \(d.hexString)") }
        if let d = shimDigest { lines.append("\(indent)Shim:    \(d.hexString)") }
        if let d = grubDigest { lines.append("\(indent)GRUB:    \(d.hexString)") }
        if let d = vmlinuzDigest { lines.append("\(indent)Vmlinuz: \(d.hexString)") }
        if let c = kernelCommandLine { lines.append("\(indent)Cmdline: \(c)") }
        if let driver = nvidiaDriver {
            lines.append(driver.cliDescription(indent: indent))
        }
        return lines.isEmpty ? "\(indent)(empty)" : lines.joined(separator: "\n")
    }
}

extension GCPv1Workload: CLIDescribable {
    public func cliDescription(indent: String = "") -> String {
        var lines: [String] = []
        if let m = workloadVMMeasurements {
            lines.append("\(indent)Workload VM:")
            lines.append(m.cliDescription(indent: indent + "  "))
        }
        if let m = keyProtectionVMMeasurements {
            lines.append("\(indent)Key Protection VM:")
            lines.append(m.cliDescription(indent: indent + "  "))
        }
        if let m = hostMeasurements {
            lines.append("\(indent)Host:")
            lines.append(m.cliDescription(indent: indent + "  "))
        }
        if let d = containerImageDigest {
            lines.append("\(indent)Container Image: \(d)")
        }
        if let v = variant {
            lines.append("\(indent)Variant: \(v)")
        }
        return lines.isEmpty ? "\(indent)(empty)" : lines.joined(separator: "\n")
    }
}

extension ReleaseV2: CLIDescribable {
    public func cliDescription(indent: String = "") -> String {
        let digest = (try? Data(self.digest()).hexString) ?? "nil"
        var lines = ["\(indent)Release (\(digest)):"]
        if let workload = gcpV1Workload {
            lines.append("\(indent)  GCPv1 Workload:")
            lines.append(workload.cliDescription(indent: indent + "    "))
        }
        if let platform = gcpV1Platform {
            lines.append("\(indent)  GCPv1 Platform:")
            lines.append(platform.cliDescription(indent: indent + "    "))
        }
        if gcpV1Workload == nil && gcpV1Platform == nil {
            lines.append("\(indent)  (empty)")
        }
        return lines.joined(separator: "\n")
    }
}

extension GCPv1DeviceIdentityManifest: CLIDescribable {
    public func cliDescription(indent: String = "") -> String {
        let digest = (try? Data(self.digest()).hexString) ?? "nil"

        var lines = ["\(indent)GCPv1 Device Identity Manifest (\(digest)):"]

        if let googleDigest = googleIdentityDigest {
            lines.append("\(indent)  Google: \(googleDigest.hexString)")
        }
        if let intelDigest = intelIdentityDigest {
            lines.append("\(indent)  Intel:  \(intelDigest.hexString)")
        }
        if let nvidiaDigests = nvidiaIdentityDigest {
            for (i, digest) in nvidiaDigests.enumerated() {
                let label = nvidiaDigests.count > 1 ? "\(indent)  NVIDIA[\(i)]: " : "\(indent)  NVIDIA: "
                lines.append("\(label)\(digest.hexString)")
            }
        }
        if googleIdentityDigest == nil && intelIdentityDigest == nil && nvidiaIdentityDigest == nil {
            lines.append("\(indent)  (empty)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - PrivateCloudCompute

extension PrivateCloudCompute_GCPv1TransparencyProofs: CLIDescribable {
    /// Human-readable, multi-line summary of the three transparency-log proof slots.
    public func cliDescription(indent: String = "") -> String {
        var lines: [String] = []
        appendCLIDescription("Certificate Transparency", proofs: certificateTransparencyProofs, indent: indent, into: &lines)
        appendCLIDescription("Software Transparency", proofs: softwareTransparencyProofs, indent: indent, into: &lines)
        appendCLIDescription("Firmware Transparency", proofs: firmwareTransparencyProofs, indent: indent, into: &lines)
        return lines.joined(separator: "\n")
    }

    private func appendCLIDescription(_ label: String, proofs: ATLogProofs, indent: String, into lines: inout [String]) {
        lines.append("\(indent)\(label):")
        guard proofs.hasInclusionProof else {
            lines.append("\(indent)  (not present)")
            return
        }
        let entry = proofs.inclusionProof
        if let logHead = try? LogHead(serializedBytes: entry.slh.object) {
            lines.append("\(indent)  Tree:        treeID=\(logHead.treeID) revision=\(logHead.revision) size=\(logHead.logSize)")
        }
        if let leaf = try? entry.leafData {
            lines.append("\(indent)  Leaf:        digest=\(leaf.dataHash.hexString) expires=\(leaf.expiry.formatted(.iso8601))")
        }
        if proofs.hasMilestoneConsistency {
            lines.append("\(indent)  Consistency: present")
        }
    }
}

// MARK: - SwiftTDX

extension V4.Header: CLIDescribable {
    public func cliDescription(indent: String = "") -> String {
        """
        \(indent)Header:
        \(indent)  Version:              4
        \(indent)  Attestation Key Type: \(attestationKeyType)
        \(indent)  TEE Type:             \(teeType)
        \(indent)  QE Vendor ID:         \(qeVendorID)
        """
    }
}

extension V4.Body: CLIDescribable {
    public func cliDescription(indent: String = "") -> String {
        """
        \(indent)Body:
        \(indent)  TEE TCB SVN:    \(teeTcbSvn.bytes.hexString)
        \(indent)  MRSEAM:         \(mrSeam.bytes.hexString)
        \(indent)  MRTD:           \(mrtd.bytes.hexString)
        \(indent)  MR Config ID:   \(mrConfigId.bytes.hexString)
        \(indent)  MR Owner:       \(mrOwner.bytes.hexString)
        \(indent)  MR Owner Config:\(mrOwnerConfig.bytes.hexString)
        \(indent)  RTMR0:          \(rtmr0.bytes.hexString)
        \(indent)  RTMR1:          \(rtmr1.bytes.hexString)
        \(indent)  RTMR2:          \(rtmr2.bytes.hexString)
        \(indent)  RTMR3:          \(rtmr3.bytes.hexString)
        \(indent)  Report Data:    \(reportData.bytes.hexString)
        \(indent)  TD Attributes:  0x\(String(tdAttributes.rawValue, radix: 16))
        \(indent)  XFAM:           0x\(String(xfam.rawValue, radix: 16))
        """
    }
}

extension V4.Quote: CLIDescribable {
    public func cliDescription(indent: String = "") -> String {
        """
        \(header.cliDescription(indent: indent))
        \(body.cliDescription(indent: indent))
        """
    }
}

extension PCKCertificate: CLIDescribable {
    public func cliDescription(indent: String = "") -> String {
        var lines = [
            "\(indent)PCK Certificate:",
            "\(indent)  Subject:  \(self.subject)",
            "\(indent)  Issuer:   \(self.issuer)",
        ]
        if let ppid = pPID {
            lines.append("\(indent)  PPID:     \(ppid.hexString)")
        }
        if let piid = platformInstanceID {
            lines.append("\(indent)  PIID:     \(piid.hexString)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - SwiftEventLog

extension Event: CLIDescribable {
    public func cliDescription(indent: String = "") -> String {
        let digestStrs = digests.map { digest -> String in
            let algName: String
            if let alg = TPM.Alg.ID(rawValue: digest.algID) {
                algName = "\(alg)"
            } else {
                algName = "0x\(String(digest.algID, radix: 16))"
            }
            return "\(algName):\(digest.data.hexString)"
        }
        return """
            \(indent)PCR=\(pcrIndex) Type=\(type.debugDescription) Digests=[\(digestStrs.joined(separator: ", "))]
            \(indent)     Data=\(data.debugByteString())
            """
    }
}

extension TCGEventLog: CLIDescribable {
    public func cliDescription(indent: String = "") -> String {
        var lines: [String] = []
        let algs = specIDEvent.digestSizes.map { "0x\(String($0.id, radix: 16))(\($0.size)B)" }
        lines.append(
            "\(indent)SpecIDEvent: v\(specIDEvent.header.versionMajor).\(specIDEvent.header.versionMinor), algorithms=[\(algs.joined(separator: ", "))]"
        )
        lines.append("\(indent)Events (\(events.count)):")
        for event in events {
            lines.append(event.cliDescription(indent: indent + "  "))
        }
        return lines.joined(separator: "\n")
    }
}

extension CEL.Record: CLIDescribable {
    public func cliDescription(indent: String = "") -> String {
        let digestStrs = digests.map { "\($0.algorithm):\($0.data.hexString)" }
        return """
            \(indent)[\(recnum)] \(index.debugDescription) Digests=[\(digestStrs.joined(separator: ", "))]
            \(indent)     Content=\(content.debugDescription)
            """
    }
}

extension CEL: CLIDescribable {
    public func cliDescription(indent: String = "") -> String {
        var lines = ["\(indent)Records (\(records.count)):"]
        for record in records {
            lines.append(record.cliDescription(indent: indent + "  "))
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - SwiftNVAttestation

extension Blackwell.AttestationReport: CLIDescribable {
    public func cliDescription(indent: String = "") -> String {
        var lines: [String] = []
        lines.append("\(indent)SPDM Attestation Report (v\(response.version.major).\(response.version.minor))")
        lines.append("\(indent)  Measurement blocks (\(response.numberOfBlocks))")
        if !response.opaqueFields.isEmpty {
            lines.append("\(indent)  Opaque fields (\(response.opaqueFields.count)):")
            for field in response.opaqueFields {
                let name: String
                if let odt = Blackwell.OpaqueDataType(rawValue: field.dataType) {
                    name = odt.name
                } else {
                    name = "0x\(String(field.dataType, radix: 16))"
                }
                let value = field.data.debugByteString(maxBytes: 32)
                lines.append("\(indent)    \(name): \(value)")
            }
        }
        lines.append("\(indent)  Signature: \(response.signature.count) bytes")
        return lines.joined(separator: "\n")
    }
}
