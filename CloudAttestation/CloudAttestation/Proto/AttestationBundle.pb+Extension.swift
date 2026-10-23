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
//  AttestationBundle.pb+Extension.swift
//  CloudAttestation
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

import Foundation
import CryptoKit
@_implementationOnly import Img4
import InternalSwiftProtobuf

// MARK: - SealedHash Extensions
extension Proto_SealedHashLedger {
    subscript(index: UUID) -> Proto_SealedHash? {
        get {
            self.slots[index.uuidString]
        }
        set(newValue) {
            self.slots[index.uuidString] = newValue
        }
    }
}

extension Proto_HashAlg {
    var hashFunction: (any HashFunction.Type)? {
        switch self {
        case .sha256:
            SHA256.self
        case .sha384:
            SHA384.self
        default:
            nil
        }
    }
}

// MARK: - Codable Extension
extension Proto_AttestationBundle: Encodable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.sepAttestation.isEmpty ? nil : self.sepAttestation, forKey: .sepAttestation)
        try container.encodeIfPresent(self.apTicket.isEmpty ? nil : self.apTicket, forKey: .apTicket)
        try container.encodeIfPresent(self.hasSealedHashes ? self.sealedHashes : nil, forKey: .sealedHashes)
        try container.encodeIfPresent(
            self.provisioningCertificateChain.isEmpty ? nil : self.provisioningCertificateChain,
            forKey: .provisioningCertificateChain
        )
        try container.encodeIfPresent(self.appData.isEmpty ? nil : self.appData, forKey: .appData)
        try container.encodeIfPresent(self.hasKeyExpiration ? self.keyExpiration.date : nil, forKey: .keyExpiration)
        try container.encodeIfPresent(self.hasTransparencyProofs ? self.transparencyProofs : nil, forKey: .transparencyProofs)
        try container.encodeIfPresent(self.hasLocalPolicy ? self.localPolicy : nil, forKey: .localPolicy)
        try container.encodeIfPresent(self.sfrManifest.isEmpty ? nil : self.sfrManifest, forKey: .sfrManifest)
    }

    enum CodingKeys: CodingKey {
        case provisioningCertificateChain
        case sepAttestation
        case apTicket
        case sealedHashes
        case appData
        case keyExpiration
        case transparencyProofs
        case localPolicy
        case sfrManifest
    }
}

extension Proto_LocalPolicy: Encodable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.policy.isEmpty ? nil : self.policy, forKey: .policy)
        try container.encodeIfPresent(self.implementation.rawValue != 0 ? self.implementation : nil, forKey: .implementation)
    }

    enum CodingKeys: CodingKey {
        case policy
        case implementation
    }
}

extension Proto_LocalPolicy.Implementation: Encodable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .unknown:
            try container.encode("IMPLEMENTATION_UNKNOWN")
        case .ec384Sha384:
            try container.encode("IMPLEMENTATION_EC384SHA384")
        case .UNRECOGNIZED(let int):
            try container.encode(int)
        }
    }
}

extension Proto_SealedHashLedger: Encodable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.slots.isEmpty ? nil : self.slots, forKey: .slots)
    }

    enum CodingKeys: CodingKey {
        case slots
    }
}

extension Proto_SealedHash: Encodable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.hashAlg.rawValue != 0 ? self.hashAlg : nil, forKey: .hashAlg)
        try container.encodeIfPresent(self.entries.isEmpty ? nil : self.entries, forKey: .entries)
    }

    enum CodingKeys: CodingKey {
        case hashAlg
        case entries
    }
}

extension Proto_SealedHash.Entry: Encodable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.digest.isEmpty ? nil : self.digest, forKey: .digest)
        try container.encodeIfPresent(self.flags != 0 ? self.flags : nil, forKey: .flags)

        switch self.info {
        case .cryptex(_):
            try container.encode(self.cryptex, forKey: .cryptex)

        case .cryptexSalt(_):
            try container.encode(self.cryptexSalt, forKey: .cryptexSalt)

        case .secureConfig(_):
            try container.encode(self.secureConfig, forKey: .secureConfig)

        default:
            break
        }

        try container.encodeIfPresent(self.metadata.isEmpty ? nil : self.metadata, forKey: .metadata)
    }

    enum CodingKeys: CodingKey {
        case digest
        case flags
        case cryptex
        case cryptexSalt
        case secureConfig
        case metadata
    }
}

extension Proto_Cryptex: Encodable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.image4Manifest.isEmpty ? nil : self.image4Manifest, forKey: .image4Manifest)
    }

    enum CodingKeys: CodingKey {
        case image4Manifest
    }
}

extension Proto_Cryptex.Salt: Encodable {
    public func encode(to encoder: any Encoder) throws {
        _ = encoder.container(keyedBy: CodingKeys.self)
    }

    enum CodingKeys: CodingKey {}
}

extension Proto_SecureConfig: Encodable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.entry.isEmpty ? nil : self.entry, forKey: .entry)
        try container.encodeIfPresent(self.metadata.isEmpty ? nil : self.metadata, forKey: .metadata)
        try container.encodeIfPresent(self.data.isEmpty ? nil : self.data, forKey: .data)
    }

    enum CodingKeys: CodingKey {
        case entry
        case metadata
        case data
    }
}

extension Proto_HashAlg: Encodable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .unknown:
            try container.encode("HASH_ALG_UNKNOWN")
        case .sha256:
            try container.encode("HASH_ALG_SHA256")
        case .sha384:
            try container.encode("HASH_ALG_SHA384")
        case .UNRECOGNIZED(let int):
            try container.encode(int)
        }
    }
}

extension HashFunction {
    static var protoHashAlg: Proto_HashAlg {

        switch Self.self {
        case is SHA256.Type:
            .sha256

        case is SHA384.Type:
            .sha384

        default:
            .unknown
        }
    }
}

extension Proto_TransparencyProofs: Encodable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.hasProofs ? self.proofs : nil, forKey: .proofs)
    }

    enum CodingKeys: CodingKey {
        case proofs
    }
}

extension ATLogProofs: Encodable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.hasInclusionProof ? self.inclusionProof : nil, forKey: .inclusionProof)
        try container.encodeIfPresent(self.hasMilestoneConsistency ? self.milestoneConsistency : nil, forKey: .milestoneConsistency)
    }

    enum CodingKeys: CodingKey {
        case inclusionProof
        case milestoneConsistency
    }
}

extension LogEntry: Encodable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.logType.rawValue != 0 ? self.logType : nil, forKey: .logType)
        try container.encodeIfPresent(self.hasSlh ? self.slh : nil, forKey: .slh)
        try container.encodeIfPresent(
            self.hashesOfPeersInPathToRoot.isEmpty ? nil : self.hashesOfPeersInPathToRoot,
            forKey: .hashesOfPeersInPathToRoot
        )
        try container.encodeIfPresent(self.nodeBytes.isEmpty ? nil : self.nodeBytes, forKey: .nodeBytes)
        try container.encodeIfPresent(self.nodePosition != 0 ? self.nodePosition : nil, forKey: .nodePosition)
        try container.encodeIfPresent(self.nodeType.rawValue != 0 ? self.nodeType : nil, forKey: .nodeType)
    }

    enum CodingKeys: CodingKey {
        case logType
        case slh
        case hashesOfPeersInPathToRoot
        case nodeBytes
        case nodePosition
        case nodeType
    }
}

extension LogType: Encodable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .unknownLog:
            try container.encode("UNKNOWN_LOG")
        case .perApplicationChangeLog:
            try container.encode("PER_APPLICATION_CHANGE_LOG")
        case .perApplicationTree:
            try container.encode("PER_APPLICATION_TREE")
        case .topLevelTree:
            try container.encode("TOP_LEVEL_TREE")
        case .ctLog:
            try container.encode("CT_LOG")
        case .atLog:
            try container.encode("AT_LOG")
        case .UNRECOGNIZED(let int):
            try container.encode(int)
        }
    }
}

extension SignedObject: Encodable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.object.isEmpty ? nil : self.object, forKey: .object)
        try container.encodeIfPresent(self.hasSignature ? self.signature : nil, forKey: .signature)
    }

    enum CodingKeys: CodingKey {
        case object
        case signature
    }
}

extension Signature: Encodable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.signature.isEmpty ? nil : self.signature, forKey: .signature)
        try container.encodeIfPresent(
            self.signingKeySpkihash.isEmpty ? nil : self.signingKeySpkihash,
            forKey: .signingKeySPKIHash
        )
        try container.encodeIfPresent(self.algorithm.rawValue != 0 ? self.algorithm : nil, forKey: .algorithm)
    }

    enum CodingKeys: CodingKey {
        case signature
        case signingKeySPKIHash
        case algorithm
    }
}

extension Signature.SignatureAlgorithm: Encodable {}

extension NodeType: Encodable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .paclNode:
            try container.encode("PACL_NODE")
        case .patNode:
            try container.encode("PAT_NODE")
        case .patConfigNode:
            try container.encode("PAT_CONFIG_NODE")
        case .tltNode:
            try container.encode("TLT_NODE")
        case .tltConfigNode:
            try container.encode("TLT_CONFIG_NODE")
        case .logClosedNode:
            try container.encode("LOG_CLOSED_NODE")
        case .ctNode:
            try container.encode("CT_NODE")
        case .atlNode:
            try container.encode("ATL_NODE")
        case .UNRECOGNIZED(let int):
            try container.encode(int)
        }
    }
}

extension LogConsistency: Encodable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.hasStartSlh ? self.startSlh : nil, forKey: .startSLH)
        try container.encodeIfPresent(self.hasEndSlh ? self.endSlh : nil, forKey: .endSLH)
        try container.encodeIfPresent(self.proofHashes.isEmpty ? nil : self.proofHashes, forKey: .proofHashes)
        try container.encodeIfPresent(self.hasPatInclusionProof ? self.patInclusionProof : nil, forKey: .patInclusionProof)
        try container.encodeIfPresent(self.hasTltInclusionProof ? self.tltInclusionProof : nil, forKey: .tltInclusionProof)
    }

    enum CodingKeys: CodingKey {
        case startSLH
        case endSLH
        case proofHashes
        case patInclusionProof
        case tltInclusionProof
    }
}

extension Proto_AppData {
    var identifiers: (version: UInt32, domain: String, name: String) {
        return (version, domain, name)
    }
}

extension Proto_LocalPolicy {
    var tbpmDigest: Data {
        get throws {
            guard !self.policy.isEmpty else {
                throw Error.missingLocalPolicy
            }

            var img4 = Img4()
            try self.policy.withUnsafeBytes { buffer in
                let ret = Img4DecodeInit(buffer.baseAddress, buffer.count, &img4)
                guard ret == DR_Success else {
                    throw Error.decodeFailed(status: ret.rawValue)
                }
            }

            var implementation: Img4DecodeImplementation
            let digestSize: Int
            switch self.implementation {
            case .unknown, .UNRECOGNIZED(_):
                throw Error.unsupportedImplementation
            case .ec384Sha384:
                implementation = kImg4DecodeLocalPolicyEc384Sha384
                digestSize = 48
            }

            let ret = Img4DecodePerformTrustEvaluation(UInt32(kImg4Tag_lpol), &img4, { _, _, _, _ in 0 }, &implementation, nil)
            guard ret == DR_Success else {
                throw Error.trustEvaluationFailed(status: ret.rawValue)
            }

            var buffer = Data(repeating: 0, count: digestSize)
            try buffer.withUnsafeMutableBytes { buffer in
                let ret = Img4DecodeCopyManifestTrustedBootPolicyMeasurement(&img4, { _, _, _, _ in 0 }, &implementation, buffer.baseAddress, buffer.count)
                guard ret == DR_Success else {
                    throw Error.tbpmDigestCalculationFailed(status: ret.rawValue)
                }
            }

            return buffer
        }
    }

    var nsihDigest: Data {
        get throws {
            guard !self.policy.isEmpty else {
                throw Error.missingLocalPolicy
            }

            var img4 = Img4()
            try policy.withUnsafeBytes { buffer in
                let ret = Img4DecodeInit(buffer.baseAddress, buffer.count, &img4)
                guard ret == DR_Success else {
                    throw Error.decodeFailed(status: ret.rawValue)
                }
            }

            var size: Int = 0
            var pointer: UnsafeMutablePointer<UInt8>? = nil
            let ret = Img4DecodeGetDataFromSection(&img4, UInt32(kImg4ManifestIndex), DERTag(kImg4Tag_nsih), &pointer, &size)
            guard ret == DR_Success, let pointer else {
                throw Error.decodeFailed(status: ret.rawValue)
            }

            return Data(bytesNoCopy: pointer, count: size, deallocator: .none)
        }
    }
}

extension Proto_LocalPolicy {
    enum Error: Swift.Error {
        case missingLocalPolicy
        case decodeFailed(status: Int32)
        case unsupportedImplementation
        case trustEvaluationFailed(status: Int32)
        case tbpmDigestCalculationFailed(status: Int32)
    }
}
