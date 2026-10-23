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

// A brief explanation for why this exists here.
//
// When testing (never in customer) it is not always tenable to get a proper SEP backed key and associated
// CloudAttestation. Instead conventional (in memroy) keys are used.
// The clients are informed of these keys through a serialisation protocol that must 'fit' into the same
// messages as are used for the real CloudAttestations (as this is how the PublicKey and other information is
// passed in the proper production paths to retain the needed privacy gurantees)
//
// Since the attestation format is not controled by this project, and has important verifiability requirements,
// it is undesirable for the testing code paths to try to 'fake' something that is parsable as a
// CloudAttestation. An alternative format is therefore required which can be hidden behind an abstraction
// layer. This code provides that formatting so it can be defined in one place
//
// Since:
// - LocalCloudboardClient needs to depend on this
// - Lots of other targets which do not depend on LocalCloudboardClient needs to depend on this
//    - It is undesirable for many of those to depend on LocalCloudboardClient
// - Creating a target just for this is overkill
// - We make use of the OHTTP formats to do this encoding
//
// Putting that code here is deemed reasonable
//
// So there is no confusion, this code is NOT a security/Privacy concern. This is entirely impossible to
// use in customer, during local development testing we don't care about that, just exercising almost all
// the same paths as the proper production paths where feasible.

import CryptoKit
import Foundation

/// The data available on this may change over time, the wire format backing it supports it.
/// This looks very like the `ValidatedAttestation`` type - that is because it is attempting to
/// encode all the data that can provide

/// We take complete control of what is serialized because it needs to be stable
/// We also want to retain strong backward compatibility for the last version
///
/// This enum functions as a namespace for all types involved in the serialisation.
/// Types may be used in many versions where their format is unchanged, or where the change is
/// trivially compatible (for example adding an optional field). Anything retained solely for compatibility
/// should be marked as such.
///
/// Where types are reasonable to use as both the basis for the encoding format and the API
/// they may be placed in a package extension. Where they are solely for the encoding (say to retain
/// backward compatibility keep them fileprivate
internal enum TestOnlyAttestationFormat {}

extension TestOnlyAttestationFormat {
    // Note: Version 0 is no longer supported, this was simply the PublickKey and KEM
    // We detect it to trigger a clean error

    /// Version 1 information embedded in the attestation
    struct Info: Codable {
        var expiration: Date
        var releaseDigest: String
        var computeNodeMetadata: [String: Data]?
        /// older forms used udid instead of hardwareID - we emit both and parse both
        /// to retain compatibility till the older implementations are no longer in use
        var udid: String?
        var hardwareID: String?
        var appData: TestOnlyAttestationInfo.AppData

        init(info: TestOnlyAttestationInfo) {
            self.expiration = info.expiration
            self.releaseDigest = info.releaseDigest
            self.computeNodeMetadata = info.computeNodeMetadata
            // write to both names so older versions will understand it
            self.udid = info.hardwareID
            self.hardwareID = info.hardwareID
            self.appData = info.appData
        }
    }

    /// Version 1 complete bundle
    struct Version1: Codable {
        // the public key
        var nameKeyConfiguration: Data
        // additional information
        var info: Info
    }
}

/// The data available on this may change over time.
/// This looks very like the `ValidatedAttestation`` type - that is because it is attempting to
/// encode all the data that can provide
package struct TestOnlyAttestationInfo: Sendable {
    /// The key should not be used after this date
    package var expiration: Date

    /// The SHA256 digest of the release this attestation is for
    package var releaseDigest: String

    package var computeNodeMetadata: [String: Data]?

    /// the identifier for the device that provided this attestation, equivalent to a UDID
    package var hardwareID: String?

    /// Application-specific data such as the trusted release set for proxy node attestations
    package var appData: TestOnlyAttestationInfo.AppData

    package init(
        expiration: Date,
        releaseDigest: String,
        appData: TestOnlyAttestationInfo.AppData,
        computeNodeMetadata: [String: Data],
        // This is not nillable because CloudAttestations always have a udid
        // The nillability for the property is because it comes over the wire and we must handle it
        // not being present
        hardwareID: String
    ) {
        self.expiration = expiration
        self.releaseDigest = releaseDigest
        self.appData = appData
        self.computeNodeMetadata = computeNodeMetadata
        self.hardwareID = hardwareID
    }

    fileprivate init(info: TestOnlyAttestationFormat.Info) {
        self.expiration = info.expiration
        self.releaseDigest = info.releaseDigest
        self.appData = info.appData
        self.computeNodeMetadata = info.computeNodeMetadata
        /// if both preasent hardwareID wins, fallback to udid for older version support
        self.hardwareID = info.hardwareID ?? info.udid
    }
}

/// Part of the API, and the serialization format
package extension TestOnlyAttestationInfo {
    /// Proxy specific additional information
    struct ProxyAppData: Codable, Sendable {
        /// The SHA256 digests of the releases this attestation transitively trusts
        package var transitivelyTrustedReleaseDigests: [String]

        package init(transitivelyTrustedReleaseDigests: [String]) {
            self.transitivelyTrustedReleaseDigests = transitivelyTrustedReleaseDigests
        }
    }

    /// Compute specific additional information
    struct ComputeAppData: Codable, Sendable {
        /// Metadata associated with the compute node app data
        package var metadata: [String: Data]

        package init(metadata: [String: Data]) {
            self.metadata = metadata
        }
    }

    // Application specific data contained in the attestation
    enum AppData: Codable, Sendable {
        case none
        case proxy(ProxyAppData)
        case compute(ComputeAppData)
    }
}

package enum TestOnlyAttestationError: Error {
    case invalidSectionLength(expected: Int, actual: Int, section: StaticString)
    case invalidKeyId(keyId: UInt8)
    case unsupportedKEM(kem: Data)
    case unexpected(error: StaticString)
    case jsonOutputNotValidUtf8
}

/// The InMemoryKey mode (a development tool) uses this.
/// Previously it was something which could be broken at will but other components might use it for testing
/// too so it has a requirement for some degree of backwards and forwards compatibilty.
/// Since it is relatively simple serialized JSON this is not complex to achieve.
package enum TestOnlyAttestationBundle {
    /// Format that allows for additional metadata to be included in the attestation bundle
    case version1(Curve25519.KeyAgreement.PublicKey, TestOnlyAttestationInfo)

    /// https://www.ietf.org/archive/id/draft-thomson-http-oblivious-01.html#name-key-configuration-encoding
    /// only stores the public key and the KEM (which we ignore anyway)
    private static func encodeAsNameKeyConfigurationEncoding(
        for publicKey: any HPKEDiffieHellmanPublicKey,
        kem: HPKE.KEM
    ) throws -> Data {
        var keyBytes = Data()
        keyBytes.append(0) // Key ID
        keyBytes.append(contentsOf: [0x00, 0x20]) // KEM ID
        try keyBytes.append(contentsOf: publicKey.hpkeRepresentation(kem: kem))
        keyBytes.append(contentsOf: [0x00, 0x04]) // Length of the following in bytes
        keyBytes.append(contentsOf: [0x00, 0x01]) // KDF ID
        keyBytes.append(contentsOf: [0x00, 0x01]) // AEAD ID
        return keyBytes
    }

    package static func encodeAsVersion1(
        for publicKey: any HPKEDiffieHellmanPublicKey,
        kem: HPKE.KEM,
        info: TestOnlyAttestationInfo
    ) throws -> Data {
        var result = Data()
        // sentinel value, deliberately not the same as the prior legacy format
        result.append(0x0F)
        // version number (highly unlikely to change)
        result.append(0x01)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let version1Data = try Self.encodeAsJson(for: publicKey, kem: kem, info: info)
        // Length of version1Data in network byte order as UInt32
        // if the encoded form gets bigger than UInt32.max it's fine to crash, this is testing code
        let length = UInt32(version1Data.count)
        withUnsafeBytes(of: length.bigEndian) { result.append(contentsOf: $0) }
        // The version 1 in JSON coded form
        result.append(contentsOf: version1Data)
        return result
    }

    private static func encodeAsJson(
        for publicKey: any HPKEDiffieHellmanPublicKey,
        kem: HPKE.KEM = Self.kem,
        info: TestOnlyAttestationInfo
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(
            TestOnlyAttestationFormat.Version1(
                nameKeyConfiguration: self.encodeAsNameKeyConfigurationEncoding(for: publicKey, kem: kem),
                info: TestOnlyAttestationFormat.Info(info: info)
            )
        )
    }

    // Could decode more, but we assume the HPKE.KEM
    private static func decodeNameKeyConfigurationEncoding(
        _ data: Data
    ) throws -> Curve25519.KeyAgreement.PublicKey {
        // these are always exactly 41 bytes for now
        guard data.count == 41 else {
            throw TestOnlyAttestationError.invalidSectionLength(
                expected: 41,
                actual: data.count,
                section: "NameKeyConfiguration"
            )
        }
        // Taking a copy in test code worth it to have very clear parsing
        var data = data
        // key ID (1)
        let keyId = try data.popUInt8("Key ID")
        guard keyId == 0x00 else {
            throw TestOnlyAttestationError.invalidKeyId(keyId: keyId)
        }
        // KEM ID (2)
        // Could parse out the KEM but in practice it has never changed so just check it matches
        // .Curve25519_HKDF_SHA256
        let kem = try data.popBytes(takeBytes: 2, section: "KEM ID")
        guard kem == Data([0x00, 0x20]) else {
            throw TestOnlyAttestationError.unsupportedKEM(kem: kem)
        }
        // The PublicKey is always 32 bytes for the KEM
        let rawKey = try data.popBytes(takeBytes: 32, section: "Public Key")
        let publicKey = try Curve25519.KeyAgreement.PublicKey(
            rawKey,
            kem: .Curve25519_HKDF_SHA256
        )
        // length of trailer (2)
        let footerLength = try data.popUInt16("Length of trailer")
        guard footerLength == 4 else {
            throw TestOnlyAttestationError.unexpected(error: "Expected the footer length to be 4")
        }
        // KDF ID (2) + AEAD ID (2) (not bothering to parse)
        return publicKey
    }

    /// Heuristic, returns false if definitely not, true if it might be
    package static func mightBeThisFormat(bundle data: Data) -> Bool {
        // 0   : magic byte
        // 1   : version byte
        // 2-5 : UInt32 length
        // 6   : '{' for opening JSON (It is never an array, and we always encode as UTF-8)
        if data.count >= 7, data[0] == 0x0F, data[1] == 0x01, data[6] == 0x7B {
            return true
        }
        return false
    }

    /// Infer the format from the wire form, if it's unrecognisable it returns nil,
    /// if it recognises the format but fails to parse it will throw
    public init?(data: Data) throws {
        if data.count >= 2, data[0] == 0x0F, data[1] == 0x01 {
            var data = data
            _ = try data.popUInt8("Magic Number")
            _ = try data.popUInt8("Version")
            // Length of version1Data in network byte order as UInt32
            let lengthJson = try data.popUInt32("Length")
            guard Int(lengthJson) == data.count else {
                throw TestOnlyAttestationError.invalidSectionLength(
                    expected: Int(lengthJson), actual: data.count, section: "Embedded JSON"
                )
            }
            self = try Self(jsonData: data)
        } else {
            return nil
        }
    }

    private init(jsonData data: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let version1 = try decoder.decode(TestOnlyAttestationFormat.Version1.self, from: data)
        let publicKey = try Self.decodeNameKeyConfigurationEncoding(version1.nameKeyConfiguration)
        self = .version1(publicKey, TestOnlyAttestationInfo(info: version1.info))
    }

    /// Construct an ``TestOnlyAttestationBundle`` output of ``jsonString()``
    public init(jsonString json: String) throws {
        self = try Self(jsonData: json.data(using: .utf8)!)
    }

    /// All attestations provide the public key
    public var publicKey: Curve25519.KeyAgreement.PublicKey {
        switch self {
        case .version1(let publicKey, _):
            publicKey
        }
    }

    /// All attestations provide the version as a StaticString for safe logging
    public var version: StaticString {
        switch self {
        case .version1:
            "version1"
        }
    }

    public var releaseDigest: String {
        switch self {
        case .version1(_, let info):
            info.releaseDigest
        }
    }

    public var appData: TestOnlyAttestationInfo.AppData {
        switch self {
        case .version1(_, let info):
            info.appData
        }
    }

    /// This is assumed/validated in the customer parts too
    private static let kem = HPKE.KEM.Curve25519_HKDF_SHA256

    /// This is used is LocalCloudBoardClient to make a string representation of the bundle
    /// It is not expected to be human readable but it should round trip through a constructor taking
    /// `jsonString`
    public func jsonString() throws -> String {
        switch self {
        case .version1(let key, let info):
            guard let json = try Self.encodeAsJson(for: key, info: info).utf8String else {
                throw TestOnlyAttestationError.jsonOutputNotValidUtf8
            }
            return json
        }
    }

    /// This is exposed by LocalCloudBoardClient to provide an equivalent to
    /// ``CloudAttestation/AttestationBundle/serializedData``
    /// It should round trip via ``init(data:)``
    public func serializedData() throws -> Data {
        switch self {
        case .version1(let key, let info):
            return try Self.encodeAsVersion1(
                for: key,
                // This is assumed/validated in the customer parts too
                kem: .Curve25519_HKDF_SHA256,
                info: info
            )
        }
    }
}

/// Consume network byte order values
extension Data {
    mutating func popUInt8(_ section: StaticString) throws -> UInt8 {
        guard self.count >= 1 else {
            throw TestOnlyAttestationError.invalidSectionLength(
                expected: 1, actual: self.count, section: section
            )
        }
        defer {
            self = self.dropFirst(1)
        }
        return self[self.startIndex]
    }

    mutating func popUInt16(_ section: StaticString) throws -> UInt16 {
        guard self.count >= 2 else {
            throw TestOnlyAttestationError.invalidSectionLength(
                expected: 2, actual: self.count, section: section
            )
        }

        defer {
            self = self.dropFirst(2)
        }

        return UInt16(self[self.startIndex]) << 8 | UInt16(self[self.startIndex + 1])
    }

    mutating func popUInt32(_ section: StaticString) throws -> UInt32 {
        guard self.count >= 4 else {
            throw TestOnlyAttestationError.invalidSectionLength(
                expected: 4, actual: self.count, section: section
            )
        }

        defer {
            self = self.dropFirst(4)
        }

        // swiftformat:disable all
        return UInt32(
            UInt32(self[self.startIndex])     << 24 |
            UInt32(self[self.startIndex + 1]) << 16 |
            UInt32(self[self.startIndex + 2]) <<  8 |
            UInt32(self[self.startIndex + 3])
        )
    }

    mutating func popBytes(takeBytes:Int, section: StaticString) throws -> Data {
        guard self.count >= takeBytes else {
            throw TestOnlyAttestationError.invalidSectionLength(
                expected: takeBytes, actual: self.count, section: section)
        }

        let taken = self.prefix(takeBytes)
        self = self.dropFirst(takeBytes)
        return taken
    }
    
    var hex: String {
        return reduce("") {$0 + String(format: "%02x", $1)}
    }
    
    /// Converts Data to a UTF-8 encoded String.
    internal var utf8String: String? {
        String(data: self, encoding: .utf8)
    }
    
    /// Converts Data to a String by trying utf8, and if not base64 encoding.
    fileprivate var utf8StringOrBase64: String {
        guard let s = utf8String else {
            return self.base64EncodedString()
        }
        return s
    }
}

