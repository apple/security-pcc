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

import CloudBoardDomain
import CloudBoardJobHelperAPI
import CloudBoardLogging
import CloudBoardMetrics
import CryptoKit
import Foundation
internal import ObliviousX
import os

/// This maintains the state necessary to successfully negotiate an SEP backed AEAD (possibly) bidirectional
/// stream which will enable communication with the original parent of a request via ROPES.
///
/// This (along with the OBliviousX libraries) implements those parts of the OHTTP spec detailed in RFC
/// https://datatracker.ietf.org/doc/rfc9458/) relevant to decapsulating the, then fully decrypted, inputs
/// and encapsulating the responses for the first steps of the return journey.
/// This is Chiefly sections 4.3 and 4.4 of that RFC.
/// Significant sections of this are therefore also implementing parts of HPKE from RFC
/// https://datatracker.ietf.org/doc/rfc9180/ as the innermost layer of OHTTP is based on that.
///
/// To allow the response bypass functionality some of those internal operations are exposed (in part) as a
/// means to make an unauthenticated, but encrypted, reply to the client as if it was a "normal" OHTTP reply
/// stream. But allowing the AEAD key to be known so it can be transmited (on a separate already existing
/// secure channel) thus avoiding the need for an additional Public/Private key handshake.
struct OHTTPServerStateMachine {
    public static let logger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "OHTTPServerStateMachine"
    )
    /// This is assumed throughput the system
    /// if it were to be changed there would be a cascade well beyond this type
    private static let ciphersuite = HPKE.Ciphersuite.Curve25519_SHA256_AES_GCM_128

    enum State {
        case awaitingKey([FinalizableChunk<Data>])
        case gotKeyAndNonce(key: SymmetricKey, nonce: Data, counter: UInt64)
        case gotKey(key: SymmetricKey)
        // used as an intermediate state while performing transitions
        // should never end up in this state after the receive functions return
        case modifying
    }

    /// What is known at the point the key is received
    struct HandshakeCompleteInfo {
        /// decrypted data to be sent to the cloud app
        let pendingInboundData: [FinalizableChunk<Data>]
        /// the target for sending data back
        let outboundStream: StreamingResponseProtocol
    }

    private var state: State

    var dataEncryptionKey: SymmetricKey? {
        switch self.state {
        case .gotKeyAndNonce(key: let key, nonce: _, counter: _):
            return key
        case .gotKey(key: let key):
            return key
        default:
            return nil
        }
    }

    init() {
        self.state = .awaitingKey([])
    }

    mutating func receiveChunk(_ data: Data, isFinal: Bool) throws -> Data? {
        switch self.state {
        case .awaitingKey(var chunks):
            Self.logger.info(
                "Received chunk awaiting key: chunk size \(data.count, privacy: .public) bytes, isFinal=\(isFinal, privacy: .public)"
            )
            self.state = .modifying // avoid CoW
            chunks.append(.init(chunk: data, isFinal: isFinal))
            self.state = .awaitingKey(chunks)
            return nil
        case .gotKeyAndNonce(let key, let nonce, let counter):
            Self.logger.info(
                "Received chunk, chunk size \(data.count, privacy: .public) bytes, decrypting with counter \(counter, privacy: .public), isFinal=\(isFinal, privacy: .public)"
            )
            let result = try AES.GCM.open(
                AES.GCM.SealedBox(rawNonce: nonce, counter: counter, ciphertextAndTag: data),
                using: key,
                authenticating: isFinal ? Data("final".utf8) : Data()
            )
            self.state = .gotKeyAndNonce(key: key, nonce: nonce, counter: counter + 1)
            return result
        case .gotKey(let key):
            Self.logger.info(
                "Received chunk, awaiting nonce, chunk size \(data.count, privacy: .public) bytes, isFinal=\(isFinal, privacy: .public)"
            )
            var data = data

            let aead = try data.popAEAD()
            guard aead == 0x0001 else {
                throw ReportableJobHelperError(wrappedError: OHTTPError.invalidAEAD, reason: .invalidAEAD)
            }

            let nonce = data.prefix(defaultGCMNonceByteCount)
            let counter = UInt64(0)

            let result = try AES.GCM.open(
                AES.GCM.SealedBox(combined: data),
                using: key,
                authenticating: isFinal ? Data("final".utf8) : Data()
            )
            self.state = .gotKeyAndNonce(key: key, nonce: nonce, counter: counter + 1)
            return result
        case .modifying:
            preconditionFailure("receiveChunk called when in modifying state.")
        }
    }

    mutating func receiveKey(
        _ ohttpProtectedKey: Data,
        privateKey: any HPKEDiffieHellmanPrivateKey,
        responseBypassMode: ResponseBypassMode
    ) throws -> HandshakeCompleteInfo {
        switch self.state {
        case .awaitingKey(let chunks):
            var chunkSlice = chunks[...]
            guard let (requestHeader, consumed) = OHTTPEncapsulation
                .parseRequestHeader(encapsulatedRequest: ohttpProtectedKey) else {
                throw ReportableJobHelperError(
                    wrappedError: OHTTPError.unableToParseEncapsulatedRequest,
                    reason: .ohttpEncapsulationFailure
                )
            }

            let recipient: HPKE.Recipient
            let key: SymmetricKey
            do {
                // The SEP is only used at one point here, at the point the call to decapsulator construction via
                // `PrivateKey.sharedSecretFromKeyAgreement`, however that call being in the constructor of the
                // Recipient, or the first call to decapsulate is an implementation detail.
                // Since the subsequent use of the symetric key that is created is trivial compared to the SEP call
                // we just include the entire setup as being costed to that.
                (recipient, key) = try cbSignposter.withIntervalSignpost("CB.sep.unwrap") {
                    var decapsulator = try OHTTPEncapsulation.StreamingRequestDecapsulator(
                        requestHeader: requestHeader,
                        mediaType: requestContentType,
                        privateKey: privateKey
                    )
                    let keyBytes = try decapsulator.decapsulate(
                        content: ohttpProtectedKey.dropFirst(consumed),
                        final: true
                    )
                    let recipient = decapsulator.recipient
                    let key = SymmetricKey(data: keyBytes)
                    return (recipient, key)
                }
            } catch {
                throw ReportableJobHelperError(wrappedError: error, reason: .ohttpDecapsulationFailure)
            }

            var decryptedChunks = [FinalizableChunk<Data>]()
            decryptedChunks.reserveCapacity(chunkSlice.count)
            if let first = chunkSlice.popFirst() {
                var data = first.chunk
                let aead = try data.popAEAD()
                guard aead == 0x0001 else {
                    throw ReportableJobHelperError(wrappedError: OHTTPError.invalidAEAD, reason: .invalidAEAD)
                }

                let nonce = data.prefix(defaultGCMNonceByteCount)
                var counter = UInt64(0)

                let decryptedChunk = try AES.GCM.open(
                    AES.GCM.SealedBox(combined: data),
                    using: key,
                    authenticating: first.isFinal ? Data("final".utf8) : Data()
                )
                counter += 1
                decryptedChunks.append(.init(chunk: decryptedChunk, isFinal: first.isFinal))

                for chunk in chunkSlice {
                    let decryptedChunk = try AES.GCM.open(
                        AES.GCM.SealedBox(rawNonce: nonce, counter: counter, ciphertextAndTag: chunk.chunk),
                        using: key,
                        authenticating: chunk.isFinal ? Data("final".utf8) : Data()
                    )
                    counter += 1
                    decryptedChunks.append(.init(chunk: decryptedChunk, isFinal: chunk.isFinal))
                }

                self.state = .gotKeyAndNonce(key: key, nonce: nonce, counter: counter)
            } else {
                self.state = .gotKey(key: key)
            }
            let outboundStream: StreamingResponseProtocol =
                switch responseBypassMode {
                case .none:
                    try OHTTPEncapsulation.StreamingResponse(
                        // This would be either the client or the proxy depending on who initiated
                        // the request
                        context: recipient,
                        encapsulatedKey: requestHeader.encapsulatedKey,
                        mediaType: responseContentType,
                        ciphersuite: Self.ciphersuite
                    )
                case .matchRequestCiphersuiteSharedAeadState:
                    /// This is used in the *worker* sending the response.
                    /// This does a constrained subset of what ``OHTTPEncapsulation.StreamingResponse`` would
                    /// have done if the original request appeared to come from the proxy, but in a manner
                    /// where the client has been provided by another channel the expected AEAD key and AEAD
                    /// nonce which will match with the internal state of the result of this call
                    try ForcedStateStreamingResponse(
                        // this should always be the proxy, but in a manner where it exposes (securely)
                        // the necessary key and nonce that anyone else with that can decrypt it
                        context: recipient,
                        encapsulatedKey: requestHeader.encapsulatedKey,
                        mediaType: responseContentType,
                        ciphersuite: Self.ciphersuite
                    )
                }

            return HandshakeCompleteInfo(
                pendingInboundData: decryptedChunks,
                outboundStream: outboundStream
            )
        case .gotKey, .gotKeyAndNonce:
            throw OHTTPError.receivedKeyTwice
        case .modifying:
            preconditionFailure("receiveKey called when in modifying state.")
        }
    }
}

private let defaultGCMNonceByteCount = 12
private let requestContentType = "application/protobuf chunked request"
private let responseContentType = "application/protobuf chunked response"

extension AES.GCM.SealedBox {
    fileprivate init(rawNonce: Data, counter: UInt64, ciphertextAndTag: Data) throws {
        var combined = Data(capacity: rawNonce.count + ciphertextAndTag.count)
        combined.append(rawNonce)
        combined.xorLast8Bytes(with: counter)
        combined.append(ciphertextAndTag)
        self = try .init(combined: combined)
    }
}

extension Data {
    fileprivate mutating func popAEAD() throws -> UInt16 {
        guard self.count >= 2 else {
            throw OHTTPError.insufficientBytesForAEAD
        }

        defer {
            self = self.dropFirst(2)
        }

        return UInt16(self[self.startIndex]) << 8 | UInt16(self[self.startIndex + 1])
    }

    private mutating func popNonce() throws -> Data {
        guard self.count >= defaultGCMNonceByteCount else {
            throw OHTTPError.invalidNonceSize
        }

        let nonce = self.prefix(defaultGCMNonceByteCount)
        self = self.dropFirst(defaultGCMNonceByteCount)
        return nonce
    }

    fileprivate mutating func xorLast8Bytes(with value: UInt64) {
        // We handle value in network byte order.
        precondition(self.count >= 8)

        var index = self.endIndex
        for byteNumber in 0 ..< 8 {
            // Unchecked math in here is all sound, byteNumber is between 0 and 7 and index is
            // always positive.
            let byte = UInt8(truncatingIfNeeded: value >> (byteNumber &* 8))
            index &-= 1
            self[index] ^= byte
        }
    }
}

enum OHTTPError: ReportableError, Equatable {
    case unableToParseEncapsulatedRequest
    case receivedKeyTwice
    case invalidNonceSize
    case insufficientBytesForAEAD
    case invalidAEAD
    case invalidWorkload(String)

    var publicDescription: String {
        let errorType = switch self {
        case .unableToParseEncapsulatedRequest: "unableToParseEncapsulatedRequest"
        case .receivedKeyTwice: "receivedKeyTwice"
        case .invalidNonceSize: "invalidNonceSize"
        case .insufficientBytesForAEAD: "insufficientBytesForAEAD"
        case .invalidAEAD: "invalidAEAD"
        case .invalidWorkload: "invalidWorkload"
        }
        return "ohttp.\(errorType)"
    }
}

extension HPKE.Ciphersuite {
    static var Curve25519_SHA256_AES_GCM_128: HPKE.Ciphersuite {
        .init(kem: .Curve25519_HKDF_SHA256, kdf: .HKDF_SHA256, aead: .AES_GCM_128)
    }
}
