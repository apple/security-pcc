// Copyright © 2025 Apple Inc. All Rights Reserved.

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
//  Transparency.swift
//  CloudAttestation
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

import Foundation
import CryptoKit
import SwiftASN1Internal

/// A DER-codable structure that canonically represents all of the software components running on a device, including OS and installed cryptexes.
/// Intended for use in Transparency Logs.
public struct Release: Sendable, Hashable {
    public var version: Int { 1 }
    public let apTicket: ASN1OctetString
    public let cryptexTickets: Set<ASN1OctetString>

    @usableFromInline
    let unknownFields: [ASN1Any]

    /// Creates a new `Release`
    /// Use autogenerated member-wise initializer to keep up to date.
    /// Don't make this public unless necessary.
    init(apTicket: ASN1OctetString, cryptexTickets: Set<ASN1OctetString>, unknownFields: [ASN1Any] = []) {
        self.apTicket = apTicket
        self.cryptexTickets = cryptexTickets
        self.unknownFields = unknownFields
    }

    /// Creates a new `Release`.
    /// - Parameters:
    ///   - apTicket: The AP ticket.
    ///   - cryptexTickets: The cryptex tickets.
    public init(apTicket: Data, cryptexTickets: some Sequence<Data>) {
        self.apTicket = ASN1OctetString(contentBytes: [UInt8](apTicket)[...])
        self.cryptexTickets = Set(cryptexTickets.map { ASN1OctetString(contentBytes: [UInt8]($0)[...]) })
        self.unknownFields = []
    }

    /// Creates a new `Release`.
    /// - Parameters:
    ///   - apTicket: The AP ticket.
    ///   - cryptexTickets: The cryptex tickets.
    public init(apTicket: ASN1OctetString, cryptexTickets: some Sequence<ASN1OctetString>) {
        self.apTicket = apTicket
        self.cryptexTickets = Set(cryptexTickets)
        self.unknownFields = []
    }

    /// Creates a new `Release`.
    /// - Parameters:
    ///   - apTicket: The AP ticket.
    ///   - cryptexTickets: The cryptex tickets.
    public init(apTicket: Image4Manifest, cryptexTickets: some Sequence<Image4Manifest>) {
        self = .init(apTicket: apTicket.data, cryptexTickets: Set(cryptexTickets.map { $0.data }))
    }

    /// Creates a new `Release`.
    /// - Parameter tickets: The tickets.
    public init(tickets: [Image4Manifest]) throws {
        let tickets = Dictionary(grouping: tickets, by: { $0.kind })

        guard let apTicket = tickets[.ap]?.first else {
            throw Error.missingAPTicket
        }

        self = .init(apTicket: apTicket, cryptexTickets: (tickets[.cryptex] ?? []) + (tickets[.pdi] ?? []) + (tickets[.pdiOrCryptex] ?? []))
    }

    /// Creates a new `Release`.
    /// - Parameter serializedData: The serialized data.
    public init(serializedData: some DataProtocol) throws {
        self = try .init(derEncoded: ArraySlice(serializedData))
    }

    /// Creates a new `Release` from an ``AttestationBundle``.
    /// - Parameter bundle: The bundle.
    public init(bundle: AttestationBundle) throws {
        self = try .init(proto: bundle.proto)
    }

    /// Creates a new `Release` from an ``AttestationBundle``, optionally evaluating the Image4Manifest.
    /// - Parameters:
    ///   - bundle: The bundle.
    ///   - evaluateTrust: The trust evaluation flag.
    public init(bundle: AttestationBundle, evaluateTrust: Bool) throws {
        self = try .init(proto: bundle.proto, evaluateTrust: evaluateTrust)
    }

    /// Creates a new `Release` from an ``AttestationBundle``, optionally evaluating the Image4Manifest
    /// - Parameters:
    ///   - bundle: The bundle.
    ///   - evaluateTrust: The trust evaluation flag.
    ///   - requireCryptex1: The trust evaluation flag.
    public init(bundle: AttestationBundle, evaluateTrust: Bool, requireCryptex1: Bool) throws {
        self = try .init(proto: bundle.proto, evaluateTrust: evaluateTrust, requireCryptex1: requireCryptex1)
    }

    init(proto: Proto_AttestationBundle, evaluateTrust: Bool = true, requireCryptex1: Bool = false) throws {
        let apTicket = try Image4Manifest(data: proto.apTicket, kind: .ap).canonicalize(evaluateTrust: evaluateTrust)
        let cryptexes = try Set(proto.cryptexes(requireCryptex1: requireCryptex1)?.image4Manifests.map { try $0.canonicalize(evaluateTrust: evaluateTrust).data } ?? [])
        self = .init(apTicket: apTicket.data, cryptexTickets: cryptexes)
    }

    /// Returns the digest of the release.
    /// - Parameter using: The hash function.
    @inlinable
    public func digest<Hash: HashFunction>(using: Hash.Type = SHA256.self) -> Hash.Digest {
        return Hash.hash(data: self.serializedData)
    }

    /// The serialized data in ASN.1 DER bytes.
    @inlinable
    public var serializedData: Data {
        var serializer = DER.Serializer()
        // We only have primitive types and should never throw
        try! serializer.serialize(self)
        return Data(serializer.serializedBytes)
    }
}

// MARK: - JSON Encoding
extension Release: CustomStringConvertible {
    public var sha256: String {
        digest().hexString
    }

    public var description: String {
        "release(sha256: \(sha256))"
    }
}

extension Release: Encodable {
    /// The JSON string representation of ``Release``.
    public var jsonString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: (try? encoder.encode(self)) ?? Data(), as: UTF8.self)
    }

    public func encode(to encoder: any Encoder) throws {
        try EncodableRelease(release: self).encode(to: encoder)
    }
}

// This is easier than manually implementing Encodable wtih CodingKeys
private struct EncodableRelease: Encodable {
    var version: Int
    let apTicket: String
    let cryptexTickets: [String]

    init(release: Release) {
        self.version = release.version
        self.apTicket = release.apTicket.sha256
        self.cryptexTickets = release.cryptexTickets.map { $0.sha256 }.sorted()
    }
}

extension Release {
    enum Error: Swift.Error {
        case missingAPTicket
    }
}

extension ASN1OctetString {
    fileprivate var sha256: String {
        SHA256.hash(data: self.bytes).compactMap { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - DER Encoding
extension Release: DERImplicitlyTaggable {
    @inlinable
    public func serialize(into coder: inout DER.Serializer, withIdentifier identifier: ASN1Identifier) throws {
        try coder.appendConstructedNode(identifier: identifier) { coder in
            try coder.serialize(self.version)
            try coder.serialize(self.apTicket)
            try coder.serializeSetOf(self.cryptexTickets, identifier: .set)
            for node in self.unknownFields {
                try coder.serialize(node)
            }
        }
    }

    public static var defaultIdentifier: ASN1Identifier {
        .sequence
    }

    public init(derEncoded: ASN1Node, withIdentifier identifier: ASN1Identifier) throws {
        self = try DER.sequence(derEncoded, identifier: identifier) { nodes in
            let version = try Int(derEncoded: &nodes)

            guard version == 1 else {
                throw ASN1Error.invalidASN1Object(reason: "Unsupported version: \(version)")
            }

            let apTicket = try ASN1OctetString(derEncoded: &nodes)

            let cryptexes = try DER.set(of: ASN1OctetString.self, identifier: .set, nodes: &nodes)

            // Drain any new optional fields that our current implementation may not be aware of.
            var unknownFields: [ASN1Any] = []
            while let node = nodes.next() {
                unknownFields.append(ASN1Any(derEncoded: node))
            }

            return Release(apTicket: apTicket, cryptexTickets: Set(cryptexes), unknownFields: unknownFields)
        }
    }
}

extension Release {
    public static func local(assetProvider: some AttestationAssetProvider) throws -> Release {
        return try Self.local(assetProvider: assetProvider, requireCryptex1: false)
    }

    public static func local(assetProvider: some AttestationAssetProvider, requireCryptex1: Bool) throws -> Release {
        let apTicket = try assetProvider.apTicket
        let sealedHashEntries = try assetProvider.sealedHashEntries

        let cryptexSlot = sealedHashEntries[cryptexSlotUUID]
        let cryptexTickets = try cryptexSlot?.compactMap { entry -> Data? in
            guard let data = entry.data, entry.flags != .ratchetLocked else {
                return nil
            }
            let kind: Image4Manifest.Kind = requireCryptex1 ? .cryptex : .pdiOrCryptex
            return try Image4Manifest(data: data, kind: kind).canonicalize().data
        }

        return Release(apTicket: try Image4Manifest(data: apTicket, kind: .ap).canonicalize().data, cryptexTickets: cryptexTickets ?? [])
    }
}
