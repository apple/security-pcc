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

// MARK: SerializationVersion

public struct SerializationVersion: RawRepresentable, Sendable {
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

extension TransparencyByteBuffer {
    @discardableResult
    mutating func writeSerializationVersion(_ type: SerializationVersion) -> Int {
        return self.writeInteger(type.rawValue)
    }

    mutating func readSerializationVersion() -> SerializationVersion? {
        return self.readInteger().map { SerializationVersion(rawValue: $0) }
    }
}

// MARK: ATLeafType

public struct ATLeafType: RawRepresentable, Sendable {
    public var rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }
}

extension ATLeafType: CaseIterable {
    static let RELEASE = ATLeafType(rawValue: 1)
    static let MODEL = ATLeafType(rawValue: 2)
    static let KEYBUNDLE_TGT = ATLeafType(rawValue: 3)
    static let KEYBUNDLE_OTT = ATLeafType(rawValue: 4)
    static let KEYBUNDLE_OHTTP = ATLeafType(rawValue: 5)
    static let TEST_MARKER = ATLeafType(rawValue: 100)

    public static var allCases: [ATLeafType] {
        return [.RELEASE, .MODEL, .KEYBUNDLE_TGT, .KEYBUNDLE_OTT, .KEYBUNDLE_OHTTP, .TEST_MARKER]
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
        case .TEST_MARKER:
            return ".TEST_MARKER"
        default:
            return "ATLeafType(rawValue: \(self.rawValue))"
        }
    }
}

extension TransparencyByteBuffer {
    @discardableResult
    mutating func writeATLeafType(_ type: ATLeafType) -> Int {
        return self.writeInteger(type.rawValue)
    }

    mutating func readATLeafType() -> ATLeafType? {
        return self.readInteger().map { ATLeafType(rawValue: $0) }
    }
}

// MARK: TransparencyExtensionType

// enum {
//    (255)
// } TransparencyExtensionType;

public struct TransparencyExtensionType: RawRepresentable {
    public var rawValue: UInt8

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

extension TransparencyByteBuffer {
    @discardableResult
    mutating func writeTransparencyExtensionType(_ type: TransparencyExtensionType) -> Int {
        return self.writeInteger(type.rawValue)
    }

    mutating func readTransparencyExtensionType() -> TransparencyExtensionType? {
        return self.readInteger().map { TransparencyExtensionType(rawValue: $0) }
    }
}

// MARK: TransparencyExtension

// in extensions vectors, there may only be one Extension of any TransparencyExtensionType, Extensions are ordered by TransparencyExtensionType
// struct {
//    TransparencyExtensionType TransparencyExtensionType;
//    opaque extensionData<0..65535>;
// } Extension;

enum TransparencyExtension {
    case releaseType(TransparencyExtensionType, TransparencyByteBuffer)
    case insertionTimeMs(TransparencyExtensionType, TransparencyByteBuffer)
    case unknownExtension(TransparencyExtensionType, TransparencyByteBuffer)

    var type: TransparencyExtensionType {
        switch self {
        case .releaseType(let type, _):
            type
        case .insertionTimeMs(let type, _):
            type
        case .unknownExtension(let type, _):
            type
        }
    }
}

extension TransparencyExtension: Hashable {}

extension TransparencyByteBuffer {
    @discardableResult
    mutating func writeTransparencyExtension(_ ext: TransparencyExtension) -> Int {
        var written = self.writeTransparencyExtensionType(ext.type)
        written += self.writeVariableLengthVector(lengthFieldType: UInt16.self) { buffer in
            switch ext {
            case .releaseType(_, let extensionData):
                return buffer.writeImmutableBuffer(extensionData)
            case .insertionTimeMs(_, let extensionData):
                return buffer.writeImmutableBuffer(extensionData)
            case .unknownExtension(_, let extensionData):
                return buffer.writeImmutableBuffer(extensionData)
            }
        }
        return written
    }

    mutating func readTransparencyExtension() throws -> TransparencyExtension? {
        guard let type = self.readTransparencyExtensionType() else {
            return nil
        }

        return try self.readVariableLengthVector(lengthFieldType: UInt16.self) { extensionData in
            switch type.rawValue {
            case 1:
                return .releaseType(type, extensionData.readSlice(length: extensionData.readableBytes)!)
            case 2:
                return .insertionTimeMs(type, extensionData.readSlice(length: extensionData.readableBytes)!)
            default:
                // We ignore unknown extensions
                return .unknownExtension(type, extensionData.readSlice(length: extensionData.readableBytes)!)
            }
        }
    }
}

// MARK: ATLeafData

// SerializationVersion version;
// ATLeafType type;
// opaque description<0..255>;
// HashValue dataHash;
// uint64 expiryMs;
// Extension extensions<0..65535>;
struct ATLeafData {
    var version: SerializationVersion
    var type: ATLeafType
    var ATDescription: Data
    var dataHash: Data
    var expiryMs: UInt64
    var extensions: [TransparencyExtension]
    var verifier: NSObject?

    init(version: SerializationVersion,
         type: ATLeafType,
         ATDescription: Data,
         dataHash: Data,
         expiryMs: UInt64,
         extensions: [TransparencyExtension])
    {
        self.version = version
        self.type = type
        self.ATDescription = ATDescription
        self.dataHash = dataHash
        self.expiryMs = expiryMs
        self.extensions = extensions
    }

    init(bytes: inout TransparencyByteBuffer) throws {
        func readEntireBuffer(_ buffer: inout TransparencyByteBuffer) -> TransparencyByteBuffer {
            // We consume the full buffer. This force unwrap is safe: we always have readable bytes worth of bytes.
            return buffer.readSlice(length: buffer.readableBytes)!
        }

        func readExtensions(_ buffer: inout TransparencyByteBuffer) throws -> [TransparencyExtension] {
            var extensions = [TransparencyExtension]()

            while let ext = try buffer.readTransparencyExtension() {
                extensions.append(ext)
            }

            return extensions
        }

        guard let version = bytes.readSerializationVersion(),
              let type = bytes.readATLeafType(),
              let ATDescription = try bytes.readVariableLengthVector(lengthFieldType: UInt8.self, readEntireBuffer)?.readableBytesView,
              let dataHash = try bytes.readVariableLengthVector(lengthFieldType: UInt8.self, readEntireBuffer)?.readableBytesView,
              let expiryMs = bytes.readInteger(as: UInt64.self),
              let extensions = try bytes.readVariableLengthVector(lengthFieldType: UInt16.self, readExtensions)
        else {
            throw TransparencyTLSError.truncatedMessage
        }

        self = ATLeafData(version: version, type: type, ATDescription: ATDescription, dataHash: dataHash, expiryMs: expiryMs, extensions: extensions)
    }

    func write(into buffer: inout TransparencyByteBuffer) -> Int {
        var written = buffer.writeSerializationVersion(self.version)
        written += buffer.writeATLeafType(self.type)
        written += buffer.writeVariableLengthVector(lengthFieldType: UInt8.self) {
            $0.writeImmutableBuffer(TransparencyByteBuffer(data: self.ATDescription))
        }
        written += buffer.writeVariableLengthVector(lengthFieldType: UInt8.self) {
            $0.writeImmutableBuffer(TransparencyByteBuffer(data: self.dataHash))
        }
        written += buffer.writeInteger(self.expiryMs)
        written += buffer.writeVariableLengthVector(lengthFieldType: UInt16.self) { buffer in
            self.extensions.sorted {
                $0.type.rawValue < $1.type.rawValue
            }.reduce(into: 0) { count, ext in
                count += buffer.writeTransparencyExtension(ext)
            }
        }

        return written
    }
}

extension ATLeafData: Hashable {
    public static func ==(lhs: ATLeafData, rhs: ATLeafData) -> Bool {
        return (lhs.version == rhs.version) &&
            (lhs.type == rhs.type) &&
            (lhs.ATDescription == rhs.ATDescription) &&
            (lhs.dataHash == rhs.dataHash) &&
            (lhs.expiryMs == rhs.expiryMs) &&
            (lhs.extensions.sorted(by: { $0.type.rawValue < $1.type.rawValue }) == rhs.extensions.sorted(by: { $0.type.rawValue < $1.type.rawValue }))
    }
}

extension ATLeafData {
    var releaseType: ATReleaseType {
        for ext in self.extensions {
            switch ext {
            case .releaseType(_, var buffer):
                if let type = buffer.readInteger(as: UInt8.self),
                   let releaseType = ATReleaseType(rawValue: type) {
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
            case .insertionTimeMs(_, var buffer):
                return buffer.readInteger(as: UInt64.self)
            default:
                continue
            }
        }

        return nil
    }
}

enum ATReleaseType: UInt8 {
    case production = 0
    case seed = 1
}

extension ATReleaseType: CustomStringConvertible {
    var description: String {
        switch self {
        case .production: return "production"
        case .seed: return "seed"
        }
    }
}
