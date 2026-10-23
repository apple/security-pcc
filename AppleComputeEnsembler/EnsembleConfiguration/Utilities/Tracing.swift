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
//  Tracing.swift
//  AppleComputeEnsembler
//
//  Created by Dhanasekar Thangavel on 5/14/25.
//

import os
import Foundation

public enum ConvergenceSummaryStatus: String {
    case ok = "OK"
    case error = "ERROR"
}

public enum ConvergenceSummaryClock {
    public typealias Timestamp = Int64
    /// Returns current time in nanoseconds since UNIX Epoch (January 1st 1970)
    public static var now: Timestamp {
        var ts = timespec()
        clock_gettime(CLOCK_REALTIME, &ts)
        /// We use unsafe arithmetic here because `UInt64.max` nanoseconds is more than 580 years,
        /// and the odds that this code will still be running 530 years from now is very, very low,
        /// so as a practical matter this will never overflow.
        let nowNanos = Int64(ts.tv_sec) &* 1_000_000_000 &+ Int64(ts.tv_nsec)

        return nowNanos
    }
}

public protocol ConvergenceSummary {
    var traceID: String? { get }
    var operationName: String { get }
    var type: String { get }
    var serviceName: String { get }
    var namespace: String { get }
    var startTimeNanos: Int64? { get set }
    var endTimeNanos: Int64? { get set }
    var durationMicros: Int64? { get }
    var status: ConvergenceSummaryStatus? { get }
    var error: Error? { get set }

    /// Populate the status and error fields, appropriately handling `ReportableError`
    mutating func populate(error: Error)

    /// Emit the log event
    func log(to logger: Logger)
}

extension ConvergenceSummary {
    public var status: ConvergenceSummaryStatus? {
        if error != nil {
            return .error
        } else {
            return .ok
        }
    }

    public var durationMicros: Int64? {
        switch (startTimeNanos, endTimeNanos) {
        case (.some(let startTimeNanos), .some(let endTimeNanos)):
            return Int64(endTimeNanos / 1000) - Int64(startTimeNanos / 1000)
        case _: return nil
        }
    }
}

extension ConvergenceSummary {
    public mutating func populate(error: Error) {
        self.error = error
    }
}

public protocol ConvergenceCheckpoint {
    var requestID: String? { get }
    var operationName: String { get }
    var type: StaticString { get }
    var serviceName: StaticString { get }
    var namespace: StaticString { get }
    var status: ConvergenceSummaryStatus? { get }
    var error: Error? { get set }

    /// Emit the log event
    func log(to logger: Logger, level: OSLogType)
}

extension ConvergenceCheckpoint {
    // This is just the naming to represent span event
    public var type: StaticString { "RequestCheckpoint" }

    public var status: ConvergenceSummaryStatus? {
        if error != nil {
            return .error
        } else {
            return .ok
        }
    }
}

public func getNanoSec() -> Int64 {
    return Int64(Date().timeIntervalSince1970 * 1_000_000_000)
}

public func generateSpanId() -> String {
    let spanId = UInt64.random(in: 0..<UInt64.max)
    return String(format: "%016llx", spanId)
}

func generateTraceID() -> String {
    return UUID().uuidString.replacingOccurrences(of: "-", with: "")
}

// construct links to trace from the trace_id and span_id we got from darwininit
public func getJsonFormattedTraceLink(traceID: String?, spanID: String?) -> String {
    
    guard let traceID = traceID, let spanID = spanID else {
        return ""
    }
    
    let jsonArray: [[String: String]] = [
        [
            "trace_id": traceID,
            "span_id": spanID
        ]
    ]

    if let jsonData = try? JSONSerialization.data(withJSONObject: jsonArray, options: .prettyPrinted),
       let jsonString = String(data: jsonData, encoding: .utf8) {
        return jsonString
    }
    
    return ""
}

struct EnsembleFormationConvergenceCheckpoint: ConvergenceCheckpoint {
    var requestID: String?
    let traceID: String?
    let spanID: String?
    let linkTraceID: String?
    let linkSpanID: String?
    var operationName: String
    let serviceName: StaticString = "ensembled"
    let namespace: StaticString = "com.apple.cloudos.AppleComputeEnsembler"
    var error: Error?

    public init(
           operationName: String,
           error: Error? = nil,
           traceID: String? = nil,
           spanID: String? = nil,
           linkTraceID: String? = nil,
           linkSpanID: String? = nil
       ) {
           self.operationName = operationName
           if let error {
               self.error = error
           }
           self.traceID = traceID
           self.spanID = spanID
           self.linkTraceID = linkTraceID
           self.linkSpanID = linkSpanID
       }

       public func log(to logger: Logger, level: OSLogType = .default) {
           let time = getNanoSec()
           logger.log(level: level, """
           ttl=\(self.type, privacy: .public)
           tracing.name=\(self.operationName, privacy: .public)
           tracing.type=\(self.type, privacy: .public)
           tracing.trace_id=\(self.traceID ?? "", privacy: .public)
           tracing.span_id=\(self.spanID ?? "", privacy: .public)
           tracing.time_unix_nano=\(time, privacy: .public)
           service.name=\(self.serviceName, privacy: .public)
           service.namespace=\(self.namespace, privacy: .public)
           tracing.status=\(status?.rawValue ?? "", privacy: .public)
           error.type=\(self.error.map { String(describing: Swift.type(of: $0)) } ?? "", privacy: .public)
           error.description=\(self.error, privacy: .public)
           trace-origin=\(self.linkTraceID ?? "", privacy: .public)
           tracing.links=\(getJsonFormattedTraceLink(traceID: linkTraceID, spanID: linkSpanID), privacy: .public)
           """)
       }

}
struct EnsembleFormationConvergenceSummary: ConvergenceSummary {
    let operationName: String = "ensemble formation"
    let type: String = "RequestSummary"
    let traceID: String?
    let spanID: String?
    let linkTraceID: String?
    let linkSpanID: String?
    let serviceName: String = "ensembled"
    let namespace: String = "com.apple.cloudos.AppleComputeEnsembler"
    var error: Error?
    var startTimeNanos: Int64?
    var endTimeNanos: Int64?

    public init(
           error: Error? = nil,
           traceID: String? = nil,
           spanID: String? = nil,
           linkTraceID: String? = nil,
           linkSpanID: String? = nil
       ) {
           
           self.traceID = traceID
           self.spanID = spanID
           self.linkTraceID = linkTraceID
           self.linkSpanID = linkSpanID
           
           if let error {
               self.error = error
           }
       }
    
    /// NOTE: This value will be logged as public and therefore must not contain public information
    public func log(to logger: Logger) {
        logger.log("""
        ttl=\(self.type, privacy: .public)
        tracing.name=\(self.operationName, privacy: .public)
        tracing.type=\(self.type, privacy: .public)
        tracing.trace_id=\(self.traceID ?? "", privacy: .public)
        tracing.span_id=\(self.spanID ?? "", privacy: .public)
        tracing.parent_span_id=""
        tracing.start_time_unix_nano=\(self.startTimeNanos ?? 0, privacy: .public)
        tracing.end_time_unix_nano=\(self.endTimeNanos ?? 0, privacy: .public)
        service.name=\(self.serviceName, privacy: .public)
        service.namespace=\(self.namespace, privacy: .public)
        durationMicros=\(self.durationMicros ?? 0, privacy: .public)
        tracing.status=\(self.status?.rawValue ?? "", privacy: .public)
        error.type=\(self.error.map { String(describing: Swift.type(of: $0)) } ?? "", privacy: .public)
        error.description=\(self.error, privacy: .public)
        trace-origin=\(self.linkTraceID ?? "", privacy: .public)
        tracing.links=\(getJsonFormattedTraceLink(traceID: linkTraceID, spanID: linkSpanID), privacy: .public)
        """)
    }
}
