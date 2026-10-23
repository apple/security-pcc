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
//  LengthPrefixDeframer.swift
//  PrivateCloudCompute
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

import Foundation
import InternalSwiftProtobuf

enum LengthPrefixDeframerError: Error {
    case receivedEndButWasExpectingMoreDataToFrameAnotherMessage
}

struct LengthPrefixDeframer<
    Base: AsyncSequence,
    Length: UnsignedInteger & FixedWidthInteger,
    Message: InternalSwiftProtobuf.Message
>: AsyncSequence where Base.Element == Data {
    typealias Element = Message

    let base: Base

    init(_ base: Base, lengthType: Length.Type, messageType: Message.Type) {
        self.base = base
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: self.base.makeAsyncIterator())
    }

    struct AsyncIterator: AsyncIteratorProtocol {
        typealias Element = Message

        enum State {
            case needLength
            case needBody(Length)
            case finished((any Error)?)
        }

        private var base: Base.AsyncIterator
        private var buffer: Data

        private var state: State = .needLength

        init(base: Base.AsyncIterator) {
            self.base = base
            self.buffer = Data()
        }

        mutating func next() async throws -> Message? {
            while true {
                switch self.state {
                case .needLength:
                    if let length = self.readFrameSize() {
                        self.state = .needBody(length)
                    } else {
                        await self.loadMore()
                    }
                // continues loop

                case .needBody(let length):
                    if let body = self.readBytes(length: Int(length)) {
                        self.state = .needLength
                        return try Message(serializedBytes: body)
                    } else {
                        await self.loadMore()
                        // continues loop
                    }

                case .finished(let error):
                    if let error {
                        throw error
                    } else {
                        return nil
                    }
                }
            }
        }

        private mutating func loadMore() async {
            do {
                if let data = try await self.base.next(isolation: #isolation) {
                    self.buffer.append(data)
                } else {
                    switch self.state {
                    case .needLength:
                        if self.buffer.isEmpty {
                            self.state = .finished(nil)
                        } else {
                            let error = LengthPrefixDeframerError.receivedEndButWasExpectingMoreDataToFrameAnotherMessage
                            self.state = .finished(error)
                        }

                    case .needBody:
                        let error = LengthPrefixDeframerError.receivedEndButWasExpectingMoreDataToFrameAnotherMessage
                        self.state = .finished(error)

                    case .finished:
                        break
                    }
                }
            } catch {
                self.state = .finished(error)
            }
        }

        private mutating func readFrameSize() -> Length? {
            guard let bytes = self.readBytes(length: Length.bitWidth / 8) else {
                return nil
            }

            return bytes.withUnsafeBytes {
                return Length(bigEndian: $0.loadUnaligned(as: Length.self))
            }
        }

        private mutating func readBytes(length: Int) -> Data? {
            if length == 0 {
                return Data()
            }

            if self.buffer.count < length {
                return nil
            }

            // SUBTLE: we must ensure `buffer` is uniquely referenced before removing this prefix,
            // because Data is copy-on-write. Copying the body into its own storage first drops the
            // shared reference to its backing storage, so the removeSubrange below mutates in place
            // instead of cloning the entire buffer.
            let subrange = self.buffer.startIndex..<self.buffer.startIndex.advanced(by: length)
            let prefix = Data(self.buffer[subrange])

            self.buffer.removeSubrange(subrange)

            return prefix
        }
    }
}

extension AsyncSequence where Element == Data {
    func deframed<
        Length: UnsignedInteger & FixedWidthInteger,
        Message: InternalSwiftProtobuf.Message
    >(lengthType: Length.Type, messageType: Message.Type) -> LengthPrefixDeframer<Self, Length, Message> {
        LengthPrefixDeframer(self, lengthType: Length.self, messageType: Message.self)
    }
}
