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
//  ExpiredBuildNotification.swift
//  PrivateCloudCompute
//
//  Copyright © 2025 Apple Inc. All rights reserved.
//

import CoreServices_Private
private import DarwinPrivate.os.variant
import Foundation
import PrivateCloudCompute
import os.log

private let logger = Logger(for: .notifications)

protocol ExpiredBuildNotificationStore: Sendable {
    var expiredBuildLastNotificationTime: Date? { get set }
}

/// A system-wide notification that displays on internal devices when the selected LiveOn build is invalid.
actor ExpiredBuildNotification<
    UserNotification: UserNotificationProtocol,
    Store: ExpiredBuildNotificationStore,
> {
    /// Rate limit in seconds, to avoid spamming the user with popups.
    private let displayInterval: TimeInterval

    private var store: Store
    private let isInternalBuild: Bool
    private let userNotification: UserNotification
    private let openSettingsAction: () async throws -> Void

    init(
        displayInterval: TimeInterval,
        store: Store,
        isInternalBuild: Bool = os_variant_allows_internal_security_policies(privateCloudComputeOsVariantSubsystem),
        userNotification: UserNotification = SystemUserNotification(),
        openSettingsAction: @Sendable @escaping () async throws -> Void = openSettings,
    ) {
        self.displayInterval = displayInterval
        self.store = store
        self.isInternalBuild = isInternalBuild
        self.userNotification = userNotification
        self.openSettingsAction = openSettingsAction
    }

    func show(now: Date = Date()) async {
        #if os(iOS)
        logger.info("ExpiredBuildNotification requested")

        guard canShow(now: now) else {
            return
        }

        store.expiredBuildLastNotificationTime = now
        logger.info("ExpiredBuildNotification will show")

        let result = await userNotification.show(
            header: "Expired Private Cloud Compute Build",
            message: "The build you selected is no longer available. Please select a different build in Settings to continue.",
            defaultButtonText: "Open Settings",
            alternateButtonText: "Cancel",
        )

        switch result {
        case .default:
            logger.info("ExpiredBuildNotification completed: user requested settings")
            do {
                try await openSettingsAction()
                logger.info("ExpiredBuildNotification successfully opened settings")
            } catch {
                logger.error("ExpiredBuildNotification failed to open settings. error=\(error)")
            }
        case .cancel, .alternate:
            logger.info("ExpiredBuildNotification completed: user dismissed")
        case .failure:
            logger.error("ExpiredBuildNotification failed to display")
        }
        #else
        logger.info("ExpiredBuildNotification not available")
        #endif
    }

    private func canShow(now: Date) -> Bool {
        guard isInternalBuild else {
            logger.info("ExpiredBuildNotification suppressed: not an internal build")
            return false
        }

        guard let lastNotificationTime = store.expiredBuildLastNotificationTime else {
            return true
        }
        let timeSinceLastNotification = now.timeIntervalSince(lastNotificationTime)

        guard timeSinceLastNotification >= displayInterval else {
            logger.info("ExpiredBuildNotification suppressed: lastNotificationTime=\(lastNotificationTime) was \(timeSinceLastNotification)s ago, displayInterval=\(self.displayInterval)s")
            return false
        }

        return true
    }

    private static func openSettings() async throws {
        #if os(iOS)
        // Indirect link is intentional; technical limitations prevent a direct link.
        let settingsURL = URL(string: "settings-navigation://com.apple.Settings.Internal.Classic")!

        let configuration = _LSOpenConfiguration()
        configuration.isSensitive = true

        try await LSApplicationWorkspace.default().open(settingsURL, configuration: configuration)
        #endif
    }

}
