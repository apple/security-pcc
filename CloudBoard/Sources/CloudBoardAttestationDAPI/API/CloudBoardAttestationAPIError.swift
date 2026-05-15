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

package import CloudBoardAsyncXPC
import Foundation

package enum CloudBoardAttestationAPIError: Error, Codable, Hashable {
    case internalError
    case noDelegateSet
    case notConnected
    case missingEntitlement(String)
    case noXPCConnectionInTaskLocal
    // We cannot act on the supplied key.
    // This would happen if
    // * it's not a legal keyId
    // * if the key was lost (say due to a crash)
    // * the key expired
    // We maintain a limited window to provide ``expired`` information to assist diagnosis of errors
    // but this is not a guarantee, as we cannnot maintain that information indefinitely
    case unavailableKeyID(requestKeyID: Data, expired: Bool)
    // This timeout may ultimately happen at the point the requestKeyId expires
    case validationTimedOut(requestKeyID: Data, workerKeyId: Data)

    // Used in testing where implementing a feature is pointless but you want
    // to know when it happens rather than triggering a fataError
    case notImplemented
}

extension CloudBoardAttestationAPIError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .internalError:
            return "Internal error"
        case .noDelegateSet:
            return "No delegate set"
        case .notConnected:
            return "Not connected"
        case .missingEntitlement(let entitlement):
            return "Missing entitlement \(entitlement)"
        case .noXPCConnectionInTaskLocal:
            return "No connection in task local"
        case .unavailableKeyID(let requestKeyID, let expired):
            return "Unavailable key ID: \(requestKeyID.base64EncodedString()) expired: \(expired)"
        case .validationTimedOut(let requestKeyID, let workerKeyID):
            return "Validation timed out for request key: \(requestKeyID.base64EncodedString()) with worker key \(workerKeyID.base64EncodedString())"
        case .notImplemented:
            return "Not implemented"
        }
    }
}

extension CloudBoardAttestationAPIError: ByteBufferCodable {
    public func encode(to buffer: inout ByteBuffer) throws {
        switch self {
        case .internalError:
            buffer.writeInteger(0)
        case .noDelegateSet:
            buffer.writeInteger(1)
        case .notConnected:
            buffer.writeInteger(2)
        case .missingEntitlement(let entitlement):
            buffer.writeInteger(3)
            try entitlement.encode(to: &buffer)
        case .noXPCConnectionInTaskLocal:
            buffer.writeInteger(4)
        case .unavailableKeyID(let keyID, let expired):
            buffer.writeInteger(5)
            try keyID.encode(to: &buffer)
            try expired.encode(to: &buffer)
        case .validationTimedOut(let requestKeyID, let workerKeyId):
            buffer.writeInteger(6)
            try requestKeyID.encode(to: &buffer)
            try workerKeyId.encode(to: &buffer)
        case .notImplemented:
            buffer.writeInteger(7)
        }
    }

    public init(from buffer: inout ByteBuffer) throws {
        guard let enumCase: Int = buffer.readInteger() else {
            throw DecodingError.valueNotFound(
                Self.self,
                .init(codingPath: [], debugDescription: "no expected enum case")
            )
        }
        switch enumCase {
        case 0:
            self = .internalError
        case 1:
            self = .noDelegateSet
        case 2:
            self = .notConnected
        case 3:
            self = try .missingEntitlement(.init(from: &buffer))
        case 4:
            self = .noXPCConnectionInTaskLocal
        case 5:
            self = try .unavailableKeyID(requestKeyID: .init(from: &buffer), expired: .init(from: &buffer))
        case 6:
            self = try .validationTimedOut(
                requestKeyID: .init(from: &buffer),
                workerKeyId: .init(from: &buffer)
            )
        case 7:
            self = .notImplemented
        case let value:
            throw DecodingError.dataCorrupted(.init(
                codingPath: [ByteBufferCodingKey(Self.self)],
                debugDescription: "bad result enum case \(value)"
            ))
        }
    }
}
