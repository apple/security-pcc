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
//  TopHandler.swift
//  CloudRemoteDiagnosticsCore
//
//  Created by Marco Magdy on 11/28/23.
//

import Foundation

public class CloudRemoteDiagnosticsHandler {
    public init() { }
    public func handleGetProcessStats(samplesPerSecond: UInt64, durationSeconds: UInt64) -> String {
        let samplesPerSecond = samplesPerSecond > 10 ? 10 : samplesPerSecond
        let durationSeconds = durationSeconds > 10 ? 10 : durationSeconds
        // Add one to the total samples to account for the first sample having ZERO CPU utilization.
        // The CPU utilization is calculated by comparing the current sample with the previous one.
        let totalSamples = samplesPerSecond * durationSeconds + 1

        crd_process_stats_initialize()
        defer {
            crd_process_stats_shutdown()
        }

        var statsMap = SamplesMap()

        var counter: Int32 = 0
        while counter < totalSamples {
            var data = [crd_process_sample](repeating: crd_process_sample(), count: 100)
            let procsNum = crd_process_sample_collect(&data, 100)
            let samples = convertToProcessSamples(samples: data, processCount: procsNum, sampleId: counter)
            if counter > 0 {
                // The first sample will always have ZERO CPU utilization, so we skip it.
                appendSamplesToStats(map: &statsMap, samples: samples)
            }
            counter += 1

            // Don't sleep after the last sample.
            if counter < totalSamples {
                Thread.sleep(forTimeInterval: 1 / Double(samplesPerSecond))
            }
        }

        var result = [ProcessStats]()
        for sample in statsMap {
            guard let command = sample.value.first?.name else {
                fatalError("Empty sample") // should never happen
            }
            let ps = ProcessStats(pid: sample.key, name: command, samples: sample.value)
            result.append(ps)
        }

        // Using the last sample collected, sort descendingly by cpu utilization.
        result.sort { a, b in
            guard let lastA = a.samples.last?.cpuUtilizationPercentage else {
                return false;
            }
            guard let lastB = b.samples.last?.cpuUtilizationPercentage else {
                return true;
            }

            return lastA > lastB
        }

        guard let jsonOutput = try? JSONEncoder().encode(result) else {
            return "error encoding process stats to json data"
        }

        guard let jsonString = String(data: jsonOutput, encoding: .utf8) else {
            return "error converting json data to utf8 string"
        }

        return jsonString
    }
    
    private typealias SamplesMap = [Int32: [ProcessSample]]
    private func convertToProcessSamples(samples: [crd_process_sample], processCount: Int, sampleId: Int32) -> [ProcessSample] {
        var result = [ProcessSample]()
        result.reserveCapacity(processCount)
        for i in 0..<processCount {
            let crd_sample = samples[i]
            let ps = ProcessSample(pid: crd_sample.pid,
                                   name: String(cString: crd_sample.name),
                                   sampleId: sampleId,
                                   memoryUsedInBytes: crd_sample.memory_used_bytes,
                                   threadCount: crd_sample.thread_count,
                                   cpuUtilizationPercentage: crd_sample.cpu_utilization_percent)
            result.append(ps)
            crd_sample.name.deallocate()
        }
        return result
    }

    private func appendSamplesToStats(map: inout SamplesMap, samples: [ProcessSample]) {
        for item in samples {
            if map[item.pid] == nil {
                var collection = [ProcessSample]()
                collection.append(item)
                map[item.pid] = collection
            }
            else {
                map[item.pid]?.append(item)
            }
        }
    }
}

