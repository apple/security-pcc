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
//  LogConsistency+Extension.swift
//  CloudAttestation
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//

import Foundation
import CryptoKit
import InternalSwiftProtobuf

extension LogConsistency {
    /// Verifies the consistency proof between two tree heads according to RFC9162 Section 2.1.4.2.
    public var isValid: Bool {
        typealias Hash = SHA256

        // Parse log heads from signed objects
        guard let firstLogHead = try? LogHead(serializedBytes: startSlh.object),
            let secondLogHead = try? LogHead(serializedBytes: endSlh.object)
        else {
            return false
        }

        let first = firstLogHead.logSize
        let second = secondLogHead.logSize
        let firstHash = firstLogHead.logHeadHash
        let secondHash = secondLogHead.logHeadHash

        // Precondition: 0 < first < second
        guard first > 0 && first < second else {
            return false
        }

        // 1. If consistency_path is an empty array, stop and fail the proof verification.
        guard !proofHashes.isEmpty else {
            return false
        }

        // 2. If first is an exact power of 2, then prepend first_hash to the consistency_path array.
        var consistencyPath = proofHashes
        if first.isPowerOfTwo {
            consistencyPath.insert(firstHash, at: 0)
        }

        // 3. Set fn to first - 1 and sn to second - 1.
        var fn = first - 1
        var sn = second - 1

        // 4. If LSB(fn) is set, then right-shift both fn and sn equally until LSB(fn) is not set.
        while fn.isOdd {
            fn >>= 1
            sn >>= 1
        }

        // 5. Set both fr and sr to the first value in the consistency_path array.
        guard let firstProof = consistencyPath.first else {
            return false
        }
        var fr = Data(firstProof)
        var sr = Data(firstProof)

        // 6. For each subsequent value c in the consistency_path array:
        for c in consistencyPath.dropFirst() {
            // 6a. If sn is 0, then stop the iteration and fail the proof verification.
            guard sn != 0 else {
                return false
            }

            // 6b. If LSB(fn) is set, or if fn is equal to sn, then:
            if fn.isOdd || fn == sn {
                // 6b.i. Set fr to HASH(0x01 || c || fr).
                fr = Data(Hash.interior(left: c, right: fr))
                // 6b.ii. Set sr to HASH(0x01 || c || sr).
                sr = Data(Hash.interior(left: c, right: sr))

                // 6b.iii. If LSB(fn) is not set, then right-shift both fn and sn
                //         equally until either LSB(fn) is set or fn is 0.
                if fn.isEven {
                    repeat {
                        fn >>= 1
                        sn >>= 1
                    } while fn.isEven && fn != 0
                }
            } else {
                // Otherwise: Set sr to HASH(0x01 || sr || c).
                sr = Data(Hash.interior(left: sr, right: c))
            }

            // 6c. Finally, right-shift both fn and sn one time.
            fn >>= 1
            sn >>= 1
        }

        // 7. After completing iterating through the consistency_path array as described above,
        //    verify that the fr calculated is equal to the first_hash supplied, that the sr
        //    calculated is equal to the second_hash supplied, and that sn is 0.
        return fr == firstHash && sr == secondHash && sn == 0
    }

    var logRevision: (start: TransparencyLogRevision, end: TransparencyLogRevision) {
        get throws {
            let logHeadStart = try LogHead(serializedBytes: self.startSlh.object)
            let logHeadEnd = try LogHead(serializedBytes: self.endSlh.object)
            return (start: logHeadStart.logRevision, end: logHeadEnd.logRevision)
        }
    }
}
