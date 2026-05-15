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

import ArgumentParserInternal
import CloudBoardCommon
import CloudBoardController
import CloudBoardLogging
import os

@main
struct ShadowTunnelCloudControllerApp: AsyncParsableCommand {
    static let log: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "ShadowTunnelCloudController"
    )

    func run() async throws {
        // unusually we do some real work first as the *very* first thing
        guard let secureConfig = Self.loadSecureConfig() else {
            Self.cleanTerminate("Unable to load secure config so failing safe and terminating")
        }

        // we might still not actually do antyhing, this is just a hard reason not to
        let reasonNotAllowedToRun: StaticString?
        switch secureConfig.securityPolicy {
        case .none:
            Self.log.info("ShadowTunnel functionality allowed when no security policy")
            reasonNotAllowedToRun = nil
        case .carry:
            // this is never allowed in carry but fiat - changing this would require privacy approval
            reasonNotAllowedToRun = "ShadowTunnel functionality not allowed in carry"
        case .customer:
            // this allows VRE researchers to run this code
            if secureConfig.shouldEnforceAppleInfrastructureSecurityConfig {
                Self.log
                    .notice(
                        "ShadowTunnel functional allowed in \(secureConfig.securityPolicy, privacy: .public) due to researcher flag"
                    )
                reasonNotAllowedToRun = nil
            } else {
                reasonNotAllowedToRun = "ShadowTunnel functional not allowed in carry"
            }
        }
        if let reasonNotAllowedToRun {
            Self.cleanTerminate(reasonNotAllowedToRun)
        }
        // Even if *allowed* we still need to be configured to do it
        // The shadow controller kicks in for every cloud app that is shadowed
        // registering each one separately. The "proper" cloud controller needs to be written to be aware
        // of this and not register itself. this is not a significant issue since any cloud app wanting to
        // use this functionality
        let atLeastOneShadow = try await withThrowingTaskGroup { group in
            var atLeastOneShadow = false
            for cloudApp in secureConfig.cloudAppNames {
                let config = try secureConfig.cloudAppConfig(cloudApp: cloudApp)
                guard config.shadow.enabled else {
                    Self.log.info("cloud app \(cloudApp, privacy: .public) not configured to use shadow tunnel")
                    continue
                }
                guard config.shadow.cloudController != .original else {
                    Self.log
                        .notice(
                            "cloud app \(cloudApp, privacy: .public) is shadowed, but not configured to use shadow tunnel controller"
                        )
                    continue
                }
                Self.log.notice(
                    "cloud app \(cloudApp, privacy: .public) configured to use shadow \(config.shadow.cloudController.rawValue, privacy: .public) - starting controller"
                )
                atLeastOneShadow = true
                group.addTaskWithLogging(
                    operation: "ShadowTunnelController_\(cloudApp)",
                    // if this functionality is in use _everything_ is not sensitive
                    sensitiveError: false
                ) {
                    try await ShadowTunnelCloudController(
                        cloudApp: cloudApp,
                        config: config,
                        secureConfig: secureConfig
                    ).run()
                }
            }
            return atLeastOneShadow
        }
        guard atLeastOneShadow else {
            Self.cleanTerminate("No cloudApps shadowing their Controllers")
        }
        Self.log.info("All shadow controllers cleanly exited - exiting")
    }

    private static func loadSecureConfig() -> SecureConfig? {
        do {
            self.log.info("Loading secure config from SecureConfigDB")
            return try SecureConfigLoader.real.load()
        } catch {
            self.log.error(
                "Error loading secure config: \(String(unredacted: error), privacy: .public)"
            )
            return nil
        }
    }

    private static func cleanTerminate(_ reason: StaticString) -> Never {
        self.log.info("\(reason, privacy: .public). Exiting cleanly")
        // ShadowController is configuerd to not be restarted if it exists cleanly
        exit()
    }
}
