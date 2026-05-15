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
//  SEP+Attestation.swift
//  CloudAttestation
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

import os.log
import AppleKeyStore
import AppleKeyStore.aks_attestation_verify

/// Umbrella namespace for Secure Enclave Processor structures.
extension SEP {

    private static let kAKSReturnSuccess = 0

    /// An attestation structure from the SEP
    public struct Attestation: Sendable {
        static let logger = Logger(subsystem: "com.apple.CloudAttestation", category: "SEP.Attestation")

        public let data: Data
        private let contextData: Data

        @_spi(Private)
        public init(from blob: Data) throws {
            var contextData = Data(repeating: 0, count: aks_attest_context_size)
            let initResult = contextData.withUnsafeMutableBytes { (contextPtr: UnsafeMutableRawBufferPointer) in
                let context = aks_attest_context_t(contextPtr.baseAddress!)
                return blob.withUnsafeBytes { blobPtr in
                    aks_attest_context_init(blobPtr.baseAddress!, blobPtr.count, context)
                }
            }
            guard initResult == kAKSReturnSuccess else {
                throw Error.invalidBlob
            }
            self.data = blob
            self.contextData = contextData
        }

        /// Creates a new attestation structure without validating it against a public key.
        /// - Parameter blob: The blob to use for the attestation.
        public init(from blob: some DataProtocol) throws {
            self = try .init(from: Data(blob))
        }

        /// Creates a new attestation structure that is validated against a public key.
        /// - Parameters:
        ///   - blob: The blob to use for the attestation.
        ///   - signer: The signer to use for the attestation.
        public init(from blob: Data, signer: SecKey) throws {
            try self.init(from: blob)

            var err: Unmanaged<CFError>!
            guard let keyPub = SecKeyCopyExternalRepresentation(signer, &err) as Data? else {
                throw err.takeRetainedValue()
            }

            try keyPub.withUnsafeBytes { ptr in
                try self.withContext { context in
                    let result = aks_attest_context_verify(context, ptr.baseAddress!, ptr.count)
                    guard result == kAKSReturnSuccess else {
                        throw Error.invalidSignature
                    }
                }
            }
        }

        /// Creates a new attestation structure that is validated against a public key.
        /// - Parameters:
        ///   - blob: The blob to use for the attestation.
        ///   - signer: The signer to use for the attestation.
        public init(from blob: some DataProtocol, signer: SecKey) throws {
            self = try .init(from: Data(blob), signer: signer)
        }

        func withContext<ResultType>(_ body: (aks_attest_context_t) throws -> ResultType) rethrows -> ResultType {
            return try self.contextData.withUnsafeBytes { (contextPtr: UnsafeRawBufferPointer) in
                let context = aks_attest_context_t(contextPtr.baseAddress!)
                return try body(context)
            }
        }

        /// Returns the sealed hash for the given slot.
        /// - Parameter slot: The slot to get the sealed hash for.
        public func sealedHash(at slot: UUID) -> SealedHash? {
            var sealedHash = aks_sealed_hash_value_t()
            return self.withContext { context in
                var uuid = slot.uuid
                guard kAKSReturnSuccess == aks_attest_context_get_sealed_hash(context, &uuid, &sealedHash) else {
                    return nil
                }
                let hashData = withUnsafeBytes(of: sealedHash.digest) { buf in
                    Data(bytes: buf.baseAddress!, count: Int(sealedHash.digest_len))
                }
                let flags = sealedHash.flags

                return SealedHash(from: hashData, flags: .init(rawValue: flags))
            }
        }

        /// The seal data for the given slot.
        public var sealData: SealData? {
            var bufPtr: UnsafePointer<UInt8>!
            var len: Int = 0

            return self.withContext { context in
                guard kAKSReturnSuccess == aks_attest_context_get(context, aks_attest_param_pka_seal_data, &bufPtr, &len), bufPtr != nil else {
                    return nil
                }

                let payload = Data(bytes: bufPtr, count: len)
                return SEP.SealData(for: self.identity, data: payload)
            }
        }

        /// The seal data for the given slot.
        public var sealDataA: SealData? {
            var bufPtr: UnsafePointer<UInt8>!
            var len: Int = 0

            return self.withContext { context in
                guard kAKSReturnSuccess == aks_attest_context_get(context, aks_attest_param_seal_data_a, &bufPtr, &len), bufPtr != nil else {
                    return nil
                }

                let payload = Data(bytes: bufPtr, count: len)
                return SEP.SealData(for: self.identity, data: payload)
            }
        }

        /// The seal data for the given slot.
        public var sealDataB: SealData? {
            var bufPtr: UnsafePointer<UInt8>!
            var len: Int = 0

            return self.withContext { context in
                guard kAKSReturnSuccess == aks_attest_context_get(context, aks_attest_param_seal_data_b, &bufPtr, &len), bufPtr != nil else {
                    return nil
                }

                let payload = Data(bytes: bufPtr, count: len)
                return SEP.SealData(for: self.identity, data: payload)
            }
        }

        /// The identity of the device.
        public var identity: Identity? {
            var bufPtr: UnsafePointer<UInt8>!
            var len: Int = 0

            return self.withContext { context in
                guard kAKSReturnSuccess == aks_attest_context_get(context, aks_attest_param_identity, &bufPtr, &len), bufPtr != nil else {
                    return nil
                }

                guard let id = Identity(data: Data(bytes: bufPtr, count: len)) else {
                    return nil
                }

                return id
            }
        }

        /// The board ID of the device.
        public var boardID: UInt32? {
            return self.withContext { context in
                var val: UInt64 = 0
                guard kAKSReturnSuccess == aks_attest_context_get_uint64(context, aks_attest_param_board_id, &val) else {
                    return nil
                }
                precondition(val <= UInt32.max)
                return UInt32(val)
            }
        }

        /// The nonce used for the attestation.
        public var nonce: Data? {
            var bufPtr: UnsafePointer<UInt8>!
            var len: Int = 0

            return self.withContext { context in
                guard kAKSReturnSuccess == aks_attest_context_get(context, aks_attest_param_nonce, &bufPtr, &len) else {
                    return nil
                }
                return Data(bytes: bufPtr, count: len)
            }
        }

        /// The key options used for the attestation.
        public var keyOptions: KeyOptions? {
            return self.withContext { context in
                var val: UInt64 = 0
                guard kAKSReturnSuccess == aks_attest_context_get_uint64(context, aks_attest_param_key_options, &val) else {
                    return nil
                }

                return KeyOptions(rawValue: val)
            }
        }

        /// The attestation result.
        public var restrictedExecutionMode: Bool? {
            return self.withContext { context in
                var state: UInt64 = 0
                guard kAKSReturnSuccess == aks_attest_context_get_uint64(context, aks_attest_param_restricted_execution_mode_state, &state) else {
                    return nil
                }

                return state == 1
            }
        }

        /// The attestation result.
        public var ephemeralDataMode: Bool? {
            return self.withContext { context in
                var state: UInt64 = 0
                guard kAKSReturnSuccess == aks_attest_context_get_uint64(context, aks_attest_param_ephemeral_data_mode_state, &state) else {
                    return nil
                }

                return state == 1
            }
        }

        /// The attestation result.
        public var developerMode: Bool? {
            return self.withContext { context in
                var state: UInt64 = 0
                guard kAKSReturnSuccess == aks_attest_context_get_uint64(context, aks_attest_param_developer_mode_state, &state) else {
                    return nil
                }

                return state == 1
            }
        }

        /// The raw public key data.
        public var rawPublicKeyData: Data? {
            var bufPtr: UnsafePointer<UInt8>!
            var len: Int = 0

            return self.withContext { context in
                guard kAKSReturnSuccess == aks_attest_context_get(context, aks_attest_param_pub_key, &bufPtr, &len) else {
                    return nil
                }

                let keyData = Data(bytes: bufPtr, count: len)

                return keyData
            }
        }

        /// Whether the cryptex sealedhash is locked
        public var cryptexLockdown: Bool? {
            self.sealedHash(at: cryptexSlotUUID)?.flags.contains(.ratchetLocked)
        }

        /// The key type.
        public var keyType: AKSRefKeyType? {
            self.withContext { (context) -> AKSRefKeyType? in
                var type: UInt64 = 0
                guard kAKSReturnSuccess == aks_attest_context_get_uint64(context, aks_attest_param_key_type, &type) else {
                    return nil
                }

                return AKSRefKeyType(rawValue: Int64(bitPattern: type))
            }
        }

        /// The public key bytes.
        public var publicKeyData: PublicKeyData? {
            guard let data = self.rawPublicKeyData, !data.isEmpty else {
                return nil
            }

            switch self.keyType {
            case .curve25519:
                return .curve25519(data)
            case .ecP256, .pkaP256, .ecP384, .pkaP384:
                return .x963(data)
            default:
                Self.logger.debug("Unsupported public key type")
                return nil
            }
        }

        /// The os type of the attestation.
        public var osType: OSType? {
            var bufPtr: UnsafePointer<UInt8>!
            var len: Int = 0

            return self.withContext { context in
                guard kAKSReturnSuccess == aks_attest_context_get(context, aks_attest_param_os_type, &bufPtr, &len), bufPtr != nil, len == 1 else {
                    return nil
                }

                return OSType(type: aks_attest_os_type_t(bufPtr.pointee))
            }
        }
    }
}

// MARK: - Error API
extension SEP.Attestation {
    public enum Error: Swift.Error {
        case invalidBlob
        case invalidField
        case invalidSelfKey
        case invalidSignature
    }
}

extension SEP.Attestation {
    public enum OSType {
        case none
        case iOS
        case watchOS
        case macOS
        case bridgeOS
        case tvOS
        case visionOS
        case rtKit

        init(type: aks_attest_os_type_t) {
            switch type {
            case aks_attest_os_type_ios:
                self = .iOS
            case aks_attest_os_type_macos:
                self = .macOS
            case aks_attest_os_type_watchos:
                self = .watchOS
            case aks_attest_os_type_bridgeos:
                self = .bridgeOS
            case aks_attest_os_type_tvos:
                self = .tvOS
            case aks_attest_os_type_visionos:
                self = .visionOS
            case aks_attest_os_type_rtkit:
                self = .rtKit
            default:
                self = .none
            }
        }
    }
}
