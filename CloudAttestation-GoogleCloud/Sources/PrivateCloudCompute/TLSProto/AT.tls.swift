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

//  Copyright © 2024 Apple, Inc. All rights reserved.
//

import Foundation
import Common
import BinaryCoding

// MARK: SerializationVersion

public struct SerializationVersion: RawRepresentable, StaticSized, BinaryDecodable, Sendable {
    public var rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }
}

extension SerializationVersion: CaseIterable {
    static let V1 = SerializationVersion(rawValue: 1)

    public static var allCases: [SerializationVersion] {
        return [.V1]
    }
}

extension SerializationVersion: Hashable {}

extension SerializationVersion: CustomStringConvertible {
    public var description: String {
        switch self {
        case .V1:
            return ".V1"
        default:
            return "SerializationVersion(rawValue: \(self.rawValue))"
        }
    }
}

// MARK: ATLeafType

public struct ATLeafType: RawRepresentable, StaticSized, BinaryDecodable, Sendable {
    public var rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }
}

extension ATLeafType: CaseIterable {
    package static let RELEASE = ATLeafType(rawValue: 1)
    package static let MODEL = ATLeafType(rawValue: 2)
    package static let KEYBUNDLE_TGT = ATLeafType(rawValue: 3)
    package static let KEYBUNDLE_OTT = ATLeafType(rawValue: 4)
    package static let KEYBUNDLE_OHTTP = ATLeafType(rawValue: 5)
    package static let SERVER_NODE = ATLeafType(rawValue: 6)
    package static let TEST_MARKER = ATLeafType(rawValue: 100)

    public static var allCases: [ATLeafType] {
        return [.RELEASE, .MODEL, .KEYBUNDLE_TGT, .KEYBUNDLE_OTT, .KEYBUNDLE_OHTTP, .SERVER_NODE, .TEST_MARKER]
    }
}

extension ATLeafType: Hashable {}

extension ATLeafType: CustomStringConvertible {
    public var description: String {
        switch self {
        case .RELEASE:
            return ".RELEASE"
        case .MODEL:
            return ".MODEL"
        case .KEYBUNDLE_TGT:
            return ".KEYBUNDLE_TGT"
        case .KEYBUNDLE_OTT:
            return ".KEYBUNDLE_OTT"
        case .KEYBUNDLE_OHTTP:
            return ".KEYBUNDLE_OHTTP"
        case .SERVER_NODE:
            return ".SERVER_NODE"
        case .TEST_MARKER:
            return ".TEST_MARKER"
        default:
            return "ATLeafType(rawValue: \(self.rawValue))"
        }
    }
}

// MARK: TransparencyExtensionType

// enum {
//    (255)
// } TransparencyExtensionType;

public struct TransparencyExtensionType: RawRepresentable, Sendable, StaticSized, BinaryDecodable {
    public var rawValue: UInt8

    public static let releaseType: TransparencyExtensionType = .init(rawValue: 1)
    public static let insertionTimeMs: TransparencyExtensionType = .init(rawValue: 2)

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }
}

extension TransparencyExtensionType: Hashable {}

extension TransparencyExtensionType: CustomStringConvertible {
    public var description: String {
        switch self {
        default:
            return "TransparencyExtensionType(rawValue: \(self.rawValue))"
        }
    }
}

// MARK: TransparencyExtension

// in extensions vectors, there may only be one Extension of any TransparencyExtensionType, Extensions are ordered by TransparencyExtensionType
// struct {
//    TransparencyExtensionType TransparencyExtensionType;
//    opaque extensionData<0..65535>;
// } Extension;

package enum TransparencyExtension: BinaryDecodable, TaggedBinaryDecodable {
    package typealias Tag = TransparencyExtensionType
    case releaseType(ArraySlice<UInt8>)
    case insertionTimeMs(ArraySlice<UInt8>)
    case unknownExtension(TransparencyExtensionType, ArraySlice<UInt8>)

    package var type: TransparencyExtensionType {
        switch self {
        case .releaseType(_):
            TransparencyExtensionType.releaseType
        case .insertionTimeMs(_):
            TransparencyExtensionType.insertionTimeMs
        case .unknownExtension(let type, _):
            type
        }
    }

    package var byteCount: Int {
        let c =
            switch self {
            case .releaseType(let arraySlice):
                arraySlice.byteCount
            case .insertionTimeMs(let arraySlice):
                arraySlice.byteCount
            case .unknownExtension(_, let arraySlice):
                arraySlice.byteCount
            }
        return self.type.byteCount + c
    }

    package init(from buffer: inout ArraySlice<UInt8>) throws {
        let type = try TransparencyExtensionType(from: &buffer)
        try self.init(from: &buffer, with: type)
    }

    package init(from buffer: inout ArraySlice<UInt8>, with tag: TransparencyExtensionType) throws {
        let vector = try TLSVector<UInt16>(from: &buffer)
        switch tag {
        case .releaseType:  // RELEASE_TYPE
            self = .releaseType(vector.data)
        case .insertionTimeMs:  // INSERTION_TIME_MS
            self = .insertionTimeMs(vector.data)
        default:
            self = .unknownExtension(tag, vector.data)
        }
    }
}

extension TransparencyExtension: Hashable {}

// MARK: ATLeafData

// SerializationVersion version;
// ATLeafType type;
// opaque description<0..255>;
// HashValue dataHash;
// uint64 expiryMs;
// Extension extensions<0..65535>;
package struct ATLeafData: BinaryDecodable {
    package var version: SerializationVersion
    package var type: ATLeafType
    package var ATDescription: Data
    package var dataHash: Data
    package var expiryMs: UInt64
    package var extensions: [TransparencyExtension]

    init(
        version: SerializationVersion,
        type: ATLeafType,
        ATDescription: Data,
        dataHash: Data,
        expiryMs: UInt64,
        extensions: [TransparencyExtension]
    ) {
        self.version = version
        self.type = type
        self.ATDescription = ATDescription
        self.dataHash = dataHash
        self.expiryMs = expiryMs
        self.extensions = extensions
    }

    package init(from buffer: inout ArraySlice<UInt8>) throws {
        self.version = try SerializationVersion(from: &buffer)
        self.type = try ATLeafType(from: &buffer)
        self.ATDescription = Data(try TLSVector<UInt8>(from: &buffer).data)
        self.dataHash = Data(try TLSVector<UInt8>(from: &buffer).data)
        // expiryMs is a uint64 in TLS network byte order.
        self.expiryMs = try buffer.readUInt64(byteOrder: .bigEndian)
        var extensionsBuffer = try TLSVector<UInt16>(from: &buffer).data
        var extensions: [TransparencyExtension] = []
        while !extensionsBuffer.isEmpty {
            extensions.append(try TransparencyExtension(from: &extensionsBuffer))
        }
        self.extensions = extensions
    }

    @StructureSize
    public var byteCount: Int {
        self.version
        self.type
        self.ATDescription
        self.dataHash
        self.expiryMs
        self.extensions
    }

    package var expiry: Date {
        Date(timeIntervalSince1970: Double(self.expiryMs) / 1000)
    }
}

extension ATLeafData: Hashable {
    public static func == (lhs: ATLeafData, rhs: ATLeafData) -> Bool {
        return (lhs.version == rhs.version) && (lhs.type == rhs.type) && (lhs.ATDescription == rhs.ATDescription) && (lhs.dataHash == rhs.dataHash)
            && (lhs.expiryMs == rhs.expiryMs)
            && (lhs.extensions.sorted(by: { $0.type.rawValue < $1.type.rawValue }) == rhs.extensions.sorted(by: { $0.type.rawValue < $1.type.rawValue }))
    }
}

extension ATLeafData {
    var releaseType: ATReleaseTypeTLS {
        for ext in self.extensions {
            switch ext {
            case .releaseType(var buffer):
                if let raw = try? buffer.readUInt8(),
                    let releaseType = ATReleaseTypeTLS(rawValue: raw)
                {
                    return releaseType
                }
            default:
                continue
            }
        }

        return .production
    }

    var insertionTime: UInt64? {
        for ext in self.extensions {
            switch ext {
            case .insertionTimeMs(var buffer):
                return try? buffer.readUInt64(byteOrder: .bigEndian)
            default:
                continue
            }
        }

        return nil
    }
}

enum ATReleaseTypeTLS: UInt8 {
    case production = 0
    case seed = 1
}

private struct TLSVector<LengthField: FixedWidthInteger & Sized>: BinaryDecodable {
    var length: LengthField
    var data: ArraySlice<UInt8>

    init(from buffer: inout ArraySlice<UInt8>) throws {
        // TLS presentation language specifies network byte order for the length prefix.
        self.length = try buffer.read(LengthField.self, byteOrder: .bigEndian)
        self.data = try buffer.readBytes(count: Int(self.length))
    }

    @StructureSize
    var byteCount: Int {
        self.length
        self.data
    }
}
