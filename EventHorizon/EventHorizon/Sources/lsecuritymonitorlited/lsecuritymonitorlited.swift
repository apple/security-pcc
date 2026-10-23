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

import EventHorizon
import Foundation
#if canImport(ArgumentParserInternal)
import ArgumentParserInternal
#else
import ArgumentParser
#endif

#if !os(Linux)
import os
#endif

@main
final class LSecurityMonitorLiteDaemon: ParsableCommand {
    static let daemonName = "com.apple.lsecuritymonitorlited"
    static let log = EHLog.withCategory(LSecurityMonitorLiteDaemon.daemonName)

    #if os(Linux)
    @Option(help: "logging level")
    public var logging_level: Level = .info

    @Option(help: "path to host filesystem root bind-mount (for container scenarios). Subpaths (/proc, /sys, /etc/machine-id) are derived from this root. Override is cleared if the path doesn't exist.")
    public var host_root: String?

    @Flag(help: "Also write events to OSLog (stdout) for debugging, in addition to the ASEP HTTP poster")
    public var add_stdout_logging: Bool = false
    #endif

    @Option(help: "Emit the metrics audit-list JSON for this binary to the given path and exit. Used by `make log-audit-generate` to build audit-lists/metrics/metrics.json from the live EHMetrics registry.")
    public var emit_metrics_audit_list: String?

    func run() throws {
        if let outPath = self.emit_metrics_audit_list {
            #if os(Linux)
            let lsmlFrontend = LSMLFrontend(hostRootPath: self.host_root, add_stdout_logging: self.add_stdout_logging)
            let transformIDs = Array(Set(lsmlFrontend.pipeline.transforms.map(\.name)))
            #else
            let transformIDs: [String] = []
            #endif
            try EmitMetricsAuditList.write(
                toPath: outPath,
                binaryName: Self.daemonName,
                dimensionValues: [
                    EHMetrics.DefaultDimensions.eh_frontend.rawValue: ["LSMLFrontend"],
                    EHMetrics.DefaultDimensions.eh_variant.rawValue: ["lsml"],
                    EHMetrics.Labels.Dimensions.transform_id.rawValue: transformIDs
                ]
            )
            return
        }

        var frontend: any EHFrontend = NullFrontend()
        #if os(Linux)
        EHGlobalLogLevel.shared.level = self.logging_level
        let obsConfig = Observability.lockedSecurityMonitorConfig(
            serviceName: Self.daemonName,
            defaultLogLevel: self.logging_level
        )
        Observability.setup(obsConfig)
        frontend = LSMLFrontend(hostRootPath: self.host_root ?? "/host", add_stdout_logging: self.add_stdout_logging)
        #endif

        EHInfo.shared.currentVariant = "lsml"
        os_log(.info, log: Self.log, "starting daemon")
        try EHDaemon(frontend).runForever()
        os_log(.info, log: Self.log, "daemon exited")
    }
}
