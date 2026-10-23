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
//  PanicMonitor.swift
//  splunkloggingd
//
//  Copyright © 2024 Apple, Inc.  All rights reserved.
//

import Foundation
import LoggingSupport
import os
import PanicHelper

fileprivate let log = Logger(subsystem: sharedSubsystem, category: "PanicMonitor")

protocol PanicMonitorDelegate: AnyObject, Sendable {
    func handlePanicEvent(_ event: SplunkEvent) async
}

/// Monitor for the creation of panic logs and forward the file if found
actor PanicMonitor {
    // DumpPanic will create this file with 400 perms when it has finished running. If a panic was written, this file will
    // contain the path to the panic file. Otherwise, it will be empty.
    static var defaultBreadCrumbURL: URL = URL(filePath: "/private/var/db/com.apple.DumpPanic.panicLogPathBreadcrumb")
    private let breadCrumbURL: URL

    private var breadCrumbMonitor: FileMonitor
    weak var delegate: PanicMonitorDelegate? = nil

    init(at url: URL = PanicMonitor.defaultBreadCrumbURL) async {
        self.breadCrumbURL = url
        self.breadCrumbMonitor = .init(url: breadCrumbURL)
        await self.breadCrumbMonitor.setDelegate(self)
    }

    // If the breadcrumb already exists when the monitor begins, we have a race:
    // - Daemon creates the monitor
    // - Monitor finds the file and calls the delegate's callback, but the delegate is nil
    // - Daemon sets itself as the delegate for the monitor
    // Swift complains if the daemon passes self to the monitor's init, so we have to break out a "start" method
    /// Called after delegate has been set on the monitor
    func start() async {
        if (self.delegate == nil) {
            log.error("Error: starting monitor without a delegate to handle panics")
        }

        await self.breadCrumbMonitor.startMonitoring()
    }

    func setDelegate(_ newDelegate: PanicMonitorDelegate) async {
        self.delegate = newDelegate
    }

    private func retiredPath(forOriginalPath origPath: URL) -> URL {
        let panicName = origPath.lastPathComponent
        let rootPath = origPath.deletingLastPathComponent()

        return rootPath.appending(components: "Retired", panicName)
    }

    // Breadcrumb is a plist containing a dict mapping:
    // key: the boot session uuid in which the file was written
    // val: empty string if no panic, else the panic path
    private func extractPathFromBreadCrumb() async -> URL? {
        let bootUUID: String
        do {
            bootUUID = try getBootSessionUUID()
        } catch {
            log.error("No boot UUID found: \(error, privacy: .public)")
            return nil
        }

        let contentsData: Data
        do {
            contentsData = try Data(contentsOf: self.breadCrumbURL)
        } catch {
            log.error("Failed to read contents of breadcrumb file '\(self.breadCrumbURL, privacy: .public)' with error \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard contentsData.count > 0 else {
            log.log("Found empty breadcrumb file")
            return nil
        }

        let decoder = PropertyListDecoder()
        let pathDict: [String:String]
        do {
            pathDict = try decoder.decode([String:String].self, from: contentsData)
        } catch {
            log.error("Failed to decode breadcrumb: \(error, privacy: .public)")
            return nil
        }

        guard let pathString = pathDict[bootUUID] else {
            log.log("Breadcrumb missing boot UUID: \(bootUUID, privacy: .public)")
            return nil
        }

        if pathString == "" {
            log.log("No panic found this boot, stopping monitoring breadcrumb")
            await self.stopMonitoring()
            return nil
        }

        let pathURL = URL(filePath: pathString)
        let fm = FileManager.default
        if fm.fileExists(atPath: pathString) {
            return pathURL
        }

        // File may have been retired since the breadcrumb was written
        let retiredPathURL = retiredPath(forOriginalPath:pathURL)
        let retiredPathString = retiredPathURL.path(percentEncoded: false)
        if fm.fileExists(atPath: retiredPathString) {
            return retiredPathURL
        }

        log.error("Breadcrumb file has path: '\(pathString, privacy: .public), but no file found there or \(retiredPathString, privacy: .public)'")
        return nil
    }

    // On failure, we still want to send something to Splunk to denote a panic
    private func fallbackReportData(from reportData: Data, atPath pathString: String) -> [String:Any] {
        log.error("Failed to extract json from redacted panic report. Sending raw data for path \(pathString, privacy: .public)")
        return ["panicReport": String(decoding: reportData, as: UTF8.self)]
    }

    private func formatPanicLog(atPath path: String, withContents reportData: Data) -> SplunkEvent? {
        var event: [String:Any] = extractOSAnalyticsJson(from: reportData) ?? fallbackReportData(from: reportData, atPath: path)

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
        return .panicReport(data: responseData)
    }

    private func handleFoundBreadcrumb() async {
        // If breadcrumb is empty or missing this boot, nothing to do
        guard let panicURL = await extractPathFromBreadCrumb() else {
            return
        }
        let stringPath = panicURL.path(percentEncoded: false)

        // Redact the report via DumpPanic's SPI
        guard let ph = PanicReport(reportPath: panicURL) else {
            log.error("Failed to initialize Panic Helper at path '\(stringPath, privacy: .public)'")
            return
        }
        ph.prepareReportForSubmission()
        guard let redactedReportData: Data = ph.reportData else {
            log.error("Failed to redact panic report at path '\(stringPath, privacy: .public)'")
            return
        }

        // Now format it with common fields and forward
        if let splunkEvent = formatPanicLog(atPath: stringPath, withContents: redactedReportData) {
            log.log("Forwarding panic event to Splunk from path \(stringPath, privacy: .public)")
            Task { await self.delegate?.handlePanicEvent(splunkEvent) }
        }
    }
}

extension PanicMonitor: FileMonitorDelegate {
    // Function called when file is created or modified
    func didObserveChange(FileMonitor: FileMonitor) async {
        log.info("Observed change in \(self.breadCrumbURL.path(), privacy: .public)")
        await self.handleFoundBreadcrumb()
    }

    // Called if file exists when we first start monitoring
    func didStartMonitoring(FileMonitor: FileMonitor) async {
        log.info("Started monitoring \(self.breadCrumbURL.path(), privacy: .public)")
        await self.handleFoundBreadcrumb()
    }

    func didStopMonitoring(FileMonitor: FileMonitor) {
        log.info("Stopped monitoring \(self.breadCrumbURL.path(), privacy: .public)")
    }

    func stopMonitoring() async {
        await self.breadCrumbMonitor.stopMonitoring()
    }
}
