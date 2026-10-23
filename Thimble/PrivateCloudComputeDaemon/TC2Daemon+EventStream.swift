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
//  TC2Daemon+EventStream.swift
//  PrivateCloudCompute
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//

import Foundation
import PrivateCloudCompute
import os.log

private let logger = Logger(for: .daemon)

extension TC2Daemon {
    func runEventStreamLoop() async {
        let metricExporter = MetricReporter()

        // thimbled event stream should never be finished
        await withDiscardingTaskGroup { taskGroup in
            for await event in self.thimbledEventStream {
                switch event {
                case .expiredAttestationList(let expiredAttestationList, let workload):
                    taskGroup.addTask {
                        await self.handleExpiredAttestationList(expiredAttestationList: expiredAttestationList, workload: workload)
                    }

                case .reportDailyActiveUserIfNecessary(let requestID, let environment):
                    taskGroup.addTask {
                        await self.handleReportDailyActiveUserIfNecessary(metricReporter: metricExporter, requestID: requestID, environment: environment)
                    }

                case .reportDailyPrefetchMetricIfNecessary(let requestID, let environment):
                    taskGroup.addTask {
                        await self.handleReportDailyPrefetchMetricIfNecessary(metricReporter: metricExporter, requestID: requestID, environment: environment)
                    }

                case .exportMetric(let metric):
                    taskGroup.addTask {
                        await self.handleExportMetric(metricReporter: metricExporter, metric: metric)
                    }

                case .rateLimitConfigurations(let rateLimitConfigs):
                    taskGroup.addTask {
                        await self.handleRateLimitConfigurations(rateLimitConfigs: rateLimitConfigs)
                    }

                case .attestationStoreCleanup:
                    taskGroup.addTask {
                        await self.handleAttestationStoreCleanup()
                    }

                case .prefetchAttestationsForNewWorkload(let workload):
                    // Use medium priority to avoid starving user request path
                    taskGroup.addTask(priority: .medium) {
                        await self.handlePrefetchAttestationsForNewWorkload(workload: workload)
                    }

                case .discardUsedAttestationsAndPrefetchBatch(let serverRequestID, let workload):
                    // Use medium priority to avoid starving user request path
                    taskGroup.addTask(priority: .medium) {
                        await self.handleDiscardUsedAttestationsAndPrefetchBatch(serverRequestID: serverRequestID, workload: workload)
                    }

                case .nodesReceived(let nodeIDs, let source):
                    taskGroup.addTask {
                        await self.handleNodesReceived(nodeIDs: nodeIDs, source: source)
                    }

                case .tapToRadarIndicationReceived(let context):
                    taskGroup.addTask {
                        await self.handleTapToRadarIndicationReceived(context: context)
                    }

                case .componentTimeMeasurementReceived(let clientRequestID, let source):
                    taskGroup.addTask {
                        self.handleComponentTimeMeasurementReceived(clientRequestID: clientRequestID, source: source)
                    }

                case .fetchServerDrivenConfigurationIfAllowed:
                    taskGroup.addTask {
                        await self.handleFetchServerDrivenConfigurationIfAllowed()
                    }

                case .trustedRequestCompleted(let featureId, let error):
                    taskGroup.addTask {
                        await self.handleTrustedRequestCompleted(featureId: featureId, error: error)
                    }
                }
            }
        }
    }

    private func handleExpiredAttestationList(expiredAttestationList: Proto_Ropes_HttpService_InvokeResponse.ExpiredAttestationList, workload: Workload) async {
        await withOSActivity {
            await withOSTransaction(name: "com.apple.privatecloudcomputed.prefetch") {
                await self.prefetchAttestationsAsResponseToExpiredAttestationList(
                    expiredAttestationList,
                    parameters: workload
                )
            }
        }
    }

    private func handleReportDailyActiveUserIfNecessary(metricReporter: MetricReporter, requestID: UUID, environment: String) async {
        await withOSActivity {
            if let metric = await self.dailyActiveUserReporter.makeDailyInvokeRequestReportEvent(requestID: requestID, environment: environment) {
                await metricReporter.reportCloudTelemetryMetric(metric: metric)
            }
        }
    }

    private func handleReportDailyPrefetchMetricIfNecessary(metricReporter: MetricReporter, requestID: UUID, environment: String) async {
        await withOSActivity {
            if let metric = await self.dailyActiveUserReporter.makeDailyPrefetchReportEvent(
                requestID: requestID,
                environment: environment,
                workloadsCache: self.prefetchActivity.parametersCache
            ) {
                await metricReporter.reportCloudTelemetryMetric(metric: metric)
            }
        }
    }

    private func handleExportMetric(metricReporter: MetricReporter, metric: any CloudTelemetryReportable) async {
        await withOSActivity {
            await metricReporter.reportCloudTelemetryMetric(metric: metric)
        }
    }

    private func handleRateLimitConfigurations(rateLimitConfigs: [RateLimitConfiguration]) async {
        await withOSActivity {
            for rateLimitConfig in rateLimitConfigs {
                await self.rateLimiter.limitByConfiguration(rateLimitConfig)
            }
            await self.rateLimiter.trimExpiredData()
            await self.rateLimiter.save()
        }
    }

    private func handleAttestationStoreCleanup() async {
        await withOSActivity {
            switch self.attestationStoreOrLegacyStore {
            case .legacyStore(let legacyStore):
                await legacyStore.deleteEntriesWithExpiredAttestationBundles()
            case .attestationStore(let v3Store):
                do {
                    try await v3Store.deleteEntriesWithExpiredAttestationBundles()
                } catch {
                    logger.error("failed to clean up expired attestation bundles: \(error)")
                }
            }
        }
    }

    private func handlePrefetchAttestationsForNewWorkload(workload: Workload) async {
        await withOSActivity {
            await withOSTransaction(name: "com.apple.privatecloudcomputed.prefetch") {
                _ = await self.prefetchRequestHandler.run(
                    workload: workload,
                    prewarm: false,
                    fetchType: .fetchAllBatches,
                    bundleIdentifier: nil,
                    featureIdentifier: nil,
                    serviceClass: nil
                )
            }
        }
    }

    private func handleDiscardUsedAttestationsAndPrefetchBatch(serverRequestID: UUID, workload: Workload) async {
        await withOSActivity {
            // This operation is only applicable to the legacy attestation store
            guard case .legacyStore(let legacyAttestationStore) = self.attestationStoreOrLegacyStore else {
                logger.error("Attempting to discard attestations and prefetch batch in new attestation store")
                return
            }

            await withOSTransaction(name: "com.apple.privatecloudcomputed.prefetch") {
                // 1. Issue a delete request to the store with trustedRequestID
                let batchID = await legacyAttestationStore.deleteAttestationsUsedByTrustedRequest(serverRequestID: serverRequestID)

                // 2. Prefetch a single batch to top up the store
                _ = await self.prefetchRequestHandler.run(
                    workload: workload,
                    prewarm: false,
                    fetchType: .fetchSingleBatch(batchID: batchID),
                    bundleIdentifier: nil,
                    featureIdentifier: nil,
                    serviceClass: nil
                )
            }
        }
    }

    private func handleNodesReceived(nodeIDs: [String], source: NodeReceivingSource) async {
        await withOSActivity {
            await self.nodeDistributionAnalyzer.receivedNodesWith(nodeIDs: nodeIDs, from: source)
        }
    }
    private func handleTapToRadarIndicationReceived(context: TapToRadarContext) async {
        await withOSActivity {
            _ = await self.tapToRadarController.ttrIndicationReceived(context)
        }
    }

    private func handleComponentTimeMeasurementReceived(clientRequestID: UUID, source: ComponentTimeMeasurementSource) {
        withOSActivity {
            self.componentTimeMeasurementReporter.process(clientRequestID: clientRequestID, source: source)
        }

    }

    private func handleFetchServerDrivenConfigurationIfAllowed() async {
        await withOSActivity {
            await self.fetchServerDrivenConfigurationIfAllowed()
        }

    }

    private func handleTrustedRequestCompleted(featureId: String?, error: PrivateCloudComputeError?) async {
        await withOSActivity {
            if let error {
                if error.code == .invalidClientOverrideBuildVersion {
                    await self.expiredBuildNotification.show()
                }
            } else {
                await self.featureUsageAnalyzer.requestSucceeded(featureId: featureId ?? "")
            }
        }
    }
}
