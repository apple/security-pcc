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
//  Reports.swift
//  CoreDiagnostics
//
//  Copyright © 2024 Apple, Inc.  All rights reserved.
//


import Foundation
import os.log
public import OSAnalytics
#if !(targetEnvironment(macCatalyst) || os(bridgeOS) || os(tvOS))
@_weakLinked import SecureConfigDB
#endif

fileprivate let log = Logger(subsystem: "com.apple.corediagnostics", category: "IPSReport")

public class CrashReport: IPSReport, Submittable {
    var redacter: CrashRedacter!
    var bodyJson: [String: Any]

    override init?(header: Data, body: Data) {
        // IPS crash report expects the body to of JSON type
        guard let bodyJson = Self.dataToJson(body) else {
            log.error("Failed to convert to body to json")
            return nil
        }
        self.bodyJson = bodyJson

        super.init(header: header, body: body)
        self.redacter = CrashRedacter(crashReport: self)
        guard self.bugType == "309" else {
            Logger().error("Invalid bug_type for crash report: \(self.bugType)")
            return nil
        }
    }

    // Submission requires the report body to be redacted
    public func prepareReportForSubmission() {
        self.redacter.performRedaction()
    }

    internal class CrashRedacter {
        static let maxPartialReportsPerHour = 3
        static let maxBacktraceLen = 32

        enum CrashRedactionAmount: String {
            case None    // Not running in setting where redaction required
            case Partial // Able to only redact some data. Sending of partial logs is throttled
            case Full    // The default, safest case. Most logs sent are sent as fully redacted when redaction is required
        }

        unowned let crashReport: CrashReport

        // This needs to be behind a lock so multiple threads can try to handle crash submission
        static let partialReports: OSAllocatedUnfairLock <[Date]> = .init(initialState: [])

        init(crashReport: CrashReport) {
            self.crashReport = crashReport
        }

        var isRedactionEnabled: Bool = {
#if !(targetEnvironment(macCatalyst) || os(bridgeOS) || os(tvOS))
            if #_hasSymbol(SecureConfigParameters.self) {
                do {
                    let result = try SecureConfigParameters.loadContents().crashRedactionEnabled
                    log.info("crashRedactionEnabled: found value of \(String(describing: result), privacy: .public) from Secure Config")
                    guard let result else {
                        log.info("Got no value from SecureConfig for crashRedactionEnabled, returning false")
                        return false
                    }
                    return result
                } catch {
                    log.error("SecureConfig error for crashRedactionEnabled, defaulting to true: \(error)")
                }
            }
            return true
#else
            return false
#endif /* !(targetEnvironment(macCatalyst) || os(bridgeOS)) */
        }()

        lazy var getReportDate: () -> Date? = {
            return {
                guard let timestamp = self.crashReport.headerJson["timestamp"] as? String else {
                    return nil
                }

                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SS Z"
                dateFormatter.locale = Locale(identifier: "en_US_POSIX")
                guard let reportDate = dateFormatter.date(from: timestamp) else {
                    log.log("Report timestamp could not be parsed; defaulting to full redaction")
                    return nil
                }

                return reportDate
            }
        }()

        var randGenerator: (Range<Int>) -> Int = Int.random

        // Partially redacted: 20% of the time
        // Fully redacted: 80% of the time
        // Limit 3 partially redacted logs per hour
        func calculateRedaction() -> CrashRedactionAmount {
            if !isRedactionEnabled {
                log.log("Crash redaction is disabled")
                return .None
            }

            guard let reportDate = self.getReportDate() else {
                return .Full
            }

            // Full redaction 80% of the time
            let rand = self.randGenerator(0..<5)
            log.log("Generated random number \(rand) for redaction")
            if rand > 0 {
                return .Full
            }

            let secondsPerHour: TimeInterval = 60 * 60

            // For the 20% partial redaction, we must limit number performed in the past hour
            let needsFullRedaction = Self.partialReports.withLock { reports in
                var count = reports.count
                if Self.maxPartialReportsPerHour == 0 {
                    return true
                }
                if count > Self.maxPartialReportsPerHour {
                    log.error("Error: expecting max of \(Self.maxPartialReportsPerHour) reports per hour, but found \(count)")
                    let slice = reports[0..<Self.maxPartialReportsPerHour]
                    reports = Array(slice)
                    count = reports.count
                }
                if count == Self.maxPartialReportsPerHour {
                    if reportDate.timeIntervalSince(reports[count-1]) < secondsPerHour {
                        // List is full and less than an hour has passed
                        return true
                    }
                    reports.remove(at: count-1)
                }
                reports.insert(reportDate, at: 0)
                return false
            }

            return (needsFullRedaction) ? .Full : .Partial
        }

        /// Remove the register values for all threads
        private func redactRegisterValues(from body: inout [String:Any]) -> Bool {
            guard var threads = body["threads"] as? [[String:Any]] else {
                log.error("Crash report missing thread data")
                return false
            }

            for i in threads.indices {
                if let _ = threads[i]["threadState"] {
                    threads[i]["threadState"] = nil
                }
            }

            body["threads"] = threads
            return true
        }

        /// Remove the exception message
        private func redactExceptionMessage(from body: inout [String:Any]) -> Bool {
            if let _ = body["exception"] {
                body["exception"] = nil
            }
            return true
        }

        /// Remove the last exception backtrace
        private func redactLastExceptionBacktrace(from body: inout [String:Any]) -> Bool {
            // This is an optional key sometimes included by Foundation to provide an alternate call stack
            if let _ = body["lastExceptionBacktrace"] {
                body["lastExceptionBacktrace"] = nil
            }

            return true
        }

        /// Limit the number of frames in the last exception backtrace to a fixed limit
        private func truncateLastExceptionBacktrace(from body: inout [String:Any]) -> Bool {
            // This is an optional key sometimes included by Foundation to provide an alternate call stack
            guard let rawExceptionBacktrace = body["lastExceptionBacktrace"] else {
                return true
            }

            guard let exceptionBacktrace = rawExceptionBacktrace as? [Any] else {
                log.error("Unexpected type for exception backtrace")
                return false
            }

            if exceptionBacktrace.count > Self.maxBacktraceLen {
                let slice = exceptionBacktrace[0..<Self.maxBacktraceLen]
                body["lastExceptionBacktrace"] = Array(slice)
            }

            return true
        }

        /// Limit the number of frames in each stack backtrace to a fixed limit
        private func truncateStacks(from body: inout [String:Any]) -> Bool {
            guard var threads = body["threads"] as? [[String:Any]] else {
                log.error("Crash report missing thread data")
                return false
            }

            for i in threads.indices {
                if let frames = threads[i]["frames"] {
                    guard let frames = frames as? [Any] else {
                        log.error("Thread has backtrace with unexpected type")
                        return false
                    }
                    if frames.count > Self.maxBacktraceLen {
                        let slice = frames[0..<Self.maxBacktraceLen]
                        threads[i]["frames"] = Array(slice)
                    }
                }
            }

            body["threads"] = threads
            return true
        }

        /// Redact stack backtraces from all threads but the crashing one
        private func redactNonCrashingStacks(from body: inout [String:Any]) -> Bool {
            guard var threads = body["threads"] as? [[String:Any]] else {
                log.error("Crash report missing thread data")
                return false
            }

            for i in threads.indices {
                // Only keep the triggering stack's frames
                if let isCrashingStack = threads[i]["triggered"] as? Bool,
                   isCrashingStack == true {
                    continue
                }

                threads[i]["frames"] = nil
            }

            body["threads"] = threads
            return true
        }

        private func _redactFrames(for frames: inout [[String:Any]], usingImages usedImages: [[String:Any]]) -> Bool {
            for (i, frame) in frames.enumerated().reversed() {
                guard let imageIndex = frame["imageIndex"] as? Int else {
                    log.error("Crash frame missing image index")
                    return false
                }

                // Found invalid index. Redact frame and continue
                if (imageIndex < 0) || (imageIndex >= usedImages.count) {
                    frames[i] = ["imageOffset": 0, "symbol": "<redacted>"]
                    continue
                }

                // Found frame with valid index, but frame points to the "absolute image," which
                // is used to represent an invalid image -> redact this frame
                guard let source = usedImages[imageIndex]["source"] as? String else {
                    log.error("Crash frame has valid image index, but image missing source name")
                    return false
                }

                // A for "absolute image"
                if source == "A" {
                    frames[i] = ["imageOffset": 0, "symbol": "<redacted>"]
                }
            }
            return true
        }

        /// If a frame points to an image not listed in the images (or an invalid one), redact it
        private func redactInvalidFrames(from body: inout [String: Any]) -> Bool {
            guard var threads = body["threads"] as? [[String:Any]] else {
                log.error("Crash report missing thread data")
                return false
            }

            let usedImages = body["usedImages"] as? [[String:Any]] ?? []

            for i in threads.indices {
                guard var frames = threads[i]["frames"] as? [[String:Any]] else {
                    log.error("Crash report frames have unexpected type")
                    return false
                }

                if !_redactFrames(for: &frames, usingImages:usedImages) {
                    log.error("Failed to redact frames for normal thread")
                    return false
                }
                threads[i].updateValue(frames, forKey: "frames")
            }
            body["threads"] = threads

            // This is an optional key sometimes included by Foundation to provide an alternate call stack
            if let rawExceptionBacktrace = body["lastExceptionBacktrace"] {
                guard var exceptionBacktrace = rawExceptionBacktrace as? [[String:Any]] else {
                    log.error("Unexpected type for exception backtrace")
                    return false
                }

                if !_redactFrames(for: &exceptionBacktrace, usingImages:usedImages) {
                    log.error("Failed to redact frames for lastExceptionBacktrace")
                    return false
                }
                body["lastExceptionBacktrace"] = exceptionBacktrace
            }

            return true
        }

        func performRedaction() {
            let redaction: CrashRedactionAmount = calculateRedaction()
            var bodyJson = crashReport.bodyJson
            var success = true
            switch redaction {
            case .None:
                break

            case .Partial:
                success = success && redactRegisterValues(from: &bodyJson)
                success = success && redactInvalidFrames(from: &bodyJson)

                success = success && truncateLastExceptionBacktrace(from: &bodyJson)

            case .Full:
                success = success && redactRegisterValues(from: &bodyJson)
                success = success && redactInvalidFrames(from: &bodyJson)

                success = success && redactExceptionMessage(from: &bodyJson)
                success = success && redactNonCrashingStacks(from: &bodyJson)
                success = success && truncateStacks(from: &bodyJson)
                success = success && redactLastExceptionBacktrace(from: &bodyJson)
            }

            if !success {
                bodyJson = ["crashReport": "Failed to decode crash report"]
            }

            bodyJson["redactionLevel"] = redaction.rawValue
            crashReport.bodyJson = bodyJson
            if let updatedBody = jsonToData(bodyJson) {
                crashReport.body = updatedBody
            }
        }
    }
}

public class JetsamReport: IPSReport, Submittable {
    override init?(header: Data, body: Data) {
        super.init(header: header, body: body)
        guard self.bugType == "298" else {
            Logger().error("Invalid bug_type for Jetsam report: \(self.bugType)")
            return nil
        }
    }

    public func prepareReportForSubmission() {
        // No operations as of now
    }
}

