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

import Foundation
import Logging
import os.log

public struct OSLogHandler: LogHandler {
    /// logLevel is ignored by the handler because how log items are handled is decided by the underlying os log
    public var logLevel: Logging.Logger.Level = .debug
    let subsystem: String
    public var metadata = Logging.Logger.Metadata()
    private let osLogger: os.Logger

    /// Initialise a new os.Logger
    ///
    /// - Parameters:
    ///   - subsystem: oslog subsystem to use. `com.apple.cloudos.cloudboard` is configured to not
    ///   truncate messages by default
    ///   - category: oslog cateogry
    init(subsystem: String, category: String?) {
        self.subsystem = subsystem
        self.osLogger = os.Logger(subsystem: subsystem, category: category ?? "")
    }

    init(subsystem: String) {
        self.init(subsystem: subsystem, category: nil)
    }

    /// Create a new handler with the specified label for category
    /// - Parameter label: category label to use
    /// - Returns: new `OSLogHandler` with the current subsystem and the provided label for category
    func withCategory(_ label: String) -> OSLogHandler {
        OSLogHandler(subsystem: self.subsystem, category: label)
    }

    public func log(
        level: Logging.Logger.Level,
        message: Logging.Logger.Message,
        metadata messageMetadata: Logging.Logger.Metadata?,
        source _: String,
        file _: String,
        function _: String,
        line _: UInt
    ) {
        var metadata = metadata
        if let messageMetadata {
            for (key, value) in messageMetadata {
                metadata[key] = value
            }
        }

        let prettyMetadata: String? = Self.prettify(metadata)
        switch level {
        case .trace: self.osLogger
            .trace("ttl=\"\(message, privacy: .public)\"\(prettyMetadata.map { "\n\($0)" } ?? "", privacy: .public)")
        case let level: self.osLogger
            .log(
                level: level.asOSLogType(),
                "ttl=\"\(message, privacy: .public)\"\(prettyMetadata.map { "\n\($0)" } ?? "", privacy: .public)"
            )
        }
    }

    public subscript(metadataKey metadataKey: String) -> Logging.Logger.Metadata.Value? {
        get {
            self.metadata[metadataKey]
        }
        set {
            self.metadata[metadataKey] = newValue
        }
    }

    private static func prettify(_ metadata: Logging.Logger.Metadata, keyPrefix: String? = nil) -> String? {
        if metadata.isEmpty {
            return nil
        } else {
            return metadata.lazy.sorted(by: { $0.key < $1.key })
                .map { key, value in
                    switch value {
                    case .string(let value): return "\(keyPrefix ?? "")\(key)=\"\(value)\""
                    case .stringConvertible(let value): return "\(keyPrefix ?? "")\(key)=\"\(value)\""
                    case .dictionary(let metadata):
                        return self.prettify(metadata, keyPrefix: "\(key)_") ?? "\(keyPrefix ?? "")\(key)=\"\""
                    case .array(let value): return "\(keyPrefix ?? "")\(key)=\"\(value)\""
                    }
                }
                .joined(separator: "\n")
        }
    }
}

extension Logging.Logger.Level {
    func asOSLogType() -> OSLogType {
        switch self {
        case .trace: preconditionFailure("Trace logs should be handled directly") // trace is not exposed as OSLogType
        case .debug: return OSLogType.debug
        case .info: return OSLogType.info
        case .notice: return OSLogType.default
        case .warning: return OSLogType.default
        case .error: return OSLogType.error
        case .critical: return OSLogType.fault
        }
    }
}

extension Logging.Logger {
    public init(osLogSubsystem: String, osLogCategory: String, domain: String) {
        self.init(label: osLogCategory) { _ in
            var handler = OSLogHandler(
                subsystem: osLogSubsystem,
                category: osLogCategory
            )
            handler.metadata["activity"] = .string(domain)
            return handler
        }
    }
}
