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
//  Release+Attestation.swift
//  CloudAttestationV2
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//

import ArgumentParser
import CloudAttestationV2
import Common
import Crypto
import Foundation

extension Release {
    public struct Attestation: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            abstract: "Extract release from an attestation bundle."
        )

        public init() {}

        @OptionGroup
        public var inputOptions: BundleInputOptions

        @OptionGroup
        public var outputOptions: OutputOptions

        public func run() async throws {
            let bundle: AttestationBundle
            let workloadRelease: ReleaseV2
            let firmwareRelease: ReleaseV2
            do {
                bundle = try inputOptions.bundle()
                let validated = try await GCPv1Validator().validate(bundle: bundle, against: GCPv1Validator.structuralPolicy)
                workloadRelease = try validated.workloadRelease()
                firmwareRelease = try validated.firmwareRelease()
            } catch {
                if outputOptions.outputFormat == .json {
                    try SubprocessEnvelope.failure(
                        .domainFailure,
                        summary: "failed to extract release from attestation bundle",
                        error: error
                    ).print()
                    throw ExitCode(1)
                }
                throw error
            }

            switch outputOptions.outputFormat {
            case .text:
                try await outputOptions.display(workloadRelease)
                try await outputOptions.display(firmwareRelease)
            case .json:
                let workloadDigest = try Data(workloadRelease.digest()).hexString
                let firmwareDigest = try Data(firmwareRelease.digest()).hexString
                let proofs = bundle.proto.gcpv1AttestationBundle.transparencyProofs
                // The envelope's top-level `digest` is the *workload* release digest:
                // that's what software-transparency proofs are over and what
                // `attestation canonicalize` historically printed for v1. The firmware
                // release digest is in `detail.firmwareDigest`. Documented in
                // Docs/SubprocessContract.md.
                try SubprocessEnvelope(
                    ok: true,
                    summary: "workload \(workloadDigest); firmware \(firmwareDigest)",
                    digest: workloadDigest,
                    detail: Detail(
                        workloadDigest: workloadDigest,
                        workload: workloadRelease,
                        firmwareDigest: firmwareDigest,
                        firmware: firmwareRelease,
                        softwareTransparencyProof: proofs.hasSoftwareTransparencyProofs
                            ? try proofs.softwareTransparencyProofs.serializedData() : nil,
                        firmwareTransparencyProof: proofs.hasFirmwareTransparencyProofs
                            ? try proofs.firmwareTransparencyProofs.serializedData() : nil,
                        certificateTransparencyProof: proofs.hasCertificateTransparencyProofs
                            ? try proofs.certificateTransparencyProofs.serializedData() : nil
                    )
                ).print()
            }
        }

        /// `SubprocessEnvelope.detail` for `release attestation -f json`.
        public struct Detail: Encodable, Sendable {
            public let workloadDigest: String
            public let workload: ReleaseV2
            public let firmwareDigest: String
            public let firmware: ReleaseV2
            /// Serialized `PrivateCloudCompute_TransparencyLog_ATLogProofs` bytes
            /// witnessed at attestation time — the inclusion proof for
            /// `workloadDigest` against the software-release transparency
            /// tree. Hex-encoded by the envelope. `nil` when the bundle
            /// carries no proof (e.g. simulator-minted with
            /// `NopTransparencyLog`). Consumers that don't link this module
            /// (pccvre's `transparency-log verify-inclusion`) decode these
            /// with the wire-compatible `CloudAttestation.…ATLogProofs` type.
            public let softwareTransparencyProof: Data?
            /// As above, for `firmwareDigest` against the firmware tree.
            public let firmwareTransparencyProof: Data?
            /// As above, for the platform-certificate leaf against the
            /// certificate tree.
            public let certificateTransparencyProof: Data?
        }
    }
}
