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

//  Copyright © 2024 Apple, Inc. All rights reserved.
//

import ArgumentParserInternal
import CryptoKit
import Foundation
import InternalSwiftProtobuf
@_spi(TransparencyAuditor) import CloudAttestation

extension CLI.TransparencyLogCmd {
    struct VerifyInclusionCmd: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "verify-inclusion",
            abstract: "Verify the inclusion proof of an attestation against a local copy of the transparency-log."
        )

        @OptionGroup var transparencyLogOptions: CLI.TransparencyLogCmd.options

        @OptionGroup var attestOptions: CLI.AttestationFormatOptions

        @Argument(help: "Path to input file. Use '-' to read from stdin.",
                  completion: .file())
        var file: String

        func run() async throws {
            let proofBytes: Data
            let releaseDigest: Data

            switch try attestOptions.loadAndDispatch(file: file) {
            case .v2(let nodeBytes):
                // The helper's `release attestation` returns the workload
                // release digest and the serialized ATLogProofs witnessed at
                // attestation time (hex-encoded); those bytes are
                // wire-compatible with CloudAttestation's ATLogProofs, so the
                // merkle math below is identical for v1 and v2.
                let resolver = PCCVREAttestationHelperResolver(environment: transparencyLogOptions.environment)
                let envelope = try await attestOptions.runV2Helper(
                    nodeBytes: nodeBytes,
                    via: resolver,
                    subcommand: ["release", "attestation"]
                )
                guard envelope.ok else {
                    throw CLIError("extract release from v2 bundle: \(envelope.summary)")
                }
                let detail = try Self.decodeV2Detail(envelope.detail)
                guard let proof = detail.softwareTransparencyProof else {
                    throw CLIError(
                        "v2 bundle carries no software transparency proof; " +
                        "verify-inclusion needs one witnessed at attestation time."
                    )
                }
                proofBytes = proof
                releaseDigest = detail.workloadDigest

            case .v1(let nodeBytes, let fileData):
                let attestationBundle = try attestOptions.decodeV1Bundle(nodeBytes: nodeBytes, fileData: fileData)
                proofBytes = try attestationBundle.atLogProofs
                let release = try Release(bundle: attestationBundle)
                releaseDigest = Data(release.digest())
            }

            try verifyInclusion(proofBytes: proofBytes, releaseDigest: releaseDigest)
        }

        /// Shared v1/v2 core: decode `proofBytes` as an `ATLogProofs`, verify
        /// its merkle inclusion path against the locally-downloaded copy of
        /// the transparency tree, then confirm the leaf's `dataHash` matches
        /// `releaseDigest`.
        private func verifyInclusion(proofBytes: Data, releaseDigest: Data) throws {
            let storageURL = FileManager.fileURL(transparencyLogOptions.storage)
                .appending(path: transparencyLogOptions.environment.rawValue)

            let decoder = JSONDecoder()
            var applicationTree = try decoder.decode(MerkleTree<SHA256>.self,
                                                     from: Data(contentsOf: storageURL.appending(path: "applicationTree.json")))

            let logProofs = try CloudAttestation.PrivateCloudCompute_TransparencyLog_ATLogProofs(serializedBytes: proofBytes)
            let inclusionProof = logProofs.inclusionProof
            let leafBytes = logProofs.inclusionProof.nodeBytes
            let logHead = try CloudAttestation.LogHead(serializedBytes: inclusionProof.slh.object)

            guard applicationTree.count >= Int(logHead.logSize) else {
                throw TransparencyLogError("Inclusion proof is from a later revision of the transparency log compared to the locally downloaded copy")
            }

            applicationTree.leaves = .init(applicationTree.leaves[..<Int(logHead.logSize)])

            guard applicationTree.verifyInclusion(of: leafBytes, with: inclusionProof.merkleInclusionProof()) else {
                throw CLIError("Failed to verify inclusion proof")
            }

            // now check that the release digest actually matches the hash in the ATLeaf node.
            let changeLogNode = try CloudAttestation.ChangeLogNodeV2(serializedBytes: leafBytes)
            var transparencyByteBuffer = TransparencyByteBuffer(data: changeLogNode.mutation)
            let atLeaf = try ATLeafData(bytes: &transparencyByteBuffer)

            guard releaseDigest.elementsEqual(atLeaf.dataHash) else {
                throw CLIError("Release digest from attestaton bundle does not match digest in ATLeaf node")
            }

            print("Successfully verified inclusion proof ✅ (revision: \(logHead.revision), index: \(inclusionProof.nodePosition), logSize: \(logHead.logSize), rootDigest: \(applicationTree.rootDigest.hexString))")
        }

        /// Minimal decode of the helper's `release attestation -f json`
        /// `detail` payload — only the fields verify-inclusion needs.
        private struct V2Detail {
            let workloadDigest: Data
            let softwareTransparencyProof: Data?
        }

        private static func decodeV2Detail(_ json: String) throws -> V2Detail {
            guard let data = json.data(using: .utf8),
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let workloadHex = obj["workloadDigest"] as? String,
                  let workloadDigest = Data(hexString: workloadHex)
            else {
                throw CLIError("decode helper release-attestation detail: missing/malformed workloadDigest")
            }
            let proof: Data?
            if let proofHex = obj["softwareTransparencyProof"] as? String {
                guard let decoded = Data(hexString: proofHex) else {
                    throw CLIError("decode helper release-attestation detail: softwareTransparencyProof is not valid hex")
                }
                proof = decoded
            } else {
                proof = nil
            }
            return V2Detail(workloadDigest: workloadDigest, softwareTransparencyProof: proof)
        }
    }
}

private extension CloudAttestation.LogEntry {
    func merkleInclusionProof() -> MerkleTree<SHA256>.InclusionProof {
        return .init(index: Int(nodePosition), path: hashesOfPeersInPathToRoot)
    }
}
