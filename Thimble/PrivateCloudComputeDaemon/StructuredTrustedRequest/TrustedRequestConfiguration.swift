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
//  TrustedRequestConfiguration.swift
//  PrivateCloudCompute
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

import Foundation
import PrivateCloudCompute
import Security

// This is a specially recognized workload type that does not
// support response bypass.
private let agentWorkloadType = "pcc-agent"

struct TrustedRequestConfiguration: CustomStringConvertible {
    var maxCachedAttestations: Int
    var maxTotalAttestations: Int
    var maxInlineAttestations: Int

    var maxProtobufRandomizedPaddingSize: Int

    var overrideCellID: String?

    var rateLimiterMaximumRateLimitDuration: Double
    var rateLimiterMaximumRateLimitTTL: Double
    var rateLimiterDefaultJitterFactor: Double

    var ignoreCertificateErrors: Bool
    var environment: String
    var forceOHTTP: Bool
    var endpointURL: URL
    var trustedRequestHostname: String
    var trustedRequestPath: String
    var enforceWorkloadParametersFiltering: Bool

    var testSignalHeader: String?
    var testOptionsHeader: String?
    var routingGroupAlias: String?
    var trustedProxyRequestBypass: Bool?
    var trustedProxyResponseBypass: Bool
    var trustedProxyRoutingGroupAlias: String?

    /// This is bundle id associated with our adopter's process. Shouldn't be used much here other than for rate limiting attribution purposes.
    var clientBundleID: String
    /// This is the bundle id we associate the request with.
    /// This would be either `clientBundleID` or `bundleIdentifierOverride` if adopter calling us has an entitlement allowing them to override
    /// bundle id associated with the request. This may also be referred to as `onBehalfOf`.
    var bundleID: String
    var featureID: String?
    var sessionID: UUID?
    /// Provided by the adopter. Typically when adopter has an entitlement to override `bundleID`, the `originatingBundleID` would be a parent of it.
    /// This may also be referred to as `parentOfOnBehalfOf`.
    var originatingBundleID: String?
    var userID: uid_t?

    var aeadKey: Data
    var serverQoS: ServerQoS

    var isServerDrivenConfigurationOutdated: Bool

    var multiTurn: Bool

    init(
        maxCachedAttestations: Int,
        maxTotalAttestations: Int,
        maxInlineAttestations: Int,
        maxProtobufRandomizedPaddingSize: Int,
        overrideCellID: String?,
        rateLimiterMaximumRateLimitDuration: Double,
        rateLimiterMaximumRateLimitTTL: Double,
        rateLimiterDefaultJitterFactor: Double,
        ignoreCertificateErrors: Bool,
        environment: String,
        forceOHTTP: Bool,
        endpointURL: URL,
        trustedRequestHostname: String,
        trustedRequestPath: String,
        enforceWorkloadParametersFiltering: Bool,
        testSignalHeader: String?,
        testOptionsHeader: String?,
        routingGroupAlias: String?,
        trustedProxyRequestBypass: Bool?,
        trustedProxyResponseBypass: Bool,
        trustedProxyRoutingGroupAlias: String?,
        clientBundleID: String,
        bundleID: String,
        originatingBundleID: String?,
        featureID: String?,
        sessionID: UUID?,
        aeadKey: Data,
        serverQoS: ServerQoS,
        userID: uid_t?,
        isServerDrivenConfigurationOutdated: Bool,
        multiTurn: Bool
    ) {
        self.maxCachedAttestations = maxCachedAttestations
        self.maxTotalAttestations = maxTotalAttestations
        self.maxInlineAttestations = maxInlineAttestations
        self.maxProtobufRandomizedPaddingSize = maxProtobufRandomizedPaddingSize
        self.overrideCellID = overrideCellID
        self.rateLimiterMaximumRateLimitDuration = rateLimiterMaximumRateLimitDuration
        self.rateLimiterMaximumRateLimitTTL = rateLimiterMaximumRateLimitTTL
        self.rateLimiterDefaultJitterFactor = rateLimiterDefaultJitterFactor
        self.ignoreCertificateErrors = ignoreCertificateErrors
        self.environment = environment
        self.forceOHTTP = forceOHTTP
        self.endpointURL = endpointURL
        self.trustedRequestHostname = trustedRequestHostname
        self.trustedRequestPath = trustedRequestPath
        self.enforceWorkloadParametersFiltering = enforceWorkloadParametersFiltering
        self.testSignalHeader = testSignalHeader
        self.testOptionsHeader = testOptionsHeader
        self.routingGroupAlias = routingGroupAlias
        self.trustedProxyRequestBypass = trustedProxyRequestBypass
        self.trustedProxyResponseBypass = trustedProxyResponseBypass
        self.trustedProxyRoutingGroupAlias = trustedProxyRoutingGroupAlias
        self.clientBundleID = clientBundleID
        self.bundleID = bundleID
        self.originatingBundleID = originatingBundleID
        self.featureID = featureID
        self.sessionID = sessionID
        self.aeadKey = aeadKey
        self.serverQoS = serverQoS
        self.userID = userID
        self.isServerDrivenConfigurationOutdated = isServerDrivenConfigurationOutdated
        self.multiTurn = multiTurn
    }

    init<
        ServerDrivenConfiguration: ServerDrivenConfigurationProtocol,
        SystemInfo: SystemInfoProtocol,
        FeatureFlagChecker: FeatureFlagCheckerProtocol
    >(
        clientBundleID: String,
        bundleID: String,
        originatingBundleID: String?,
        featureID: String?,
        sessionID: UUID?,
        configuration: any Configuration,
        parameters: Workload,
        multiTurn: Bool,
        serverConfiguration: ServerDrivenConfiguration,
        userID: uid_t?,
        systemInfo: SystemInfo,
        featureFlagChecker: FeatureFlagChecker
    ) throws {
        let aeadKey = try {
            if let forceAEADKey = configuration[.forceAEADKey], forceAEADKey.count > 0 {
                // if we are forcing a specific AEAD key based on defaults, decode it and use it.
                guard let data = Data(base64Encoded: forceAEADKey.data(using: .utf8) ?? Data()) else {
                    throw TrustedRequestError(code: .failedToLoadKeyData)
                }

                return data
            } else {
                // Otherwise, generate random data to use as kData.
                var kData = Data(count: 16)

                let result = kData.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) in
                    SecRandomCopyBytes(kSecRandomDefault, 16, ptr.baseAddress!)
                }

                if result != errSecSuccess {
                    throw TrustedRequestError(code: .failedToLoadKeyData)
                }

                return kData
            }
        }()

        let environment = configuration.environment(systemInfo: systemInfo)

        let maxCachedAttestations: Int
        let maxInlineAttestations: Int
        let maxTotalAttestations: Int
        let trustedProxyRequestBypass: Bool?
        let trustedProxyResponseBypass: Bool

        let maxCachedAttestationsFromConfigOrDefault = configuration[.trustedProxyMaxCachedAttestations] ?? serverConfiguration.trustedProxyMaxCachedAttestations ?? 2
        // clamp to valid range. Ideally we should do it in some other layer
        maxCachedAttestations = maxCachedAttestationsFromConfigOrDefault.clamped(to: 0...2)

        let maxTotalAttestationsOrDefault = configuration[.trustedProxyMaxTotalAttestations] ?? serverConfiguration.trustedProxyDefaultTotalAttestations ?? 4
        maxTotalAttestations = maxTotalAttestationsOrDefault.clamped(to: 1...4)

        let maxInlineAttestationsFromConfigOrCalculated = configuration[.trustedProxyMaxInlineAttestations] ?? maxTotalAttestations - maxCachedAttestations
        maxInlineAttestations = maxInlineAttestationsFromConfigOrCalculated.clamped(to: 0...4)

        if multiTurn || parameters.type == agentWorkloadType {
            trustedProxyRequestBypass = false
            trustedProxyResponseBypass = false
        } else {
            trustedProxyRequestBypass = configuration[.trustedProxyRequestBypass]
            trustedProxyResponseBypass = configuration[.trustedProxyResponseBypass]
        }

        self.init(
            maxCachedAttestations: maxCachedAttestations,
            maxTotalAttestations: maxTotalAttestations,
            maxInlineAttestations: maxInlineAttestations,
            maxProtobufRandomizedPaddingSize: configuration[.maxProtobufRandomizedPaddingSize],
            overrideCellID: configuration[.overrideCellID],
            rateLimiterMaximumRateLimitDuration: configuration[.rateLimiterMaximumRateLimitDuration],
            rateLimiterMaximumRateLimitTTL: configuration[.rateLimiterMaximumRateLimitTtl],
            rateLimiterDefaultJitterFactor: configuration[.rateLimiterDefaultJitterFactor],
            ignoreCertificateErrors: configuration[.ignoreCertificateErrors],
            environment: environment.name,
            forceOHTTP: environment.forceOHTTP,
            endpointURL: environment.ropesUrl,
            trustedRequestHostname: environment.ropesHostname,
            trustedRequestPath: configuration[.trustedRequestPath],
            enforceWorkloadParametersFiltering: configuration[.enforceWorkloadParametersFiltering],
            testSignalHeader: configuration[.testSignalHeader],
            testOptionsHeader: configuration[.testOptions],
            routingGroupAlias: configuration[.routingGroupAlias],
            trustedProxyRequestBypass: trustedProxyRequestBypass,
            trustedProxyResponseBypass: trustedProxyResponseBypass,
            trustedProxyRoutingGroupAlias: configuration[.trustedProxyRoutingGroupAlias],
            clientBundleID: clientBundleID,
            bundleID: bundleID,
            originatingBundleID: originatingBundleID,
            featureID: featureID,
            sessionID: sessionID,
            aeadKey: aeadKey,
            serverQoS: ServerQoS(taskPriority: Task.currentPriority),
            userID: userID,
            isServerDrivenConfigurationOutdated: serverConfiguration.isOutdated,
            multiTurn: multiTurn
        )
    }

    var description: String {
        return """
            <TrustedRequestConfiguration
                maxCachedAttestations: \(maxCachedAttestations)
                maxTotalAttestations: \(maxTotalAttestations)
                maxInlineAttestations: \(maxInlineAttestations)

                overrideCellID: \(String(describing: overrideCellID))

                rateLimiterMaximumRateLimitDuration: \(rateLimiterMaximumRateLimitDuration)
                rateLimiterMaximumRateLimitTTL: \(rateLimiterMaximumRateLimitTTL)
                rateLimiterDefaultJitterFactor: \(rateLimiterDefaultJitterFactor)

                useTrustedProxy: true
                trustedProxyResponseBypass: \(trustedProxyResponseBypass)
                trustedProxyRequestBypass: \(String(describing: trustedProxyRequestBypass))
                trustedProxyRoutingGroupAlias: \(String(describing: trustedProxyRoutingGroupAlias))

                multiTurn: \(multiTurn)

                ignoreCertificateErrors: \(ignoreCertificateErrors)
                environment: \(environment)
                forceOHTTP: \(forceOHTTP)
                endpointURL: \(endpointURL)
                trustedRequestHostname: \(trustedRequestHostname)
                trustedRequestPath: \(trustedRequestPath)
                enforceWorkloadParametersFiltering: \(enforceWorkloadParametersFiltering)

                testSignalHeader: \(String(describing: testSignalHeader))
                testOptionsHeader: \(String(describing: testOptionsHeader))
                routingGroupAlias: \(String(describing: routingGroupAlias))

                bundleID: \(bundleID)
                featureID: \(String(describing: featureID))
                sessionID: \(String(describing: sessionID))
                originatingBundleID: \(String(describing: self.originatingBundleID))

                aeadKey: \(aeadKey)
                serverQoS: \(serverQoS)

                isServerDrivenConfigurationOutdated: \(isServerDrivenConfigurationOutdated)
            >
            """

    }
}

enum ServerQoS: String {
    case high = "high"
    case low = "low"
    case background = "background"

    init(taskPriority: TaskPriority) {
        self =
            switch taskPriority {
            case .background:
                .background
            case .utility:
                .low
            case .low:
                .low
            case .medium:
                .high
            case .high:
                .high
            case .userInitiated:
                .high
            default:
                .high
            }
    }
}
