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
//  LegacyBundleIDProvider.swift
//  PrivateCloudCompute
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//

import AppSupport
private import DarwinPrivate.os.variant
import PrivateCloudCompute
import RunningBoardServices
import os.log

private let logger = Logger(for: .daemon)

struct LegacyBundleIDProvider: BundleIDProviderProtocol {
    func bundleIdentifier(for pid: pid_t) -> BundleIdentifier {
        return resolveIdentifier(pid: pid)
    }

    func bundleIdentifier(for auditToken: audit_token_t) throws -> BundleIdentifier {
        var bundleID: Unmanaged<CFString>?
        guard CPCopyBundleIdentifierAndTeamFromAuditToken(auditToken, &bundleID, nil) else {
            throw PrivateCloudComputeError(message: "failed to get bundle ID from audit token")
        }

        guard let bundleID = bundleID?.takeRetainedValue() else {
            throw PrivateCloudComputeError(message: "failed to retain bundle ID from audit token")
        }
        return BundleIdentifier(rawValue: bundleID as String, provenance: .preRedacted)
    }
}

// MARK: - Legacy BundleID Derivation Functions

private let allowedDaemons = ["generativeexperiencesd", "generativeexper", "SpringBoard"]
private let allowedCLITools = ["photosctl", "summarizationctl", "summarizationct", "tcutil", "sagetool", "tgtool", "spellcheck", "iftool"]

/// Resolve the bundle identifier for a process, classifying it by provenance.
///
/// Apple and allow-listed identifiers get `.preRedacted` provenance. Identifiable
/// non-Apple processes get `.thirdParty` provenance with the real identifier preserved
/// (redaction is handled downstream by `BundleIdentifier.redactedValue`). Unresolvable
/// processes get `.unknown` provenance with a sentinel value.
private func resolveIdentifier(pid: Int32) -> BundleIdentifier {
    guard let pidIdentifier = RBSProcessIdentifier(pid: pid) else {
        logger.debug("could not get identifier for pid \(pid)")
        return BundleIdentifier(rawValue: "com.unknown.RBS", provenance: .unknown)
    }

    do {
        let handle = try RBSProcessHandle(for: pidIdentifier)

        if handle.isDaemon {
            guard let daemonName = handle.name else {
                logger.debug("daemon has no name for pid=\(pid)")
                return BundleIdentifier(rawValue: "com.unknown.daemon", provenance: .unknown)
            }
            if allowedDaemons.contains(daemonName) {
                logger.debug("allowing daemon \(daemonName)")
                return BundleIdentifier(rawValue: daemonName, provenance: .preRedacted)
            }
            logger.debug("daemon \(daemonName) for pid=\(pid) is not allowed")
            return BundleIdentifier(rawValue: daemonName, provenance: .thirdParty)
        }

        if let bundle = handle.bundle, let bundleIdentifier = bundle.identifier {
            if bundleIdentifier.starts(with: "com.apple.") {
                logger.debug("request is bundle-id \(bundleIdentifier) for pid \(pid)")
                return BundleIdentifier(rawValue: bundleIdentifier, provenance: .preRedacted)
            } else {
                logger.debug("request is third party bundle-id")
                return BundleIdentifier(rawValue: bundleIdentifier, provenance: .thirdParty)
            }
        } else {
            if os_variant_allows_internal_security_policies(privateCloudComputeOsVariantSubsystem) {
                guard let cliTool = handle.name else {
                    logger.debug("CLI tool has no name for pid=\(pid)")
                    return BundleIdentifier(rawValue: "com.unknown.tool", provenance: .unknown)
                }
                if allowedCLITools.contains(cliTool) {
                    logger.debug("bundle identifier is cli tool \(cliTool)")
                    return BundleIdentifier(rawValue: cliTool, provenance: .preRedacted)
                } else {
                    logger.debug("bundle identifier is an unknown cli tool")
                    return BundleIdentifier(rawValue: cliTool, provenance: .thirdParty)
                }
            }
            logger.debug("could not get process bundle for pid=\(pid)")
            return BundleIdentifier(rawValue: "com.unknown.bundle", provenance: .unknown)
        }
    } catch {
        logger.debug("could not get handle for pid \(pid)")
        return BundleIdentifier(rawValue: "com.unknown.ebundle", provenance: .unknown)
    }
}
