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

import Foundation
@_spi(HPKEAlgID) import CryptoKit
internal import ObliviousX

/// Anything provided with this can decrypt the response stream from a worker
/// if it was made in response bypass mode
/// Treat it a critical to security, only to be passed to the client over a SEP backed HPKE
/// protected channel
public struct ResponseBypassCapability: Sendable {
    public var aead: HPKE.AEAD
    public var aeadKey: SymmetricKey
    public var aeadNonce: Data
}

// This is based on ObliviousX: OHTTPEncapsulation.StreamingResponseDecapsulator
// Then altered to:
// * allow specifying the AEAD key and nonce values in advance
// * implement OHTTPStreamingResponseDecapsulatorProtocol
public struct StreamingResponseBypassDecapsulator: OHTTPStreamingResponseDecapsulatorProtocol {
    public mutating func decapsulateResponseMessage(_ message: Data, isFinal: Bool) throws -> Data {
        // Force unwrap detects mismanaged message boundaries.
        return try self.decapsulate(message, final: isFinal)!
    }

    private let aead: HPKE.AEAD
    private let aeadKey: SymmetricKey
    // mutable to allow an efficient xor with counter operation without additional memory
    private var aeadNonce: Data
    private var nextCounter: UInt64 = 0
    // this state still exists because the wire protocol remains the same
    private var awaitingResponseNonce: Bool = true

    public init(
        aead: HPKE.AEAD,
        aeadKey: SymmetricKey,
        aeadNonce: Data,
    ) throws {
        self.aead = aead
        if aeadKey.bitCount != aead.keyByteCount * 8 {
            throw CryptoKitError.incorrectKeySize
        }
        self.aeadKey = aeadKey
        self.aeadNonce = aeadNonce
        if aeadNonce.count != aead.nonceByteCount {
            throw CryptoKitError.incorrectParameterSize
        }
    }

    public mutating func decapsulate(
        _ message: Data,
        final: Bool,
        expectEncapsulationWrapper _: Bool = false
    ) throws -> Data? {
        let counter = self.nextCounter
        self.nextCounter = counter + 1
        let ciphertext: Data.SubSequence
        if self.awaitingResponseNonce {
            var payload = message[...]
            let nonceLength = max(self.aead.keyByteCount, self.aead.nonceByteCount)
            guard let responseNonce = payload.popFirst(nonceLength) else {
                throw CryptoKitError.incorrectParameterSize
            }
            // We validate the response nonce so we fail fast and also disallow
            // the mutation of any part of the message even if not strictly needed
            try Self.validateAedHandshakeResponseNonce(
                self.aead, responseNonce: responseNonce
            )
            self.awaitingResponseNonce = false
            ciphertext = payload
        } else {
            ciphertext = message[...]
        }
        // We temporarily mutate the AEAD nonce. To avoid intermediate allocations, we mutate in place and
        // return it back by xoring again.
        self.aeadNonce.xor(with: counter)
        defer {
            self.aeadNonce.xor(with: counter)
        }
        return try self.aead.open(
            ciphertext,
            nonce: self.aeadNonce,
            authenticating: final ? finalAAD : Data(),
            using: self.aeadKey
        )
    }

    /// This is *deliberately* duplicated from ForcedStateStreamingResponse as this code represents
    /// The implementation on the client side which cannot be easily changed
    /// See the comments on AedHandshakeResponseNonce for the rationale
    private static func validateAedHandshakeResponseNonce(
        _ aead: HPKE.AEAD,
        responseNonce: Data
    ) throws {
        let expected = self.makeAedHandshakeResponseNonce(aead)
        if responseNonce != expected {
            throw CryptoKitError.incorrectParameterSize
        }
    }

    /// This *must* function exactly the same on the proxy and the compute nodes
    /// This is a duplicate of the code in ForcedStateStreamingResponse
    /// A refactor of the dependency hierachy might be desirable to avoid that
    private static func makeAedHandshakeResponseNonce(_ aead: HPKE.AEAD) -> Data {
        let nonceLength = max(aead.keyByteCount, aead.nonceByteCount)
        var responseNonce = Data(repeating: 0, count: nonceLength)
        responseNonce[nonceLength - 1] = 0x01
        return responseNonce
    }

    /// Pre-generate the AEAD key and (initial) AEAD nonce assuming a statically known responseNonce
    static func pregenerateAeadKeyAndNonce<EncapsulatedKey: RandomAccessCollection>(
        context: HPKE.Sender,
        encapsulatedKey: EncapsulatedKey,
        mediaType: String,
        ciphersuite: HPKE.Ciphersuite
    ) throws -> ResponseBypassCapability where EncapsulatedKey.Element == UInt8 {
        let secret = try context.exportSecret(
            context: Array(mediaType.utf8),
            outputByteCount: ciphersuite.aead.keyByteCount
        )
        let responseNonce = self.makeAedHandshakeResponseNonce(ciphersuite.aead)

        var salt = Data(encapsulatedKey)
        salt.append(contentsOf: responseNonce)

        let prk = ciphersuite.kdf.extract(salt: salt, ikm: secret)
        let aeadKey = ciphersuite.kdf.expand(
            prk: prk,
            info: Data("key".utf8),
            outputByteCount: ciphersuite.aead.keyByteCount
        )
        let aeadNonce = Data(ciphersuite.kdf.expand(
            prk: prk,
            info: Data("nonce".utf8),
            outputByteCount: ciphersuite.aead.nonceByteCount
        ))
        return .init(aead: ciphersuite.aead, aeadKey: aeadKey, aeadNonce: aeadNonce)
    }
}

@available(*, unavailable)
extension StreamingResponseBypassDecapsulator: Sendable {}

// MARK: - lifted directly from ObliviousX where not exposed. entirely unmodified except to make fileprivate

extension RandomAccessCollection where Element == UInt8, Self == Self.SubSequence {
    fileprivate mutating func popFirst(_ n: Int) -> Self? {
        guard self.count >= n else {
            return nil
        }

        let rvalue = self.prefix(n)
        self = self.dropFirst(n)
        return rvalue
    }
}

extension Data {
    fileprivate init(_ key: SymmetricKey) {
        self = key.withUnsafeBytes { Data($0) }
    }

    fileprivate mutating func xor(with value: UInt64) {
        // We handle value in network byte order.
        precondition(self.count >= 8)

        var index = self.endIndex
        for byteNumber in 0 ..< 8 {
            // Unchecked math in here is all sound, byteNumber is between 0 and 8 and index is
            // always positive.
            let byte = UInt8(truncatingIfNeeded: value >> (byteNumber &* 8))
            index &-= 1
            self[index] ^= byte
        }
    }
}

extension HPKE.AEAD {
    fileprivate var keyByteCount: Int {
        switch self {
        case .AES_GCM_128:
            return 16
        case .AES_GCM_256:
            return 32
        case .chaChaPoly:
            return 32
        case .exportOnly:
            fatalError("ExportOnly should not return a key size.")
        @unknown default:
            fatalError("no handling for \(self.value)")
        }
    }

    fileprivate var nonceByteCount: Int {
        switch self {
        case .AES_GCM_128, .AES_GCM_256, .chaChaPoly:
            return 12
        case .exportOnly:
            fatalError("ExportOnly should not return a nonce size.")
        @unknown default:
            fatalError("no handling for \(self.value)")
        }
    }

    fileprivate func open(
        _ ct: some DataProtocol,
        nonce: Data,
        authenticating aad: some DataProtocol,
        using key: SymmetricKey
    ) throws -> Data {
        guard ct.count >= self.tagByteCount else {
            throw HPKE.Errors.expectedPSK
        }

        switch self {
        case .AES_GCM_128, .AES_GCM_256: do {
                let nonce = try AES.GCM.Nonce(data: nonce)
                let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ct.dropLast(16), tag: ct.suffix(16))
                return try AES.GCM.open(sealedBox, using: key, authenticating: aad)
            }
        case .chaChaPoly: do {
                let nonce = try ChaChaPoly.Nonce(data: nonce)
                let sealedBox = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ct.dropLast(16), tag: ct.suffix(16))
                return try ChaChaPoly.open(sealedBox, using: key, authenticating: aad)
            }
        case .exportOnly:
            throw HPKE.Errors.exportOnlyMode
        @unknown default:
            fatalError("no handling for \(self.value)")
        }
    }
}

extension HPKE.KDF {
    fileprivate func extract(salt: some DataProtocol, ikm: SymmetricKey) -> SymmetricKey {
        switch self {
        case .HKDF_SHA256:
            return SymmetricKey(data: HKDF<SHA256>.extract(inputKeyMaterial: ikm, salt: salt))
        case .HKDF_SHA384:
            return SymmetricKey(data: HKDF<SHA384>.extract(inputKeyMaterial: ikm, salt: salt))
        case .HKDF_SHA512:
            return SymmetricKey(data: HKDF<SHA512>.extract(inputKeyMaterial: ikm, salt: salt))
        @unknown default:
            fatalError("\(self) not handled")
        }
    }

    fileprivate func expand(prk: SymmetricKey, info: Data, outputByteCount: Int) -> SymmetricKey {
        switch self {
        case .HKDF_SHA256:
            return SymmetricKey(data: HKDF<SHA256>.expand(
                pseudoRandomKey: prk,
                info: info,
                outputByteCount: outputByteCount
            ))
        case .HKDF_SHA384:
            return SymmetricKey(data: HKDF<SHA384>.expand(
                pseudoRandomKey: prk,
                info: info,
                outputByteCount: outputByteCount
            ))
        case .HKDF_SHA512:
            return SymmetricKey(data: HKDF<SHA512>.expand(
                pseudoRandomKey: prk,
                info: info,
                outputByteCount: outputByteCount
            ))
        @unknown default:
            fatalError("\(self) not handled")
        }
    }
}

private let finalAAD = Data("final".utf8)
