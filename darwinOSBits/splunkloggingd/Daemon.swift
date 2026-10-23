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
//  Daemon.swift
//  splunkloggingd
//
//  Copyright © 2024 Apple, Inc.  All rights reserved.
//

import Darwin
import Foundation
import os
internal import OSPrivate_os_log

fileprivate let log = Logger(subsystem: sharedSubsystem, category: "Daemon")

enum SplunkloggingdError: Error {
    case missingBootSessionUUID(_: String)
    case missingAuditTable(_: String)
    case mockingError(_: String)
    case invalidPredicate(_: String)
}

// Helper to compute when we should use an audit table / which one to use.
// Returns a path if:
//     system configured to use audit table and valid one exists
//     system configured to *not* use audit table, but override path passed
// Returns nil if configured to *not* use audit table and no override passed
// Throws if configured to use an audit table but none found
fileprivate func computeAuditTableURL(forPassedURL passedURL: URL?) throws -> URL? {
    if try logFilteringEnforced() {
        // Don't use a cli-passed audit table if filtering enforced; *only* use the SecureConfig one
        guard let configuredURL = try configuredSystemAuditTable() else {
            throw SplunkloggingdError.missingAuditTable("Log filtering enforced, but no audit table found")
        }
        if passedURL != nil {
            log.error("Manually passed audit table found, but configured to use SecureConfig. Ignoring passed table")
        }
        return configuredURL
    } else {
        // If configured to not enforce filtering, ignore SecureConfig audit table.
        // If one passed on cli, take that override (e.g. for clients needing structured logs like SecurityMonitor_Lite)
        return passedURL
    }
}

// In most configurations, logs make it to disk, and we can debug splunkloggingd via sysdiagnose
//
// In the other configurations, we can't have splunkloggingd stream / forward its own logs without creating a loop, so
// we have to be creative. The hook lets us redirect logs to stdout, and a key in the launchd plist tells launchd to
// redirect that to a file
func setupLogHook() {
    if !canLogToStdout() {
        log.log("Logging to stdout is disabled, not setting log hook")
        return
    }

    // Any scenario where debug/info are enabled you'd have better debug tools anyway, so only log default+ to disk.
    // Only log things emitted by our subsystem for privacy reasons
    var previous_hook: os_log_hook_t? = nil
    previous_hook = os_log_set_hook(OSLogType.default) { type, proxy in
        if let subsystemCStr = proxy?.pointee.subsystem,
           String(cString: subsystemCStr) == sharedSubsystem,
           let msgCStr = os_log_copy_decorated_message(type, proxy)
        {
            let msg = String(cString: msgCStr).trimmingCharacters(in: .whitespacesAndNewlines)
            print("\(msg)")
            free(msgCStr)
            fflush(stdout)
        }

        previous_hook?(type, proxy)
    }
}

actor Daemon {
    /// The current configuration the daemon is using
    var config: Configuration

    /// Interactive flag registers a signal handler for SIGINFO, SIGABRT, SIGINT, and SIGILL
    let interactive: Bool
    /// Configuration Plist to monitor for configuration changes
    var configURL: URL

    /// Optional audit table to check before forwarding logs to Splunk
    nonisolated let systemAuditTable: AuditTable?

    let configMonitor: ConfigurationMonitor
    var offloader: SplunkEventOffloader?
    var rotatingBuffer: SplunkEventRotatingBuffer
    var logMonitor: LogMonitor?

    /// Object that monitors for panic reports being written
    let panicMonitor: PanicMonitor

    /// Object that monitors for crash and jetsam reports, and can redact / format them
    let crashMonitor: CrashMonitor

    var filterPredicate: NSPredicate? = nil

    // The log monitor callback retains a reference to self, so deinit will never be called if a stream is active.
    // Rather, the caller has to manually force the stream to end, which then ends the retain cycle
    func cleanUp() async {
        self.logMonitor?.invalidate()
        await self.panicMonitor.stopMonitoring()
    }

    // We need a way (for testing) to start the daemon's monitoring without hanging the main thread
    func runAndReturn() async throws {
        // Sharing refs to self must be done after all properties are initialized, so do it when running rather than in init
        await self.configMonitor.setDelegate(self)
        await self.panicMonitor.setDelegate(self)
        self.crashMonitor.delegate = self

        await configMonitor.read()
        await panicMonitor.start()
        self.crashMonitor.start()

        // Fetching the hostname is potentially network bound. Kick it off early before we start processing messages
        _ = getHostName()

        rotatingBuffer = SplunkEventRotatingBuffer(bufferCount: self.config.bufferCount,
                                                   bufferSize: self.config.bufferSize,
                                                   timeout: self.config.timeout)
        rotatingBuffer.updateDelegate(to: self.offloader)

        setupLogMonitor()

        var signalHandler: SignalHandler?
        if interactive {
            signalHandler = SignalHandler(signals: SIGINT, SIGILL, SIGABRT, SIGINFO)
            signalHandler?.activate { [self] signal in
                print(Statistics.shared)
                if signal == SIGINFO {
                    if let predicate = logMonitor?.stream.filterPredicate {
                        print(predicate)
                    }
                    return
                }
                Darwin.exit(-signal)
            }
        }
    }

    func run() async throws {
        try await self.runAndReturn()
        return await withUnsafeContinuation { _ in }
    }

    // We can't call out to instance methods from within init. As such, we must duplicate some code to init the offloader
    // Any changes to this method should take into account the initializer
    private func updateSplunkEventOffloader() {
        guard let server = self.config.serverURL else {
           log.error("Failed to update SplunkEventOffloader: server not present")
           return
        }

        do {
            try self.offloader = .init(splunkServer: server, index: self.config.index, token: self.config.token)
            rotatingBuffer.updateDelegate(to: self.offloader)
        } catch SplunkEventOffloaderError.invalidSplunkURL {
            log.error("Failed to update SplunkEventOffloader: invalid Splunk URL \(server, privacy: .public)")
        } catch {
            log.error("Failed to update SplunkEventOffloader: unexpected error \(error.localizedDescription, privacy: .public))")
        }
    }

    init(config: Configuration,
         interactive: Bool,
         configURL: URL,
         auditTableURL: URL?) async throws {

        // Do this first to get any init logs
        setupLogHook()

        self.config = config
        self.interactive = interactive
        self.configURL = configURL
        self.logMonitor = nil

        do {
            if let computedAuditTableURL = try computeAuditTableURL(forPassedURL: auditTableURL) {
                self.systemAuditTable = try AuditTable(at: computedAuditTableURL)
            } else {
                self.systemAuditTable = nil
                log.log("Not using audit table, as none required and none passed")
            }
        } catch {
            self.systemAuditTable = nil
            log.error("Daemon init error while parsing audit table: \(error, privacy: .public)")
            throw error
        }

        await self.configMonitor = ConfigurationMonitor(at: configURL)
        self.rotatingBuffer = .init(bufferCount: self.config.bufferCount,
                                    bufferSize: self.config.bufferSize,
                                    timeout: self.config.timeout)

        self.panicMonitor = await PanicMonitor()
        self.crashMonitor = CrashMonitor()

        // We can't call instance methods from within init. As such, we must duplicate some code to init the offloader
        if let server = self.config.serverURL {
            // Any errors to this should be fatal
            do {
                self.offloader = try .init(splunkServer: server, index: self.config.index, token: self.config.token)
            } catch {
                log.error("Daemon init error while creating offloader: \(error, privacy: .public)")
                throw error
            }
            rotatingBuffer.updateDelegate(to: self.offloader)
        }
    }
}

extension Daemon: PanicMonitorDelegate {
    func handlePanicEvent(_ event: SplunkEvent) async {
        if !self.config.forwardPanicReports {
            log.log("Panic forwarding disabled, dropping panic")
            Statistics.shared.skippedEvents += 1
            return
        }
        let populatedEvent = addSharedPayloadItems(to: event, index: self.config.index, globalLabels: self.config.globalLabels) ?? event
        Statistics.shared.processedEvents += 1
        if !self.rotatingBuffer.handle(incoming: populatedEvent) {
            Statistics.shared.skippedEvents += 1
        }
        Statistics.shared.panicReports += 1

        // Only 1 panic expected per boot. Stop monitoring
        await self.panicMonitor.stopMonitoring()
    }
}

extension Daemon: CrashMonitorDelegate {
    private func handleIpsEvent(_ event: SplunkEvent) {
        if !self.config.forwardCrashReports {
            log.log("Crash forwarding disabled, dropping event of type \(event, privacy: .public)")
            Statistics.shared.skippedEvents += 1
            return
        }

        let populatedEvent = addSharedPayloadItems(to: event, index: self.config.index, globalLabels: self.config.globalLabels) ?? event
        Statistics.shared.processedEvents += 1
        if !self.rotatingBuffer.handle(incoming: populatedEvent) {
            Statistics.shared.skippedEvents += 1
        }
    }

    func handleJetsamEvent(_ event: SplunkEvent) {
        self.handleIpsEvent(event)
        Statistics.shared.jetsamReports += 1
    }

    func handleCrashEvent(_ event: SplunkEvent) async {
        self.handleIpsEvent(event)
        Statistics.shared.crashReports += 1
    }
}

extension Daemon: ConfigurationMonitorDelegate {
    func configDidChange(_ newConfig: Configuration) async {
        var shouldUpdateOffloader = false
        var shouldUpdateBuffers = false
        var shouldUpdateLogMonitor = false

        if (self.config.serverURL != newConfig.serverURL) ||
            (self.config.index != newConfig.index) ||
            (self.config.token != newConfig.token)
        {
            shouldUpdateOffloader = true
        }

        if (self.config.timeout != newConfig.timeout) ||
            (self.config.bufferSize != newConfig.bufferSize) ||
            (self.config.bufferCount != newConfig.bufferCount)
        {
            shouldUpdateBuffers = true
        }

        if (self.config.level != newConfig.level) {
            shouldUpdateLogMonitor = true
        }

        if (self.config.predicates != newConfig.predicates) {
            self.updateFilterPredicate(newConfig.predicates)
            shouldUpdateLogMonitor = true
        }

        if (self.config.forwardPanicReports != newConfig.forwardPanicReports) {
            await self.panicMonitor.stopMonitoring()

            // If going from off -> on, we need to stop and restart the current monitor so it re-forwards the panic report
            if newConfig.forwardPanicReports {
                await self.panicMonitor.start()
            }
        }

        self.config = newConfig

        if shouldUpdateOffloader { self.updateSplunkEventOffloader() }
        if shouldUpdateBuffers {
            self.rotatingBuffer = .init(bufferCount: self.config.bufferCount,
                                        bufferSize: self.config.bufferSize,
                                        timeout: self.config.timeout)
        }
        if shouldUpdateLogMonitor { self.setupLogMonitor() }
    }

    func updateFilterPredicate(_ predicates: [String]) {
        var validPredicates: [NSPredicate] = []
        for pred in predicates {
            do {
                let stripped = pred.trimmingCharacters(in: .whitespacesAndNewlines)
                let predicate = try NSPredicate(format: stripped)
                let logMonitor = try LogMonitor.init(level: self.config.level)
                // XXX: The following will validate the predicate with OSLogEventStreamBase.
                // XXX: Instead of simply checking that the compound predicate is valid, we
                // XXX: need to check each individual predicate and discard any that are not
                // XXX: valid so that we're left with something sane in the final compound
                // XXX: predicate
                try logMonitor.stream.assignFilterPredicate(predicate)
                validPredicates.append(predicate)
            } catch {
                log.error("Bad predicate in plist: \(pred, privacy: .public): \(error.localizedDescription, privacy: .private)")
            }
        }
        // "OR" Combine the valid predicates into an `NSCompoundPredicate`
        if validPredicates.count > 0 {
            self.filterPredicate = NSCompoundPredicate(orPredicateWithSubpredicates: validPredicates)
        } else {
            self.filterPredicate = nil
        }
    }

    private func setupLogMonitor() {
        self.logMonitor?.invalidate()
        self.logMonitor = nil

        guard let predicate = self.filterPredicate else {
            log.log("No predicate, so not activating log monitor")
            return
        }

        let logMonitor: LogMonitor
        do {
            logMonitor = try LogMonitor.init(level: self.config.level)
        } catch {
            log.error("Unable to allocate LogMonitor \(error, privacy: .public)")
            return
        }

        do {
            try logMonitor.stream.assignFilterPredicate(predicate)
        } catch {
            log.error("Unable to assign predicate to log monitor: \(predicate, privacy: .public)")
            log.error("Log monitor assignment error: \(error, privacy: .public)")
            return
        }

        logMonitor.activate { eventProxy in
            // If an audit table was passed, enforce it on the message
            if let auditTable = self.systemAuditTable {
                if !auditTable.allows(event: eventProxy) {
                    Statistics.shared.skippedEvents += 1
                    return
                }
            }

            // Transform the event proxy into a `SplunkEvent` so we can
            // post-process it. The event proxy parameter value is going to
            // disappear at the end of this block scope.
            let event = eventProxy.formatJsonEvent(forAuditTable: self.systemAuditTable)

            Task {
                await self.receivedEvent(event)
            }
        }

        log.log("Activated stream with predicate: \(predicate, privacy: .public)")
        self.logMonitor = logMonitor
    }

    private func receivedEvent(_ rawEvent: SplunkEvent?) {
        let event = addSharedPayloadItems(to: rawEvent, index: self.config.index, globalLabels: self.config.globalLabels)
        guard let event else {
            Statistics.shared.skippedEvents += 1
            return
        }

        Statistics.shared.processedEvents += 1
        if !self.rotatingBuffer.handle(incoming: event) {
            Statistics.shared.skippedEvents += 1
        }
    }
}
