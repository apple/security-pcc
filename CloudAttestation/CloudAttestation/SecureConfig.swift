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

import Foundation
import CryptoKit
@_weakLinked import SecureConfigDB

/// A representation of a `SecureConfigDB` entry.
public struct SecureConfig: Sendable {

    /// The raw entry data
    public let entry: Data

    /// The entry metadata
    public let metadata: [String: String]

    /// The serialized JSON data
    public let serializedData: Data

    /// Convenience getter `mime_type` from ``metadata``
    public var mimeType: String? {
        self.metadata["mime_type"]
    }

    /// Convenience getter for `name` from ``metadata``
    public var name: String? {
        self.metadata["name"]
    }

    public var rawMetadata: Data {
        // serializedData already validated during initialization
        let splits = serializedData.split(separator: "\n".first!.asciiValue!, maxSplits: 2)
        return splits[0]
    }

    /// Creates a new `SecureConfig` from a serialized string.
    /// - Parameter serialized: The serialized string.
    /// - Returns nil if the string is not a valid ``SecureConfig``
    public init?(from serialized: Data) {
        let splits = serialized.split(separator: "\n".first!.asciiValue!, maxSplits: 2)
        guard splits.count == 2 else {
            return nil
        }
        let (header, entry) = (splits[0], splits[1])
        let decoder = JSONDecoder()
        guard let metadata = try? decoder.decode([String: String].self, from: header) else {
            return nil
        }
        self.serializedData = serialized
        self.entry = entry
        self.metadata = metadata
    }

    /// Creates a new `SecureConfig`.
    /// - Parameters:
    ///   - entry: The entry data.
    ///   - metadata: The metadata.
    @available(iOS, deprecated: 18.4, message: "reconstruction of parsed metadata is unreliable")
    @available(macOS, deprecated: 15.4, message: "reconstruction of parsed metadata is unreliable")
    public init(entry: Data, metadata: [String: String]) {
        self.init(entry: entry, unreliableMetadata: metadata)
    }

    internal init(entry: Data, unreliableMetadata metadata: [String: String]) {
        self.entry = entry
        self.metadata = metadata
        // [String: String] will never fail to encode
        self.serializedData = try! JSONSerialization.data(withJSONObject: metadata, options: .sortedKeys) + "\n".utf8 + entry
    }

    init?(entry: Data, rawMetadata: Data) {
        self.init(from: rawMetadata + "\n".utf8 + entry)
    }
}

// MARK: - Helpers

extension Proto_AttestationBundle {
    var secureConfigHashFunction: (any HashFunction.Type)? {
        guard let slot = self.sealedHashes.slots[SecureConfigPolicy.slot.uuidString] else {
            return nil
        }

        return slot.hashAlg.hashFunction
    }

    var secureConfigs: [SecureConfig]? {
        guard let slot = self.sealedHashes.slots[SecureConfigPolicy.slot.uuidString] else {
            return nil
        }

        let configs = slot.entries.compactMap { slotEntry -> SecureConfig? in
            guard case let .secureConfig(sconf) = slotEntry.info else {
                return nil
            }
            if sconf.data.isEmpty {
                // Deprecated, only for use with original PCC
                return SecureConfig(entry: sconf.entry, unreliableMetadata: sconf.metadata)
            }
            return SecureConfig(from: sconf.data)
        }

        guard configs.count == slot.entries.count else {
            return nil
        }

        return configs
    }
}

extension Array where Self.Element == SecureConfig {
    func replaySealedHash(with hash: any HashFunction.Type = SHA384.self) throws -> SEP.SealedHash.Value {
        try SEP.SealedHash(ratchet: self.map { Data(hash.hash(data: $0.serializedData)) }).value
    }
}

extension Collection where Self.Element == SecureConfig {
    var darwinInit: DarwinInit {
        get throws {
            let darwinInits = self.filter { config in
                config.name == "darwin-init" && config.mimeType == "application/json"
            }

            guard let darwinInitConfig = darwinInits.first else {
                throw DarwinInit.Error.missingDarwinInit
            }

            guard darwinInits.count == 1 else {
                throw DarwinInit.Error.tooManyDarwinInit
            }

            return try DarwinInit(from: darwinInitConfig)
        }
    }
}
