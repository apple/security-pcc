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
//  TarExtractor.swift
//  CloudAttestationV2
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//

import Foundation

/// Streaming USTAR/PAX archive scanner that yields the bytes of the *first*
/// entry whose name satisfies the supplied predicate. All other entries are
/// skipped. Padding is consumed transparently. Used to pull a raw `.img` /
/// `.raw` disk image out of an OS-image tarball without extracting the rest
/// of the archive.
public struct TarExtractor {
    private enum State {
        case seeking
        case extracting(remaining: Int)
        case done
    }

    private let shouldExtract: (String) -> Bool
    private var state: State = .seeking
    private var buffer = Data()
    private var skipRemaining = 0

    /// Name of the entry that satisfied the predicate, or `nil` if no entry
    /// has matched (yet). Lets callers distinguish "found a 0-byte entry"
    /// from "scanned to end without a match" — both yield zero output bytes.
    public private(set) var matchedEntryName: String?

    public init(matching predicate: @escaping (String) -> Bool) {
        self.shouldExtract = predicate
    }

    /// `true` once the matching entry has been fully yielded (or the archive's
    /// terminating zero block was reached). Callers can use this to stop
    /// feeding chunks early.
    public var isDone: Bool {
        if case .done = state { return true }
        return false
    }

    public mutating func feed(_ data: Data) -> Data {
        switch state {
        case .extracting(let remaining):
            let take = min(data.count, remaining)
            let newRemaining = remaining - take
            state = newRemaining > 0 ? .extracting(remaining: newRemaining) : .done
            return data.prefix(take)

        case .done:
            return Data()

        case .seeking:
            break
        }

        var remainder = data

        if skipRemaining > 0 {
            let skip = min(remainder.count, skipRemaining)
            skipRemaining -= skip
            remainder = remainder.dropFirst(skip)
            if skipRemaining > 0 { return Data() }
        }

        buffer.append(remainder)
        var output = Data()

        loop: while true {
            switch state {
            case .seeking:
                if skipRemaining > 0 {
                    let skip = min(buffer.count, skipRemaining)
                    buffer.removeFirst(skip)
                    skipRemaining -= skip
                    if skipRemaining > 0 { break loop }
                }

                guard buffer.count >= 512 else { break loop }
                let header = Data(buffer.prefix(512))
                buffer.removeFirst(512)

                if header.allSatisfy({ $0 == 0 }) {
                    state = .done
                    break loop
                }

                let name = tarEntryName(header)
                let size = tarEntrySize(header)

                if shouldExtract(name) {
                    matchedEntryName = name
                    let take = min(buffer.count, size)
                    output.append(buffer.prefix(take))
                    // Reassign rather than `removeAll(keepingCapacity:)`: `header`
                    // still aliases this storage, and clearing an offset-based
                    // empty slice through the COW copy path traps inside
                    // Foundation's `ensureUniqueBufferReference`. We don't reuse
                    // the capacity past this point anyway (state moves to
                    // .extracting/.done, which never touches `buffer`).
                    buffer = Data()
                    let remaining = size - take
                    state = remaining > 0 ? .extracting(remaining: remaining) : .done
                    break loop
                } else {
                    let padding = (512 - size % 512) % 512
                    skipRemaining = size + padding
                }

            case .extracting, .done:
                break loop
            }
        }

        return output
    }

    private func tarEntryName(_ header: Data) -> String {
        let name = String(bytes: header[0..<100].prefix(while: { $0 != 0 }), encoding: .utf8) ?? ""
        let prefix = String(bytes: header[345..<500].prefix(while: { $0 != 0 }), encoding: .utf8) ?? ""
        if !prefix.isEmpty { return "\(prefix)/\(name)" }
        return name
    }

    private func tarEntrySize(_ header: Data) -> Int {
        let sizeBytes = header[124..<136]

        if let first = sizeBytes.first, first & 0x80 != 0 {
            // GNU/star base-256: only the first byte carries the 0x80 marker;
            // the remaining 11 bytes are full-width big-endian binary.
            var value = UInt64(first & 0x7F)
            for byte in sizeBytes.dropFirst() {
                value = (value << 8) | UInt64(byte)
            }
            return Int(clamping: value)
        }

        let sizeStr = String(bytes: sizeBytes.prefix(while: { $0 != 0 && $0 != 0x20 }), encoding: .utf8) ?? ""
        return Int(sizeStr, radix: 8) ?? 0
    }
}
