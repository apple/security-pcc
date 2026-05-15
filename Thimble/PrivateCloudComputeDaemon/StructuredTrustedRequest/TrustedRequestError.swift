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
//  TrustedRequestError.swift
//  PrivateCloudCompute
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

struct TrustedRequestError: Error {
    enum Code {
        case failedToLoadKeyData
        case privacyProxyPermissionDenied
        case privacyProxyIpcFailed
        case privacyProxyInvalidUserTier
        case privacyProxyInvalidParam
        case privacyProxyInvalidConfigData
        case privacyProxyInvalidConfigDataSign
        case privacyProxyServerFailure
        case privacyProxyFeatureDisabled
        case privacyProxyRateLimited
        case privacyProxyInvalidAuthentication
        case privacyProxyInvalidRequest
        case privacyProxyNetworkFailure
        case privacyProxyTransparencyFailure
        case privacyProxyInvalidConfigDates
        case privacyProxyTDMFailure
        case privacyProxyInvalidResponse
        case privacyProxyFailed
        case failedToValidateAllAttestations
        case responseSummaryIndicatesFailure
        case responseSummaryIndicatesUnauthenticated
        case responseSummaryIndicatesInternalError
        case responseSummaryIndicatesInvalidRequest
        case invalidClientOverrideBuildVersion
        case responseSummaryIndicatesProxyFindWorkerError
        case responseSummaryIndicatesProxyWorkerValidationError
        case missingAttestationBundle
        case invalidAttestationBundle
        case routingHintMismatch
        /// When response bypass is on, but we do not receive a REL with a response bypass context
        case missingResponseBypassContext
        /// When response bypass is on, but the node stream gives response data
        case expectedResponseOnBypass
        /// When response bypass is off, but we get a REL with a response bypass context
        case unexpectedlyReceivedResponseBypassContext
        /// Used when we validated an attestation using CloudAttestation framework, but can't determine NodeKind from
        /// the results.
        case unexpectedAttestationKind
        /// Indicates that the kind of node we have validated an attestation for is not what we expected.
        case attestationKindMismatch
        /// The initial network send, InvokeRequest, failed probably due to a timeout cancellation.
        case invokeRequestPayloadSendFailedAndCancelled
    }

    var code: Code
    var errorReason: PrivacyProxyErrorReason?
    var underlying: [any Error] = []

    var errorCodeString: String {
        switch code {
        case .failedToLoadKeyData:
            return "FailedToLoadKeyData"
        case .privacyProxyPermissionDenied:
            return "PrivacyProxyPermissionDenied"
        case .privacyProxyIpcFailed:
            return "PrivacyProxyIpcFailed"
        case .privacyProxyInvalidUserTier:
            return "PrivacyProxyInvalidUserTier"
        case .privacyProxyInvalidParam:
            return "PrivacyProxyInvalidParam"
        case .privacyProxyInvalidConfigData:
            return "PrivacyProxyInvalidConfigData"
        case .privacyProxyInvalidConfigDataSign:
            return "PrivacyProxyInvalidConfigDataSign"
        case .privacyProxyServerFailure:
            return "PrivacyProxyServerFailure"
        case .privacyProxyFeatureDisabled:
            return "PrivacyProxyFeatureDisabled"
        case .privacyProxyRateLimited:
            return "PrivacyProxyRateLimited"
        case .privacyProxyInvalidAuthentication:
            return "PrivacyProxyInvalidAuthentication"
        case .privacyProxyInvalidRequest:
            return "PrivacyProxyInvalidRequest"
        case .privacyProxyNetworkFailure:
            return "PrivacyProxyNetworkFailure"
        case .privacyProxyTransparencyFailure:
            return "PrivacyProxyTransparencyFailure"
        case .privacyProxyInvalidConfigDates:
            return "PrivacyProxyInvalidConfigDates"
        case .privacyProxyTDMFailure:
            return "PrivacyProxyTDMFailure"
        case .privacyProxyInvalidResponse:
            return "PrivacyProxyInvalidResponse"
        case .privacyProxyFailed:
            return "PrivacyProxyFailed"
        case .failedToValidateAllAttestations:
            return "FailedToValidateAllAttestations"
        case .responseSummaryIndicatesFailure:
            return "ResponseSummaryIndicatesFailure"
        case .responseSummaryIndicatesUnauthenticated:
            return "ResponseSummaryIndicatesUnauthenticated"
        case .responseSummaryIndicatesInternalError:
            return "ResponseSummaryIndicatesInternalError"
        case .responseSummaryIndicatesInvalidRequest:
            return "ResponseSummaryIndicatesInvalidRequest"
        case .invalidClientOverrideBuildVersion:
            return "InvalidClientOverrideBuildVersion"
        case .responseSummaryIndicatesProxyFindWorkerError:
            return "ResponseSummaryIndicatesProxyFindWorkerError"
        case .responseSummaryIndicatesProxyWorkerValidationError:
            return "ResponseSummaryIndicatesProxyWorkerValidationError"
        case .missingAttestationBundle:
            return "MissingAttestationBundle"
        case .invalidAttestationBundle:
            return "InvalidAttestationBundle"
        case .routingHintMismatch:
            return "RoutingHintMismatch"
        case .missingResponseBypassContext:
            return "MissingResponseBypassContext"
        case .expectedResponseOnBypass:
            return "ExpectedResponseOnBypass"
        case .unexpectedlyReceivedResponseBypassContext:
            return "UnexpectedlyReceivedResponseBypassContext"
        case .unexpectedAttestationKind:
            return "UnexpectedAttestationKind"
        case .attestationKindMismatch:
            return "AttestationKindMismatch"
        case .invokeRequestPayloadSendFailedAndCancelled:
            return "InvokeRequestPayloadSendFailedAndCancelled"
        }
    }

    var selfOrFirstUnderlying: any Error {
        return self.underlying.first ?? self
    }

    init(code: Code, errorReason: PrivacyProxyErrorReason? = nil, underlying: [any Error] = []) {
        self.code = code
        self.errorReason = errorReason
        self.underlying = underlying
    }
}
