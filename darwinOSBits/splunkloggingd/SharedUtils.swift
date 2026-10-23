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
//  SharedUtils.swift
//  splunkloggingd
//
//  Copyright © 2024 Apple, Inc.  All rights reserved.
//

internal import DarwinPrivate.os.variant
import Foundation
import MobileGestaltPrivate
import os
import SecureConfigDB
import OSAServicesClient
import OSAnalytics_Private

let sharedSubsystem = "com.apple.splunkloggingd"
fileprivate let log = Logger(subsystem: sharedSubsystem, category: "SharedUtils")
fileprivate let serialNo = MobileGestalt.current.serialNumber as String?

fileprivate let releaseType: String = MobileGestalt.current.releaseType
#if os(iOS)
fileprivate let isPCC: Bool = releaseType.contains("Darwin Cloud")
#else
fileprivate let isPCC: Bool = false
#endif

let kUsageLabelKey = "serverOS-usage-label"

// Lazily initialize / cache values so we only fetch once
fileprivate let hostNameWrapper = HostNameWrapper()
let kUsageLabelValue:String? = { getUsageLabel() }()
fileprivate let kIsAppleInternal:Bool = os_variant_has_internal_content(sharedSubsystem) || os_variant_has_internal_diagnostics(sharedSubsystem)
fileprivate let _testingMock: OSAllocatedUnfairLock<TestingMock?> = OSAllocatedUnfairLock(initialState: nil)
fileprivate let _canLogToStdout: OSAllocatedUnfairLock<Bool> = OSAllocatedUnfairLock(initialState: true)

fileprivate actor HostNameWrapper {
    private nonisolated let _hostname: OSAllocatedUnfairLock<String>
    private let updateTimer: DispatchSourceTimer
    private let timerFrequencySec: Double = 60.0

    init() {
        let fallbackHostname = ProcessInfo.processInfo.hostName
        let initialHostname = (fallbackHostname.count > 0) ? fallbackHostname : "hostname-not-found"
        log.log("Setting initial hostname to \(initialHostname, privacy: .public)");

        self._hostname = OSAllocatedUnfairLock(initialState: initialHostname)

        // Periodically try to fetch the hostname in case it's changed
        let queue = DispatchSerialQueue(label: "com.apple.splunkloggingd.hostname-update-queue")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        self.updateTimer = timer

        timer.schedule(deadline: .now(), repeating: self.timerFrequencySec)
        timer.setEventHandler {
            guard let newHostname = self._getDarwinHostName() else { return }
            self._hostname.withLock { ivar in
                guard ivar != newHostname else { return }

                log.log("Updating hostname to \(newHostname, privacy: .public)")
                ivar = newHostname
            }
        }
        timer.activate()
    }

    nonisolated
    private func _getDarwinHostName() -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let retVal = buffer.withUnsafeMutableBufferPointer { ptr -> CInt in
            return Darwin.gethostname(ptr.baseAddress, ptr.count)
        }

        if retVal == 0 {
            return String(cString: buffer)
        }

        let code = errno
        let err_s: String
        if let raw = strerror(code) {
            err_s = String(cString: raw)
        } else {
            err_s = "nil"
        }
        log.error("Failed to fetch darwin hostname with retval: \(retVal), errno: \(code), error: \(err_s, privacy: .private)")
        return nil
    }

    nonisolated
    func hostname() -> String {
        self._hostname.withLock { $0 }
    }
}

func getHostName() -> String {
    return hostNameWrapper.hostname()
}

func getBootSessionUUID() throws -> String {
    var size = 0
    guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0 else {
        throw SplunkloggingdError.missingBootSessionUUID("sysctlbyname(kern.bootsessionuuid) failed with errno \(Darwin.errno)")
    }

    var buf = [CChar](repeating: 0, count: size)
    guard sysctlbyname("kern.bootsessionuuid", &buf, &size, nil, 0) == 0 else {
        throw SplunkloggingdError.missingBootSessionUUID("sysctlbyname(kern.bootsessionuuid) failed with errno \(Darwin.errno)")
    }

    return String(cString: buf)
}

// MARK: --------------------- MOCKING LOGIC ---------------------

typealias OSAnalyticsMethod_t = @Sendable (OSADiagnosticObserver, [String]) -> Void
final class TestingMock: Sendable, CustomStringConvertible {
    let logFilteringEnforced: Bool?
    let crashRedactionEnabled: Bool?
    let logPolicyPath: URL?
    let registerForReports: OSAnalyticsMethod_t?
    let isInternal: Bool?
    let ownCrashDeletion: Bool?
    let crashDir: String?

    init(logFilteringEnforced: Bool? = nil,
         crashRedactionEnabled: Bool? = nil,
         logPolicyPath: URL? = nil,
         isInternal: Bool? = nil,
         registerForReports: OSAnalyticsMethod_t? = nil,
         ownCrashDeletion: Bool? = nil,
         crashDir: String? = nil)
    throws {
        if !kIsAppleInternal {
            throw SplunkloggingdError.mockingError("Trying to set SecureConfig mock on customer build!")
        }
        self.logFilteringEnforced = logFilteringEnforced
        self.crashRedactionEnabled = crashRedactionEnabled
        self.logPolicyPath = logPolicyPath
        self.isInternal = isInternal
        self.registerForReports = registerForReports
        self.ownCrashDeletion = ownCrashDeletion
        self.crashDir = crashDir
    }

    var description: String { get {
        return """

logFilteringEnforced: \(String(describing: logFilteringEnforced))
crashRedactionEnabled: \(String(describing: crashRedactionEnabled))
logPolicyPath: \(String(describing: logPolicyPath))
registerForReports non nil: \(registerForReports != nil)
isInternal: \(String(describing: isInternal))
"""
    }}
}

func canLogToStdout() -> Bool {
    return _canLogToStdout.withLock { $0 }
}

func setCanLogToStdout(_ newVal: Bool) {
    log.log("Setting canLogToStdout: \(newVal)")
    _canLogToStdout.withLock { ivar in
        ivar = newVal
    }
}

func setTestingMock(_ newMock: TestingMock?) throws {
    if !kIsAppleInternal {
        throw SplunkloggingdError.mockingError("Trying to set new testing mock on customer build!")
    }

    log.log("Setting testing mock: \(String(describing: newMock))")
    _testingMock.withLock { ivar in
        ivar = newMock
    }
}

func unsetTestingMock() {
    log.log("Unsetting testing mock")
    _testingMock.withLock { ivar in
        ivar = nil
    }
}

private func getTestingMock() -> TestingMock? {
    return _testingMock.withLock { ivar in
        return ivar
    }
}

func isAppleInternal() -> Bool {
    if kIsAppleInternal,
       let mock = getTestingMock(),
       let val = mock.isInternal
    {
        log.log("Found mocked value for isAppleInternal, returning \(val)")
        return val
    }
    return kIsAppleInternal
}

func getSerialNo() -> String? {
    return serialNo
}

// If crashes aren't deleted, ReportCrash will hit its cap and stop writing new ones.
// OTACrashCopier owns deletion on embedded, and SubmitDiagInfo on macOS
// Splunkloggingd has to own it in prcos. Can't check for just "above 2 mastered out" because there may be other configs
// in which something else owns this behavior. The tightest check we can enforce for now is "iOS Darwin Cloud"
func shouldOwnCrashDeletion() -> Bool {
    if kIsAppleInternal,
       let mock = getTestingMock(),
       let val = mock.ownCrashDeletion
    {
        log.log("Found mocked value for shouldOwnCrashDeletion, returning \(val)")
        return val
    }
    return isPCC
}

func systemCrashDir() -> String? {
    if kIsAppleInternal,
       let mock = getTestingMock(),
       let val = mock.crashDir
    {
        log.log("Found mocked value for crash dir, returning \(val)")
        return val
    }
    return OSASystemConfiguration.sharedInstance().pathSubmission()
}

func registerForOSAnalyticsReports(observer: OSADiagnosticObserver, types: [String]) {
    var f = OSADiagnosticMonitorClient.shared.add
    if kIsAppleInternal,
       let mock = getTestingMock(),
       let mockedF = mock.registerForReports
    {
        log.log("Found mocked value for OSAnalytics registration, registering for mock")
        f = mockedF
    }
    f(observer, types)
}

func getUsageLabel() -> String? {
    guard let value = CFPreferencesCopyValue(
        kUsageLabelKey as CFString,
        kCFPreferencesAnyApplication,
        kCFPreferencesAnyUser,
        kCFPreferencesCurrentHost) as? String else {
        log.error("Couldn't find value for key \(kUsageLabelKey, privacy: .public).")
        return nil
    }
    log.info("Found value of \(value, privacy: .public) for key \(kUsageLabelKey, privacy: .public).")
    return value
}

func jsonToData(_ json: [String:Any]) -> Data? {
    do {
        return try JSONSerialization.data(withJSONObject: json, options: [])
    } catch {
        log.error("JSON ERROR: \(error.localizedDescription, privacy: .public), payload:\n\(json, privacy: .public)")
    }

    return nil
}

func jsonToString(_ json: [String:Any]?) -> String {
    guard let json,
          let data = jsonToData(json) else {
        return "nil"
    }
    return String(decoding: data, as: UTF8.self)
}

func dataToJson(_ data: Data) -> [String:Any]? {
    do {
        return try JSONSerialization.jsonObject(with: data, options: []) as? [String : Any]
    } catch {
        log.error("JSON ERROR: \(error.localizedDescription, privacy: .public), payload:\n\(data, privacy: .public)")
    }

    return nil
}

/*
 * OSAnalytics reports consist of 2 JSON objects representing the header and the body of the report.
 * Attempt to parse header and body objects. If failure occurs or the file doesn't have this format,
 * return nil.
 */
func extractOSAnalyticsJson(from reportData: Data) -> [String:Any]? {
    let objs = reportData.split(separator: "\n".utf8, maxSplits: 1)
    let count = objs.count

    guard count == 2 else {
        log.error("Got os analytics event with unexpected number of elements: \(count)")
        return nil
    }

    guard let header = dataToJson(objs[0]),
          let body = dataToJson(objs[1])
    else {
        log.error("Found 2 elements in os analytics event, but failed to convert to json")
        return nil
    }

    var result: [String:Any] = ["header": header, "body": body]
    if let procName = body["procName"] as? String {
        result["process"] = procName
    }

    return result
}

/// Extract the modification date for a file
func modificationDate(forFile filePath: String) -> Date? {
    let fm = FileManager.default
    let attrs: [FileAttributeKey : Any]
    do {
        attrs = try fm.attributesOfItem(atPath: filePath)
    } catch {
        log.error("Failed to fetch file attrs for '\(filePath, privacy: .public)', not setting timestamp")
        return nil
    }

    guard let date = attrs[.modificationDate] as? Date else {
        log.error("Failed to fetch date from file attrs for '\(filePath, privacy: .public)', not setting timestamp")
        return nil
    }

    return date
}

// This has to be called at each event type's source. We can't do it at offload time because we batch log events, and these
// fields are needed within each one
func addSharedPayloadItems(to event: SplunkEvent?, index:String, globalLabels: [String: String]) -> SplunkEvent? {
    guard let event,
          var json = event.json()
    else {
        return nil
    }

    json["index"] = index
    json["sourcetype"] = String(describing: event)

    // System-wide usage label
    if (kUsageLabelValue != nil) || !globalLabels.isEmpty {
        var event: [String:Any] = json["event"] as? [String:Any] ?? [:]
        if let usageLabel = kUsageLabelValue {
            event["usageLabel"] = usageLabel
        }
        if !globalLabels.isEmpty {
            for (label, value) in globalLabels {
                event[label] = value
            }
        }
        json["event"] = event
    }

    guard let data = jsonToData(json) else {
        return nil
    }

    switch (event) {
    case .jsonEvent(_):
        return .jsonEvent(data: data)
    case .crashReport(_):
        return .crashReport(data: data)
    case .jetsamReport(_):
        return .jetsamReport(data: data)
    case .panicReport(_):
        return .panicReport(data: data)
    }
}

// MARK: --------------------- SECURE CONFIG ---------------------
// SecureConfig vars will be attested to and always set by darwin-init in the environments where they *must* be set.
// If not set, default to "off" to support the environments that don't set those vars.

fileprivate func _configuredSystemAuditTable() throws -> URL? {
    do {
        // First check if the system was configured with an audit table
        if let systemAuditTableDir: String = try SecureConfigParameters.loadContents().logPolicyPath {
            return URL(filePath: systemAuditTableDir)
        }
        return nil
    } catch {
        log.error("Failed to load secure config logPolicyPath with exception \(error, privacy: .public)")
        if isPCC {
            throw error
        } else {
            return nil
        }
    }
}

func configuredSystemAuditTable() throws -> URL? {
    var result: URL? = nil

    if kIsAppleInternal,
       let mock = getTestingMock()
    {
        result = mock.logPolicyPath
        log.log("Found mocked value for logPolicyPath, returning \(String(describing: result), privacy: .public)")
    } else {
        result = try _configuredSystemAuditTable()
    }

    result?.append(component: "log_audit_list.plist")

    log.log("audit table path: found value of \(String(describing: result), privacy: .public) from Secure Config")
    return result
}

fileprivate func _logFilteringEnforced() throws -> Bool? {
    do {
        let result = try SecureConfigParameters.loadContents().logFilteringEnforced
        log.log("logFilteringEnforced: found value of \(String(describing: result), privacy: .public) from Secure Config")
        return result
    } catch {
        log.error("SecureConfig error for logFilteringEnforced: \(error, privacy: .public)")
        if isPCC {
            throw error
        } else {
            return nil
        }
    }
}

func logFilteringEnforced() throws -> Bool {
    var result: Bool?

    if kIsAppleInternal,
       let mock = getTestingMock()
    {
        result = mock.logFilteringEnforced
        log.log("Found mocked value for logFilteringEnforced: \(String(describing: result), privacy: .public)")
    } else {
        result = try _logFilteringEnforced()
    }

    guard let result else {
        log.log("Got no value from SecureConfig for logFilteringEnforced, returning false")
        return false
    }
    return result
}

fileprivate func _crashRedactionEnabled() -> Bool? {
    do {
        let result = try SecureConfigParameters.loadContents().crashRedactionEnabled
        log.info("crashRedactionEnabled: found value of \(String(describing: result), privacy: .public) from Secure Config")
        return result
    } catch {
        // The path this is called from can't handle a thrown error, so we must handle it. Default to "on" for PCC
        log.error("SecureConfig error for crashRedactionEnabled, defaulting to true: \(error, privacy: .public)")
        if isPCC {
            return true
        } else {
            return false
        }
    }
}

// Error: default to true, something likely broken
// nil: default to false, value not set to support legacy environments
func crashRedactionEnabled() -> Bool {
    var result: Bool?

    if kIsAppleInternal,
       let mock = getTestingMock()
    {
        result = mock.crashRedactionEnabled
        log.log("Found mocked value for crashRedactionEnabled: \(String(describing: result), privacy: .public)")
    } else {
        result = _crashRedactionEnabled()
    }

    guard let result else {
        log.info("Got no value from SecureConfig for crashRedactionEnabled, returning false")
        return false
    }
    return result
}

func urlReqToString(_ req: URLRequest) -> String {
    guard let body = req.httpBody else {
        return "<nil>"
    }
    return body.map { String(format: "%c", $0) }.joined()
}
