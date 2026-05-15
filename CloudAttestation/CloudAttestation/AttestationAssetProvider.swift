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
//  AttestationDelegate.swift
//  CloudAttestation
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

import Foundation
@_weakLinked import SecureConfigDB
import CryptoKit
import MSUDataAccessor
#if os(macOS)
@_implementationOnly import BootPolicy
#endif

public protocol AttestationAssetProvider: Sendable {
    var apTicket: Data { get throws }
    var provisioningCertificateChain: [Data] { get async throws }
    var sealedHashEntries: [UUID: [SEP.SealedHash.Entry]] { get throws }

    #if os(macOS)
    var localBootPolicy: Data { get throws }
    var sfrManifest: Data { get throws }
    #endif
}

extension AttestationAssetProvider {
    public var apTicket: Data {
        get throws {
            do {
                let apTicketPath = try MSUDataAccessor.shared().copyPath(forPersonalizedData: MSUDA_APTICKET)
                return try Data(contentsOf: URL(fileURLWithPath: apTicketPath))
            } catch {
                throw AttestationAssetProviderError.missingAPTicket(error: error)
            }
        }
    }

    public var sealedHashEntries: [UUID: [SEP.SealedHash.Entry]] {
        get throws {
            guard #_hasSymbol(SCDataBase.self) else {
                return [:]
            }

            let db = SCDataBase()

            return try db.slots.mapValues { slot in
                let hashFn: any HashFunction.Type =
                    switch slot.algorithm {
                    case "sha256":
                        SHA256.self

                    case "sha384":
                        SHA384.self

                    default:
                        throw AttestationAssetProviderError.invalidHashFunction(slot.algorithm)
                    }
                var entries = slot.entries.map { entry in
                    var ssrEntry = SEP.SealedHash.Entry(data: entry.data, flags: .ratchet, algorithm: hashFn)
                    if slot.slotID == cryptexSlotUUID {
                        ssrEntry.flags.formUnion(.cryptexMeasurement)
                    }
                    ssrEntry.metadata = entry.metadata
                    ssrEntry.type = slot.recordType
                    return ssrEntry
                }
                if let salt = slot.salt {
                    entries.append(
                        SEP.SealedHash.Entry(
                            digest: salt.data(using: .utf8)!,
                            flags: .ratchetLocked,
                            algorithm: hashFn
                        )
                    )
                }
                return entries
            }
        }
    }

    #if os(macOS)
    public var localBootPolicy: Data {
        get throws {
            var policyExists: Bool = false
            var error = bootpolicy_volume_has_local_policy(bootpolicy_default_policy_volume_path_value, bootpolicy_root_volume_uuid_value, &policyExists)
            guard error == BOOTPOLICY_SUCCESS else {
                throw AttestationAssetProviderError.missingLocalBootPolicy
            }

            var policyBufferPointer: UnsafeMutablePointer<UInt8>?
            var policyBufferLength: size_t = 0
            error = bootpolicy_get_booted_local_policy(&policyBufferPointer, &policyBufferLength)
            guard error == BOOTPOLICY_SUCCESS, let policyBufferPointer else {
                throw AttestationAssetProviderError.missingLocalBootPolicy
            }

            return Data(bytesNoCopy: policyBufferPointer, count: policyBufferLength, deallocator: .free)
        }
    }

    public var sfrManifest: Data {
        get throws {
            do {
                let sfrManifestPath = try MSUDataAccessor.shared().copyPath(forPersonalizedData: MSUDA_SFR_MANIFEST)
                return try Data(contentsOf: URL(fileURLWithPath: sfrManifestPath))
            } catch {
                throw AttestationAssetProviderError.missingSFRManifest(error: error)
            }
        }
    }
    #endif
}

// MARK: - AttestationAssetProvider Error
public enum AttestationAssetProviderError: Swift.Error {
    case invalidHashFunction(String)
    case noSecureConfigDB
    case missingProvisioningCertificate
    case invalidProvisioningCertificate
    case missingAPTicket(error: Swift.Error)
    case missingSFRManifest(error: Swift.Error)
    case missingLocalBootPolicy
}
