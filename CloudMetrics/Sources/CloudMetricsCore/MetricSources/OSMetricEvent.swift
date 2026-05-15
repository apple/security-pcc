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

//  Copyright © 2025 Apple Inc. All rights reserved.

/// TODO: Remove can import check when all SDKs are bumped to iOS 19 or greater.
#if canImport(LoggingSupport, _version: 1788)
package import CloudMetricsXPC
import LoggingSupport

package enum OSMetricEventError: Error, Sendable {
    /// errors for decoding MetricMetaData
    case missingMetricMetaData
    case invalidMetricType(String)
    case invalidMetricBaseType(String)

    /// errors for decoding MetricData
    case missingMetricData
    case missingMetricDataValue

    case missingMetricLabel
    case missingClientName
}

package enum MetricBaseType: String {
    case uint64
    case int64
    case double
}

package struct MetricMetaData {
    var type: CloudMetricType
    var baseType: MetricBaseType
    var buckets: [Double]?

    package init(from dict: [AnyHashable: Any]) throws {
        let metricTypeStr = dict["type"] as? String
        guard let metricTypeStr, let metricType = CloudMetricType(rawValue: metricTypeStr) else {
            throw OSMetricEventError.invalidMetricType("\(metricTypeStr ?? "nil")")
        }
        type = metricType

        let metricBasetypeStr = dict["base_type"] as? String
        guard let metricBasetypeStr, let metricBaseType = MetricBaseType(rawValue: metricBasetypeStr) else {
            throw OSMetricEventError.invalidMetricBaseType("\(metricBasetypeStr ?? "nil")")
        }
        baseType = metricBaseType

        /// construct buckets
        if let bucketCount = dict["binCount"] as? Int, let binType = dict["binType"] as? String {
            if binType == "linear", let bucketInterval = dict["binInterval"] as? Int {
                buckets = (1...bucketCount).map { Double($0 * bucketInterval) }
            } else if binType == "log2" {
                buckets = (0...bucketCount-1).map { pow(2, Double($0)) }
            }
        }
    }
    
    package init(type: CloudMetricType, baseType: MetricBaseType, buckets: [Double]? = nil) {
        self.type = type
        self.baseType = baseType
        self.buckets = buckets
    }
}

package struct MetricData {
    var value: Any
    var delta: Any?
    var bins: [Double]?

    package init(from dict: [String: Any]) throws {
        guard let value = dict["value"] else {
            throw OSMetricEventError.missingMetricDataValue
        }
        self.value = value
        self.delta = dict["delta"]
        bins = dict["bins"] as? [Double]
    }
    
    package init(value: Any, delta: Any, bins: [Double]? = nil) {
        self.value = value
        self.delta = delta
        self.bins = bins
    }
}

package struct OSMetricEvent {
    var dimensions: [String: String]
    var label: String
    var metaData: MetricMetaData
    var data: MetricData
    var client: String
    var epoch: Double

    init(from event: OSLogEventProxy) throws {
        self.epoch = Date().timeIntervalSince1970
    
        guard let metricMetaDataDict = event.metricMetadata else {
            throw OSMetricEventError.missingMetricMetaData
        }
        self.metaData = try MetricMetaData(from: metricMetaDataDict)
    
        guard let metricDataDict = event.metricData as? [String: Any] else {
            throw OSMetricEventError.missingMetricData
        }
        self.data = try MetricData(from: metricDataDict)
    
        guard let metricLabel = event.metricLabel else {
            throw OSMetricEventError.missingMetricLabel
        }
        self.label = metricLabel
    
        guard let client = event.process else {
            throw OSMetricEventError.missingClientName
        }
        self.client = client

        if let dimensionsRaw = event.metricDimensions {
            self.dimensions = dimensionsRaw
        } else {
            self.dimensions = [:]
        }
    }

    package init(dimensions: [String: String], label: String, metaData: MetricMetaData,
         data: MetricData, client: String, epoch: Double) {
        self.dimensions = dimensions
        self.label = label
        self.metaData = metaData
        self.data = data
        self.client = client
        self.epoch = epoch
    }
}

#else
package struct OSMetricEvent {}
#endif
