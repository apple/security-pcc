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
//  Configuration.swift
//  splunkloggingd
//
//  Copyright © 2024 Apple, Inc.  All rights reserved.
//

/*
 ************************ Expected config file format ************************
 * Note: all keys are optional, though without some (like "Server")
 * splunkloggingd is unlikely to do anything useful.  Most have default values,
 * specified as kDefault* within the Configuration object below.
 * {
 * 	   "Server": String (URL to send logs, like "http://192.168.128.181:8088")
 * 	   "Index": String
 * 	   "Level": String, one of Default, Info, Debug
 * 	   "Timeout": Double
 * 	   "Token": UUID
 * 	   "BufferSize": Int
 * 	   "BufferCount": Int
 * 	   "Predicates": [String], all predicates combined as "(p1) OR (p2)..."
 * }
 */

import Foundation
import LoggingSupport
import os

fileprivate let log = Logger(subsystem: sharedSubsystem, category: "Configuration")

enum LogLevel: String, Codable, CustomStringConvertible {
    case `default` = "Default"
    case info = "Info"
    case debug = "Debug"
    enum CodingKeys: String, CodingKey {
        case `default` = "Default"
        case info = "Info"
        case debug = "Debug"
    }
    var description: String { self.rawValue }
}

protocol ConfigurationMonitorDelegate: AnyObject, Sendable {
    func configDidChange(_ config: Configuration) async
}

struct Configuration: Codable, Equatable, Sendable {
    // Unfortunately a decoder cannot use default values for missing properties; a missing property will translate to nil
    // To get around this we need to manually decodeIfPresent the key and assign the default value.
    // We want the same defaults used when constructing a Config obj in code via init(), so define them as constants here.
    static let kDefaultIndex: String = "acdc"
    static let kDefaultTimeout: Double = 30.0
    static let kDefaultBufferSize: Int = 256 * 1024
    static let kDefaultBufferCount: Int = 2
    static let kDefaultLevel: LogLevel = .default
    static let kDefaultPredicates: [String] = []
    static let kDefaultGlobalLabels: [String:String] = [:]
    static let kDefaultForwardPanicReports: Bool = true
    static let kDefaultForwardCrashReports: Bool = true

    /// The URL of the Splunk HEC
    // Decoding a URL from a plist is a mess that requires a nested dict and would break backwards compatibility.
    // Instead use a string and manually convert to URL
    private var serverString: String?
    var serverURL: URL?

    /// The Splunk Index
    var index: String = kDefaultIndex
    /// The Splunk HEC Token (talk to your Splunk Admin)
    var token: UUID?
    /// Amount of time to wait (in seconds) before a partially filled buffer is offloaded
    var timeout: Double = kDefaultTimeout
    /// Size of an individual buffer in bytes
    var bufferSize: Int = kDefaultBufferSize
    /// Number of buffers
    var bufferCount: Int = kDefaultBufferCount
    /// Log level to stream for
    var level: LogLevel = kDefaultLevel
    /// Predicates to stream for
    var predicates: [String] = kDefaultPredicates
    /// Set of arbitrary k:v labels to be attached to every message payload
    var globalLabels: [String: String] = kDefaultGlobalLabels

    // Whether crashes and panics should be forwarded by the daemon
    var forwardCrashReports: Bool = kDefaultForwardCrashReports
    var forwardPanicReports: Bool = kDefaultForwardPanicReports

    enum CodingKeys: String, CodingKey {
        case serverString = "Server"
        case index = "Index"
        case token = "Token"
        case timeout = "Timeout"
        case bufferSize = "BufferSize"
        case bufferCount = "BufferCount"
        case level = "Level"
        case predicates = "Predicates"
        case globalLabels = "GlobalLabels"
        case forwardCrashReports = "ForwardCrashReports"
        case forwardPanicReports = "ForwardPanicReports"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Properties with default values
        self.index = try container.decodeIfPresent(String.self, forKey: .index) ?? Self.kDefaultIndex
        self.timeout = try container.decodeIfPresent(Double.self, forKey: .timeout) ?? Self.kDefaultTimeout
        self.bufferSize = try container.decodeIfPresent(Int.self, forKey: .bufferSize) ?? Self.kDefaultBufferSize
        self.bufferCount = try container.decodeIfPresent(Int.self, forKey: .bufferCount) ?? Self.kDefaultBufferCount
        self.level = try container.decodeIfPresent(LogLevel.self, forKey: .level) ?? Self.kDefaultLevel
        self.globalLabels = try container.decodeIfPresent([String:String].self, forKey: .globalLabels) ??  Self.kDefaultGlobalLabels
        self.predicates = try container.decodeIfPresent([String].self, forKey: .predicates) ?? Self.kDefaultPredicates
        self.forwardCrashReports = try container.decodeIfPresent(Bool.self, forKey: .forwardCrashReports) ?? Self.kDefaultForwardCrashReports
        self.forwardPanicReports = try container.decodeIfPresent(Bool.self, forKey: .forwardPanicReports) ?? Self.kDefaultForwardPanicReports

        try validatePredicates(self.predicates)

        // Optional properties
        self.token = try container.decodeIfPresent(UUID.self, forKey: .token)

        self.serverString = try container.decodeIfPresent(String.self, forKey: .serverString)
        if let serverString = self.serverString {
            self.serverURL = URL(string: serverString)
        }
    }

    init(fromPath path: URL) throws {
        let decoder = PropertyListDecoder()
        var data: Data
        do {
            data = try Data(contentsOf: path)
        } catch {
            log.error("Failed to read config with error \(error, privacy: .public)")
            throw error
        }

        do {
            self = try decoder.decode(Configuration.self, from: data)
        } catch {
            log.error("Failed to decode config with error \(error, privacy: .public)")
            throw error
        }
    }

    init() {}

    // Don't want to implement "description", as we have mixed privacy in the log message
    func logNewConfig() {
        log.log("""
Got new config:
ServerURL: \(String(describing: serverURL), privacy: .public)
Index: \(index, privacy: .public)
Token provided: \(token != nil)
Token: \(String(describing: token), privacy: .sensitive)
Timeout: \(timeout)
BufferSize: \(bufferSize)
BufferCount: \(bufferCount)
Level: \(level, privacy: .public)
ForwardCrashes: \(forwardCrashReports)
ForwardPanics: \(forwardPanicReports)
""")
        log.log("Predicates: \(String(describing: predicates), privacy: .public)")
        log.log("GlobalLabels: \(String(describing: globalLabels), privacy: .public)")
    }

    private func validatePredicates(_ predicates: [String]) throws {
        for pred in predicates {
            let pred = pred.lowercased()

            // Test daemon should be able to stream the test runner
            if pred.contains("splunkloggingdtests") || pred.contains("com.apple.splunkloggingd.test_emitter"){
                continue
            }

            // Nothing should be able to ask splunkloggingd to stream itself
            if pred.contains("splunkloggingd") {
                log.error("Found invalid predicate with string 'splunkloggingd': \(pred, privacy: .public)")
                throw SplunkloggingdError.invalidPredicate("Predicate contains disallowed string 'splunkloggingd': \(pred)")
            }
        }
    }
}

/// Read configuration for splunkloggingd
/// Accept a plist URL to read from and monitor for changes.
actor ConfigurationMonitor: FileMonitorDelegate {
    weak var delegate: ConfigurationMonitorDelegate?
    private let configPlistMonitor: FileMonitor

    func read() async {
        guard let config = try? Configuration(fromPath: self.configPlistMonitor.url) else {
            return
        }

        config.logNewConfig()
        await self.delegate?.configDidChange(config)
    }

    init(at path: URL) async {
        log.log("Creating config monitor at \(path.path(), privacy: .public)")
        self.configPlistMonitor = .init(url: path)
        await self.configPlistMonitor.setDelegate(self)
        await self.configPlistMonitor.startMonitoring()
    }

    func setDelegate(_ newDelegate: ConfigurationMonitorDelegate) async {
        self.delegate = newDelegate
    }

    func stopMonitoring() async {
        await self.configPlistMonitor.stopMonitoring()
    }

    func didObserveChange(FileMonitor monitor: FileMonitor) {
        log.info("\(#function, privacy: .public)")
        Task { await self.read() }
    }

    func didStartMonitoring(FileMonitor: FileMonitor) {
        log.info("\(#function, privacy: .public)")
    }

    func didStopMonitoring(FileMonitor: FileMonitor) {
        log.info("\(#function, privacy: .public)")
    }
}
