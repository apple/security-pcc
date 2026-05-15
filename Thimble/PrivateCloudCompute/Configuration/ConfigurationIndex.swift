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
//  ConfigurationIndex.swift
//  PrivateCloudCompute
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

package enum ClientConfigurationKey: String, CaseIterable {
    case environment
    case expiredBuildNotificationDisplayInterval
    case ignoreCertificateErrors
    case rateLimitRequestPath
    case rateLimitRequestMinimumSpacing
    case rateLimitUnmatchedRequestStorageTimeout
    case prefetchRequestPath
    case trustedRequestPath
    case forceAEADKey
    case lttIssuer
    case ottIssuer
    case prewarmAttestationsValidityInSeconds
    case maxProtobufRandomizedPaddingSize
    case overrideCellID
    case rateLimiterSessionTimeout
    case rateLimiterSessionLengthForSoftening
    case rateLimiterDefaultJitterFactor
    case rateLimiterMaximumRateLimitTtl
    case rateLimiterMaximumRateLimitDuration
    case testSignalHeader
    case testOptions
    case trustedProxyMaxCachedAttestations
    case trustedProxyMaxInlineAttestations
    case trustedProxyMaxPrefetchBatches
    case trustedProxyMaxPrefetchedAttestations
    case trustedProxyMaxTotalAttestations
    case trustedProxyRequestBypass
    case trustedProxyResponseBypass
    case trustedProxyRoutingGroupAlias
    case routingGroupAlias
    case enforceWorkloadParametersFiltering
    case proposedLiveOnEnvironment
    case bootFixedLiveOnEnvironment

    package var domain: String {
        switch self {
        case .environment:
            return "com.apple.privateCloudCompute"
        default:
            return "com.apple.privateCloudCompute.client"
        }
    }
}

package struct ConfigurationIndex<Value> {
    package var domain: String
    package var name: String
    package var defaultValue: Value
    package var isAllowedOnCustomerBuilds: Bool

    init(key: ClientConfigurationKey, defaultValue: Value, isAllowedOnCustomerBuilds: Bool = false) {
        self.domain = key.domain
        self.name = key.rawValue
        self.defaultValue = defaultValue
        self.isAllowedOnCustomerBuilds = isAllowedOnCustomerBuilds
    }
}

extension ConfigurationIndex: Sendable where Value: Sendable {
}

extension ConfigurationIndex {
    /// The environment to use. This defaults to "" to allow automatically picking carry vs. production.
    package static var environment: ConfigurationIndex<String?> { .init(key: .environment, defaultValue: nil) }

    package static var ignoreCertificateErrors: ConfigurationIndex<Bool> { .init(key: .ignoreCertificateErrors, defaultValue: false) }

    package static var rateLimitRequestPath: ConfigurationIndex<String> { .init(key: .rateLimitRequestPath, defaultValue: "/ratelimits") }
    package static var rateLimitRequestMinimumSpacing: ConfigurationIndex<Double> { .init(key: .rateLimitRequestMinimumSpacing, defaultValue: 60.0) }

    package static var prefetchRequestPath: ConfigurationIndex<String> { .init(key: .prefetchRequestPath, defaultValue: "/prefetch") }

    package static var trustedRequestPath: ConfigurationIndex<String> { .init(key: .trustedRequestPath, defaultValue: "/invoke") }

    package static var forceAEADKey: ConfigurationIndex<String?> { .init(key: .forceAEADKey, defaultValue: nil) }

    package static var lttIssuer: ConfigurationIndex<String> { .init(key: .lttIssuer, defaultValue: "tis.gateway.icloud.com") }
    package static var ottIssuer: ConfigurationIndex<String> { .init(key: .ottIssuer, defaultValue: "rts.gateway.icloud.com") }

    package static var prewarmAttestationsValidityInSeconds: ConfigurationIndex<Double> { .init(key: .prewarmAttestationsValidityInSeconds, defaultValue: 30.0 * 60.0) }

    /// Allows to override `TrustedProxyMaxCachedAttestations` from
    /// server-driven config with another value that could be _smaller or larger_. This is not used for clamping the value to valid range
    /// since this may be used to either increase or decrease the number of attestations used.
    package static var trustedProxyMaxCachedAttestations: ConfigurationIndex<Int?> { .init(key: .trustedProxyMaxCachedAttestations, defaultValue: nil) }
    /// Allows to override the number of max inline attestations used that is typically calculated from max cached and max total
    /// attestation fields in the server-driven config.
    package static var trustedProxyMaxInlineAttestations: ConfigurationIndex<Int?> { .init(key: .trustedProxyMaxInlineAttestations, defaultValue: nil) }
    package static var trustedProxyMaxPrefetchBatches: ConfigurationIndex<Int> { .init(key: .trustedProxyMaxPrefetchBatches, defaultValue: 1) }
    package static var trustedProxyMaxPrefetchedAttestations: ConfigurationIndex<Int> { .init(key: .trustedProxyMaxPrefetchedAttestations, defaultValue: 60) }
    /// Allows to override `TrustedProxyMaxTotalAttestations` value from server-driven config.
    package static var trustedProxyMaxTotalAttestations: ConfigurationIndex<Int?> { .init(key: .trustedProxyMaxTotalAttestations, defaultValue: nil) }

    /// Maximum number of random bytes that should be added as a padding to some protobuf messages.
    package static var maxProtobufRandomizedPaddingSize: ConfigurationIndex<Int> { .init(key: .maxProtobufRandomizedPaddingSize, defaultValue: 2048) }

    package static var overrideCellID: ConfigurationIndex<String?> { .init(key: .overrideCellID, defaultValue: nil, isAllowedOnCustomerBuilds: true) }

    package static var rateLimiterSessionTimeout: ConfigurationIndex<Double> { .init(key: .rateLimiterSessionTimeout, defaultValue: 60.0) }
    package static var rateLimiterSessionLengthForSoftening: ConfigurationIndex<Int> { .init(key: .rateLimiterSessionLengthForSoftening, defaultValue: 5) }
    package static var rateLimiterDefaultJitterFactor: ConfigurationIndex<Double> { .init(key: .rateLimiterDefaultJitterFactor, defaultValue: 0.1) }
    package static var rateLimiterMaximumRateLimitTtl: ConfigurationIndex<Double> { .init(key: .rateLimiterMaximumRateLimitTtl, defaultValue: 60.0 * 60.0 * 24.0) }
    package static var rateLimiterMaximumRateLimitDuration: ConfigurationIndex<Double> { .init(key: .rateLimiterMaximumRateLimitDuration, defaultValue: 60.0 * 60.0 * 24.0) }
    package static var rateLimitUnmatchedRequestStorageTimeout: ConfigurationIndex<Double> { .init(key: .rateLimitUnmatchedRequestStorageTimeout, defaultValue: 60.0) }

    /// If set, then /invoke requests to ropes will contain a header `apple-test-signal` with this value
    package static var testSignalHeader: ConfigurationIndex<String?> { .init(key: .testSignalHeader, defaultValue: nil) }
    package static var testOptions: ConfigurationIndex<String?> { .init(key: .testOptions, defaultValue: nil) }

    /// If set, then invoke request will contain a header `apple-trusted-proxy-request-bypass` with value `"true"` or `"false"` depending on the value.
    package static var trustedProxyRequestBypass: ConfigurationIndex<Bool?> { .init(key: .trustedProxyRequestBypass, defaultValue: nil) }
    /// If set to false, then the trusted proxy request will expect a response on the node stream, rather than via a response bypass.
    /// This is for testing only right now. In production all trusted proxy requests have response bypass.
    package static var trustedProxyResponseBypass: ConfigurationIndex<Bool> { .init(key: .trustedProxyResponseBypass, defaultValue: true) }

    /// If set, then invoke and prefetch requests will contain a header `apple-trusted-proxy-routing-group-alias` with this value
    package static var trustedProxyRoutingGroupAlias: ConfigurationIndex<String?> { .init(key: .trustedProxyRoutingGroupAlias, defaultValue: nil) }
    package static var routingGroupAlias: ConfigurationIndex<String?> { .init(key: .routingGroupAlias, defaultValue: nil) }

    package static var enforceWorkloadParametersFiltering: ConfigurationIndex<Bool> { .init(key: .enforceWorkloadParametersFiltering, defaultValue: true) }

    package static var proposedLiveOnEnvironment: ConfigurationIndex<String?> { .init(key: .proposedLiveOnEnvironment, defaultValue: nil) }
    package static var bootFixedLiveOnEnvironment: ConfigurationIndex<String?> { .init(key: .bootFixedLiveOnEnvironment, defaultValue: nil) }

    /// The minimum time (in seconds)  before the ExpiredBuildNotification can be triggered again after being shown.
    package static var expiredBuildNotificationDisplayInterval: ConfigurationIndex<Double> {
        .init(
            key: .expiredBuildNotificationDisplayInterval,
            defaultValue: 60.0 * 60.0 * 24.0  // 24 hours
        )
    }
}
