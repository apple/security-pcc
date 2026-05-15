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

import CloudBoardLogging
import Foundation
import NIOCore

/// This key is used for AntiReplay protection.
/// Requirements:
/// - No false negatives
/// - Probability of a false positive is such that it is never expected to happen in the lifetime of the system
///  under the most conservative assumptions
///
/// The (encrypted) bytes for the key material are essentially a random value of high entropy where a subset
/// of any bytes from this retains that property, so we select a subset of them that achives our other goals.
///
/// For a key with 24 hour life, with a session use every 2ms (unrealistic actual rate) we get
/// 43,200,00 entries
///
/// Applying a birthday collision calculation:
/// 8 bytes (64bits) gives us an approximate value of probability of collision of 0.00005 which isn't enough.
/// we just go to 16 bytes to keep alignment and then we are doing better than version 4 UUIDS so it's fine
struct SessionKey: Hashable, Sendable {
    enum SessionKeyError: ReportableError {
        case insufficientBytes(length: Int)
        case invalidByteCount(length: Int)
        /// As a protection against accidental screw ups we declare the zero form illegal to create.
        /// This has the desirable benefit that it is possible to explicitly write zeros to a
        /// storage file such that, even if it happened to have the right length, it would fail
        case sentinelZeroValue

        /// Including length would needlessly complicate the metric filtering this provides
        var publicDescription: String {
            switch self {
            case .insufficientBytes:
                return "attempt to create from less than \(byteLength) bytes"
            case .invalidByteCount:
                return "exactly one SessionKey was used with invalid byte count"
            case .sentinelZeroValue:
                return "SessionKey was initialized with a zero value"
            }
        }
    }

    internal static let byteLength = MemoryLayout<UInt128>.size

    internal let key: UInt128

    /// Read a SessionKey from a buffer which must be precisely the right length
    internal init(exactlyTheRightSize buffer: inout ByteBuffer) throws {
        guard buffer.readableBytes == Self.byteLength else {
            throw SessionKeyError.invalidByteCount(length: buffer.readableBytes)
        }
        guard let key = buffer.readInteger(endianness: .host, as: UInt128.self) else {
            // we checked the length - so some assumption is very wrong here
            fatalError("failed to read \(UInt128.self) from \(buffer.readableBytes) length buffer")
        }
        guard key != 0 else {
            throw SessionKeyError.sentinelZeroValue
        }
        self.key = key
    }

    internal init(from buffer: inout ByteBuffer) throws {
        guard let key = buffer.readInteger(endianness: .host, as: UInt128.self) else {
            throw SessionKeyError.invalidByteCount(length: buffer.readableBytes)
        }
        guard key != 0 else {
            throw SessionKeyError.sentinelZeroValue
        }
        self.key = key
    }

    internal init(forTesting key: UInt128) {
        // This is a testing path, so is allowed to make the invalid sentinel value
        self.key = key
    }

    // making a new Data each time is trivial compared to the IO
    internal var asData: Data {
        var data = Data(count: Self.byteLength)
        data.withUnsafeMutableBytes {
            $0.storeBytes(of: self.key, as: UInt128.self)
        }
        return data
    }
}
