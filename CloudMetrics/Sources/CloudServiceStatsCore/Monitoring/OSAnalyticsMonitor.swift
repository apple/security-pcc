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

//  Copyright © 2024 Apple Inc. All rights reserved.

import Foundation
import OSAServicesClient
import os
import CloudMetricsFramework

final class OSAnalyticsMonitor: NSObject, Sendable {
    static let logger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudservicestatsd",
        category: "OSAnalyticsMonitor"
    )

    // The types of logs we want to subscribe to.
    // all log types available can be found at
    private static let logTypes = [
        // ExcResource
        "385"
    ]

    public func registerForOSAnalyticsReports() {
        OSADiagnosticMonitorClient.shared.add(self, forTypes: Self.logTypes)
        Self.logger.log("Registered for OSAnalyticsReports")
    }

    // Extracts the content from a diagnostic log report. The log report has two json objects with a summary(header)
    // and full report(body). Currently we only care about the full report as it contains more useful information about the
    // exception.
    private func extractDiagnosticLogJson(from logFilePath: String) -> [String: Any]? {
        let pathURL = URL(fileURLWithPath: logFilePath)
        let diagnosticLogData: Data
        do {
            Self.logger.log("Reading diagnostic log report at log_file_path=\(logFilePath)")
            diagnosticLogData = try Data(contentsOf: pathURL)
        } catch {
            Self.logger.error("Couldn't read diagnostic log report error=\(error.localizedDescription)")
            return nil
        }

        let objs = diagnosticLogData.split(separator: "\n".utf8, maxSplits: 1)
        let count = objs.count
        guard count == 2 else {
            Self.logger.error("Got diagnostic log report with unexpected number of elements: \(count)")
            return nil
        }

        let bodyData = objs[1]
        do {
            return try JSONSerialization.jsonObject(with: bodyData, options: []) as? [String : Any]
        } catch {
            Self.logger.error(
                "error serializing payload=\(bodyData, privacy: .public) with error=\(error.localizedDescription, privacy: .public)"
            )
        }
        return nil
    }

    // Extracts and validates that a diagnostic log file of type ExcResource(385) is a soft memory violation
    private func extractExcResourceSoftMemoryLogJson(from logFilePath: String) -> [String: Any]? {
        guard let jsonData = extractDiagnosticLogJson(from: logFilePath) else {
            return nil
        }

        // we only care about log files that are NOT a crash report. Since a soft memory violation would not result
        // in a crash. Other violations, like hard memory limits, will result in a similar log type without the
        // isSimulated key.
        guard let isSimulated = jsonData["isSimulated"] as? Bool, isSimulated == true else {
            Self.logger.log("Diagnostic log file for log_file_path=\(logFilePath) is a crash, expected non crash report. Ignoring.")
            return nil
        }

        guard let exception = jsonData["exception"] as? [String: Any],
              exception["type"] as? String == "EXC_RESOURCE",
              exception["subtype"] as? String == "MEMORY" else {
            Self.logger.log("Diagnostic log file for log_file_path=\(logFilePath) is not a memory violation, ignoring.")
            return nil
        }

        return jsonData
    }
}

extension OSAnalyticsMonitor: OSADiagnosticObserver {
    func willWriteDiagnosticLog(_ bugType: String, logId: String, logInfo: [AnyHashable : Any]) {
        return
    }

    func didWriteDiagnosticLog(_ bugType: String, logId: String, logFilePath path: String?, logInfo: [AnyHashable : Any], error: (any Error)?) {
        Self.logger.log("""
        Received diagnostic report
        bug_type=\(bugType)
        log_file_path=\(path ?? "nil")
        log_info=\(logInfo)
        error=\(String(describing: error?.localizedDescription ?? nil))
        """)

        guard let path = path else {
            Self.logger.error("Diagnostic report did not have a file path")
            return
        }

        switch bugType {
        case "385":
            guard let logJson = extractExcResourceSoftMemoryLogJson(from: path),
                  let processName = logJson["procName"] as? String else {
                return
            }

            let reportType = CategorizedReportType.jetsamSoftMemoryLimit
            Self.logger.log("Processed jetsam soft memory limit report for process_name=\(processName)")
            Counter(
                label: reportType.metricLabel,
                dimensions: [("process", processName)]
            ).increment()
        default:
            Self.logger.log("Recieved unexpected bugType bug_type=\(bugType), will ignore.")
        }

    }
}
