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
//  SplunkloggingdConfigWriter.swift
//  SplunkloggingdConfigWriter
//
//  Created by Marco Magdy on 03/05/2024
//
// The config writer generates the config file which is used by splunkloggingd.
//
// The config writer first uses CFPrefs to retrieve the preferences
// It stores these in the file at the given output path.
//
// The file contains the predicates which are used by splunkloggingd
// for filtering log messages.
//
// The config writer then subscribes to any changes to the predicates
// using FastConfig. If there is any update in the predicates, it
// overrides the predicates in the output file with the latest ones
// received from FastConfig.
//
// If the FastConfig property is subsequently removed, the config
// writer will revert back to the CFPrefs predicates.

import Foundation
import OSLog
#if canImport(cloudOSInfo)
@_weakLinked import cloudOSInfo
#endif
#if canImport(CloudConfigurationPreferences)
@_weakLinked import CloudConfigurationPreferences
#endif

internal let kDomain = "com.apple.prcos.splunkloggingd"

private let logger = Logger(subsystem: "SplunkloggingdConfigWriter", category: "")

internal struct SplunkLoggingdHotProperties: Decodable, Sendable, Hashable {
    /// This must match the name used in the upstream configuration service.
    static let domain: String = "com.apple.cloudos.hotproperties.splunkloggingd"

    public var predicates: [String]?
}

@main
class SplunkloggingdConfigWriter {
    static func main() async throws {
        // Hop off the main actor
        try await run()
    }

    static func run() async throws {
        // First command line argument is the path to the output configuration file
        if CommandLine.argc < 2 {
            logger.error("Usage: SplunkloggingdConfigWriter <output file>")
            exit(1)
        }

        if CommandLine.argc == 3 {
            let prismOutputFile = CommandLine.arguments[2]
            logger.info("Will write a Prism config file at \(CommandLine.arguments[2])")

            // If a second argument is provided, read the Prism config
            if let prismConfig = readPrismConfig() {
                writeOutputFile(config: prismConfig, prismOutputFile)
                logger.info("Prism configuration written to \(prismOutputFile, privacy: .public)")
            }
            else {
                // missing prism configuration is not a fatal error.
                logger.error("Failed to read Prism configuration. No files will be written.")
            }
        }

        let outputFile = CommandLine.arguments[1]
        // Get the static configuration from CFPrefs.
        guard let config = readConfig() else {
            logger.error("Failed to read configuration. No files will be written.")
            exit(1)
        }
        // Create config file using CFPrefs.
        if (!FileManager.default.fileExists(atPath: outputFile)) {
            writeOutputFile(config: config, outputFile)
        }

        try await Self.listenToHotProperties(config: config, outputFile: outputFile)
    }

    // Check that CloudConfigurationPreferences and cloudOSInfo are in the SDK (will pass for macOS and fail for BMC)
    #if canImport(CloudConfigurationPreferences) && canImport(cloudOSInfo)
    private static func listenToHotProperties(config: SplunkloggingdConfiguration, outputFile: String) async throws {
        guard #_hasSymbol(CloudConfigurationPreferences.PreferencesVersionInfo.self) else {
            logger.fault("CloudConfigurationPreferences not available")
            return
        }

        guard #_hasSymbol(CloudOSInfoProvider.self) else {
            logger.fault("CloudOSInfoProvider not available")
            return
        }

        let cloudOSInfoProvider = CloudOSInfoProvider()
        do {
            guard try cloudOSInfoProvider.cloudOSReleaseType().lowercased().starts(with: "private cloudos") else {
                logger.log("Release type is not Private cloudOS. Exiting.")
                return
            }
        } catch {
            logger.error("Failed to get release type: \(error)")
            throw error
        }

        logger.log("Release type is Private cloudOS. Attempting to listen to hot properties.")

        // Store predicates from CFPrefs as fallback
        let staticPredicates = config.predicates

        // Listen for predicate changes from FastConfig
        // Will retry 10 times if the Preference Framework
        // Async Stream throws
        for attemptCount in 1...10 {
            let preferencesUpdates = PreferencesUpdates(
                preferencesDomain: SplunkLoggingdHotProperties.domain,
                maximumUpdateDuration: .seconds(1),
                forType: SplunkLoggingdHotProperties.self
            )
            do {
                for try await update in preferencesUpdates {
                    await update.applyingPreferences { newPreference in
                        if let newPredicates = newPreference.predicates {
                            logger.log("""
                                Received predicates from hot properties. \
                                \(newPredicates, privacy: .public)
                                """)
                            config.predicates = newPredicates
                        } else {
                            logger.log("""
                                No hot properties set. Reverting to CFPrefs predicates. \
                                static_predicates=\(staticPredicates, privacy: .public)
                                """)
                            config.predicates = staticPredicates
                        }
                        writeOutputFile(config: config, outputFile)
                    }
                }
            } catch {
                logger.error("""
                    Preferences framework closed stream. \
                    error=\(String(reportable: error)).
                    """)
                if attemptCount < 10 {
                    logger.log("Will retry listening FastConfig updates in 60 seconds")
                    try await Task.sleep(for: .seconds(60))
                }
                else {
                    logger.error("Ran out of retries to subscribe to FastConfig. Exiting")
                    exit(1)
                }
            }
        }
    }
    #else
    private static func listenToHotProperties(config: SplunkloggingdConfiguration, outputFile: String) async throws {
        logger.log("Not built for Private cloudOS. Skipping listening to hot properties.")
    }
    #endif
}

private func writeOutputFile(config: SplunkloggingdConfiguration, _ path: String) {
    let url = URL(fileURLWithPath: path)
    // Create the directory if it doesn't exist
    let directory = url.deletingLastPathComponent()
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
    } catch {
        logger.error("""
            Failed to create directory. \
            directory_path=\(directory.path) \
            error=\(String(reportable: error), privacy: .public)
            """)
        exit(1)
    }

    do {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let data = try encoder.encode(config)
        try data.write(to: url)
    } catch {
        logger.error("""
            Failed to write configuration to file. \
            error=\(String(reportable: error), privacy: .public)
            """)
        exit(1)
    }
    logger.log("Configuration written. path=\(url.path, privacy: .public)")
}

private func readConfig() -> SplunkloggingdConfiguration? {
    let result = SplunkloggingdConfiguration()
    // Read the server name
    let server = CFPreferencesCopyValue("Server" as CFString, kDomain as CFString, kCFPreferencesAnyUser, kCFPreferencesAnyHost)
    guard server != nil else {
        logger.error("Failed to read server from configuration. server is nil.")
        return nil
    }

    guard let server = server as? String else {
        logger.error("Failed to read server from configuration. server is not a string.")
        return nil
    }
    result.server = server

    // Read the index name
    let indexName = CFPreferencesCopyValue("Index" as CFString, kDomain as CFString, kCFPreferencesAnyUser, kCFPreferencesAnyHost)
    guard indexName != nil else {
        logger.error("Failed to read index from configuration. index is nil.")
        return nil
    }

    guard let indexName = indexName as? String else {
        logger.error("Failed to read index from configuration. index is not a string.")
        return nil
    }
    result.indexName = indexName

    // Read the token
    let token = CFPreferencesCopyValue("Token" as CFString, kDomain as CFString, kCFPreferencesAnyUser, kCFPreferencesAnyHost)
    if let token = token as? String {
        result.token = token
    }

    // Read the buffer size
    let bufferSize = CFPreferencesCopyValue("BufferSize" as CFString, kDomain as CFString, kCFPreferencesAnyUser, kCFPreferencesAnyHost)
    if bufferSize != nil {
        guard let bufferSize = bufferSize as? NSNumber else {
            logger.error("Failed to read buffer size from configuration. bufferSize is not a number.")
            return nil
        }
        result.bufferSize = Int64(truncating: bufferSize)
    }

    // Read the predicates array
    let predicates = CFPreferencesCopyValue("Predicates" as CFString, kDomain as CFString, kCFPreferencesAnyUser, kCFPreferencesAnyHost)
    guard predicates != nil else {
        logger.error("Failed to read predicates from configuration. predicates is nil.")
        return nil
    }
    guard let predicates = predicates as? [Any] else {
        logger.error("Failed to read predicates from configuration. predicates is not an array.")
        return nil
    }

    // Check that all elements in the array are strings
    for predicate in predicates {
        guard predicate is String else {
            logger.error("Failed to read predicates from configuration. One of the elements is not a string.")
            return nil
        }
    }

    result.predicates = predicates as! [String]
    result.observabilityLabels = readObservabilityLabels()

    return result
}

private func readPrismConfig() -> SplunkloggingdConfiguration? {
    let result = SplunkloggingdConfiguration()
    // Read the server name
    let server = CFPreferencesCopyValue("PrismServer" as CFString, kDomain as CFString, kCFPreferencesAnyUser, kCFPreferencesAnyHost)
    guard server != nil else {
        logger.error("Failed to read Prism server from configuration. server is nil.")
        return nil
    }

    guard let server = server as? String else {
        logger.error("Failed to read Prism server from configuration. server is not a string.")
        return nil
    }
    result.server = server
    // Read the index name
    let indexName = CFPreferencesCopyValue("PrismIndex" as CFString, kDomain as CFString, kCFPreferencesAnyUser,
                                           kCFPreferencesAnyHost)
    guard indexName != nil else {
        logger.error("Failed to read Prism index from configuration. index is nil.")
        return nil
    }
    guard let indexName = indexName as? String else {
        logger.error("Failed to read Prism index from configuration. index is not a string.")
        return nil
    }
    result.indexName = indexName
    // Read buffer size
    let bufferSize = CFPreferencesCopyValue("PrismBufferSize" as CFString, kDomain as CFString, kCFPreferencesAnyUser,
                                            kCFPreferencesAnyHost)
    if bufferSize != nil {
        guard let bufferSize = bufferSize as? NSNumber else {
            logger.error("Failed to read Prism buffer size from configuration. bufferSize is not a number.")
            return nil
        }
        result.bufferSize = Int64(truncating: bufferSize)
    }
    // Read the predicates array
    let predicates = CFPreferencesCopyValue("PrismPredicates" as CFString, kDomain as CFString, kCFPreferencesAnyUser,
                                            kCFPreferencesAnyHost)
    guard predicates != nil else {
        logger.error("Failed to read Prism predicates from configuration. predicates is nil.")
        return nil
    }
    guard let predicates = predicates as? [Any] else {
        logger.error("Failed to read Prism predicates from configuration. predicates is not an array.")
        return nil
    }
    // Check that all elements in the array are strings
    for predicate in predicates {
        guard predicate is String else {
            logger.error("Failed to read Prism predicates from configuration. One of the elements is not a string.")
            return nil
        }
    }

    result.predicates = predicates as! [String]
    result.observabilityLabels = readObservabilityLabels()

    return result
}

private func readObservabilityLabels() -> [String: String]? {
    var observabilityLabels: [String: String]?

    #if canImport(cloudOSInfo)
    guard #_hasSymbol(CloudOSInfoProvider.self) else {
        logger.error("CloudOSInfoProvider not available. Proceeding without any labels.")
        return observabilityLabels
    }

    let cloudOSInfoProvider = CloudOSInfoProvider()
    do {
        observabilityLabels = try cloudOSInfoProvider.observabilityLabels()
    } catch {
        logger.warning("Failed to read observability labels. Proceeding without any labels.")
    }
    #endif

    return observabilityLabels
}

internal class SplunkloggingdConfiguration: Encodable {
    var server: String = ""
    var indexName: String = ""
    var token: String?
    var predicates: [String] = []
    var bufferSize: Int64?
    var observabilityLabels: [String: String]?

    // serialize with PascalCase
    enum CodingKeys: String, CodingKey {
        case server = "Server"
        case indexName = "Index"
        case predicates = "Predicates"
        case bufferSize = "BufferSize"
        case token = "Token"
        case observabilityLabels = "GlobalLabels"
    }
}

fileprivate protocol ReportableError {
    /// Description of the error that can safely be logged or emitted as a metric dimension in
    /// production and is guaranteed to not contain privacy-sensitive information
    var publicDescription: String { get }
}

fileprivate extension String {
    /// Converts an error to a string that is suitable to be included in privacy-preserving logging.
    /// If the type conforms to ``ReportableError`` the ``ReportableError/publicDescription`` is used.
    /// Otherwise the name of error type is used.
    init(reportable error: Error) {
        if let reportableError = error as? ReportableError {
            self = reportableError.publicDescription
        } else {
            self = String(describing: type(of: error))
        }
    }
}
