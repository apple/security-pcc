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
//  CloudMetricsServiceMessages.swift
//  
//
//  Created by Andrea Guzzo on 8/24/22.
//

import Foundation
private import CloudMetricsAsyncXPC

// swiftlint:disable nesting
package enum CloudMetricsServiceMessages: Sendable {
    package struct SetConfiguration: CloudMetricsAsyncXPCMessage {
        package typealias Failure = CloudMetricsServiceError
        package typealias Success = CloudMetricsServiceSuccess

        package let configuration: CloudMetricsConfigurationDictionary

        package init(_ configuration: CloudMetricsConfigurationDictionary) {
            self.configuration = configuration
        }
    }

    package struct IncrementCounter: CloudMetricsAsyncXPCMessage {
        package typealias Failure = CloudMetricsServiceError
        package typealias Success = CloudMetricsServiceSuccess

        package let counter: CloudMetricsCounter
        package let amount: Int64
        package let epoch: Double

        package init(_ counter: CloudMetricsCounter, by amount: Int64, epoch: Double) {
            self.counter = counter
            self.amount = amount
            self.epoch = epoch
        }
    }

    package struct IncrementFloatingPointCounter: CloudMetricsAsyncXPCMessage {
        package typealias Failure = CloudMetricsServiceError
        package typealias Success = CloudMetricsServiceSuccess

        package let counter: CloudMetricsCounter
        package let amount: Double
        package let epoch: Double

        package init(_ counter: CloudMetricsCounter, by amount: Double, epoch: Double) {
            self.counter = counter
            self.amount = amount
            self.epoch = epoch
        }
    }

    package struct ResetCounter: CloudMetricsAsyncXPCMessage {
        package typealias Failure = CloudMetricsServiceError
        package typealias Success = CloudMetricsServiceSuccess

        package let counter: CloudMetricsCounter
        package let epoch: Double

        package init(_ counter: CloudMetricsCounter, epoch: Double) {
            self.counter = counter
            self.epoch = epoch
        }
    }

    package struct RecordInteger: CloudMetricsAsyncXPCMessage {
        package typealias Failure = CloudMetricsServiceError
        package typealias Success = CloudMetricsServiceSuccess

        package let recorder: CloudMetricsRecorder
        package let value: Int64
        package let epoch: Double

        package init(_ recorder: CloudMetricsRecorder, value: Int64, epoch: Double) {
            self.recorder = recorder
            self.value = value
            self.epoch = epoch
        }
    }

    package struct RecordDouble: CloudMetricsAsyncXPCMessage {
        package typealias Failure = CloudMetricsServiceError
        package typealias Success = CloudMetricsServiceSuccess

        package let recorder: CloudMetricsRecorder
        package let value: Double
        package let epoch: Double

        package init(_ recorder: CloudMetricsRecorder, value: Double, epoch: Double) {
            self.recorder = recorder
            self.value = value
            self.epoch = epoch
        }
    }

    package struct RecordNanoseconds: CloudMetricsAsyncXPCMessage {
        package typealias Failure = CloudMetricsServiceError
        package typealias Success = CloudMetricsServiceSuccess

        package let timer: CloudMetricsTimer
        package let duration: Int64
        package let epoch: Double

        package init(_ timer: CloudMetricsTimer, duration: Int64, epoch: Double) {
            self.timer = timer
            self.duration = duration
            self.epoch = epoch
        }
    }

    package struct ResetCounterWithDoubleValue: CloudMetricsAsyncXPCMessage {
        package typealias Failure = CloudMetricsServiceError
        package typealias Success = CloudMetricsServiceSuccess

        package let counter: CloudMetricsCounter
        package let value: Double
        package let epoch: Double

        package init(_ counter: CloudMetricsCounter, value: Double, epoch: Double) {
            self.counter = counter
            self.value = value
            self.epoch = epoch
        }
    }

    package struct ResetCounterWithIntValue: CloudMetricsAsyncXPCMessage {
        package typealias Failure = CloudMetricsServiceError
        package typealias Success = CloudMetricsServiceSuccess

        package let counter: CloudMetricsCounter
        package let value: Int64
        package let epoch: Double

        package init(_ counter: CloudMetricsCounter, value: Int64, epoch: Double) {
            self.counter = counter
            self.value = value
            self.epoch = epoch
        }
    }

    package struct RecordHistogramInteger: CloudMetricsAsyncXPCMessage {
        package typealias Failure = CloudMetricsServiceError
        package typealias Success = CloudMetricsServiceSuccess

        package let histogram: CloudMetricsHistogram
        package let buckets: [Double]
        package let value: Int64
        package let epoch: Double

        package init(_ histogram: CloudMetricsHistogram, buckets: [Double], value: Int64, epoch: Double) {
            self.histogram = histogram
            self.buckets = buckets
            self.value = value
            self.epoch = epoch
        }
    }

    package struct RecordHistogramDouble: CloudMetricsAsyncXPCMessage {
        package typealias Failure = CloudMetricsServiceError
        package typealias Success = CloudMetricsServiceSuccess

        package let histogram: CloudMetricsHistogram
        package let buckets: [Double]
        package let value: Double
        package let epoch: Double

        package init(_ histogram: CloudMetricsHistogram, buckets: [Double], value: Double, epoch: Double) {
            self.histogram = histogram
            self.buckets = buckets
            self.value = value
            self.epoch = epoch
        }
    }

    package struct RecordHistogramBuckets: CloudMetricsAsyncXPCMessage {
        package typealias Failure = CloudMetricsServiceError
        package typealias Success = CloudMetricsServiceSuccess

        package let histogram: CloudMetricsHistogram
        package let buckets: [Double]
        package let values: [Int]
        package let sum: Double
        package let count: Int
        package let epoch: Double

        package init(_ histogram: CloudMetricsHistogram,
                    buckets: [Double],
                    values: [Int],
                    sum: Double,
                    count: Int,
                    epoch: Double) {
            self.histogram = histogram
            self.buckets = buckets
            self.values = values
            self.sum = sum
            self.count = count
            self.epoch = epoch
        }
    }

    package struct RecordSummaryInteger: CloudMetricsAsyncXPCMessage {
        package typealias Failure = CloudMetricsServiceError
        package typealias Success = CloudMetricsServiceSuccess

        package let summary: CloudMetricsSummary
        package let quantiles: [Double]
        package let value: Int64
        package let epoch: Double

        package init(_ summary: CloudMetricsSummary, quantiles: [Double], value: Int64, epoch: Double) {
            self.summary = summary
            self.quantiles = quantiles
            self.value = value
            self.epoch = epoch
        }
    }

    package struct RecordSummaryDouble: CloudMetricsAsyncXPCMessage {
        package typealias Failure = CloudMetricsServiceError
        package typealias Success = CloudMetricsServiceSuccess

        package let summary: CloudMetricsSummary
        package let quantiles: [Double]
        package let value: Double
        package let epoch: Double

        package init(_ summary: CloudMetricsSummary, quantiles: [Double], value: Double, epoch: Double) {
            self.summary = summary
            self.quantiles = quantiles
            self.value = value
            self.epoch = epoch
        }
    }

    package struct RecordSummaryQuantiles: CloudMetricsAsyncXPCMessage {
        package typealias Failure = CloudMetricsServiceError
        package typealias Success = CloudMetricsServiceSuccess

        package let summary: CloudMetricsSummary
        package let quantiles: [Double]
        package let values: [Double]
        package let sum: Double
        package let count: Int
        package let epoch: Double

        package init(_ summary: CloudMetricsSummary,
                    quantiles: [Double],
                    values: [Double],
                    sum: Double,
                    count: Int,
                    epoch: Double) {
            self.summary = summary
            self.quantiles = quantiles
            self.values = values
            self.sum = sum
            self.count = count
            self.epoch = epoch
        }
    }

    case setConfiguration(SetConfiguration)
    case incrementCounter(IncrementCounter)
    case incrementFloatingPointCounter(IncrementFloatingPointCounter)
    case resetCounter(ResetCounter)
    case recordInteger(RecordInteger)
    case recordDouble(RecordDouble)
    case recordNanoseconds(RecordNanoseconds)
    case resetCounterWithDoubleValue(ResetCounterWithDoubleValue)
    case resetCounterWithIntValue(ResetCounterWithIntValue)
    case recordHistogramInteger(RecordHistogramInteger)
    case recordHistogramDouble(RecordHistogramDouble)
    case recordHistogramBuckets(RecordHistogramBuckets)
    case recordSummaryInteger(RecordSummaryInteger)
    case recordSummaryDouble(RecordSummaryDouble)
    case recordSummaryQuantiles(RecordSummaryQuantiles)

}
// swiftlint:enable nesting
