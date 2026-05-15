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
import CloudBoardLogging
import Foundation

package enum LengthPrefixBufferError: ReportableError {
    case exceedingMaxMessageSize(maxSize: Int, announcedSize: Int)
    case receivedAdditionalChunkAfterFinalChunk
    case finalChunkContainsIncompleteMessage

    package var publicDescription: String {
        switch self {
        case .exceedingMaxMessageSize: "exceedingMaxMessageSize"
        case .receivedAdditionalChunkAfterFinalChunk: "receivedAdditionalChunkAfterFinalChunk"
        case .finalChunkContainsIncompleteMessage: "finalChunkContainsIncompleteMessage"
        }
    }
}

/// LengthPrefixBuffer assembles network chunked data at cb_jobhelper and
/// Application data chunked by device at CloudApp Framework
/// Assembly happens by reading length-prefixed segments.
///
/// **How it works:**
/// - Reads 4-byte length (UInt32)
/// - Reads that many bytes of data
/// - Repeats until complete
///
/// **When does it stop?**
/// - Receiving finalMessage for a normal request
/// - Receiving closeSubrequest for a sub-request
///
/// **Validation:**
/// - Call `validateCompleteDataChunksReceived()` to ensure all chunks for a request were received and data is complete.
///
/// /// **Applied to Application Data Paths:**
/// - Device → Proxy(request data when request by pass is off)
/// - Device → Compute node(request data when request by pass is on)
/// - Proxy → Compute (compute collects proxy chunked worker data)
/// - Compute → Proxy (proxy collects worker chunked response)
/// /// **Applied to Network Data Paths:**
/// - Device → Proxy
/// - Device → Compute node
///
/// **Configuration:**
/// - maxMessageSize is set per cloudApp at Application Data Path via secure config
/// - maxMessageSize is set  via hot properties at network protocol layer
package struct LengthPrefixBuffer {
    enum State {
        case waitingForLengthPrefix
        case waitingForData(Int)
        case finalChunkSeen
    }

    var buffer: Data
    var state: State

    /// maximum message size in bytes that we are willing to buffer in-memory
    let maxMessageSize: Int

    package init(maxMessageSize: Int) {
        self.buffer = Data()
        self.state = .waitingForLengthPrefix
        self.maxMessageSize = maxMessageSize
    }

    package mutating func append(_ chunkFragment: FinalizableChunk<Data>) throws -> [FinalizableChunk<Data>] {
        self.buffer.append(chunkFragment.chunk)

        var result: [FinalizableChunk<Data>] = []
        while !self.buffer.isEmpty {
            switch self.state {
            case .waitingForLengthPrefix:
                guard let length = buffer.getLength() else {
                    if chunkFragment.isFinal {
                        throw LengthPrefixBufferError.finalChunkContainsIncompleteMessage
                    }
                    return result
                }
                guard length <= self.maxMessageSize else {
                    throw LengthPrefixBufferError.exceedingMaxMessageSize(
                        maxSize: self.maxMessageSize,
                        announcedSize: length
                    )
                }
                self.buffer = self.buffer.dropFirst(4)
                self.state = .waitingForData(length)

            case .waitingForData(let length):
                guard length > 0 else {
                    self.state = .waitingForLengthPrefix
                    continue
                }
                guard self.buffer.count >= length else {
                    if chunkFragment.isFinal {
                        throw LengthPrefixBufferError.finalChunkContainsIncompleteMessage
                    }
                    return result
                }

                if chunkFragment.isFinal, self.buffer.count == length {
                    // this is the last chunk and we are at the last message in that chunk
                    result.append(.init(chunk: Data(self.buffer), isFinal: true))
                    self.buffer = Data()
                    self.state = .finalChunkSeen
                } else {
                    // This might be the last chunk fragment but it contains multiple messages.
                    // This is then not yet the last message and therefore we need to set isFinal to false and
                    // parse the the next message in the following iteration
                    // It might also not be the last chunk in which case we set isFinal false too
                    result.append(.init(chunk: Data(self.buffer.prefix(length)), isFinal: false))
                    self.buffer = self.buffer.dropFirst(length)
                    self.state = .waitingForLengthPrefix
                }

            case .finalChunkSeen:
                throw LengthPrefixBufferError.receivedAdditionalChunkAfterFinalChunk
            }
        }

        return result
    }

    package mutating func validateCompleteDataChunksReceived() throws {
        switch self.state {
        case .waitingForLengthPrefix, .finalChunkSeen:
            if !self.buffer.isEmpty {
                throw LengthPrefixBufferError.finalChunkContainsIncompleteMessage
            }
        case .waitingForData(let length):
            if length != 0 {
                throw LengthPrefixBufferError.finalChunkContainsIncompleteMessage
            }
        }
    }
}

extension Data {
    fileprivate func getLength() -> Int? {
        guard self.count >= 4 else { return nil }
        // swiftformat:disable all
        return Int(
            UInt32(self[startIndex])     << 24 |
            UInt32(self[startIndex + 1]) << 16 |
            UInt32(self[startIndex + 2]) <<  8 |
            UInt32(self[startIndex + 3])
        )
    }
}

