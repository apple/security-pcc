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
//  SEP+SealedHash.swift
//  CloudAttestation
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

import CryptoKit
@preconcurrency import AppleKeyStore

extension SEP {

    /// A virtual SEP SealedHash object
    ///
    /// Virtual Sealed Hash objects are useful for replaying a ledger of hashes ratcheted into a real SEP Software Sealed Hash
    public struct SealedHash: Equatable, Sendable {
        /// The flags of the Sealed Hash.
        public private(set) var flags: Flags

        /// The hash value of the Sealed Hash.
        public private(set) var value: Value

        /// The digest of the Sealed Hash as ``Data``.
        public var data: Data {
            value.data
        }

        /// Creates a ``SealedHash`` from a sequence of byte-sequence-like objects.
        public init<Outer, Inner>(ratchet elements: Outer) throws where Outer: Sequence, Inner: Sequence, Outer.Element == Inner, Inner.Element == UInt8 {
            self.flags = [.ratchet]
            self.value = .ratchet(hash: SHA384())

            var empty = true
            for e in elements {
                empty = false
                try self.ratchet(digest: Data(e))
            }
            guard !empty else {
                throw Error.emptySequence
            }
        }

        /// Creates a ``SealedHash`` from an entry.
        /// - Parameter entry: The entry to use to initialize the ``SealedHash``.
        public init(entry: Entry) throws {
            self = try .init(digest: entry.digest, flags: entry.flags)
        }

        /// Creates a ``SealedHash`` from a sequence of entries.
        /// - Parameter entries: The entries to use to initialize the ``SealedHash``.
        public init(entries: some Sequence<Entry>) throws {
            self = try .init(ratchet: entries.map { $0.digest })
            self.flags = entries.reduce(
                [],
                {
                    $0.union($1.flags)
                }
            )
        }

        /// Creates a ``SealedHash`` from a ``Data`` digest and flags.
        /// - Parameters:
        ///   - digest: The digest to use to initialize the ``SealedHash``.
        ///   - flags: The flags to use.
        public init(digest: Data, flags: Flags) throws {
            guard digest.count <= SHA384Digest.byteCount else {
                throw Error.invalidDigestLength
            }

            self.flags = flags

            let ratchet = flags.contains(.ratchet)

            if ratchet {
                var hash = SHA384()
                hash.update(data: digest)
                self.value = .ratchet(hash: hash)
            } else {
                self.value = .single(value: digest)
            }
        }

        /// Initializes a SealedHash from the captured values of an existing one.
        public init(from value: Data, flags: Flags) {
            self.value = .readOnly(value: value)
            self.flags = flags
        }

        /// Performs a ratchet update on the ``SealedHash``.
        /// - Parameters:
        ///   - digest: The digest to use to perform the ratchet update.
        ///   - flags: The flags to use.
        public mutating func ratchet(digest: Data, flags: Flags = .none) throws {
            guard digest.count <= SHA384Digest.byteCount else {
                throw Error.invalidDigestLength
            }

            guard self.flags.contains(.ratchet), !self.flags.contains(.ratchetLocked), case .ratchet(var hashFunc) = self.value else {
                throw Error.readOnly
            }

            if flags.contains(.ratchetLocked) {
                self.flags.insert(.ratchetLocked)
            }

            hashFunc.update(data: digest)
            self.value = .ratchet(hash: hashFunc)
        }

        /// A flag set that indicates the type of the ``SealedHash``.
        public struct Flags: OptionSet, Sendable {
            public let rawValue: UInt8

            public init(rawValue: UInt8) {
                self.rawValue = rawValue
            }

            public init(rawValue: Int32) {
                self = .init(rawValue: UInt8(rawValue & 0xFF))
            }

            public static let none = Flags([])
            public static let ratchet = Flags(rawValue: UInt8(sealed_hash_flag_rachet))
            public static let ratchetLocked = Flags(rawValue: UInt8(sealed_hash_flag_rachet_locked))
            public static let cryptexMeasurement = Flags(rawValue: UInt8(sealed_hash_flag_cryptex_measurement))
        }

        /// A representation of the data a SealedHash register has, depending on if it is in ratcheting mode or not.
        public enum Value: Sendable, Equatable, CustomStringConvertible {
            public var description: String { self.data.hexString }

            public static func == (lhs: SEP.SealedHash.Value, rhs: SEP.SealedHash.Value) -> Bool {
                return lhs.data == rhs.data
            }

            init(data: some Sequence<UInt8>) {
                self = .readOnly(value: .init(data))
            }

            case ratchet(hash: SHA384)
            case single(value: Data)
            case readOnly(value: Data)

            var data: Data {
                switch self {
                case .ratchet(let hash):
                    Data(hash.finalize())
                case .single(let value):
                    value
                case .readOnly(let value):
                    value
                }
            }
        }
    }
}

extension SEP.SealedHash {
    /// A single entry that was ratcheted SealedHash register.
    public struct Entry: Sendable {
        /// The digest of the entry.
        public let digest: Data
        /// The data of the entry.
        public let data: Data?
        /// The flags assosciated with the entry when it was ratcheted.
        public var flags: Flags
        /// The algorithm used to generate the digest.
        public let algorithm: any HashFunction.Type
        /// Arbitrary metadata that is not sealed
        public var metadata: [String: Data]? = nil
        /// The type of entry.
        public var type: String? = nil

        init(digest: Data, data: Data?, flags: Flags, algorithm: any HashFunction.Type) {
            self.digest = digest
            self.data = data
            self.flags = flags
            self.algorithm = algorithm
        }

        /// Creates a new entry.
        /// - Parameters:
        ///   - data: The data to seal.
        ///   - flags: The flags assosciated with the entry when it was ratcheted.
        ///   - algorithm: The algorithm used to generate the digest.
        @_disfavoredOverload
        public init(data: Data, flags: Flags, algorithm: (some HashFunction).Type = SHA384.self) {
            self.digest = Data(algorithm.hash(data: data))
            self.data = data
            self.flags = flags
            self.algorithm = algorithm
        }

        /// Creates a new entry.
        /// - Parameters:
        ///   - data: The data to seal.
        ///   - flags: The flags assosciated with the entry when it was ratcheted.
        ///   - algorithm: The algorithm used to generate the digest.
        ///   - metadata: The arbitrary metadata that is not sealed...
        ///   - type: The type of entry.
        public init(data: Data, flags: Flags, algorithm: (some HashFunction).Type = SHA384.self, metadata: [String: Data]? = nil, type: String? = nil) {
            self.digest = Data(algorithm.hash(data: data))
            self.data = data
            self.flags = flags
            self.algorithm = algorithm
            self.metadata = metadata
            self.type = type
        }

        /// Creates a new entry.
        /// - Parameters:
        ///   - digest: The digest to seal.
        ///   - flags: The flags assosciated with the entry when it was ratcheted.
        ///   - algorithm: The algorithm used to generate the digest.
        @_disfavoredOverload
        public init<Hash: HashFunction>(digest: Hash.Digest, flags: Flags, algorithm: Hash.Type = SHA384.self) {
            self.digest = Data(digest)
            self.data = nil
            self.flags = flags
            self.algorithm = algorithm
        }

        /// Creates a new entry.
        /// - Parameters:
        ///   - digest: The digest to seal.
        ///   - flags: The flags assosciated with the entry when it was ratcheted.
        ///   - algorithm: The algorithm used to generate the digest.
        @_disfavoredOverload
        public init(digest: Data, flags: Flags, algorithm: (some HashFunction).Type = SHA384.self) {
            self.digest = digest
            self.data = nil
            self.flags = flags
            self.algorithm = algorithm
        }

        /// Creates a new entry.
        /// - Parameters:
        ///   - data: The digeset to seal.
        ///   - flags: The flags assosciated with the entry when it was ratcheted.
        ///   - algorithm: The algorithm used to generate the digest.
        ///   - metadata: The arbitrary metadata that is not sealed...
        ///   - type: The type of entry.
        public init(digest: Data, flags: Flags, algorithm: (some HashFunction).Type = SHA384.self, metadata: [String: Data]? = nil, type: String? = nil) {
            self.digest = digest
            self.data = nil
            self.flags = flags
            self.algorithm = algorithm
            self.metadata = metadata
            self.type = type
        }
    }
}

// MARK: - Error API

extension SEP.SealedHash {
    public enum Error: Swift.Error, Equatable {
        case readOnly
        case invalidDigestLength
        case emptySequence
        case keystoreError(kern_return_t)
    }
}
