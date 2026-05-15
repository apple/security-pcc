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

//
//  Apply.swift
//  darwin-init
//

import ArgumentParserInternal
internal import OSPrivate_os_log
internal import OSPrivate.os.transactionPrivate
import os
import RemoteServiceDiscovery
import System

final class Apply: AsyncParsableCommand {
    struct Failure: Error, CustomStringConvertible {
        var description: String

        init(_ description: String) {
            self.description = description
        }
    }

    static let configuration = CommandConfiguration(
        abstract: "Apply a configuration to the running system",
        discussion: """
			Applies a configuration provided as a command line argument or in the \
			"darwin-init" nvram parameter. Diagnostic output is logged using the \
			"com.apple.darwin-init" subsystem. The darwin-init daemon runs only once.
			""")

    @Argument(help: .init(
        "Configuration to apply",
        discussion: """
			<source> must either be a path to a local file, a url to a networked file, or a \
			json string containing a darwin-init config.
			"""))
    var source: DInitConfigSource?

    @Flag(name: [.short, .long, .customShort("b"), .customLong("boot")],
		  help: .init(
        "Apply the system configuration, used internally when running at boot via launchd",
        discussion: """
			The system configuration is expected to be stored in the "darwin-init" nvram \
			variable. It must contain json data (optionally base64 encoded) with a "source" \
			key containing a nested json encoded darwin-init config, a path to a local file, \
			or a url to a networked file. See darwin-init(7) for more details.
			"""))
    var system: Bool = false

	@Option(name: .shortAndLong,
		help: .init ("Watchdog timeout value",
		discussion: """
			The timeout value for the Apply command can be specified as an \
			integer followed by a unit suffix. For example, a timeout of "5min" \
			is 5 minutes. If the unit suffix is omitted, the timeout value is \
			in seconds. The timeout can also be specified via the "apply-timeout" \
			key in the config itself.
			"""))
	var timeout: Duration?

	@Option(name: .shortAndLong, help: .init("Action to take if a failure occurs",
		 discussion: """
			If a timeout or an error occurs, what action can be taken. This includes: \
			"reboot" and "shutdown" on failure. The failure action "shutdown" is not allowed on BMC. \
			The default is exit unless this machine is a BMC, and then the default failure action is "reboot". \
			This CLI option is overridden by NVRAM arguments or failureActions set from darwin-init config.
			"""))
	var failureAction: DInitFailureAction?

	@Flag(name: [.short, .long], help: .init("Suppress logging output to stdout/console",
		discussion: """
			When enabled, prevents darwin-init logs from being printed to stdout/stderr or console. \
			Without this flag, non-system mode logs to stderr and system mode logs to console. \
			Logs are always sent to the system logging infrastructure (os_log) regardless of this flag.
			"""))
	var quiet: Bool = false

    func validate() throws {
        if let timeout = timeout, timeout <= .zero {
            throw ValidationError("timeout value must be greater than 0")
        }
#if !os(macOS)
        guard failureAction != .shutdown else {
            throw ValidationError("Failure action \"shutdown\" only allowed on macOS")
        }
#endif
    }

    static func validateConfigs(
        policyString: String,
        configs: [Config],
        on computer: some Computer
    ) async throws {
        let validator = PCCRegoValidator(configs: configs, bundlePath: computer.regoBundle)
        let result = try await validator.validate()

        // Report any warnings even if valid
        if !result.warnings.isEmpty {
            // Also print for validate CLI subcommand
            print("Detected the following warnings under \(policyString) security policy: \(result.warnings)")
            logger.error("Detected the following warnings under \(policyString) security policy: \(result.warnings)")
        }

        guard result.isValid else {
            throw PCCRegoValidatorError("Configs invalid with respect to \(policyString) security policy due to the following errors: \(result.errors)")
        }

        logger.log("Configs valid with respect to \(policyString) security policy")
    }

    func run() async throws {
        let computer = RealComputer.shared
        try await run(on: computer)
    }

    fileprivate func configureLoggingHooks(_ computer: any Computer) {
        if quiet {
            logger.debug("Quiet mode enabled: suppressing stdout logging output")
            return
        }

        // When not in system mode, log to stderr
        var file = stderr
        var logFile: UnsafeMutablePointer<FILE>?
        if system {
            guard let consoleFile = computer.console else {
                logger.error("Failed to fopen(/dev/console). Logging hook was NOT set.")
                return
            }
            file = consoleFile

            logFile = kDInitLogFilepath.withPlatformString { fopen($0, "w") }
            if let logFile {
                setvbuf(logFile, nil, _IOLBF, 0)
            } else {
                logger.error("Failed to open log file at \(kDInitLogFilepath). File logging disabled.")
            }
        }

        Logger.addHook(.info) { _, msgstr in
            fputs(msgstr, file)
            if let logFile {
                fputs(msgstr, logFile)
            }
        }
    }

    func run(on computer: any Computer) async throws {
        // Create an os_transaction that lives for the entire lifetime of the apply.
        let applyTransaction = os_transaction_create("com.apple.darwin-init.apply")
        // TODO: rdar://100902294 Use withExtendedLifetime
        defer { _fixLifetime(applyTransaction) }

        // Check if configuration has already been applied by looking for cookie
        // Do this before running apply so this sort of failure doesn't trigger
        // a failure action. If the failure action is reboot and we reboot after
        // this failure, the device will enter a boot loop as nothing removes the
        // file at kDInitDoneFilepath if ephemeral data mode is turned off.
        if try system && computer.fileSystem.fileExists(at: kDInitDoneFilepath) {
            logger.warning("darwin-init has already run, exiting")
            return
        }

        configureLoggingHooks(computer)

        // Disable BMC and Darwin Cloud SSH login on physical devices using ESC credentials as early as possible
        if computer.isBMC || (!computer.isVM && computer.isDarwinCloud) {
            if !EngineeringSSHCA.disableGlobalAccess() {
                logger.error("darwin-init failed to disable ESC SSH")
            }
        }

        /// Set locale to `en_US_POSIX`
        if !computer.setLocale("en_US_POSIX") {
            logger.error("Unable to set locale")
        }

        // Set default failure action from CLI, then fall back to platform default.
        failureAction = failureAction ?? (computer.isBMC ? .reboot : .exit)

        // Apply the configuration with a deadline

        do {
            try await apply(on: computer)
        } catch {
            logger.error("darwin-init apply failed: \(error)")

            if system {
                let status = DarwinInitApplyStatus.failure(info: .init(errorString: "\(error)"))
                try computer.fileSystem.write(json: status, to: kDInitStatusFilepath)
            }

            guard let failureAction, failureAction != .exit else {
                logger.error("No failure action specified, exiting...")
                throw ExitCode.failure
            }

            let timeoutBeforeSleep = if case ConfigLoader.Error.unableToLoad(_, _) = error, computer.isBMC {
                kDInitSleepBeforeFailureActionOnLoadFailure
            } else {
                kDInitDefaultSleepBeforeFailureAction
            }

            logger.error("Sleeping for \(timeoutBeforeSleep) before running failure action.")
            try await Task.sleep(for: timeoutBeforeSleep)

            // Don't reboot / shutdown if there's host attached to the BMC at debug port.
            // Check this after sleeping for some time to avoid racing with RSD
            if computer.isBMC && computer.isHostAttached {
                logger.log("Not running the failure action because a host is attached on the debug port.")
                throw ExitCode.failure
            }

            switch failureAction {
            case .reboot:
                try computer.reboot()
            case .shutdown:
                try computer.shutdown()
            case .exit:
                throw ExitCode.failure
            }
        }
    }

    func prepare(configs: [Config], on computer: any Computer) async throws -> Globals {
        var featureFlagsPresent: Bool = false

        var builder = GlobalsBuilder()
        Globals.setup(builder: &builder, computer: computer)

        var cryptexes: [URL] = []

        // Collect the global state from all configurations
        for (i, config) in configs.enumerated() {

            do {
                try builder.update(from: config, at: i)
            } catch {
                throw Failure(
                    "Conflicting global value, will NOT apply config: \(error)"
                )
            }

            let urls = config.cryptex?.cryptexes?.map { (id, item) in item.url } ?? []
            cryptexes.append(contentsOf: urls)

            let retainedURLs = config.cryptex?.cache?.retainedCryptexes?.map { (id, item) in item.url } ?? []
            cryptexes.append(contentsOf: retainedURLs)

            featureFlagsPresent = (config.featureFlags != nil) ? true : featureFlagsPresent
        }

        var globals = builder.realize()

        if system && globals.USRAfterSetup == nil {
            logger.info("Using machine's default USR action")
            globals.USRAfterSetup = computer.defaultUSRAction
        }

        if featureFlagsPresent && !globals.willUserspaceReboot {
            if globals.USRAfterSetup == nil {
                logger.info("Setting USRAction to userReboot because featureFlags were specified and USR was not set")
                globals.USRAfterSetup = .userReboot
            } else {
                logger.info("Failed to set USRAction to userReboot because USR was specifically set to none")
            }
        }

        logger.debug("Globals: \(globals)")

        // Ensure that current workload has access to cryptex cache contents before applying config
        do {
            let id = globals.cryptexCacheInvalidationId
            logger.log("Verifying that cryptex cache only contains contents accessible to current workload...")
            // verify will only throw if purging the cache or reading/writing the invalidation ID fails
            let invalidator = CryptexCacheInvalidator()
            try invalidator.verify(invalidationId: id)
        } catch {
            // ...So, trigger a crash if we hit a filesystem error so we can get a crash report
            fatalError("Failed to enforce cryptex cache only contains contents accessible to current workload due to: \(error)")
        }
        logger.log("Successfully enforced that cryptex cache only contains contents accessible to current workload")

        if globals.retainCachedCryptexes == false {
            let cacheDelegate = CryptexCacheDelegate()

            logger.info("Purge cache entries from previous workload")

            // If we fail to create the cache here, we will very likely fail to create it
            // it later when downloading cryptexes so not purging the cache should be ok
            if let cryptexCache = CryptexCache(at: CryptexCache.defaultCacheDirectoryPath,
                                               delegate: cacheDelegate,
                                               maxTotalSize: 0) {
                do {
                    try await cryptexCache.purge(retainingEntriesForURLs: cryptexes)
                } catch {
                    logger.error("Failed to purge cache entries from previous workload: \(error)")
                }
            }
        }

        if system {
            logger.log("Committing secure config parameters")
            try LibSecureConfig.commitSecureConfigParameters(
                parameters: globals.secureConfigParameters,
                securityPolicy: globals.configSecurityPolicy,
                to: computer
            )
        }

        return globals
    }

    func apply(on computer: any Computer) async throws {
        let system = self.system

        // Create persist storage
        do {
            try computer.fileSystem.mkdir(kDInitPersistStorage)
        } catch Errno.fileExists {
            logger.info("darwin-init persist storage already created")
        }

        // Load config from source
        let loader = ConfigLoader(computer: computer)
        let configs = try await loader.load(from: source)

        // Initial pass over the configurations
        let globals = try await prepare(configs: configs, on: computer)

        var errorReports: [ErrorReport] = []

        let writer = ResultWriter(fileSystem: computer.fileSystem)

        // validate all configs in the array under the global security policy (may only be set in config 0)
        if let policyString = globals.configSecurityPolicy {
            logger.log("Validating configs under \(policyString) policy...")
            do {
                try await Apply.validateConfigs(policyString: policyString, configs: configs, on: computer)
            } catch {
                throw Failure("Validation failed, will NOT apply configs: \(error)")
            }
        }

        for config in configs {
            // Config timeout takes precedence over --timeout CLI argument
            let timeout = config.applyTimeout ?? timeout ?? kDefaultApplyTimeout

            logger.info("Effective timeout is \(timeout)")
            let errorReportsSnapshot = errorReports
            errorReports = try await withDeadline(.now + timeout, clock: .continuous) { [writer] in
                var errorReports = errorReportsSnapshot

                // Actually apply the individual config
                let result: Config
                let errorReporter = ErrorReporter()
                result = try await self.apply(config, on: computer, env: globals, reporter: errorReporter)
                try await writer.add(result)

                let errorReport: ErrorReport
                if let origin = config.origin, origin.isV1 {
                    errorReport = ErrorReport(inputConfig: config, errors: errorReporter.errors, originalJson: origin.source)
                } else {
                    errorReport = ErrorReport(inputConfig: config, errors: errorReporter.errors)
                }
                errorReports.append(errorReport)

                // Check if applied config matches expected config
                let fullyApplied = result == config
                if !fullyApplied {
                    let errorReportJson = try errorReport.jsonString()
                    logger.error("Failed to fully apply config. Error report below:\n\(errorReportJson)\n")
                }

                if system {
                    // Write what we have applied so far to the cookie file
                    try await writer.write(to: kDInitDoneFilepath)

                    try computer.fileSystem.write(json: errorReports, to: kDInitErrorReportFilepath, redacted: false)
                }

                return errorReports
            }
        }

        // Check if we have fully applied all configurations
        if await writer.results != configs {
            throw Failure("Failed to fully apply config")
        }

        if globals.willLockCryptexes {
            do {
                try computer.lockCryptexes()
            } catch {
                throw Failure("Locking sealed software hash registers failed \(error)")
            }
        }

        // Last opportunity to write 'success' before we reboot.
        // Any failures to reboot should still be caught and written out.
        if system {
            let status = DarwinInitApplyStatus.success
            try computer.fileSystem.write(json: status, to: kDInitStatusFilepath)
        }

        // Run rebootAfterSetup if needed
        if globals.rebootAfterSetup == true {
            try computer.reboot()
        } else if let usr = globals.USRAfterSetup {
            if globals.willUserspaceReboot {
                try computer.userspaceReboot(usr)
            } else {
                logger.log("Skipping userspace-reboot by request of configuration")
            }
        }
	}

    @Sendable
    func apply(_ config: Config, on computer: any Computer, env globals: Globals, reporter: ErrorReporter)  async throws -> Config {

        if system {
            logger.log("Committing configuration.")
            try LibSecureConfig.commit(config: config, to: computer)
        }

        // Override failureAction with values loaded from config or NVRAM
        if let failureAction = config.finish?.onFailure {
            logger.log("Setting failureAction to \(failureAction.rawValue)")
            self.failureAction = failureAction
        }

        // Serialize config
        var prettyJson = try config.jsonString(redacted: true)

        // Apply config
        logger.log("Applying configuration: \(prettyJson)")
        var result: Config

        do throws(Config.CriticalError) {
            result = try await config.apply(on: computer, env: globals, reporter: reporter)
        } catch {
            logger.error("Critical error during apply: \(error)")
            throw error
        }

        // If we're running at boot and made it this far, then secure-config params registration succeeded
        if system {
            result.secureConfig = config.secureConfig
        }

        // Serialize applied config
        prettyJson = try result.jsonString(redacted: true)
        logger.log("Applied configuration: \(prettyJson)")

        // Print the applied configuration to stdout if we're not in system mode
        if (!system && !quiet) {
            print(prettyJson)
        }

        return result
    }

}
