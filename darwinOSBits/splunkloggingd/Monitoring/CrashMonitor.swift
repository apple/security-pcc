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
//  CrashMonitor.swift
//  splunkloggingd
//
//  Copyright © 2024 Apple, Inc.  All rights reserved.
//

import CoreDiagnostics
import Foundation
import LoggingSupport
import OSAServicesClient

fileprivate let log = Logger(subsystem: sharedSubsystem, category: "CrashMonitor")

protocol CrashMonitorDelegate: AnyObject {
    func handleJetsamEvent(_ event: SplunkEvent) async
    func handleCrashEvent(_ event: SplunkEvent) async
}

// Break this out for testing
func pruneCrashes(atDir dir: URL) {
    let fm = FileManager.default
    let keys: [URLResourceKey] = [.creationDateKey]
    let cutoffTime = Date.now.addingTimeInterval(-CrashDeleter.maxCrashAgeSec)
    log.log("Requested to prune crashes")

    guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: keys) else {
        log.error("Failed to create enumerator at crash dir: \(dir.path(), privacy: .public)")
        return
    }

    var allItems: [(Date, URL)] = []
    for case let elem as URL in enumerator {
        guard let resourceValues = try? elem.resourceValues(forKeys: Set(keys)),
              let creationDate = resourceValues.creationDate
        else {
            log.error("Failed to fetch creation date for crash at path \(elem.path(), privacy: .public)")
            continue
        }

        if (elem.pathExtension == "ips") {
            allItems.append((creationDate, elem))
        }
    }

    // Want oldest file at index 0
    allItems.sort { l, r in
        // Tuple is (creationDate: Date, path: URL)
        return l.0 < r.0
    }

    // Delete at least these many. May delete more if too-old crashes found
    var numToDelete = max(allItems.count - CrashDeleter.maxCrashes, 0)
    log.log("Pruning crashes created before \(cutoffTime, privacy: .public) or more than max crashes (\(CrashDeleter.maxCrashes)). Found \(allItems.count); deleting at least \(numToDelete)")

    for item in allItems {
        let date: Date = item.0
        let url: URL = item.1

        // If we've deleted the minimum required and we've arrived at a "new enough" file, we can stop
        if (numToDelete == 0) && (date >= cutoffTime) {
            break
        }

        do {
            try fm.removeItem(at: url)
            log.log("Removed crash at path \(url.path(), privacy: .public) of age \(date, privacy: .public)")
        } catch {
            log.error("Failed to delete crash at path \(url.path(), privacy: .public) of age \(date, privacy: .public) with error: \(error, privacy: .public)")
        }

        numToDelete = max(numToDelete - 1, 0)
    }

    // Note: this will catch other .ips bug types as well, such as ExcResource, jetsam, etc. This is okay for now, but
    // if we find we *don't* want them deleted, we either need to parse the file or check the xattrs for bug type 309
}

class CrashDeleter {
    // Deletion policy is anything older than maxCrashAgeSec, or any crashes over maxCrashes (oldest first)
    static let maxCrashAgeSec: Double = (60 * 60 * 24 * 7) // 7 days
    static let maxCrashes = 100
    static let defaultDeletionInterval: Double = 10 * 60 // 10 minutes
    private let deletionInterval: Double // Break out from default for testing

    // Timer to check for old crashes that should be deleted.
    // In PRCOS the thing that normally does crash retiring / deletion (OTACrashCopier) doesn't exist. If nothing
    // deletes crashes, then ReportCrash will hit its limit of crashes on disk and stop writing reports. It falls to
    // splunkloggingd to do the deletion as it's the only crash consumer
    private var deletionTimer: DispatchSourceTimer?

    init(withInterval interval: Double) {
        self.deletionTimer = nil
        self.deletionInterval = interval
    }

    func start() {
        if !shouldOwnCrashDeletion() {
            log.log("Not configured to own crash deletion, so not setting deletion timer")
            return
        }

        // Only schedule deletion if we have a path to delete from
        guard let crashDir = systemCrashDir() else {
            log.error("Failed to get crash dir from OSAnalytics, not setting deletion timer")
            return
        }

        let crashDirURL = URL(filePath: crashDir)
        let queue = DispatchQueue(label: "com.apple.splunkloggingd.CrashMonitor.DeletionQueue")
        self.deletionTimer = DispatchSource.makeTimerSource(queue: queue)

        log.log("Scheduling crash deletion for every \(self.deletionInterval) seconds")
        self.deletionTimer?.schedule(deadline: .now() + self.deletionInterval, repeating: self.deletionInterval)
        self.deletionTimer?.setEventHandler {
            pruneCrashes(atDir: crashDirURL)
        }
        self.deletionTimer?.setCancelHandler {
            log.log("Crash deletion timer source cancelled")
        }
        self.deletionTimer?.activate()
    }
}

class CrashMonitor: NSObject {
    weak var delegate: CrashMonitorDelegate? = nil
    let deleter: CrashDeleter

    // On failure, we still want to send something to Splunk to denote a crash
    private func fallbackReportData(from reportData: Data, atPath pathString: String) -> [String:Any] {
        log.error("Failed to decode crash report. Sending failure breadcrumb for path \(pathString)")

        let data: String
        if crashRedactionEnabled() {
            data = "Failed to decode crash report format for path \(pathString)"
        } else {
            // If we don't need to redact, send the entire contents as a string
            data = String(decoding: reportData, as: UTF8.self)
        }
        return ["crashReport": data]
    }

    func formatCrashReport(atPath pathString: String) -> SplunkEvent? {
        let pathURL = URL(fileURLWithPath: pathString)
        log.log("Formatting crash report at path: \(pathString, privacy: .public)")

        guard let report = CrashReport(reportPath: pathURL) else {
            log.error("Failed to initialize crash report")
            return nil
        }
        report.prepareReportForSubmission()

        guard let redactedReportData: Data = report.reportData else {
            log.error("Failed to redact crash report")
            return nil
        }

        var event: [String:Any] = extractOSAnalyticsJson(from: redactedReportData) ??
                                  fallbackReportData(from: redactedReportData, atPath: pathString)

        if let serialNo = getSerialNo() {
            event["serial"] = serialNo
        }

        var payload: [String: Any] = [
            "event": event,
            "source": pathString
        ]
        if let date = modificationDate(forFile: pathString) {
            payload["time"] = date.timeIntervalSince1970
        }

        guard let jsonData = jsonToData(payload) else {
            return nil
        }
        return .crashReport(data: jsonData)
    }

    // Note: since jetsam collection is internal-only, we don't need any redaction
    func formatJetsamReport(atPath path: String) -> SplunkEvent? {
        log.log("Formatting jetsam report at path: \(path, privacy: .public)")
        let pathURL = URL(fileURLWithPath: path)
        let reportData: Data
        do {
            reportData = try Data(contentsOf: pathURL)
        } catch {
            log.error("Couldn't read jetsam at path '\(path, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            return nil
        }

        var event: [String:Any]
        if let rawReport = extractOSAnalyticsJson(from: reportData) {
            event = rawReport
        } else {
            log.error("Failed to decode jetsam report. Sending raw data for path \(path, privacy: .public)")
            event = ["jetsamReport": String(decoding: reportData, as: UTF8.self)]
        }

        if let serialNo = getSerialNo() {
            event["serial"] = serialNo
        }

        var payload: [String: Any] = [
            "event": event,
            "source": path
        ]
        if let date = modificationDate(forFile: path) {
            payload["time"] = date.timeIntervalSince1970
        }

        guard let responseData = jsonToData(payload) else {
            return nil
        }
        return .jetsamReport(data: responseData)

    }

    func start() {
        // Per discussion with OSAnalytics, ReportSystemMemory will write out a JetsamEvent report if the proc is
        // actually terminated by jetsam with bug type 298.
        // Crashes are 309
        var types = ["309"]
        if isAppleInternal() {
            types.append("298")
        }
        log.log("Registering for logs of types: \(types)")
        registerForOSAnalyticsReports(observer: self, types: types)
        self.deleter.start()
    }

    // Allow passing this in for testing
    init(withDeletionTimeout timeout: Double = CrashDeleter.defaultDeletionInterval) {
        self.deleter = CrashDeleter(withInterval: timeout)
    }
}

extension CrashMonitor: OSADiagnosticObserver {
    func willWriteDiagnosticLog(_ bugType: String, logId: String, logInfo: [AnyHashable : Any]) {
        // Don't care if logs going to be written, only care once they're finished being written
        return
    }

    func didWriteDiagnosticLog(_ bugType: String, logId: String, logFilePath path: String?, logInfo: [AnyHashable : Any], error: (any Error)?) {
        log.log("Received OSAnalyticsObserver callback with bugType: \(bugType, privacy: .public), path: \(path ?? "nil", privacy: .public)")
        log.info("Additional args: logID: \(logId, privacy: .public), logInfo: \(String(describing: logInfo), privacy: .private)")

        if let error {
            log.error("Received error in OSAnalyticsObserver handler: \(error.localizedDescription, privacy: .private)")
            return
        }

        guard let path else {
            return
        }

        switch bugType {
        case "298":
            if !isAppleInternal() {
                log.error("Received bug type 298 (Jetsam) on customer build!")
                return
            }
            if let event = self.formatJetsamReport(atPath: path) {
                Task { await self.delegate?.handleJetsamEvent(event) }
            }
        case "309":
            if let event = self.formatCrashReport(atPath: path) {
                Task { await self.delegate?.handleCrashEvent(event) }
            }
        default:
            log.error("Received unexpected bugType, not handling")
        }
    }
}
