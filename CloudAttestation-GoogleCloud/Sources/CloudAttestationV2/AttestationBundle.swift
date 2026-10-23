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
//  AttestationBundle.swift
//  CloudAttestationV2
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//

import Crypto
import Foundation
import SwiftTDX
import X509
import PrivateCloudCompute

/// Encapsulates an AttestationBundle parsed from its wire format.
public struct AttestationBundle: Equatable, Sendable {
    public internal(set) var proto: PrivateCloudCompute_AttestationBundle

    public init(proto: PrivateCloudCompute_AttestationBundle) {
        self.proto = proto
    }

    /// Construct an ``AttestationBundle`` from the Data bytes of a protobuf serialized AttestationBundle.
    ///
    /// Apple silicon servers use ``PrivateCloudCompute_AppleSiliconAttestationBundle`` bytes
    /// instead of the ``PrivateCloudCompute_AttestationBundle`` envelope. To stay compatible
    /// with both, this initializer first attempts the envelope parse and uses the ``version``
    /// discriminator (1 = inner-only, 2 = envelope) when present; otherwise it falls back to
    /// parsing the bytes as a raw AppleSilicon bundle and wrapping them in an envelope.
    public init(data: Data) throws {
        if let outer = try? PrivateCloudCompute_AttestationBundle(serializedBytes: data) {
            switch outer.version {
            case 2:
                self.proto = outer
                return
            case 1:
                // Wire data was a raw AppleSiliconAttestationBundle. Re-parse against the
                // inner schema rather than trusting the (incorrectly shaped) outer parse.
                break
            default:
                // Legacy data, no version marker. Trust the envelope only if its oneof was
                // populated — a raw AppleSilicon bundle either fails the envelope parse or
                // produces an empty oneof.
                if outer.attestationBundle != nil {
                    self.proto = outer
                    return
                }
            }
        }

        let inner = try PrivateCloudCompute_AppleSiliconAttestationBundle(serializedBytes: data)
        self.proto = .with {
            $0.attestationBundle = .appleSiliconAttestationBundle(inner)
        }
    }

    /// Construct an ``AttestationBundle`` from the protobuf-json serialized string of an AttestationBundle
    public init(jsonString json: String) throws {
        self.proto = try PrivateCloudCompute_AttestationBundle(jsonString: json)
    }
}

// MARK: - TDX Platform Key

extension AttestationBundle {
    /// Returns the PCK (Platform Certification Key) public key from the workload TDX quote,
    /// or `nil` if this bundle type does not contain a TDX quote.
    ///
    /// The PCK is a stable P-256 key derived from platform hardware fuses, issued by Intel.
    /// It persists across reboots and only changes when the platform's TCB is updated.
    public var tdxPlatformKey: P256.Signing.PublicKey? {
        get throws {
            switch proto.attestationBundle {
            case .gcpv1AttestationBundle(let gcpBundle):
                let tdQuote = gcpBundle.gcpv1Attestation.tdxWorkload.quote.tdxCcelQuote.tdQuote
                guard !tdQuote.isEmpty else {
                    return nil
                }
                var buffer = ArraySlice([UInt8](tdQuote))
                let quote = try V4.Quote(from: &buffer)
                guard let pck = quote.pckCertificate else {
                    return nil
                }
                return P256.Signing.PublicKey(pck.certificate.publicKey)

            case .appleSiliconAttestationBundle, .testAttestationBundle, .none:
                return nil
            }
        }
    }
}

// MARK: - AppData

extension AttestationBundle {
    /// Returns the appData included in this attestation bundle, or `nil` if none was provided.
    ///
    /// For GCPv1 bundles, appData is extracted from the serialized `AttestedMetadata` field.
    /// For AppleSilicon bundles, appData is a direct field on the bundle.
    public var appData: Data? {
        get throws {
            switch proto.attestationBundle {
            case .gcpv1AttestationBundle(let gcpBundle):
                let serializedMetadata = gcpBundle.gcpv1Attestation.attestedMetadata
                guard !serializedMetadata.isEmpty else {
                    return nil
                }
                let metadata = try PrivateCloudCompute_AttestedMetadata(serializedBytes: serializedMetadata)
                guard metadata.hasAppData, !metadata.appData.value.isEmpty else {
                    return nil
                }
                return metadata.appData.value

            case .appleSiliconAttestationBundle(let appleBundle):
                let data = appleBundle.appData
                return data.isEmpty ? nil : data

            case .testAttestationBundle, .none:
                return nil
            }
        }
    }
}

// MARK: - Serialization

extension AttestationBundle {
    /// Returns the bundle as protobuf encoded bytes.
    public func serializedData() throws -> Data {
        return try self.proto.serializedData()
    }

    /// Returns the bundle as a json encoded string.
    public func jsonString() throws -> String {
        return try self.proto.jsonString()
    }
}

// MARK: - Structural Validation

extension AttestationBundle {
    /// Returns a validated ``Validated.AttestationBundle`` if the bundle has correct structure. Does not perform any
    /// form of actual content or claim verification.
    @available(*, deprecated, renamed: "withValidatedStructure", message: "Use closure based API to avoid misuse of minimally validated bundle")
    public func validateStructure() async throws -> Validated.AttestationBundle {
        try await UniversalValidator(transparencyVerifier: NopTransparencyLog()).validate(bundle: self, against: UniversalValidator.structuralPolicy)
    }

    public func withValidatedStructure<R>(_ block: (Validated.AttestationBundle) async throws -> R) async throws -> R {
        let bundle = try await UniversalValidator(transparencyVerifier: NopTransparencyLog()).validate(bundle: self, against: UniversalValidator.structuralPolicy)
        return try await block(bundle)
    }

    public func firmwareRelease() async throws -> ReleaseV2 {
        try await UniversalValidator(transparencyVerifier: NopTransparencyLog()).validate(bundle: self, against: UniversalValidator.structuralPolicy).firmwareRelease()
    }

    public func workloadRelease() async throws -> ReleaseV2 {
        try await UniversalValidator(transparencyVerifier: NopTransparencyLog()).validate(bundle: self, against: UniversalValidator.structuralPolicy).workloadRelease()
    }

    public func deviceIdentityManifest() async throws -> DeviceIdentityManifest {
        try await UniversalValidator(transparencyVerifier: NopTransparencyLog()).validate(bundle: self, against: UniversalValidator.structuralPolicy).deviceIdentityManifest()
    }
}
