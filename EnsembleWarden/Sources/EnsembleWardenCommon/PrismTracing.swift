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
//  PrismTracing.swift
//  EnsembleWarden
//
//  Created by Oliver Chick (ORAC) on 16/09/2025.
//

private import CryptoKit
#if canImport(AppleComputeEnsembler)
@_weakLinked private import AppleComputeEnsembler
#endif
private import Dispatch
package import Foundation
internal import OSLog
@preconcurrency internal import os.activity
private import Synchronization

/// # Distributed tracing for PCC services using Prism.
///
/// Darwin does not have inbuilt distributed tracing mechanisms. Moreover, even if it did, operating
/// those in a way that is consistent with the PCC log approvals is non-trivial. Prism is how we
/// get most of the distributed tracing features, but built ontop of our existing logging mechanism.
///
/// ## Why should I use it?
/// PCC services are highly distributed: requests can use 50+ different servers and near 1,000 different
/// processes. When there are errors or slowness we need to know where these are coming from.
/// Doing this via splunk or 50 sysdiagnoses is really tricky. Prism however lets us visualise the flow
/// of data throughout the distribtued system to determine where errors come from and where time goes.
///
/// ## Show me an example
/// Take a look on Slack - people are always posting links to prism traces there.
///
/// ## How do I use it?
/// Start with your public APIs. These should already take a `(requestID: UUID, spanID: UInt64)`.
/// For each public API you should call `PrismTracing.withResumed(requestID: spanID:)` thus:
/// ```swift
///  public func myFoo(myArg: MyArg, requestID: UUID, spanID: UInt64) async {
///    await PrismTracing.withResumed(requestID: requestID, spanID: spanID) {
///      await handle(myArg: myArg)
///    }
///  }
/// ```
///
/// Now you can (and should) create subspans to separate out bits of work.
///
/// ```swift
///  private func handle(myArg: MyArg) async {
///    await PrismTracing.withSpan(name: "first-thing") {
///      await doAThing(myArg: myArg)
///    }
///    await PrismTracing.withSpan(name: "second-thing") {
///      await doAnotherThing(myArg: myArg)
///    }
///  }
/// ```
///
/// Whenever you want to get the current `requestID` you can get that from `PrismTracing.requestID`.
/// Similarly, you can get the spanID from`PrismTracing.spanID`.
///
/// ## How does this interact with Swift concurrency?
/// Good question. We use a combination of Swift task-locals and os_activity_t to handle context.
/// If you use `Task{}` or `withTaskGroup()` APIs, these should propagate your activities. If you use
/// `Task.detached{}` you might need to ensure you're handling personas correctly or use
/// `PrismTracing.resume(requestID: spanID:)`. Similarly, if you're being clever with swift Async
/// you may need to propagate this. But anyone being that clever can surely get this to work.
///
/// ## Do I need to pass around (requestID, spanID)?
/// No. `PrismTracing` does that for you. The only place you need to propagate manually is when you
/// cross process boundaries you need to pass on the requestID. So long as you are passing vouchers
/// correctly (which you should) the spanID should be propagated for you.
///
/// ## Why isn't this a framework?
/// * Base darwin does not currently offer a tracing framework.
/// * We could distribute a framework in the sparse SDK. But do you want another sparse SDK dependency?
/// * Would you just end up cargo-culting around a file to mock-out the dependency?
///
/// ## Why isn't this an SPM library?
/// * Are you going to then cargo-cult around a `Package.swift` that declares the dependency?
/// * Will you also cargo-cult around a bash script to update the dependency?
/// * Frameworks and static libs compose badly.
///
/// ## Why isn't this a submodule?
/// * Are submodules really making your life easier?
/// * As well as the usual submodule hassle, you now need to agree on the right set of compiler flags for things
///  like concurrency, import visibility, consistent weak-linking of dependencies etc.
/// * Ie, it's likely you might need to make syntax changes to this file for your codebase - swift is not designed to drop-in
/// source files and not be able to mutate them.
///
/// ## Maintaining the list of key=value pairs in my code and the audit lists is a pain
/// Yes. This is to fulfil the customer promise we made: https://security.apple.com/documentation/private-cloud-compute/management#Log-filtering
///
/// ## Why can't you provide wrappers for OSLog that mean I don't need to craft these checkpoints manually?
/// OSLog can't be wrapped:
///
/// ## Why can't you provide a Swift macro then?
/// Swift macros in B&I are a beast. Even for the OS they're hard. Given all the weirdness
/// with the app train it would not be prudent to use macros.
///
package enum PrismTracing {
    // Logging constants
    package static let subsystem = "com.apple.cloudos.prism"
    package static let category = "PrismTracing"
    
    fileprivate static func computeSpanID(from activityID: UInt64) -> UInt64 {
        var h = SHA256()
        var activityIDCopy = activityID
        h.update(data: Data(bytes: &activityIDCopy, count: MemoryLayout<UInt64>.size))
        h.update(data: salt)
        let hash = h.finalize()
        return hash.withUnsafeBytes { bytes in
            bytes.load(as: UInt64.self)
        }
    }

    internal static var currentSpan: Span {
        if let span = TaskLocal.span.wrappedValue {
            return span
        }

        let currentActivityID = self.currentActivityID
        let requestID = activityToRequestIDLock.withLock { $0[currentActivityID] }
        
        let finalRequestID = requestID ?? .init()
        assert(requestID != nil, "No requestID found in mapping for activityID")

        return Span(requestID: finalRequestID, activityID: currentActivityID, parentSpanID: nil)
    }

    /// The current spanID.
    package static var spanID: UInt64 {
        return currentSpan.spanID
    }

    /// The current requestID.
    package static var requestID: UUID {
        return currentSpan.requestID
    }

    private static var currentActivityID: UInt64 {
        return os_activity_get_identifier(currentOSActivitySymbol, nil)
    }

    /// Resume an in-progress trace from a requestID and a spanID.
    ///
    /// This is typically used when the system is midway through a request and calling into a new process.
    /// That process needs to add data to the existing trace at a particular requestID/spanID.
    /// Use this function to set the current tracing context to that point you wish to resume from.
    ///
    /// - Parameters:
    ///  - requestID: The requestID that you wish to resume. This is often passed to your framework as a parameter.
    ///  - spanID: The span you wish to resume from. If you already have a correct OS persona and your caller
    ///  is using this implementation this can be inferred from the persona. Set to be `nil` in this case.
    package static func withResumed<T>(requestID: UUID, spanID: UInt64? = nil,
                                       operation: () async throws -> T) async rethrows -> T {
        let currentActivity = self.currentActivityID
        let span: Span
        if let spanID {
            span = Span(requestID: requestID, spanID: spanID, activityID: currentActivity, parentSpanID: nil)
        } else {
            span = Span(requestID: requestID, activityID: currentActivity, parentSpanID: nil)
        }

        defer {
            _ = activityToRequestIDLock.withLock { mapping in
                mapping.removeValue(forKey: currentActivity)
            }
        }
        return try await TaskLocal.span.withValue(span) {
            return try await operation()
        }
    }

    package static func withSyncResumed<T>(requestID: UUID, spanID: UInt64? = nil,
                                           operation: () throws -> T) rethrows -> T {
        let currentActivity = self.currentActivityID
        let span: Span
        if let spanID {
            span = Span(requestID: requestID, spanID: spanID, activityID: currentActivity, parentSpanID: nil)
        } else {
            span = Span(requestID: requestID, activityID: currentActivity, parentSpanID: nil)
        }
        defer {
            _ = activityToRequestIDLock.withLock { mapping in
                mapping.removeValue(forKey: currentActivity)
            }
        }
        return try TaskLocal.span.withValue(span) {
            return try operation()
        }
    }

    /// Creates a new subspan.
    ///
    /// Code executed in the callback will automatically execute with the new subspan. If the code throws
    /// this will be treated as a span error.
    package static func withSpan<T>(name: String, operation: () async throws -> T) async rethrows -> T {
        try await self.currentSpan.withSpan(name: name) {
            do {
                let result = try await operation()
                self.currentSpan.logSummary(name: name)
                return result
            } catch {
                self.currentSpan.logSummary(name: name, error: error)
                throw error
            }
        }
    }

    package static func logCheckpoint(name: String) {
        currentSpan.logCheckpoint(name: name)
    }

    package static func logCheckpoint(name: String, error: any Error) {
        currentSpan.logCheckpoint(name: name, error: error)
    }
}

extension UInt64 {
    package var hexEncoded: String {
        String(format:"%016llx", self)
    }
}

// Yes - this is really what you have to do to get the current activity.
/// Symbol used to tell os.activity that we want to fetch the current activityID.
fileprivate let currentOSActivitySymbol: OS_os_activity = {
    let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
    return unsafeBitCast(dlsym(rtldDefault, "_os_activity_current"), to: OS_os_activity.self)
}()

// Hash the activityID with the rank.
// This is needed
fileprivate let salt: Data = {
#if canImport(AppleComputeEnsembler)
    let nodeUniqueValue: String
    if #_hasSymbol(AppleComputeEnsembler.DerivedKeyType.self) {
        let semaphore = DispatchSemaphore(value: 0)
        let resultLock = Mutex<String>("")
        
        Task { @Sendable in
            do {
                let nodeInfo = try await EnsemblerSession().getNodeInfo()
                resultLock.withLock { $0 = "\(nodeInfo.UDID)-\(nodeInfo.rank)" }
            } catch {
                // Fall back to empty string if we can't get node info
                resultLock.withLock { $0 = "" }
            }
            semaphore.signal()
        }
        
        semaphore.wait()
        nodeUniqueValue = resultLock.withLock { $0 }
    } else {
        nodeUniqueValue = ""
    }
    return nodeUniqueValue.data(using: .utf8)!
#else
    "0".data(using: .utf8)!
#endif
}()

package struct PrismTracingConfig {
    internal var serviceName: String
    internal var serviceNamespace: String

    internal static let `default` = PrismTracingConfig(
        serviceName: "ensemblewarden",
        serviceNamespace: "ensemblewarden",
    )
}

extension TaskLocal where Value == Span? {
    fileprivate static let span = TaskLocal<Span?>(wrappedValue: nil)
}

/// There's a load of plumbing through the OS to propagate activity IDs. We use activity IDs as
/// span IDs. Unfortunately there's no plumbing to let us propagate request IDs quite so nicely.
/// We therefore maintain a map from spanID to requestID (for active spans) to restore the request
/// ID when it has been lost.
fileprivate let activityToRequestIDLock = Mutex<[UInt64: UUID]>([:])

internal struct Span: Sendable {
    internal var requestID: UUID
    internal var spanID: UInt64
    internal var parentSpanID: UInt64?
    internal var startTime: Date

    internal var unixTimeNS: Int {
        Int(Date().timeIntervalSince1970 * 1_000_000_000)
    }

    internal var duration: TimeInterval {
        Date().timeIntervalSince(self.startTime)
    }

    internal let logger = Logger(subsystem: PrismTracing.subsystem, category: PrismTracing.category)

    fileprivate init(requestID: UUID, spanID: UInt64, activityID: UInt64, parentSpanID: UInt64? = nil) {
        self.requestID = requestID
        self.parentSpanID = parentSpanID
        self.spanID = spanID
        self.startTime = Date()

        activityToRequestIDLock.withLock { mapping in
            mapping[activityID] = requestID
        }
    }

    fileprivate init(requestID: UUID, activityID: UInt64, parentSpanID: UInt64? = nil) {
        // ActivityIDs increment, rather than being random.
        // For a distributed system this puts us at risk of (requestID, spanID) collisions.
        // We therefore combine with a salt and SHA.
        // This gives us random spanIDs but also means we can always map activityID->spanID
        // without maintaining state.
        let spanID = PrismTracing.computeSpanID(from: activityID)
        self.init(requestID: requestID, spanID: spanID, activityID: activityID, parentSpanID: parentSpanID)
    }

    fileprivate func createActivity(name: String, dso: UnsafeRawPointer? = #dsohandle) -> os_activity_t {
        return name.utf8CString.withUnsafeBufferPointer {
            if let dso = UnsafeMutableRawPointer(mutating: dso), let address = $0.baseAddress {
                let str = UnsafeRawPointer(address).assumingMemoryBound(to: Int8.self)
                return _os_activity_create(dso, str, currentOSActivitySymbol, os_activity_flag_t(rawValue: 0))
            }
            fatalError()
        }
    }

    fileprivate func withSpan<T>(name: String, operation: () async throws -> T) async rethrows -> T {
        let activity = createActivity(name: name)
        let activitySpanID = os_activity_get_identifier(activity, nil)
        let childSpan = Span(requestID: self.requestID, activityID: activitySpanID, parentSpanID: self.spanID)

        var state = os_activity_scope_state_s()
        os_activity_scope_enter(activity, &state)
        defer {
            os_activity_scope_leave(&state)
            _ = activityToRequestIDLock.withLock { mapping in
                mapping.removeValue(forKey: activitySpanID)
            }
        }

        return try await TaskLocal.span.withValue(childSpan) {
            do {
                let result = try await operation()
                return result
            } catch {
                throw error
            }
        }
    }

    fileprivate func logSummary(name: String, error: any Error) {
        logger.log("""
            tracing.type=RequestSummary
            tracing.name=\(name, privacy: .public)
            tracing.trace_id=\(self.requestID.traceID, privacy: .public)
            tracing.parent_span_id=\(self.parentSpanID?.hexEncoded ?? "", privacy: .public)
            tracing.span_id=\(self.spanID.hexEncoded, privacy: .public)
            tracing.status=\("ERROR", privacy: .public)
            tracing.start_time_unix_nano=\(Int64(self.startTime.timeIntervalSince1970 * 1_000_000_000), privacy: .public)
            tracing.end_time_unix_nano=\(self.unixTimeNS, privacy: .public)
            service.name=\(PrismTracingConfig.default.serviceName, privacy: .public)
            service.namespace=\(PrismTracingConfig.default.serviceNamespace, privacy: .public)
            error.type=\(String(describing: Swift.type(of: error)), privacy: .public)
            error.description=\(String(reportable: error), privacy: .public)
            """)
    }

    fileprivate func logSummary(name: String) {
        logger.log("""
            tracing.type=RequestSummary
            tracing.name=\(name, privacy: .public)
            tracing.trace_id=\(self.requestID.traceID, privacy: .public)
            tracing.parent_span_id=\(self.parentSpanID?.hexEncoded ?? "", privacy: .public)
            tracing.span_id=\(self.spanID.hexEncoded, privacy: .public)
            tracing.status=\("OK", privacy: .public)
            tracing.start_time_unix_nano=\(Int64(self.startTime.timeIntervalSince1970 * 1_000_000_000), privacy: .public)
            tracing.end_time_unix_nano=\(self.unixTimeNS, privacy: .public)
            service.name=\(PrismTracingConfig.default.serviceName, privacy: .public)
            service.namespace=\(PrismTracingConfig.default.serviceNamespace, privacy: .public)
            """)
    }
}


extension Span {
    fileprivate func logCheckpoint(name: String) {
        // Log tracing.name first - this makes it easier to read log lines since the "useful"
        // bit is at the start of the log line.
        logger.log("""
            tracing.name=\(name, privacy: .public)
            request.duration_ms=\(duration * 1000)
            request.uuid=\(self.requestID, privacy: .public)
            tracing.type=RequestCheckpoint
            tracing.trace_id=\(self.requestID.traceID, privacy: .public)
            tracing.span_id=\(self.spanID.hexEncoded, privacy: .public)
            tracing.status=OK
            tracing.time_unix_nano=\(self.unixTimeNS, privacy: .public)
            service.name=\(PrismTracingConfig.default.serviceName, privacy: .public)
            service.namespace=\(PrismTracingConfig.default.serviceNamespace, privacy: .public)
            """)
    }

    fileprivate func logCheckpoint(name: String, error: Error) {
        // Log tracing.name first - this makes it easier to read log lines since the "useful"
        // bit is at the start of the log line.
        logger.log("""
            tracing.name=\(name, privacy: .public)
            request.duration_ms=\(duration * 1000)
            request.uuid=\(self.requestID, privacy: .public)
            tracing.type=RequestCheckpoint
            tracing.trace_id=\(self.requestID.traceID, privacy: .public)
            tracing.span_id=\(self.spanID.hexEncoded, privacy: .public)
            tracing.status=\("ERROR", privacy: .public)
            tracing.time_unix_nano=\(self.unixTimeNS, privacy: .public)
            service.name=\(PrismTracingConfig.default.serviceName, privacy: .public)
            service.namespace=\(PrismTracingConfig.default.serviceNamespace, privacy: .public)
            error.type=\(String(describing: Swift.type(of: error)), privacy: .public)
            error.description=\(String(reportable: error), privacy: .public)
            """)
    }
}

extension UUID {
    var traceID: String {
        uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}
