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
//  Config+Error.swift
//  darwinOSBits
//
//

import DarwinInitConfig

extension Config {

    /// An critical error will stop the application of the Config.
    enum CriticalError: Swift.Error {
        /// Executing a script in the start section failed.
        case startupScriptFailed(String)
    }
}

extension Config.CriticalError: CustomStringConvertible {

    var description: String {
        switch self {
        case .startupScriptFailed(let script):
            return "start script failed (\(script))"
        }
    }
}

extension Config {
    protocol Error {
        var code: Int { get }
        var description: String { get }
    }
}

/// Error type for cryptex configuration application failures.
///
/// This error type represents failures that occur during processing of the
/// cryptex section of a darwin-init config. It conforms to `Config.Error` to
/// integrate with the error reporting system (ErrorReporter).
///
/// ## Error Codes
/// Error codes are stable and should not be changed, as they may be used
/// for monitoring and alerting:
/// - 1: `failedToSetBandwidthLimit` - Network bandwidth limit setup failed
/// - 2: `failedToDepsolveCryptexes` - Dependency resolution failed (deprecated)
/// - 3: `downloadFailed` - Failed to download cryptex from remote URL
/// - 4: `extractionFailed` - Failed to extract cryptex archive
/// - 5: `personalizationFailed` - Failed to personalize cryptex with signing service
/// - 6: `ticketNotCreated` - Personalization did not produce expected ticket file
/// - 7: `installationFailed` - Failed to install personalized cryptex
/// - 8: `cacheAccessFailed` - Failed to access or retrieve cryptex from cache
/// - 9: `unexpectedError` - Unexpected errors that don't fit other categories
/// - 10: `circularDependency` - Circular dependency detected by BulkInstaller
/// - 11: `duplicateCryptexIdentifier` - Duplicate cryptex identifier in installation list
struct CryptexApplyError: Swift.Error, Config.Error {
    enum ErrorKind {
        case failedToSetBandwidthLimit
        case failedToDepsolveCryptexes // Deprecated: depsolvCryptexes() removed, use circularDependency
        case downloadFailed(identifier: String)
        case extractionFailed(identifier: String)
        case personalizationFailed(identifier: String)
        case ticketNotCreated(identifier: String)
        case installationFailed(identifier: String)
        case cacheAccessFailed(identifier: String)
        case unexpectedError(Error)
        case circularDependency(identifiers: [String])
        case duplicateCryptexIdentifier(identifier: String)
    }

    let kind: ErrorKind

    /// The underlying error that caused this cryptex error, if available.
    /// This preserves detailed error information (e.g., exit codes, stderr from NonZeroExit)
    /// for programmatic inspection while still providing a high-level categorization.
    let underlyingError: Error?

    /// Creates a CryptexApplyError with optional underlying error preservation.
    init(kind: ErrorKind, underlyingError: Error? = nil) {
        self.kind = kind
        self.underlyingError = underlyingError
    }

    var code: Int {
        switch kind {
        case .failedToSetBandwidthLimit:
            return 1
        case .failedToDepsolveCryptexes:
            return 2
        case .downloadFailed:
            return 3
        case .extractionFailed:
            return 4
        case .personalizationFailed:
            return 5
        case .ticketNotCreated:
            return 6
        case .installationFailed:
            return 7
        case .cacheAccessFailed:
            return 8
        case .unexpectedError:
            return 9
        case .circularDependency:
            return 10
        case .duplicateCryptexIdentifier:
            return 11
        }
    }

    var description: String {
        switch kind {
        case .failedToSetBandwidthLimit:
            return "Failed to set bandwidth limit for Mellanox interface. Will NOT download cryptexes."
        case .failedToDepsolveCryptexes:
            return "Failed to resolve cryptex dependencies (deprecated - use circularDependency)"
        case .downloadFailed(let identifier):
            return "Failed to download cryptex '\(identifier)'"
        case .extractionFailed(let identifier):
            return "Failed to extract cryptex '\(identifier)'"
        case .personalizationFailed(let identifier):
            return "Failed to personalize cryptex '\(identifier)'"
        case .ticketNotCreated(let identifier):
            return "Personalization of cryptex '\(identifier)' did not produce ticket file"
        case .installationFailed(let identifier):
            return "Failed to install cryptex '\(identifier)'"
        case .cacheAccessFailed(let identifier):
            return "Failed to access cached cryptex '\(identifier)'"
        case .unexpectedError(let error):
            return "Unexpected error: \(error.localizedDescription)"
        case .circularDependency(let identifiers):
            return "Circular dependency detected among cryptexes: \(identifiers.joined(separator: ", "))"
        case .duplicateCryptexIdentifier(let identifier):
            return "Duplicate cryptex identifier '\(identifier)' in installation list"
        }
    }

    /// Detailed description including underlying error information.
    var detailedDescription: String {
        var message = description

        if let underlying = underlyingError {
            if let nonZeroExit = underlying as? NonZeroExit {
                message += " (exit code: \(nonZeroExit.exitCode), stderr: \(nonZeroExit.error))"
            } else {
                message += " (underlying: \(underlying.localizedDescription))"
            }
        }

        return message
    }
}
