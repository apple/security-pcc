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
//  ErrorTelemetry.swift
//  PrivateCloudCompute
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

import CloudAttestation
import CloudTelemetry
import InternalSwiftProtobuf
import Network
import PrivateCloudCompute

// This file is responsible for encoding errors into strings for telemetry.
// Every time an error is sent to telemetry in one of the event fields, that
// field should be set by `error.telemetryString`, not by string interpolation
// (`"\(error)"`) or `error.localizedDescription`. The requirements for these
// strings set by the service operators are that they roughly appear to be
// enum-like. So these should not be informed by any dynamic part of the error,
// and there should not be free-form string messages in them.

// The idea is that these strings are roughly stable. Not that they need to
// be fixed forever, but they should not shift build-to-build because that
// will compromise the measurements to some degree.

// We can evolve this contract to account for any new errors or error types
// that we deem necessary over time.

extension Error {
    package var telemetryString: String {
        switch self {
        case let error as PrivateCloudComputeError:
            return Self.telemetryString(privateCloudComputeError: error)
        case let error as TrustedRequestError:
            return Self.telemetryString(trustedRequestError: error)
        case let error as CloudAttestationError:
            return Self.telemetryString(cloudAttestationError: error)
        case let error as CloudAttestation.TransparencyLogError:
            return Self.telemetryString(transparencyError: error)
        case let error as CloudAttestation.TransparencyPolicy.Error:
            return Self.telemetryString(transparencyPolicyError: error)
        case let error as BinaryEncodingError:
            return Self.telemetryString(binaryEncodingError: error)
        case let error as BinaryDecodingError:
            return Self.telemetryString(binaryDecodingError: error)
        case let error as NWError:
            return Self.telemetryString(nwError: error)
        default:
            return Self.telemetryString(nsError: self as NSError)
        }
    }

    private static func telemetryString(privateCloudComputeError: PrivateCloudComputeError) -> String {
        return privateCloudComputeError.telemetryString
    }

    private static func telemetryString(trustedRequestError: TrustedRequestError) -> String {
        if let pper = trustedRequestError.errorReason {
            return "TrustedRequestError_\(trustedRequestError.errorCodeString)_\(pper)"
        } else {
            return "TrustedRequestError_\(trustedRequestError.errorCodeString)"
        }
    }

    private static func telemetryString(cloudAttestationError: CloudAttestationError) -> String {
        let prefix = "CloudAttestationError"
        switch cloudAttestationError {
        case .unexpected(let reason):
            // We must narrow the scope of this unbounded reason string for telemetryString.
            switch reason {
            case "Unknown public key type": return "\(prefix)_unexpected_unknownPublicKeyType"
            case "Not implemented": return "\(prefix)_unexpected_notImplemented"
            default: return "\(prefix)_unexpected"
            }
        case .attestError: return "\(prefix)_attestError"
        case .validateError: return "\(prefix)_validateError"
        case .invalidNonce: return "\(prefix)_invalidNonce"
        case .expired: return "\(prefix)_expired"
        case .emptyCertificateChain: return "\(prefix)_emptyCertificateChain"
        case .malformedSecureConfig: return "\(prefix)_malformedSecureConfig"
        case .missingAttestingKey: return "\(prefix)_missingAttestingKey"
        case .missingSealedHash: return "\(prefix)_missingSealedHash"
        case .untrustedAppData: return "\(prefix)_untrustedAppData"
        @unknown default: return "\(prefix)_UnrecognizedCase"
        }
    }

    private static func telemetryString(transparencyError: TransparencyLogError) -> String {
        let prefix = "TransparencyLogError"
        switch transparencyError {
        case .httpError(let statusCode): return "\(prefix)_httpError_\(telStr(statusCode))"
        case .internalError: return "\(prefix)_internalError"
        case .mutationPending: return "\(prefix)_mutationPending"
        case .invalidRequest: return "\(prefix)_invalidRequest"
        case .notFound: return "\(prefix)_notFound"
        case .invalidProof: return "\(prefix)_invalidProof"
        case .unknownStatus: return "\(prefix)_unknownStatus"
        case .unrecognized(let status): return "\(prefix)_unrecognized_\(telStr(status))"
        case .unknown: return "\(prefix)_unknown"
        case .insertFailed: return "\(prefix)_insertFailed"
        case .clientError: return "\(prefix)_clientError"
        case .expired: return "\(prefix)_expired"
        case .pendingExpiration: return "\(prefix)_pendingExpiration"
        case .requestLimitExceeded: return "\(prefix)_requestLimitExceeded"
        @unknown default: return "\(prefix)_UnrecognizedCase"
        }
    }

    private static func telemetryString(transparencyPolicyError: CloudAttestation.TransparencyPolicy.Error) -> String {
        let prefix = "TransparencyPolicyError"
        switch transparencyPolicyError {
        case .expired: return "\(prefix)_expired"
        case .malformedRelease(let error): return "\(prefix)_malformedRelease_\(Self.telemetryString(nsError: error as NSError))"
        case .missingProofs: return "\(prefix)_missingProofs"
        case .notIncluded: return "\(prefix)_notIncluded"
        case .unknown(let error): return "\(prefix)_unknown_\(Self.telemetryString(nsError: error as NSError))"
        @unknown default: return "\(prefix)_UnrecognizedCase"
        }
    }

    private static func telemetryString(binaryEncodingError: BinaryEncodingError) -> String {
        let prefix = "BinaryEncodingError"
        switch binaryEncodingError {
        case .anyTranscodeFailure: return "\(prefix)_anyTranscodeFailure"
        case .missingRequiredFields: return "\(prefix)_missingRequiredFields"
        @unknown default: return "\(prefix)_UnrecognizedCase"
        }
    }

    private static func telemetryString(binaryDecodingError: BinaryDecodingError) -> String {
        let prefix = "BinaryDecodingError"
        switch binaryDecodingError {
        case .trailingGarbage: return "\(prefix)_trailingGarbage"
        case .truncated: return "\(prefix)_truncated"
        case .invalidUTF8: return "\(prefix)_invalidUTF8"
        case .malformedProtobuf: return "\(prefix)_malformedProtobuf"
        case .missingRequiredFields: return "\(prefix)_missingRequiredFields"
        case .internalExtensionError: return "\(prefix)_internalExtensionError"
        case .messageDepthLimit: return "\(prefix)_messageDepthLimit"
        @unknown default: return "\(prefix)_UnrecognizedCase"
        }
    }

    private static func telemetryString(nwError: NWError) -> String {
        let prefix = "NWError"
        switch nwError {
        case .dns(let x): return "\(prefix)_dns_\(telStr(x))"
        case .posix(let x): return "\(prefix)_posix_\(telStr(x))"
        case .tls(let x): return "\(prefix)_tls_\(telStr(x))"
        case .wifiAware(let x): return "\(prefix)_wifiAware_\(telStr(x))"
        @unknown default: return "\(prefix)_UnrecognizedCase"
        }
    }

    private static func telemetryString(nsError: NSError) -> String {
        return "NSError_\(telStr(nsError.domain))_\(telStr(nsError.code))"
    }
}

func telStr<N>(_ n: N?) -> String where N: SignedInteger {
    guard let n else {
        return "unknown"
    }
    return if n >= 0 {
        "\(n)"
    } else {
        "N\(-n)"
    }
}

func telStr<S>(_ s: S?) -> String where S: StringProtocol {
    guard let s else {
        return "unknown"
    }
    return String(s)
}

func telStr<E>(_ e: E?) -> String where E: RawRepresentable, E.RawValue: SignedInteger {
    guard let e else {
        return "unknown"
    }
    return telStr(e.rawValue)
}
