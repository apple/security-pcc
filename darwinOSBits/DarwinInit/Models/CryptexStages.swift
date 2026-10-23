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
//  CryptexStages.swift
//  darwinOSBits
//
//

import CryptexKit
import DarwinInitConfig
import Foundation
import System

/// Result of downloading a cryptex from a remote source.
struct DownloadedCryptex {
    let config: CryptexConfig
    let path: FilePath
    let aeaDecryptionParameters: AEADecryptionParameters?

    /// Extracts the downloaded cryptex archive.
    ///
    /// - Returns: An ExtractedCryptex ready for personalization
    /// - Throws: CryptexApplyError if extraction fails
    func extract() async throws -> ExtractedCryptex {
        let extractedPath: FilePath
        do {
            extractedPath = try CryptexManager.setUpExtractedPath()
            try path.extract(to: extractedPath, using: aeaDecryptionParameters)
        } catch let error as CryptexApplyError {
            throw error
        } catch {
            logger.error("Failed to extract cryptex: \(error.localizedDescription)")
            throw CryptexApplyError(kind: .extractionFailed(identifier: config.identifier), underlyingError: error)
        }

        return ExtractedCryptex(config: config, path: extractedPath)
    }
}

/// Result of extracting a cryptex archive to disk.
struct ExtractedCryptex {
    let config: CryptexConfig
    let path: FilePath
    let ticketPath: FilePath?

    init(config: CryptexConfig, path: FilePath, ticketPath: FilePath? = nil) {
        self.config = config
        self.path = path
        self.ticketPath = ticketPath
    }

    /// Personalizes the cryptex using CryptexKit.
    ///
    /// Loads the cryptex bundle, reads device identity, and personalizes the cryptex for this device.
    /// Optionally writes ticket and GINF files for caching purposes.
    ///
    /// - Parameters:
    ///   - diavloServerURL: The Diavlo server URL to use if signing environment is .diavlo
    ///   - appleConnect: Whether to use Apple Connect SSO
    ///   - ginfPath: Optional path to write GINF file
    /// - Returns: A PersonalizedCryptex containing the personalized Cryptex actor and device
    /// - Throws: CryptexApplyError if personalization fails
    func personalize(
        diavloServerURL: String?,
        appleConnect: Bool,
        ginfPath: FilePath? = nil
    ) async throws -> PersonalizedCryptex {
        do {
            let bundle = try CryptexBundle(path: path)
            let device = CryptexLocalDevice()
            let identity = try await device.readIdentity()

            guard let cryptexObject = try await bundle.getCryptex(
                matching: identity,
                variant: config.config.variant
            ) else {
                throw CryptexError.cryptexNotFound
            }

            let server = config.personalizationServer(diavloServerURL: diavloServerURL)
            var options = Cryptex.PersonalizeOptions()
            options.sso = appleConnect
            options.server = server

            try await cryptexObject.personalize(for: device, options: options)
            logger.log("Successfully personalized cryptex \(config.identifier)")

            let personalized = PersonalizedCryptex(
                config: config,
                cryptexObject: cryptexObject,
                device: device,
                personalizationServer: server)

            if let ticketPath = self.ticketPath {
                try await personalized.writeManifest(to: ticketPath)
            }

            if let ginfPath = ginfPath {
                try await personalized.writeInfoPlist(to: ginfPath)
            }

            return personalized

        } catch let error as CryptexError {
            logger.error(
                "Failed to personalize cryptex \(config.identifier): \(String(describing: error))"
            )
            throw CryptexApplyError(
                kind: .personalizationFailed(identifier: config.identifier),
                underlyingError: error
            )
        } catch {
            logger.error(
                """
                Failed to personalize cryptex \(config.identifier) with unexpected error: \
                \(error.localizedDescription)
                """
            )
            throw CryptexApplyError(
                kind: .personalizationFailed(identifier: config.identifier),
                underlyingError: error
            )
        }
    }
}

/// Result of personalizing a cryptex for the local device.
///
/// Contains the CryptexKit Cryptex actor with personalized state and the device for installation.
struct PersonalizedCryptex {
    let config: CryptexConfig
    let cryptexObject: Cryptex
    let device: CryptexLocalDevice
    /// The personalization server used during personalization.
    let personalizationServer: CryptexPersonalizationService?

    /// Writes the personalized manifest to disk (for caching purposes).
    func writeManifest(to ticketPath: FilePath) async throws {
        let parentDir = ticketPath.removingLastComponent()
        try parentDir.createDirectory(intermediateDirectories: true)
        try ticketPath.createFile()
        try await cryptexObject.writePersonalizedManifest(to: ticketPath)
    }

    /// Writes the info plist to disk (for caching purposes).
    func writeInfoPlist(to ginfPath: FilePath) async throws {
        let parentDir = ginfPath.removingLastComponent()
        try parentDir.createDirectory(intermediateDirectories: true)
        try ginfPath.createFile()
        try await cryptexObject.writeInfoPlist(to: ginfPath)
    }

    /// Convert to CryptexBulkInstallBundle for bulk installation.
    ///
    /// - Parameters:
    ///   - limitLoadToREM: Whether to limit job loading to Restricted Execution Mode
    ///   - additionalDependencies: Additional dependencies beyond those in cryptex Info.plist
    /// - Returns: A CryptexBulkInstallBundle ready for bulk installation
    func toBulkInstallBundle(
        limitLoadToREM: Bool,
        additionalDependencies: [CryptexDependency] = []
    ) -> CryptexBulkInstallBundle {
        var options = Cryptex.InstallOptions()
        options.limitJobsToRestrictedExecMode = limitLoadToREM
        options.readWrite = config.config.readwrite ?? false
        options.ephemeral = true
        options.server = personalizationServer
        options.jetsamPropertiesVariant = config.config.jetsamPropertiesVariant

        return CryptexBulkInstallBundle(
            cryptex: self.cryptexObject,
            installOptions: options,
            additionalDependencies: additionalDependencies
        )
    }
}

// MARK: - Bulk Installation

extension Array where Element == PersonalizedCryptex {
    /// Performs bulk installation of personalized cryptexes using CryptexBulkInstaller.
    ///
    /// - Parameters:
    ///   - limitLoadToREM: Whether to limit job loading to Restricted Execution Mode
    ///   - cryptexes: Original cryptex configuration dictionary for error reporting
    ///   - reporter: Error reporter for tracking failures
    ///   - cryptexesPointer: JSON pointer to cryptexes section for error location
    /// - Returns: Array of successfully installed CryptexConfig. Returns partial results
    ///            if some cryptexes succeed before a failure.
    /// - Throws: CryptexApplyError for circular dependencies or duplicate identifiers.
    func bulkInstall(
        limitLoadToREM: Bool,
        cryptexes: [String: Config.Cryptex.Cryptex],
        reporter: ErrorReporter,
        cryptexesPointer: JSONPointer
    ) async throws -> [CryptexConfig] {
        logger.info("Installing \(self.count) cryptexes using BulkInstaller")

        let bulkInstaller = await prepareBulkInstaller(limitLoadToREM: limitLoadToREM)

        let installResult = try await executeInstallation(
            bulkInstaller: bulkInstaller,
            reporter: reporter,
            cryptexesPointer: cryptexesPointer
        )

        let identifierMap = await buildIdentifierMap()
        let applied = processSuccessfulInstallations(
            installResult: installResult,
            identifierMap: identifierMap
        )

        if let failed = installResult.failed {
            handleInstallationFailure(
                failed: failed,
                identifierMap: identifierMap,
                reporter: reporter,
                cryptexesPointer: cryptexesPointer,
                installResult: installResult
            )
            return applied
        }

        logger.info("Successfully installed \(applied.count) cryptexes")
        return applied
    }

    // MARK: - Private Helper Functions

    /// Prepares the CryptexBulkInstaller with all valid cryptexes.
    private func prepareBulkInstaller(limitLoadToREM: Bool) async -> CryptexBulkInstaller {
        let bulkInstaller = CryptexBulkInstaller()

        for item in self {
            // Skip cryptexes without identifiers - they can't be installed
            guard await item.cryptexObject.identifier != nil else {
                logger.error("Skipping cryptex with nil identifier during bulk installation preparation")
                continue
            }

            let additionalDependencies: [CryptexDependency] = (item.config.config.dependencies ?? []).map {
                CryptexDependency(identifier: $0)
            }
            let bundle = item.toBulkInstallBundle(
                limitLoadToREM: limitLoadToREM,
                additionalDependencies: additionalDependencies
            )
            await bulkInstaller.append(bundle)
        }

        let identifiers = await self.asyncSerialMap { await $0.cryptexObject.identifier }
        logger.info("""
            Prepared \(self.count) cryptexes for bulk installation:
            - Identifiers: \(identifiers.compactMap { $0 }.joined(separator: ", "))
            - Boot mode: \(limitLoadToREM ? "REM" : "Normal")
            """)

        return bulkInstaller
    }

    /// Executes the bulk installation and handles errors.
    private func executeInstallation(
        bulkInstaller: CryptexBulkInstaller,
        reporter: ErrorReporter,
        cryptexesPointer: JSONPointer
    ) async throws -> InstallationResult {
        do {
            let device = CryptexLocalDevice()
            return try await bulkInstaller.install(onto: device)
        } catch let error as BulkInstallerError {
            return try handleBulkInstallerError(
                error,
                reporter: reporter,
                cryptexesPointer: cryptexesPointer
            )
        } catch {
            logger.error("Unexpected bulk installation error: \(error)")
            let err = CryptexApplyError(
                kind: .unexpectedError(error),
                underlyingError: error
            )
            reporter.report(err, at: cryptexesPointer)
            throw err
        }
    }

    /// Handles specific BulkInstallerError cases.
    private func handleBulkInstallerError(
        _ error: BulkInstallerError,
        reporter: ErrorReporter,
        cryptexesPointer: JSONPointer
    ) throws -> InstallationResult {
        switch error {
        case .installationFailed(let result):
            // Partial failure - return the result for processing
            return result

        case .circularDependency(let ids):
            logger.error("Circular dependency detected among cryptexes: \(ids.joined(separator: ", "))")
            let err = CryptexApplyError(
                kind: .circularDependency(identifiers: ids.sorted()),
                underlyingError: error
            )
            reporter.report(err, at: cryptexesPointer)
            throw err

        case .duplicateCryptexIdentifier(let id):
            logger.error("Duplicate cryptex identifier in installation list: \(id)")
            let err = CryptexApplyError(
                kind: .duplicateCryptexIdentifier(identifier: id),
                underlyingError: error
            )
            reporter.report(err, at: cryptexesPointer)
            throw err

        @unknown default:
            logger.error("Unknown BulkInstaller error: \(error)")
            let err = CryptexApplyError(
                kind: .unexpectedError(error),
                underlyingError: error
            )
            reporter.report(err, at: cryptexesPointer)
            throw err
        }
    }

    /// Builds a map of identifiers to PersonalizedCryptex
    private func buildIdentifierMap() async -> [String: PersonalizedCryptex] {
        var identifierToPersonalizedMap: [String: PersonalizedCryptex] = [:]
        for item in self {
            if let identifier = await item.cryptexObject.identifier {
                identifierToPersonalizedMap[identifier] = item
            }
        }
        return identifierToPersonalizedMap
    }

    /// Processes successful installations and builds the applied list.
    private func processSuccessfulInstallations(
        installResult: InstallationResult,
        identifierMap: [String: PersonalizedCryptex]
    ) -> [CryptexConfig] {
        var applied: [CryptexConfig] = []
        for record in installResult.succeeded {
            if let personalizedCryptex = identifierMap[record.identifier] {
                applied.append(personalizedCryptex.config)
            } else {
                logger.critical(
                    """
                    Internal consistency error: BulkInstaller succeeded for '\(record.identifier)' \
                    but no matching PersonalizedCryptex found in our records. \
                    This should never happen and indicates a serious bug.
                    """
                )
            }
        }
        return applied
    }

    /// Handles installation failures by logging details and reporting errors.
    private func handleInstallationFailure(
        failed: (record: InstallationRecord, error: Error),
        identifierMap: [String: PersonalizedCryptex],
        reporter: ErrorReporter,
        cryptexesPointer: JSONPointer,
        installResult: InstallationResult
    ) {
        // The BulkInstaller reports failures using the cryptex identifier (e.g., "com.apple.foo").
        // Use the identifierMap to find the PersonalizedCryptex which holds the original config.
        guard let personalizedCryptex = identifierMap[failed.record.identifier] else {
            logger.critical(
                """
                Internal consistency error: cryptex '\(failed.record.identifier)' \
                not found in identifier map
                """
            )
            let err = CryptexApplyError(
                kind: .installationFailed(identifier: failed.record.identifier),
                underlyingError: failed.error
            )
            reporter.report(err, at: cryptexesPointer)
            return
        }

        // Log the failure
        logger.error("Failed to install cryptex '\(failed.record.identifier)': \(failed.error)")
        let err = CryptexApplyError(
            kind: .installationFailed(identifier: failed.record.identifier),
            underlyingError: failed.error
        )
        reporter.report(err, at: personalizedCryptex.config.config.jsonPointer)

        // Log what succeeded before failure
        if !installResult.succeeded.isEmpty {
            let succeededIds = installResult.succeeded.map { $0.identifier }.joined(separator: ", ")
            logger.info("Cryptexes installed before failure: \(succeededIds)")
        }

        // Log what was skipped
        if !installResult.skipped.isEmpty {
            let skippedIds = installResult.skipped.map { $0.identifier }.joined(separator: ", ")
            logger.warning("Cryptexes not attempted because '\(failed.record.identifier)' failed: \(skippedIds)")
        }
    }
}
