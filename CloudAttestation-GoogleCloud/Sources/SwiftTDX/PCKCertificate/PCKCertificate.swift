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
//  PCKCertificate.swift
//  CloudAttestationV2
//
//  Created by David Zech on 1/15/26.
//

import Common
import X509
import Foundation
import SwiftASN1
import BinaryCoding

@dynamicMemberLookup
public struct PCKCertificate: BinaryDecodable, Sendable, Hashable {
    public var certificate: X509.Certificate

    public init(_ certificate: X509.Certificate) {
        self.certificate = certificate
    }

    package init(from buffer: inout ArraySlice<UInt8>) throws {
        let node = try DER.parse(buffer)
        self.certificate = try X509.Certificate(derEncoded: node)
        buffer = buffer[node.encodedBytes.endIndex...]
    }

    public subscript<T>(dynamicMember keyPath: KeyPath<X509.Certificate, T>) -> T {
        self.certificate[keyPath: keyPath]
    }

    package var byteCount: Int {
        var serializer = DER.Serializer()
        try? serializer.serialize(certificate)
        return serializer.serializedBytes.count
    }
}

// MARK: - Helper getters

extension PCKCertificate {
    public var pPID: [UInt8]? {
        guard let ext = self.extensions[oid: Self.id_ce_sGXExtensions] else {
            return nil
        }

        guard let sgxExtensions = try? SGXExtensions(derEncoded: ext.value) else {
            return nil
        }

        guard let ppidExt = (sgxExtensions.values.first { $0.id == .pPID }) else {
            return nil
        }

        guard case .pPID(let ppid) = ppidExt else {
            return nil
        }

        return .init(ppid.bytes)
    }

    public var platformInstanceID: [UInt8]? {
        guard let ext = self.extensions[oid: Self.id_ce_sGXExtensions] else {
            return nil
        }

        guard let sgxExtensions = try? SGXExtensions(derEncoded: ext.value) else {
            return nil
        }

        guard let piidExt = (sgxExtensions.values.first { $0.id == .platformInstanceID }) else {
            return nil
        }

        guard case .platformInstanceID(let piid) = piidExt else {
            return nil
        }

        return .init(piid.bytes)
    }

    package var fmspc: Data? {
        guard let ext = self.extensions[oid: Self.id_ce_sGXExtensions],
            let sgxExtensions = try? SGXExtensions(derEncoded: ext.value),
            let fmspcExt = sgxExtensions.values.first(where: { $0.id == .fMSPC }),
            case .fMSPC(let fmspc) = fmspcExt
        else {
            return nil
        }
        return Data(fmspc.bytes)
    }

    package var sgxTcbCompSvn: Data? {
        guard let ext = self.extensions[oid: Self.id_ce_sGXExtensions],
            let sgxExtensions = try? SGXExtensions(derEncoded: ext.value),
            let tcbExt = sgxExtensions.values.first(where: { $0.id == .tCB }),
            case .tCB(let tcb) = tcbExt
        else {
            return nil
        }
        var svns = [UInt8](repeating: 0, count: 16)
        for value in tcb.values {
            switch value {
            case .sGXTCBComp01SVN(let v): svns[0] = UInt8(v)
            case .sGXTCBComp02SVN(let v): svns[1] = UInt8(v)
            case .sGXTCBComp03SVN(let v): svns[2] = UInt8(v)
            case .sGXTCBComp04SVN(let v): svns[3] = UInt8(v)
            case .sGXTCBComp05SVN(let v): svns[4] = UInt8(v)
            case .sGXTCBComp06SVN(let v): svns[5] = UInt8(v)
            case .sGXTCBComp07SVN(let v): svns[6] = UInt8(v)
            case .sGXTCBComp08SVN(let v): svns[7] = UInt8(v)
            case .sGXTCBComp09SVN(let v): svns[8] = UInt8(v)
            case .sGXTCBComp10SVN(let v): svns[9] = UInt8(v)
            case .sGXTCBComp11SVN(let v): svns[10] = UInt8(v)
            case .sGXTCBComp12SVN(let v): svns[11] = UInt8(v)
            case .sGXTCBComp13SVN(let v): svns[12] = UInt8(v)
            case .sGXTCBComp14SVN(let v): svns[13] = UInt8(v)
            case .sGXTCBComp15SVN(let v): svns[14] = UInt8(v)
            case .sGXTCBComp16SVN(let v): svns[15] = UInt8(v)
            default: break
            }
        }
        return Data(svns)
    }

    package var pcesvn: Int? {
        guard let ext = self.extensions[oid: Self.id_ce_sGXExtensions],
            let sgxExtensions = try? SGXExtensions(derEncoded: ext.value),
            let tcbExt = sgxExtensions.values.first(where: { $0.id == .tCB }),
            case .tCB(let tcb) = tcbExt
        else {
            return nil
        }
        for value in tcb.values {
            if case .pCESVN(let v) = value { return v }
        }
        return nil
    }
}

// MARK: - OIDs

extension PCKCertificate {
    static let id_ce_sGXExtensions: ASN1ObjectIdentifier = [1, 2, 840, 113741, 1, 13, 1]
    static let id_ce_sGXExtensions_pPID = id_ce_sGXExtensions { 1 }
    static let id_ce_sGXExtensions_tCB = id_ce_sGXExtensions { 2 }
    static let id_ce_sGXExtensions_pCE_ID = id_ce_sGXExtensions { 3 }
    static let id_ce_sGXExtensions_fMSPC = id_ce_sGXExtensions { 4 }
    static let id_ce_sGXExtensions_sGXType = id_ce_sGXExtensions { 5 }
    static let id_ce_sGXExtensions_platformInstanceID = id_ce_sGXExtensions { 6 }
    static let id_ce_sGXExtensions_configuration = id_ce_sGXExtensions { 7 }

    static let id_ce_tCB_sGXTCBComp01SVN = id_ce_sGXExtensions_tCB { 1 }
    static let id_ce_tCB_sGXTCBComp02SVN = id_ce_sGXExtensions_tCB { 2 }
    static let id_ce_tCB_sGXTCBComp03SVN = id_ce_sGXExtensions_tCB { 3 }
    static let id_ce_tCB_sGXTCBComp04SVN = id_ce_sGXExtensions_tCB { 4 }
    static let id_ce_tCB_sGXTCBComp05SVN = id_ce_sGXExtensions_tCB { 5 }
    static let id_ce_tCB_sGXTCBComp06SVN = id_ce_sGXExtensions_tCB { 6 }
    static let id_ce_tCB_sGXTCBComp07SVN = id_ce_sGXExtensions_tCB { 7 }
    static let id_ce_tCB_sGXTCBComp08SVN = id_ce_sGXExtensions_tCB { 8 }
    static let id_ce_tCB_sGXTCBComp09SVN = id_ce_sGXExtensions_tCB { 9 }
    static let id_ce_tCB_sGXTCBComp10SVN = id_ce_sGXExtensions_tCB { 10 }
    static let id_ce_tCB_sGXTCBComp11SVN = id_ce_sGXExtensions_tCB { 11 }
    static let id_ce_tCB_sGXTCBComp12SVN = id_ce_sGXExtensions_tCB { 12 }
    static let id_ce_tCB_sGXTCBComp13SVN = id_ce_sGXExtensions_tCB { 13 }
    static let id_ce_tCB_sGXTCBComp14SVN = id_ce_sGXExtensions_tCB { 14 }
    static let id_ce_tCB_sGXTCBComp15SVN = id_ce_sGXExtensions_tCB { 15 }
    static let id_ce_tCB_sGXTCBComp16SVN = id_ce_sGXExtensions_tCB { 16 }
    static let id_ce_tCB_pCESVN = id_ce_sGXExtensions_tCB { 17 }
    static let id_ce_tCB_cPUSVN = id_ce_sGXExtensions_tCB { 18 }

    static let id_ce_configuration_dynamicPlatform = id_ce_sGXExtensions_configuration { 1 }
    static let id_ce_configuration_cachedKeys = id_ce_sGXExtensions_configuration { 2 }
    static let id_ce_configuration_sMTEnabled = id_ce_sGXExtensions_configuration { 3 }
}

// MARK: - Extension Structures

// Sourced from `Appendix A: Profile for Specific Certificate Extensions for the Intel® Software Guard Extensions`
extension PCKCertificate {

    struct SGXExtensions: DERParseable {
        var values: [SGXExtensionValue]

        init(values: [SGXExtensionValue]) {
            self.values = values
        }

        init(derEncoded node: SwiftASN1.ASN1Node) throws {
            self.values = try DER.sequence(of: SGXExtensionValue.self, identifier: .sequence, rootNode: node)
        }
    }

    enum SGXExtensionId: DERParseable {
        case pPID
        case tCB
        case pCE_ID
        case fMSPC
        case sGXType
        case platformInstanceID
        case configuration

        var objectIdentifier: ASN1ObjectIdentifier {
            switch self {
            case .pPID:
                id_ce_sGXExtensions_pPID
            case .tCB:
                id_ce_sGXExtensions_tCB
            case .pCE_ID:
                id_ce_sGXExtensions_pCE_ID
            case .fMSPC:
                id_ce_sGXExtensions_fMSPC
            case .sGXType:
                id_ce_sGXExtensions_sGXType
            case .platformInstanceID:
                id_ce_sGXExtensions_platformInstanceID
            case .configuration:
                id_ce_sGXExtensions_configuration
            }
        }

        init?(objectIdentifier: ASN1ObjectIdentifier) {
            switch objectIdentifier {
            case id_ce_sGXExtensions_pPID:
                self = .pPID
            case id_ce_sGXExtensions_tCB:
                self = .tCB
            case id_ce_sGXExtensions_pCE_ID:
                self = .pCE_ID
            case id_ce_sGXExtensions_fMSPC:
                self = .fMSPC
            case id_ce_sGXExtensions_sGXType:
                self = .sGXType
            case id_ce_sGXExtensions_platformInstanceID:
                self = .platformInstanceID
            case id_ce_sGXExtensions_configuration:
                self = .configuration
            default:
                return nil
            }
        }

        init(derEncoded node: SwiftASN1.ASN1Node) throws {
            let objectIdentfier = try ASN1ObjectIdentifier(derEncoded: node)
            guard let s = Self(objectIdentifier: objectIdentfier) else {
                throw ASN1Error.invalidASN1Object(reason: "invalid SGXExtensionId")
            }
            self = s
        }
    }

    enum SGXExtensionValue: DERParseable {

        var id: SGXExtensionId {
            switch self {
            case .pPID:
                .pPID
            case .tCB:
                .tCB
            case .pCE_ID:
                .pCE_ID
            case .fMSPC:
                .fMSPC
            case .sGXType:
                .sGXType
            case .platformInstanceID:
                .platformInstanceID
            case .configuration:
                .configuration
            }
        }

        case pPID(ASN1OctetString)
        case tCB(TCB)
        case pCE_ID(ASN1OctetString)
        case fMSPC(ASN1OctetString)
        case sGXType(SGXType)
        case platformInstanceID(ASN1OctetString)
        case configuration(Configuration)

        init(derEncoded node: SwiftASN1.ASN1Node) throws {
            self = try DER.sequence(node, identifier: .sequence) { nodes in
                let objectId = try SGXExtensionId(derEncoded: &nodes)
                switch objectId {
                case .pPID:
                    return .pPID(try ASN1OctetString(derEncoded: &nodes))
                case .tCB:
                    return .tCB(try TCB(derEncoded: &nodes))
                case .pCE_ID:
                    return .pCE_ID(try ASN1OctetString(derEncoded: &nodes))
                case .fMSPC:
                    return .fMSPC(try ASN1OctetString(derEncoded: &nodes))
                case .sGXType:
                    return .sGXType(try SGXType(derEncoded: &nodes))
                case .platformInstanceID:
                    return .platformInstanceID(try ASN1OctetString(derEncoded: &nodes))
                case .configuration:
                    return .configuration(try Configuration(derEncoded: &nodes))
                }
            }
        }
    }

    struct TCB: DERParseable {
        var values: [TCBValue]

        init(derEncoded node: SwiftASN1.ASN1Node) throws {
            self.values = try DER.sequence(of: TCBValue.self, identifier: .sequence, rootNode: node)
        }
    }

    enum TCBId: DERParseable {
        case sGXTCBComp01SVN
        case sGXTCBComp02SVN
        case sGXTCBComp03SVN
        case sGXTCBComp04SVN
        case sGXTCBComp05SVN
        case sGXTCBComp06SVN
        case sGXTCBComp07SVN
        case sGXTCBComp08SVN
        case sGXTCBComp09SVN
        case sGXTCBComp10SVN
        case sGXTCBComp11SVN
        case sGXTCBComp12SVN
        case sGXTCBComp13SVN
        case sGXTCBComp14SVN
        case sGXTCBComp15SVN
        case sGXTCBComp16SVN
        case pCESVN
        case cPUSVN

        var objectIdentifier: ASN1ObjectIdentifier {
            switch self {
            case .sGXTCBComp01SVN:
                id_ce_tCB_sGXTCBComp01SVN
            case .sGXTCBComp02SVN:
                id_ce_tCB_sGXTCBComp02SVN
            case .sGXTCBComp03SVN:
                id_ce_tCB_sGXTCBComp03SVN
            case .sGXTCBComp04SVN:
                id_ce_tCB_sGXTCBComp04SVN
            case .sGXTCBComp05SVN:
                id_ce_tCB_sGXTCBComp05SVN
            case .sGXTCBComp06SVN:
                id_ce_tCB_sGXTCBComp06SVN
            case .sGXTCBComp07SVN:
                id_ce_tCB_sGXTCBComp07SVN
            case .sGXTCBComp08SVN:
                id_ce_tCB_sGXTCBComp08SVN
            case .sGXTCBComp09SVN:
                id_ce_tCB_sGXTCBComp09SVN
            case .sGXTCBComp10SVN:
                id_ce_tCB_sGXTCBComp10SVN
            case .sGXTCBComp11SVN:
                id_ce_tCB_sGXTCBComp11SVN
            case .sGXTCBComp12SVN:
                id_ce_tCB_sGXTCBComp12SVN
            case .sGXTCBComp13SVN:
                id_ce_tCB_sGXTCBComp13SVN
            case .sGXTCBComp14SVN:
                id_ce_tCB_sGXTCBComp14SVN
            case .sGXTCBComp15SVN:
                id_ce_tCB_sGXTCBComp15SVN
            case .sGXTCBComp16SVN:
                id_ce_tCB_sGXTCBComp16SVN
            case .pCESVN:
                id_ce_tCB_pCESVN
            case .cPUSVN:
                id_ce_tCB_cPUSVN
            }
        }

        init?(objectIdentifier: ASN1ObjectIdentifier) {
            switch objectIdentifier {
            case id_ce_tCB_sGXTCBComp01SVN:
                self = .sGXTCBComp01SVN
            case id_ce_tCB_sGXTCBComp02SVN:
                self = .sGXTCBComp02SVN
            case id_ce_tCB_sGXTCBComp03SVN:
                self = .sGXTCBComp03SVN
            case id_ce_tCB_sGXTCBComp04SVN:
                self = .sGXTCBComp04SVN
            case id_ce_tCB_sGXTCBComp05SVN:
                self = .sGXTCBComp05SVN
            case id_ce_tCB_sGXTCBComp06SVN:
                self = .sGXTCBComp06SVN
            case id_ce_tCB_sGXTCBComp07SVN:
                self = .sGXTCBComp07SVN
            case id_ce_tCB_sGXTCBComp08SVN:
                self = .sGXTCBComp08SVN
            case id_ce_tCB_sGXTCBComp09SVN:
                self = .sGXTCBComp09SVN
            case id_ce_tCB_sGXTCBComp10SVN:
                self = .sGXTCBComp10SVN
            case id_ce_tCB_sGXTCBComp11SVN:
                self = .sGXTCBComp11SVN
            case id_ce_tCB_sGXTCBComp12SVN:
                self = .sGXTCBComp12SVN
            case id_ce_tCB_sGXTCBComp13SVN:
                self = .sGXTCBComp13SVN
            case id_ce_tCB_sGXTCBComp14SVN:
                self = .sGXTCBComp14SVN
            case id_ce_tCB_sGXTCBComp15SVN:
                self = .sGXTCBComp15SVN
            case id_ce_tCB_sGXTCBComp16SVN:
                self = .sGXTCBComp16SVN
            case id_ce_tCB_pCESVN:
                self = .pCESVN
            case id_ce_tCB_cPUSVN:
                self = .cPUSVN
            default:
                return nil
            }
        }

        init(derEncoded node: SwiftASN1.ASN1Node) throws {
            let objectIdentifier = try ASN1ObjectIdentifier(derEncoded: node)
            guard let s = Self(objectIdentifier: objectIdentifier) else {
                throw ASN1Error.invalidASN1Object(reason: "invalid TCBId: \(objectIdentifier)")
            }

            self = s
        }

    }

    enum TCBValue: DERParseable {
        case sGXTCBComp01SVN(Int)
        case sGXTCBComp02SVN(Int)
        case sGXTCBComp03SVN(Int)
        case sGXTCBComp04SVN(Int)
        case sGXTCBComp05SVN(Int)
        case sGXTCBComp06SVN(Int)
        case sGXTCBComp07SVN(Int)
        case sGXTCBComp08SVN(Int)
        case sGXTCBComp09SVN(Int)
        case sGXTCBComp10SVN(Int)
        case sGXTCBComp11SVN(Int)
        case sGXTCBComp12SVN(Int)
        case sGXTCBComp13SVN(Int)
        case sGXTCBComp14SVN(Int)
        case sGXTCBComp15SVN(Int)
        case sGXTCBComp16SVN(Int)
        case pCESVN(Int)
        case cPUSVN(CPUSVN)

        var id: TCBId {
            switch self {
            case .sGXTCBComp01SVN:
                .sGXTCBComp01SVN
            case .sGXTCBComp02SVN:
                .sGXTCBComp02SVN
            case .sGXTCBComp03SVN:
                .sGXTCBComp03SVN
            case .sGXTCBComp04SVN:
                .sGXTCBComp04SVN
            case .sGXTCBComp05SVN:
                .sGXTCBComp05SVN
            case .sGXTCBComp06SVN:
                .sGXTCBComp06SVN
            case .sGXTCBComp07SVN:
                .sGXTCBComp07SVN
            case .sGXTCBComp08SVN:
                .sGXTCBComp08SVN
            case .sGXTCBComp09SVN:
                .sGXTCBComp09SVN
            case .sGXTCBComp10SVN:
                .sGXTCBComp10SVN
            case .sGXTCBComp11SVN:
                .sGXTCBComp11SVN
            case .sGXTCBComp12SVN:
                .sGXTCBComp12SVN
            case .sGXTCBComp13SVN:
                .sGXTCBComp13SVN
            case .sGXTCBComp14SVN:
                .sGXTCBComp14SVN
            case .sGXTCBComp15SVN:
                .sGXTCBComp15SVN
            case .sGXTCBComp16SVN:
                .sGXTCBComp16SVN
            case .pCESVN:
                .pCESVN
            case .cPUSVN:
                .cPUSVN
            }
        }

        init(derEncoded node: ASN1Node) throws {
            let value: TCBValue = try DER.sequence(node, identifier: .sequence) { nodes in
                let tCBId = try TCBId(derEncoded: &nodes)
                return switch tCBId {
                case .sGXTCBComp01SVN:
                    .sGXTCBComp01SVN(try Int(derEncoded: &nodes))
                case .sGXTCBComp02SVN:
                    .sGXTCBComp02SVN(try Int(derEncoded: &nodes))
                case .sGXTCBComp03SVN:
                    .sGXTCBComp03SVN(try Int(derEncoded: &nodes))
                case .sGXTCBComp04SVN:
                    .sGXTCBComp04SVN(try Int(derEncoded: &nodes))
                case .sGXTCBComp05SVN:
                    .sGXTCBComp05SVN(try Int(derEncoded: &nodes))
                case .sGXTCBComp06SVN:
                    .sGXTCBComp06SVN(try Int(derEncoded: &nodes))
                case .sGXTCBComp07SVN:
                    .sGXTCBComp07SVN(try Int(derEncoded: &nodes))
                case .sGXTCBComp08SVN:
                    .sGXTCBComp08SVN(try Int(derEncoded: &nodes))
                case .sGXTCBComp09SVN:
                    .sGXTCBComp09SVN(try Int(derEncoded: &nodes))
                case .sGXTCBComp10SVN:
                    .sGXTCBComp10SVN(try Int(derEncoded: &nodes))
                case .sGXTCBComp11SVN:
                    .sGXTCBComp11SVN(try Int(derEncoded: &nodes))
                case .sGXTCBComp12SVN:
                    .sGXTCBComp12SVN(try Int(derEncoded: &nodes))
                case .sGXTCBComp13SVN:
                    .sGXTCBComp13SVN(try Int(derEncoded: &nodes))
                case .sGXTCBComp14SVN:
                    .sGXTCBComp14SVN(try Int(derEncoded: &nodes))
                case .sGXTCBComp15SVN:
                    .sGXTCBComp15SVN(try Int(derEncoded: &nodes))
                case .sGXTCBComp16SVN:
                    .sGXTCBComp16SVN(try Int(derEncoded: &nodes))
                case .pCESVN:
                    .pCESVN(try Int(derEncoded: &nodes))
                case .cPUSVN:
                    .cPUSVN(try CPUSVN(derEncoded: &nodes))
                }
            }
            self = value
        }
    }

    typealias PPID = ASN1OctetString
    typealias CPUSVN = ASN1OctetString
    typealias PCE_ID = ASN1OctetString
    typealias FMSPC = ASN1OctetString
    typealias PlatformInstanceID = ASN1OctetString

    enum SGXType: Int, DERParseable {
        case standard = 0
        case scalable = 1
        case scalabeWithIntegrity = 2

        init(derEncoded node: SwiftASN1.ASN1Node) throws {
            let i = try Int(derEncoded: node, withIdentifier: .enumerated)
            guard let s = Self(rawValue: i) else {
                throw ASN1Error.invalidASN1Object(reason: "invalid SGXType: \(i)")
            }
            self = s
        }
    }

    struct Configuration: DERParseable {
        var values: [ConfigurationValue]

        init(derEncoded node: SwiftASN1.ASN1Node) throws {
            self = try DER.sequence(node, identifier: .sequence) { nodes in
                var values: [ConfigurationValue] = []
                while let node = nodes.next() {
                    values.append(try ConfigurationValue(derEncoded: node))
                }

                return .init(values: values)
            }
        }

        init(values: [ConfigurationValue]) {
            self.values = values
        }
    }

    enum ConfigurationValue: DERParseable {
        var configurationId: ConfigurationId {
            switch self {
            case .dynamicPlatform:
                .dynamicPlatform
            case .cachedKey:
                .cachedKeys
            case .sMTENabled:
                .sMTEnabled
            }
        }
        case dynamicPlatform(Bool)
        case cachedKey(Bool)
        case sMTENabled(Bool)

        init(derEncoded node: SwiftASN1.ASN1Node) throws {
            self = try DER.sequence(node, identifier: .sequence) { nodes in
                let configId = try ConfigurationId(derEncoded: &nodes)
                let boolValue = try Bool(derEncoded: &nodes)

                return switch configId {
                case .dynamicPlatform:
                    .dynamicPlatform(boolValue)
                case .cachedKeys:
                    .cachedKey(boolValue)
                case .sMTEnabled:
                    .sMTENabled(boolValue)
                }
            }
        }
    }

    enum ConfigurationId: DERParseable {
        case dynamicPlatform
        case cachedKeys
        case sMTEnabled

        var objectIdentifier: ASN1ObjectIdentifier {
            switch self {
            case .dynamicPlatform:
                id_ce_configuration_dynamicPlatform
            case .cachedKeys:
                id_ce_configuration_cachedKeys
            case .sMTEnabled:
                id_ce_configuration_sMTEnabled
            }
        }

        init?(objectIdentifier: ASN1ObjectIdentifier) {
            switch objectIdentifier {
            case id_ce_configuration_dynamicPlatform:
                self = .dynamicPlatform
            case id_ce_configuration_cachedKeys:
                self = .cachedKeys
            case id_ce_configuration_sMTEnabled:
                self = .sMTEnabled
            default:
                return nil
            }
        }

        init(derEncoded node: SwiftASN1.ASN1Node) throws {
            let objectIdentifier = try ASN1ObjectIdentifier(derEncoded: node)
            guard let s = Self(objectIdentifier: objectIdentifier) else {
                throw ASN1Error.invalidASN1Object(reason: "invalid ConfigurationId: \(objectIdentifier)")
            }
            self = s
        }
    }
}

extension ASN1ObjectIdentifier {
    fileprivate func callAsFunction(_ val: () -> UInt) -> ASN1ObjectIdentifier {
        try! Self.init(elements: self.oidComponents + [val()])
    }
}
