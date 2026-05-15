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
//  NodeDistributionAnalyzer.swift
//  PrivateCloudCompute
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

import Foundation
import PrivateCloudCompute
import os.log

package enum NodeReceivingSource: String, Codable, CaseIterable {
    case prefetch = "prefetch"
    case prewarm = "prewarm"
    case request = "request"
}

final actor NodeDistributionAnalyzer<
    SystemInfo: SystemInfoProtocol
>: Sendable {
    private let jsonEncoder = JSONEncoder()

    /// number of percentage buckets, should always be larger than 0
    private let bucketCount = 10

    private let environment: String
    private let systemInfo: SystemInfo

    let logger = tc2Logger(forCategory: .metricReporter)

    /// store helper
    private let storeHelper: NodeDistributionAnalyzerStoreHelper

    private struct NodeDistribution: Codable {
        /// total number of batches
        var batchCount: Int = 0
        /// total number of received node IDs
        var totalCount: Int = 0
        /// how many times we have seen these individual node IDs
        var distributionByNodeID: [String: Int] = [:]

        mutating func ingestBatchWith(nodeIDs: [String]) {
            self.batchCount += 1
            self.totalCount += nodeIDs.count
            for nodeID in nodeIDs {
                self.distributionByNodeID[nodeID, default: 0] += 1
            }
        }
    }

    init(environment: String, storeURL: URL, systemInfo: SystemInfo) {
        self.environment = environment
        self.storeHelper = .init(storeURL: storeURL)
        self.systemInfo = systemInfo
    }

    /// receiving new node
    func receivedNodesWith(nodeIDs: [String], from source: NodeReceivingSource) async {
        self.logger.debug("Receiving nodes \(nodeIDs) from \(source.rawValue)")
        let lines = [source.rawValue] + nodeIDs
        do {
            try await self.storeHelper.writeToFile(lines: lines)
        } catch {
            self.logger.error("Failed writing to file: \(error)")
        }
    }

    /// generate reportings for the distributions
    func generateDistributionReports() async -> [AttestationDistributionMetric] {
        let data: Data
        do {
            data = try await self.storeHelper.readFromFile()
        } catch {
            self.logger.error("Failed to read from temp file: \(error)")
            return []
        }

        // generate reports
        // we are reading the same data 3 times for 3 sources
        // this is to save memory usage because NodeDistribution can be a big object
        var reports: [AttestationDistributionMetric] = []
        for source in NodeReceivingSource.allCases {
            var nodeDistribution = NodeDistribution()
            var currentNodes: [String] = []
            let dataSequence = DataAsyncSequence(data: data)
            var inCurrentSource = false

            for await line in dataSequence.lines {
                // read each line
                let str = line.trimmingCharacters(in: .whitespacesAndNewlines)
                // if we are beginning a new batch
                let newSource: NodeReceivingSource?
                switch str {
                case NodeReceivingSource.prefetch.rawValue:
                    newSource = .prefetch
                case NodeReceivingSource.prewarm.rawValue:
                    newSource = .prewarm
                case NodeReceivingSource.request.rawValue:
                    newSource = .request
                default:
                    newSource = nil
                }

                if let newSource {
                    // finish current batch
                    if inCurrentSource, !currentNodes.isEmpty {
                        // add current batch
                        nodeDistribution.ingestBatchWith(nodeIDs: currentNodes)
                    }
                    currentNodes = []

                    // this is beginning of a new batch
                    if newSource == source {
                        // the new batch is for current source
                        inCurrentSource = true
                    } else {
                        inCurrentSource = false
                    }
                } else {
                    // this is still the current batch
                    if inCurrentSource {
                        currentNodes.append(str)
                    }
                }
            }
            if inCurrentSource, !currentNodes.isEmpty {
                // add current batch
                nodeDistribution.ingestBatchWith(nodeIDs: currentNodes)
            }

            if let report = generateDistributionReportFor(nodeDistribution, forSource: source) {
                reports.append(report)
            }
        }

        return reports
    }

    private func generateDistributionReportFor(_ nodeDistribution: NodeDistribution, forSource source: NodeReceivingSource) -> AttestationDistributionMetric? {
        // only report when we have ever received nodes
        if nodeDistribution.totalCount > 0 && nodeDistribution.batchCount > 0 {
            logger.log("Generating node distribution reports for \(source.rawValue) with \(nodeDistribution.batchCount) batches and \(nodeDistribution.totalCount) total nodes")
            // construct histogram
            var histogram: [Int] = Array(repeating: 0, count: self.bucketCount)
            for (_, count) in nodeDistribution.distributionByNodeID {
                // calculate which bucket this node belongs to
                // get the percentage
                let percentage: Double = Double(count) / Double(nodeDistribution.batchCount)
                // percentage increment per bucket, if the bucket size is 10, increment will be 0.10 (10%)
                let increment: Double = 1.0 / Double(self.bucketCount)
                // calculate the index
                var index: Int = Int(percentage / increment)
                if index >= self.bucketCount {
                    // hitting >= 100%
                    index = self.bucketCount - 1
                }
                histogram[index] += 1
            }

            do {
                // encode the histogram into a json string
                let jsonData = try self.jsonEncoder.encode(histogram)
                return AttestationDistributionMetric(
                    eventTime: .now,
                    environment: self.environment,
                    systemInfo: self.systemInfo,
                    locale: .current,
                    attestationSource: source,
                    totalNumberOfAttestations: nodeDistribution.totalCount,
                    attestationDistribution: String(data: jsonData, encoding: .utf8)
                )
            } catch {
                logger.error("Cannot encode histogram to JSON, error=\(error)")
            }
        } else {
            logger.log("Skip generating empty node distribution reports for \(source.rawValue)")
        }
        return nil
    }
}
