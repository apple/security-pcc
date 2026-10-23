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
//  MetricsDump.swift
//  CloudAttestationV2
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//

import Foundation
import MetricsTestKit

/// Renders the contents of a ``TestMetrics`` factory in a Prometheus-style text
/// format, used by the `--print-metrics` flag on `cloudattestationv2ctl` for
/// debuggability of the swift-metrics counters that the library modules emit.
enum MetricsDump {
    /// Render every counter, meter, recorder, and timer registered with the
    /// given factory as a sorted, multi-line string. Each entry has the shape
    /// `label{key=value,key=value} value`; metrics with no dimensions omit the
    /// `{...}` block.
    static func render(_ metrics: TestMetrics) -> String {
        var entries: [(sortKey: String, line: String)] = []

        for counter in metrics.counters {
            entries.append(entry(label: counter.label, dimensions: counter.dimensions, value: counter.totalValue))
        }
        for meter in metrics.meters {
            entries.append(entry(label: meter.label, dimensions: meter.dimensions, value: meter.lastValue ?? 0))
        }
        for recorder in metrics.recorders {
            entries.append(entry(label: recorder.label, dimensions: recorder.dimensions, value: recorder.lastValue ?? 0))
        }
        for timer in metrics.timers {
            entries.append(entry(label: timer.label, dimensions: timer.dimensions, value: timer.lastValue ?? 0))
        }

        var lines = ["=== swift-metrics ==="]
        lines.append(contentsOf: entries.sorted { $0.sortKey < $1.sortKey }.map(\.line))
        lines.append("=== end metrics ===")
        return lines.joined(separator: "\n")
    }

    /// Render the metrics dump and append a trailing newline to the given file
    /// handle. Used at process exit on the `--print-metrics` path.
    static func write(_ metrics: TestMetrics, to handle: FileHandle) {
        let payload = render(metrics) + "\n"
        if let data = payload.data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
    }

    private static func entry<V>(label: String, dimensions: [(String, String)], value: V) -> (sortKey: String, line: String) {
        let sortedDims = dimensions.sorted { $0.0 < $1.0 }
        let formattedLabel: String
        if sortedDims.isEmpty {
            formattedLabel = label
        } else {
            let body = sortedDims.map { "\($0.0)=\($0.1)" }.joined(separator: ",")
            formattedLabel = "\(label){\(body)}"
        }
        // NUL-separate the label and dimension block so labels sort before
        // their dimensional siblings without colliding with `{` ordering.
        let dimsKey = sortedDims.map { "\($0.0)=\($0.1)" }.joined(separator: ",")
        return (sortKey: "\(label)\u{0}\(dimsKey)", line: "\(formattedLabel) \(value)")
    }
}
