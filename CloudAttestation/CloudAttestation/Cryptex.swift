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
//  Cryptex.swift
//  CloudAttestation
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

import Foundation
import FeatureFlags
import CryptoKit

/// Represents metadata of a Cryptex, including the Image4 Manifest
public struct Cryptex: Equatable {
    let image4Manifest: Image4Manifest
}

// Represents an ordered sequence of Cryptexes, corresponding to their ratchet entries into the SEP.
public enum Cryptexes: Equatable {
    case unlocked([Cryptex])
    case locked([Cryptex])

    func replaySealedHash(with hash: any HashFunction.Type = SHA384.self, salt: Data? = nil) throws -> SEP.SealedHash.Value {
        var sealedHash: SEP.SealedHash
        switch (self, salt) {
        case (.locked(let cryptexes), let salt) where salt != nil:
            sealedHash = try SEP.SealedHash(ratchet: cryptexes.map { Data(hash.hash(data: $0.image4Manifest.data)) })
            try sealedHash.ratchet(digest: Data(cryptexSignatureSealedHashSalt), flags: [.ratchet, .ratchetLocked])

        case (.locked(let cryptexes), _):
            fallthrough

        case (.unlocked(let cryptexes), _):
            sealedHash = try SEP.SealedHash(
                ratchet: cryptexes.map { cryptex in
                    Data(hash.hash(data: cryptex.image4Manifest.data))
                }
            )
        }

        return sealedHash.value
    }

    var image4Manifests: [Image4Manifest] {
        switch self {
        case .unlocked(let cryptexes):
            fallthrough

        case .locked(let cryptexes):
            return cryptexes.map { $0.image4Manifest }
        }
    }
}

// MARK: - Cryptex Proto Helpers
extension Proto_AttestationBundle {
    var cryptexHashFunction: (any HashFunction.Type)? {
        guard let slot = self.sealedHashes.slots[CryptexPolicy.slot.uuidString] else {
            return nil
        }

        return slot.hashAlg.hashFunction
    }

    func cryptexes(slot: UUID, requireCryptex1: Bool = false) -> Cryptexes? {
        guard let slot = self.sealedHashes.slots[slot.uuidString] else {
            return nil
        }

        let seq = slot.entries.compactMap { entry in
            if case .cryptex(let cryptex) = entry.info {
                let kind: Image4Manifest.Kind = requireCryptex1 ? .cryptex : .pdiOrCryptex
                let manifest = Image4Manifest(data: cryptex.image4Manifest, kind: kind)
                return Cryptex(image4Manifest: manifest)
            }
            return nil
        }

        let locked = slot.entries.last.map { entry in
            if case .cryptexSalt(_) = entry.info {
                return true
            }
            return SEP.SealedHash.Flags(rawValue: entry.flags).contains(.ratchetLocked)
        }

        if locked == true {
            return .locked(seq)
        }

        return .unlocked(seq)
    }

    func cryptexes(requireCryptex1: Bool = false) -> Cryptexes? {
        if self.sealedHashes.slots.keys.contains(CryptexPolicy.slot.uuidString) {
            return self.cryptexes(slot: CryptexPolicy.slot, requireCryptex1: requireCryptex1)
        }

        return nil
    }
}
