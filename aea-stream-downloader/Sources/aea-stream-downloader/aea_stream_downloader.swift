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

import AEAStreamDownloader
import Configuration
import Foundation
import Logging
import MirkwoodConfiguration
import OTel
import OTelConfiguration
import ServiceLifecycle

@main
struct AEAStreamDownloaderMain {
    static func main() async {
        do {
            try await run()
        } catch {
            // Deliberately swallow the error rather than rethrowing. Letting
            // `main` throw causes the Swift runtime to catch it and crash with
            // a stacktrace, which performs badly on our high-thread-count
            // target systems and whose stack is never useful for diagnosis.
            Logger(label: "aea-stream-downloader.main").error(
                "Top-level error; exiting",
                metadata: ["error": "\(String(reportable: error))"]
            )
            // Give the logging pipeline a chance to flush before we exit.
            try? await Task.sleep(for: .seconds(5))
            // Exit non-zero so our supervisor restarts us.
            exit(1)
        }
    }

    static func run() async throws {
        let env = ProcessInfo.processInfo.environment

        let config = ConfigReader(
            providers: [
                EnvironmentVariablesProvider(),
                try await MeasuredConfigurationProvider(scope: .global),
                try await UnmeasuredConfigurationProvider(scope: .global),
                try await MeasuredConfigurationProvider(scope: .local),
                try await UnmeasuredConfigurationProvider(scope: .local),
            ]
        )

        var multiConfig = try MultiDownloadConfiguration(config: config.scoped(to: "aea"))

        // The CLI always uses URL-only identity checking so a sentinel that
        // records an unchanged URL can short-circuit the download without
        // needing valid GCS/S3 auth for the "nothing to do" case. Callers
        // cannot opt out; this overrides any config-provided value. Iterated
        // with a stepped index to avoid the CoW invalidation that `.indices`
        // would trigger (see the same pattern at applySigV4Credentials).
        var i = multiConfig.downloads.startIndex
        while i < multiConfig.downloads.endIndex {
            multiConfig.downloads[i].urlOnlyIdentityCheck = true
            multiConfig.downloads.formIndex(after: &i)
        }

        let otelBuilder = OTelConfigurationBuilder(config: config.scoped(to: "otel"))

        var services: [ServiceGroupConfiguration.ServiceConfiguration] = []

        if var otelConfig = otelBuilder.build() {
            // Create the OTel logging backend separately so we can wrap it
            // in a MultiplexLogHandler that also logs to stderr.
            let otelLogging = try OTel.makeLoggingBackend(configuration: otelConfig)
            services.append(.init(service: otelLogging.service))

            LoggingSystem.bootstrap { label in
                MultiplexLogHandler([
                    otelLogging.factory(label),
                    StreamLogHandler.standardError(label: label),
                ])
            }

            // Disable logs in the config before calling bootstrap() so OTel
            // doesn't try to call LoggingSystem.bootstrap a second time.
            otelConfig.logs.enabled = false
            let observability = try OTel.bootstrap(configuration: otelConfig)
            services.append(.init(service: observability))
        } else {
            LoggingSystem.bootstrap(StreamLogHandler.standardError)
        }

        // If GCP_SECRET_NAME is set, resolve the S3 HMAC credentials from
        // Google Secret Manager once and inject them into every download
        // configuration so the S3 source signs requests with SigV4 instead of
        // using mTLS.
        try await multiConfig.applySigV4Credentials(
            secretName: env["GCP_SECRET_NAME"],
            logger: Logger(label: "aea-stream-downloader.bootstrap")
        )

        services.append(
            .init(
                service: DownloadService(
                    configurations: multiConfig.downloads,
                    verbose: multiConfig.verbose,
                    mtlsCertificatePaths: multiConfig.mtlsCertificatePathsToWaitFor,
                    tlsCertificateTimeoutSeconds: multiConfig.tlsCertificateTimeoutSeconds
                ),
                successTerminationBehavior: .gracefullyShutdownGroup,
                // Use graceful shutdown on failure so OTel gets the
                // `withGracefulShutdownHandler` path and drains its log buffer
                // before the group's run() returns. With `.cancelGroup`, the
                // OTel exporter task is cancelled and the final records (most
                // importantly the error log emitted below in DownloadService)
                // are dropped.
                failureTerminationBehavior: .gracefullyShutdownGroup
            )
        )

        var serviceGroupConfig = ServiceGroupConfiguration(
            services: services,
            gracefulShutdownSignals: [.sigterm],
            cancellationSignals: [.sigint],
            logger: Logger(label: "service-group")
        )
        // Cap the worst case: if the OTLP endpoint is unreachable, OTel's
        // per-batch export timeout is 30s, and without this cap the group
        // would wait indefinitely for flush to finish.
        serviceGroupConfig.maximumGracefulShutdownDuration = .seconds(10)
        let serviceGroup = ServiceGroup(configuration: serviceGroupConfig)
        try await serviceGroup.run()
    }
}

struct DownloadService: Service {
    var configurations: [AEAConfiguration]
    var verbose: Bool
    var mtlsCertificatePaths: Set<String>
    var tlsCertificateTimeoutSeconds: Int

    func run() async throws {
        let logger: Logger = {
            var l = Logger(label: "aea-stream-downloader")
            if verbose {
                l.logLevel = .trace
            }
            return l
        }()

        do {
            try await cancelWhenGracefulShutdown {
                try await waitForCertificateFiles(
                    paths: mtlsCertificatePaths,
                    timeoutSeconds: tlsCertificateTimeoutSeconds,
                    logger: logger
                )

                let groups = groupDownloadsByOutputPath(configurations)

                for group in groups {
                    try await group.download(
                        totalCount: configurations.count,
                        logger: logger
                    )
                }
            }
        } catch {
            // Log the error here, *before* the ServiceGroup begins graceful
            // shutdown, so the record lands in OTel's buffer while the
            // exporter is still running. Logging from `main`'s catch is too
            // late: by then OTel has already shut down.
            logger.error(
                "Download service failed",
                metadata: ["error": "\(String(reportable: error))"]
            )
            throw error
        }
    }
}

// MARK: - Download grouping

private struct DownloadGroup {
    var outputPath: String
    var members: [(index: Int, configuration: AEAConfiguration)]

    func download(totalCount: Int, logger: Logger) async throws {
        if members.count == 1 {
            try await downloadSingle(totalCount: totalCount, logger: logger)
        } else {
            try await downloadMerged(logger: logger)
        }
    }

    private func downloadSingle(totalCount: Int, logger: Logger) async throws {
        let (index, configuration) = members[0]
        logger.info(
            "Downloading",
            metadata: [
                "sourceURL": "\(configuration.sourceURL)",
                "outputPath": "\(configuration.outputPath)",
                "download": "\(index + 1)/\(totalCount)",
            ]
        )

        let result = try await streamingDownloadAndExtract(
            logger: logger,
            configuration: configuration
        )

        switch result {
        case .alreadyCurrent:
            logger.info("Output directory is already up-to-date, skipping download")
        case .downloaded:
            logger.info("Download and extraction complete")
        }
    }

    private func downloadMerged(logger: Logger) async throws {
        logger.info(
            "Merge group detected",
            metadata: [
                "outputPath": "\(outputPath)",
                "sourceCount": "\(members.count)",
                "sources": "\(members.map(\.configuration.sourceURL))",
            ]
        )

        try await mergedDownloadAndExtract(
            configurations: members,
            outputPath: outputPath,
            logger: logger
        )
    }
}

/// Groups downloads by `outputPath`, preserving order of first appearance.
/// Downloads sharing an `outputPath` form a "merge group" whose results are
/// combined into a single directory.
private func groupDownloadsByOutputPath(
    _ configurations: [AEAConfiguration]
) -> [DownloadGroup] {
    var groups: [DownloadGroup] = []
    var groupIndex: [String: Int] = [:]

    for (index, configuration) in configurations.enumerated() {
        let path = configuration.outputPath
        if let gi = groupIndex[path] {
            groups[gi].members.append((index: index, configuration: configuration))
        } else {
            groupIndex[path] = groups.count
            groups.append(
                DownloadGroup(outputPath: path, members: [(index: index, configuration: configuration)])
            )
        }
    }

    return groups
}
