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

/*swift tabwidth="4" prefertabs="false"*/
//
//  CloudMetricsdCommand.swift
//  CloudMetricsCore
//
//  Created by Andrea Guzzo on 8/29/22.
//

package import ArgumentParserInternal
private import CloudMetricsConstants
package import CloudMetricsHealthFramework
private import Logging
internal import os
#if canImport(SecureConfigDB)
@_weakLinked private import SecureConfigDB
#endif

package struct CloudMetricsdCommand: AsyncParsableCommand {
    package static let configuration = CommandConfiguration(
        commandName: "cloudmetricsd",
        abstract: "agent aggregating cloud workload metrics to a metrics backend.",
        discussion: """
        cloudmetricsd collects telemetry events from hardware, platform and application \
        publishers and uploads them to a metrics backend - currently Mosaic - for \
        analysis and alerting.
        """
    )

    @Option(help: "Path to plist file containing cloudmetricsd configuration")
    package var configurationFile: String?


    package init() {}

    package func run() async throws {
        try await CloudMetricsdRunner().run(configurationFile: self.configurationFile)
    }
}

package final class CloudMetricsdRunner: Sendable {

    private let healthServer: CloudMetricsHealthServer
    private let healthContinuation: AsyncStream<CloudMetricsHealthState>.Continuation
    private let logger = Logger(subsystem: kCloudMetricsLoggingSubsystem, category: "CloudMetricsdCommand")

    package init() {
        let (stream, continuation) = AsyncStream<CloudMetricsHealthState>.makeStream()
        self.healthServer = .init(healthStream: stream)
        self.healthContinuation = continuation
    }

    package func run(configurationFile: String?) async throws {
        do {
            try await doRun(configurationFile: configurationFile)
        } catch {
            logger.error("""
                Cloudmetricsd threw error. \
                error=\(String(reportable: error), privacy: .public)
                """)
            throw error
        }
    }

    private func doRun(configurationFile: String?) async throws {
        self.logger.log("Cloudmetricsd initialising")
        // Setup the os logging backend to SwiftLog.
        // Nb. SwiftLog and os_log are two different logging solutions with
        // different design choices. We bridge them together.
        LoggingSystem.bootstrap(OSLogger.init)
        healthServer.updateHealthState(to: .initializing)

        try await withThrowingTaskGroup(of: Void.self) { group in
            //  health server
            group.addTask {
                self.logger.log("Health server starting")
                defer {
                    self.logger.log("Health server stopped")
                }
                try await self.healthServer.run()
            }

            // Run CloudMetricsDaemon
            group.addTask {
                let configuration: Configuration
                let auditLists = try await self.loadMetricAuditLists()
                if let configurationFile {
                    self.logger.log("Loading configuration. config_file=\(configurationFile, privacy: .public)")
                    configuration = try .init(configurationFile: configurationFile, auditLists: auditLists)
                } else {
                    self.logger.log("Loading configuration from CFPrefs")
                    configuration = try .makeFromCFPrefs(auditLists: auditLists)
                }
                self.logger.log("Configuration loaded. configuration=\(String(describing: configuration), privacy: .public)")
                self.logger.log("cloudmetricsd starting")
                defer {
                    self.logger.log("cloudmetricsd stopped")
                }
                let (osMetricStream, osMetricContinuation) = AsyncStream<OSMetricEvent>.makeStream()
                let cloudmetricsd = try CloudMetricsDaemon(
                    configuration: configuration,
                    healthContinuation: self.healthContinuation,
                    osMetricStream: osMetricStream,
                    osMetricContinuation: osMetricContinuation
                )
                self.healthServer.updateHealthState(to: .healthy)
                try await cloudmetricsd.run()
            }

            do {
                try await group.next()
            } catch {
                self.logger.error("""
                    Child task threw error. \
                    error=\(error, privacy: .public)
                    """)
            }
            self.logger.log("Child task exited. Marking as unhealthy")
            // Nb. We (kinda unusually) don't just cancel everything and exit here.
            // Reason being that it becomes too easy for cloudmetricsd too enter a crash loop
            // and bring down the entire ensemble with it.
            healthServer.updateHealthState(to: .unhealthy)
            try await group.waitForAll()
        }
    }

    private func loadMetricAuditLists() async throws -> Configuration.AuditLists? {
        if #_hasSymbol(SecureConfigParameters.self),
            try SecureConfigParameters.loadContents().metricsFilteringEnforced ?? false,
            let logPolicyPath = try SecureConfigParameters.loadContents().logPolicyPath {

            let plistPath = URL(filePath: "\(logPolicyPath)/metrics_audit_list.plist")
            // Audit lists can come from another cryptex.
            // cloudmetrics may be started before that other cryptex is available.
            // We therefore need to wait until that file is available.
            //
            // I considered making cloudmetricsd crash eventually if the file never becomes
            // available. However, decided against this for the time being. We've had
            // trouble before whereby crashes of cloudmetricsd cause us to tear down
            // the entire ensemble and it's all a bit painful to debug.
            while !FileManager.default.fileExists(atPath: plistPath.path()) {
                logger.log("""
                    Waiting for metrics audit list to become available. \
                    metrics_audit_list_path=\(plistPath.path(), privacy: .public)
                    """)
                try await Task.sleep(for: .milliseconds(100))
            }
            logger.log("Loading audit lists. metric_audit_lists_path=\(plistPath, privacy: .public)")
            let decoder = PropertyListDecoder()

            return try decoder.decode(Configuration.AuditLists.self, from: Data(contentsOf: plistPath))
        } else {
            logger.log("Not using metric audit lists")
            return nil
        }
    }

    package var healthState: CloudMetricsHealthFramework.CloudMetricsHealthState {
        self.healthServer.getHealthState()
    }
}
