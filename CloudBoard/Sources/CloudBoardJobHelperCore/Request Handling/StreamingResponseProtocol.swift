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

import Crypto
import Foundation
internal import ObliviousX

/// This is a generalisation of the ``OHTTPEncapsulation.StreamingResponse``
/// To allow response bypass to work more easily
internal protocol StreamingResponseProtocol {
    mutating func encapsulate<Message: DataProtocol>(_ message: Message, final: Bool) throws -> Data
}

extension OHTTPEncapsulation.StreamingResponse: StreamingResponseProtocol {
    mutating func encapsulate(_ message: some DataProtocol, final: Bool) throws -> Data {
        try self.encapsulate(message, final: final, includeEncapsulationWrapper: false)
    }
}

// MARK: - lifted straight from ObliviousX due to being internal

// made fileprivate if not already

extension Data {
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
            fatalError("\(self) not handled")
        }
    }

    fileprivate var nonceByteCount: Int {
        switch self {
        case .AES_GCM_128, .AES_GCM_256, .chaChaPoly:
            return 12
        case .exportOnly:
            fatalError("ExportOnly should not return a nonce size.")
        @unknown default:
            fatalError("\(self) not handled")
        }
    }

    fileprivate func seal(
        _ message: some DataProtocol,
        authenticating aad: some DataProtocol,
        nonce: Data,
        using key: SymmetricKey
    ) throws -> Data {
        switch self {
        case .chaChaPoly:
            return try ChaChaPoly.seal(message, using: key, nonce: ChaChaPoly.Nonce(data: nonce), authenticating: aad)
                .combined.suffix(from: nonce.count)
        default:
            return try AES.GCM.seal(message, using: key, nonce: AES.GCM.Nonce(data: nonce), authenticating: aad)
                .combined!.suffix(from: nonce.count)
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

extension UnsafeMutableRawBufferPointer {
    private func initializeWithRandomBytes(count: Int) {
        guard count > 0 else {
            return
        }

        precondition(count <= self.count)
        var rng = SystemRandomNumberGenerator()

        // We store bytes 64-bits at a time until we can't anymore.
        var targetPtr = self
        while targetPtr.count > 8 {
            targetPtr.storeBytes(of: rng.next(), as: UInt64.self)
            targetPtr = UnsafeMutableRawBufferPointer(rebasing: targetPtr[8...])
        }

        // Now we're down to having to store things an integer at a time. We do this by shifting and
        // masking.
        var remainingWord: UInt64 = rng.next()
        while targetPtr.count > 0 {
            targetPtr.storeBytes(of: UInt8(remainingWord & 0xFF), as: UInt8.self)
            remainingWord >>= 8
            targetPtr = UnsafeMutableRawBufferPointer(rebasing: targetPtr[1...])
        }
    }
}

extension Data {
    fileprivate init(_ key: SymmetricKey) {
        self = key.withUnsafeBytes { Data($0) }
    }
}

private let finalAAD = Data("final".utf8)

// MARK: - Adapted from ObliviousX OHHTPEncapsulation.StreamingResponse but not identical

// all terminology and variable names match with the original

/// ``StreamingResponse`` but allowing the responseNone to be predefined
struct ForcedStateStreamingResponse: StreamingResponseProtocol {
    /// This *must* function exactly the same on the proxy and the compute nodes
    /// This provides a legal `responce_nonce` (see https://datatracker.ietf.org/doc/rfc9458/)
    /// The semantics of this nonce are that is will be used once and only once with the specific ikm
    /// for the proxy response bypass. It does not have to supply entropy, just be single use.
    /// That this is used once and only once should be enforced elsewhere
    private static func makeAedHandshakeResponseNonce(_ aead: HPKE.AEAD) -> Data {
        let nonceLength = max(aead.keyByteCount, aead.nonceByteCount)
        var responseNonce = Data(repeating: 0, count: nonceLength)
        responseNonce[nonceLength - 1] = 0x01
        return responseNonce
    }

    private let responseNonce: Data
    private var aeadNonce: Data
    private let aeadKey: SymmetricKey
    private let aead: HPKE.AEAD
    private var counter: UInt64

    public init<EncapsulatedKey: RandomAccessCollection>(
        context: HPKE.Recipient,
        encapsulatedKey: EncapsulatedKey,
        mediaType: String,
        ciphersuite: HPKE.Ciphersuite
    ) throws where EncapsulatedKey.Element == UInt8 {
        let secret = try context.exportSecret(
            context: Array(mediaType.utf8),
            outputByteCount: ciphersuite.aead.keyByteCount
        )
        self.responseNonce = Self.makeAedHandshakeResponseNonce(ciphersuite.aead)

        var salt = Data(encapsulatedKey)
        salt.append(contentsOf: self.responseNonce)

        let prk = ciphersuite.kdf.extract(salt: salt, ikm: secret)
        self.aeadKey = ciphersuite.kdf.expand(
            prk: prk,
            info: Data("key".utf8),
            outputByteCount: ciphersuite.aead.keyByteCount
        )
        self.aeadNonce = Data(ciphersuite.kdf.expand(
            prk: prk,
            info: Data("nonce".utf8),
            outputByteCount: ciphersuite.aead.nonceByteCount
        ))
        self.aead = ciphersuite.aead
        self.counter = 0
    }

    public mutating func encapsulate(_ message: some DataProtocol, final: Bool) throws -> Data {
        // We temporarily mutate the AEAD nonce. To avoid intermediate allocations, we mutate in place and
        // return it back by xoring again.
        let counter = self.counter
        self.aeadNonce.xor(with: counter)
        defer {
            self.aeadNonce.xor(with: counter)
        }

        let ct = try self.aead.seal(
            message,
            authenticating: final ? finalAAD : Data(),
            nonce: self.aeadNonce,
            using: self.aeadKey
        )

        // This defer is here to avoid us doing it if we throw above.
        defer {
            self.counter += 1
        }

        if counter == 0 {
            // Note that the consumer will know this, but we keep the wire protocol the same as normal
            return self.responseNonce + ct
        } else {
            return ct
        }
    }
}
