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

//  Copyright © 2026 Apple, Inc. All rights reserved.
//

import Foundation

/// Minimal protobuf wire-format scanner used to read the bundle `version`
/// discriminator (field 2047) without linking cloudattestationv2. See
/// cloudattestationv2's `Docs/SubprocessContract.md` — both the v2
/// `AttestationBundle` envelope and the v1 `AppleSiliconAttestationBundle`
/// carry `uint32 version = 2047`; value `2` means "v2 envelope, route to the
/// helper", anything else (including absent) means "treat as v1".
enum ProtoSniff {
    /// Reads the protobuf field tag `fieldNumber` (varint wire type only) at
    /// the top level of `data`. Returns nil if not present, malformed, or the
    /// field uses a non-varint wire type. Skips other top-level fields by
    /// wire-type rules; does not recurse into submessages.
    static func topLevelVarint(field fieldNumber: UInt32, in data: Data) -> UInt64? {
        var i = data.startIndex
        while i < data.endIndex {
            guard let (tag, afterTag) = readVarint(data, at: i) else { return nil }
            let wireType = UInt8(tag & 0x7)
            // A tag varint that overflows 32 bits after the wire-type shift is
            // malformed; map to an impossible field number so we fall through
            // (rather than trap) and the caller treats the bytes as not-v2.
            let field = UInt32(exactly: tag >> 3) ?? .max
            i = afterTag

            if field == fieldNumber {
                guard wireType == 0 else { return nil }
                return readVarint(data, at: i)?.value
            }

            // Skip this field's payload by wire type.
            switch wireType {
            case 0:  // varint
                guard let (_, next) = readVarint(data, at: i) else { return nil }
                i = next
            case 1:  // fixed64
                i = data.index(i, offsetBy: 8, limitedBy: data.endIndex) ?? data.endIndex
            case 2:  // length-delimited
                guard let (len, afterLen) = readVarint(data, at: i),
                      let intLen = Int(exactly: len),
                      let next = data.index(afterLen, offsetBy: intLen, limitedBy: data.endIndex)
                else { return nil }
                i = next
            case 5:  // fixed32
                i = data.index(i, offsetBy: 4, limitedBy: data.endIndex) ?? data.endIndex
            default:  // groups (3,4) or unknown — bail
                return nil
            }
        }
        return nil
    }

    /// Returns true iff the bundle's top-level `version` field (2047) is `2`.
    /// Absent or any other value → false (treat as v1).
    static func isV2AttestationBundle(_ data: Data) -> Bool {
        topLevelVarint(field: 2047, in: data) == 2
    }

    private static func readVarint(_ data: Data, at start: Data.Index) -> (value: UInt64, next: Data.Index)? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var i = start
        while i < data.endIndex {
            let byte = data[i]
            result |= UInt64(byte & 0x7F) << shift
            i = data.index(after: i)
            if byte & 0x80 == 0 {
                return (result, i)
            }
            shift += 7
            if shift >= 64 { return nil }
        }
        return nil
    }
}
