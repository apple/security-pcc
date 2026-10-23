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
//  Configuration.swift
//  CloudAttestation
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

import os.log
import DarwinPrivate.os.variant
@_weakLinked import SecureConfigDB

struct Configuration {
    static let logger = Logger(subsystem: "com.apple.CloudAttestation", category: "configuration")
    let environment: Environment

    init(for environment: Environment) {
        self.environment = environment
    }

    var transparencyProofValidation: Bool {
        Self.CFPreferences.transparencyProofValidation ?? (environment >= .qa)
    }

    var strictCertificateValidation: Bool {
        Self.CFPreferences.strictCertificateValidation ?? (environment >= .qa)
    }

    var requireProdTrustAnchors: Bool {
        Self.CFPreferences.requireProdTrustAnchors ?? (environment >= .production)
    }

    var requireRestrictedExecutionMode: Bool {
        Self.CFPreferences.requireRestrictedExecutionMode ?? (environment >= .qa)
    }

    var requireEphemeralDataMode: Bool {
        Self.CFPreferences.requireEphemeralDataMode ?? (environment >= .qa)
    }

    var restrictDeveloperMode: Bool {
        Self.CFPreferences.restrictDeveloperMode ?? (environment >= .production)
    }

    var requireProdFusing: Bool {
        Self.CFPreferences.requireProdFusing ?? (environment >= .production)
    }

    var fullReleaseSetVerification: Bool {
        Self.CFPreferences.fullReleaseSetVerification ?? (environment >= .production)
    }

    var requireLockedCryptexes: Bool {
        Self.CFPreferences.requireLockedCryptexes ?? (environment >= .qa)
    }

    var allowExpired: Bool {
        Self.CFPreferences.allowExpired ?? false
    }

    var cacheProofs: Bool {
        Self.CFPreferences.cacheProofs ?? false
    }

    var requireCertificateChain: Bool {
        Self.CFPreferences.requireCertificateChain ?? (environment >= .qa)
    }

    var requireSealedHashes: Bool {
        Self.CFPreferences.requireSealedHashes ?? (environment >= .qa)
    }

    var requireCryptex1: Bool {
        Self.CFPreferences.requireCryptex1 ?? (environment >= .qa)
    }

    var ensembleTopologyValidation: Bool {
        Self.CFPreferences.ensembleTopologyValidation ?? (environment >= .qa)
    }

    var restrictSecurityPolicies: Bool {
        Self.CFPreferences.restrictSecurityPolicies ?? true
    }

    var certificateTransparency: Bool {
        Self.CFPreferences.certificateTransparency ?? (environment >= .qa)
    }

    var certificateTransparencyFetchFailClosed: Bool {
        Self.CFPreferences.certificateTransparencyFetchFailClosed ?? (environment > .production)
    }

    var certificateTransparencyVerifyFailClosed: Bool {
        Self.CFPreferences.certificateTransparencyVerifyFailClosed ?? (environment > .production)
    }

    var certificateTransparencyShouldRecycleProxyAttestation: Bool {
        Self.CFPreferences.certificateTransparencyShouldRecycleProxyAttestation ?? false
    }

    var enforceEnvironment: Bool {
        Self.CFPreferences.enforceEnvironment ?? (environment > .production)
    }
}

// MARK: - Global CFPreferences
extension Configuration {
    struct CFPreferences: Sendable {
        static let shared = CFPreferences()

        @CFPreference(key: "transparencyProofValidation")
        var transparencyProofValidation: Bool?
        static var transparencyProofValidation: Bool? {
            shared.transparencyProofValidation
        }

        @CFPreference(key: "strictCertificateValidation")
        var strictCertificateValidation: Bool?
        static var strictCertificateValidation: Bool? {
            shared.strictCertificateValidation
        }

        @CFPreference(key: "requireProdTrustAnchors")
        var requireProdTrustAnchors: Bool?
        static var requireProdTrustAnchors: Bool? {
            shared.requireProdTrustAnchors
        }

        @CFPreference(key: "requireRestrictedExecutionMode")
        var requireRestrictedExecutionMode: Bool?
        static var requireRestrictedExecutionMode: Bool? {
            shared.requireRestrictedExecutionMode
        }

        @CFPreference(key: "requireEphemeralDataMode")
        var requireEphemeralDataMode: Bool?
        static var requireEphemeralDataMode: Bool? {
            shared.requireEphemeralDataMode
        }

        @CFPreference(key: "restrictDeveloperMode")
        var restrictDeveloperMode: Bool?
        static var restrictDeveloperMode: Bool? {
            shared.restrictDeveloperMode
        }

        @CFPreference(key: "requireProdFusing")
        var requireProdFusing: Bool?
        static var requireProdFusing: Bool? {
            shared.requireProdFusing
        }

        @CFPreference(key: "fullReleaseSetVerification")
        var fullReleaseSetVerification: Bool?
        static var fullReleaseSetVerification: Bool? {
            shared.fullReleaseSetVerification
        }

        @CFPreference(key: "requireLockedCryptexes")
        var requireLockedCryptexes: Bool?
        static var requireLockedCryptexes: Bool? {
            shared.requireLockedCryptexes
        }

        @CFPreference(key: "allowExpired")
        var allowExpired: Bool?
        static var allowExpired: Bool? {
            shared.allowExpired
        }

        @CFPreference(key: "cacheProofs")
        var cacheProofs: Bool?
        static var cacheProofs: Bool? {
            shared.cacheProofs
        }

        @CFPreference(key: "requireSealedHashes")
        var requireSealedHashes: Bool?
        static var requireSealedHashes: Bool? {
            shared.requireSealedHashes
        }

        @CFPreference(key: "requireCertificateChain")
        var requireCertificateChain: Bool?
        static var requireCertificateChain: Bool? {
            shared.requireCertificateChain
        }

        @CFPreference(key: "requireCryptex1")
        var requireCryptex1: Bool?
        static var requireCryptex1: Bool? {
            shared.requireCryptex1
        }

        @CFPreference(key: "restrictSecurityPolicies")
        var restrictSecurityPolicies: Bool?
        static var restrictSecurityPolicies: Bool? {
            shared.restrictSecurityPolicies
        }

        @CFPreference(key: "ensembleTopologyValidation")
        var ensembleTopologyValidation: Bool?
        static var ensembleTopologyValidation: Bool? {
            shared.ensembleTopologyValidation
        }

        @CFPreference(key: "certificateTransparency")
        var certificateTransparency: Bool?
        static var certificateTransparency: Bool? {
            shared.certificateTransparency
        }

        @CFPreference(key: "certificateTransparencyFetchFailClosed")
        var certificateTransparencyFetchFailClosed: Bool?
        static var certificateTransparencyFetchFailClosed: Bool? {
            shared.certificateTransparencyFetchFailClosed
        }

        @CFPreference(key: "certificateTransparencyVerifyFailClosed")
        var certificateTransparencyVerifyFailClosed: Bool?
        static var certificateTransparencyVerifyFailClosed: Bool? {
            shared.certificateTransparencyVerifyFailClosed
        }

        @CFPreference(key: "certificateTransparencyShouldRecycleProxyAttestation")
        var certificateTransparencyShouldRecycleProxyAttestation: Bool?
        static var certificateTransparencyShouldRecycleProxyAttestation: Bool? {
            shared.certificateTransparencyShouldRecycleProxyAttestation
        }

        @CFPreference(key: "enforceEnvironment")
        var enforceEnvironment: Bool?
        static var enforceEnvironment: Bool? {
            shared.enforceEnvironment
        }
    }
}
