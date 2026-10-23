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

import Foundation
import SwiftProtobuf

// MARK: - Key Endorsement

/// Attestation-based endorsement of workload binding and key protection service keys.
public struct KeyEndorsement: Sendable, Codable {
    public let vmProtectedKeyEndorsement: VMProtectedKeyEndorsement

    package init(vmProtectedKeyEndorsement: VMProtectedKeyEndorsement) {
        self.vmProtectedKeyEndorsement = vmProtectedKeyEndorsement
    }
}

/// Contains two key attestations: one for the binding key held by the workload VM, and one for the protected key held by the key protection VM.
public struct VMProtectedKeyEndorsement: Sendable, Codable {
    public let bindingKeyAttestation: KeyAttestation
    public let protectedKeyAttestation: KeyAttestation

    package init(bindingKeyAttestation: KeyAttestation, protectedKeyAttestation: KeyAttestation) {
        self.bindingKeyAttestation = bindingKeyAttestation
        self.protectedKeyAttestation = protectedKeyAttestation
    }
}

/// Wrapper around an attestation.
public struct KeyAttestation: Sendable, Codable {
    public let attestation: Attestation

    package init(attestation: Attestation) {
        self.attestation = attestation
    }
}

// MARK: - Attestation

/// The type of attestation. Encoded as a base64 string on the wire.
public enum AttestationLabel: String, Sendable, Hashable {
    case workloadAttestation = "WORKLOAD_ATTESTATION"
}

extension AttestationLabel: Codable {
    public init(from decoder: any Swift.Decoder) throws {
        let container = try decoder.singleValueContainer()
        let base64String = try container.decode(String.self)
        guard let data = Data(base64Encoded: base64String),
            let decoded = String(data: data, encoding: .utf8),
            let value = AttestationLabel(rawValue: decoded)
        else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid attestation label: \(base64String)")
        }
        self = value
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Data(rawValue.utf8).base64EncodedString())
    }
}

/// Attestation evidence from a Confidential Space virtual machine.
public struct Attestation: Sendable, Codable {
    public let label: AttestationLabel
    public let challenge: Data
    public let extraData: Data
    public let quote: AttestationQuote

    package init(
        label: AttestationLabel,
        challenge: Data,
        extraData: Data,
        quote: AttestationQuote,
    ) {
        self.label = label
        self.challenge = challenge
        self.extraData = extraData
        self.quote = quote
    }

    /// Parses the ``extraData`` field as a protobuf ``GCPv1_KeyClaims`` message.
    ///
    /// - Throws: ``GCPv1/Error/invalidLabel`` if ``label`` is not ``AttestationLabel/keyAttestation``.
    public var keyClaims: Keymanager_KeyClaims {
        get throws {
            guard label == .workloadAttestation else {
                throw GCPv1Error.invalidLabel(label.rawValue)
            }

            return try Keymanager_KeyClaims(serializedBytes: extraData)
        }
    }
}

/// Quote data within an attestation.
public struct AttestationQuote: Sendable, Codable {
    public let tdxCcelQuote: TDXCCELQuote

    package init(tdxCcelQuote: TDXCCELQuote) {
        self.tdxCcelQuote = tdxCcelQuote
    }
}

/// TDX CCEL quote containing event logs and the TD quote.
public struct TDXCCELQuote: Sendable, Codable {
    /// Firmware boot log in TCG Event Log format, parseable as ``SwiftEventLog.TCGEventLog``.
    public let ccelBootEventLog: Data
    /// Launcher event log in Canonical Event Log format, parseable as ``SwiftEventLog.CEL``. Empty when the attestation is for a VM without a launcher event log (e.g. the key protection VM).
    public let celLaunchEventLog: Data
    /// Quote over the TDX VM, parseable as ``SwiftTDX.Quote``. `ReportData` has the following scheme: `SHA512(label || SHA512(challenge || SHA512(extra_data)))`.
    public let tdQuote: Data

    package init(ccelBootEventLog: Data, celLaunchEventLog: Data, tdQuote: Data) {
        self.ccelBootEventLog = ccelBootEventLog
        self.celLaunchEventLog = celLaunchEventLog
        self.tdQuote = tdQuote
    }

    public init(from decoder: any Swift.Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.ccelBootEventLog = try container.decode(Data.self, forKey: .ccelBootEventLog)
        self.celLaunchEventLog = try container.decodeIfPresent(Data.self, forKey: .celLaunchEventLog) ?? Data()
        self.tdQuote = try container.decode(Data.self, forKey: .tdQuote)
    }
}

// MARK: - Device Reports (in CCEL)

/// A device attestation report.
public struct DeviceReport: Sendable, Codable {
    public let nvidiaReport: NVIDIAReport?
}

/// NVIDIA GPU attestation report containing GPU quotes.
public struct NVIDIAReport: Sendable, Codable {
    public let mpt: MultiGPUPassThrough
}

/// Container for GPU quotes within an NVIDIA report, one for each GPU.
public struct MultiGPUPassThrough: Sendable, Codable {
    public let gpuQuotes: [GPUQuote]
}

/// GPU architecture type reported in attestation data.
public enum GPUArchitectureType: String, Sendable, Codable {
    case hopper = "GPU_ARCHITECTURE_TYPE_HOPPER"
    case blackwell = "GPU_ARCHITECTURE_TYPE_BLACKWELL"
}

/// Attestation data for a single NVIDIA GPU.
public struct GPUQuote: Sendable, Codable {
    /// String rather than ``UUID`` as it's prefixed with `GPU-`.
    public let uuid: String
    public let driverVersion: String
    public let vbiosVersion: String
    public let gpuArchitectureType: GPUArchitectureType
    public let attestationCertificateChain: Data
    /// NVIDIA attestation report, parseable as ``SwiftNVAttestation.AttestationReport``.
    public let attestationReport: Data
}

// MARK: - Host Attestations

public typealias HostAttestation = ConfidentialSpace_HostAttestation
public typealias TpmQuote = ConfidentialSpace_TpmQuote
public typealias TpmAuxiliaryAttestation = ConfidentialSpace_TpmAuxiliaryAttestation
