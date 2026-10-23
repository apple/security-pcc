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
//  EnsemblePorterError.swift
//  EnsembleWarden
//
//  Created by Oliver Chick (ORAC) on 2025-07-31.
//

/// Errors that can occur during EnsemblePorter operations.
///
/// This enumeration defines all possible error conditions that can arise
/// when using the EnsemblePorter service, from transport failures to
/// entitlement issues.
public enum EnsemblePorterError: Sendable, Error, Equatable {
    // MARK: Lifecycle
    /// The service is not currently running.
    case notRunning

    /// Invalid state transition attempted.
    case invalidStateTransition(existing: String, proposed: String)

    /// Cryptographic keys have not yet been supplied to the service.
    case keysNotYetSupplied

    /// The service is already running and cannot be started again.
    case alreadyRunning

    /// The service has already been closed.
    case alreadyClosed

    // MARK: Keys
    /// The keys supplied to the porter are invalid.
    case invalidKeysSupplied

    /// Keys should not be supplied more than once
    case keysAlreadySupplied

    /// Requested a key for a turn that we don't have
    case noKeyForTurn(Int)

    /// Follower tokens have already been fetched and cannot be fetched again
    case followerTokensAlreadyFetched

    /// Failed to distribute follower tokens to all ensemble nodes
    case followerTokensDistributionFailed

    /// Operation is only valid on leader node but was called on follower
    case notLeader

    // MARK: Transport
    /// The underlying transport mechanism failed.
    case transportFailed

    /// The message received by EnsemblePorterController was invalid
    case invalidMessageReceived

    // MARK: Entitlements
    /// Failed to check client entitlements.
    case entitlementCheckFailed

    /// A required entitlement is missing.
    /// - Parameter String: The name of the missing entitlement.
    case missingEntitlement(String)

    // MARK: Other errors

    case ensemblerSessionUnavailable

    case missingRequestID

    /// Ensembled threw an error
    case ensembledError

    /// Unsupported XPC request type
    case unsupportedXPCRequestType

    /// Launchd managed job count mismatch
    case launchdManagedJobMismatch(expected: Int, actual: Int)

    /// Invalid data length
    case invalidDataLength(expected: Int, actual: Int)

    /// An unexpected error occurred.
    case unexpectedError

    /// Heartbeat to a follower failed too many consecutive times
    case heartbeatFailure

    /// Heartbeat received for an instance that is not tracked by the controller
    case instanceNotFound

    /// ECDH key-attestation step failed: the follower's public key could not be parsed,
    /// or the shared-secret derivation failed. Distinct from `transportFailed` /
    /// `ensembledError`, which cover the transport leg of the prewarm exchange.
    case keyAttestationFailed

    // MARK: AppleComputeEnsembler data-messaging errors
    //
    // Mirror the cases of `AppleComputeEnsembler.DataMessageError` so heartbeat-failure
    // logs carry the actual failure mode (case + appID + reason) instead of the bare
    // type name "DataMessageError" that `String(reportable:)` would otherwise emit.

    /// Follower has no registered handler for this appID.
    case dataMessageNoRegisteredHandler(appID: String)

    /// Follower app callback did not return within the allotted time.
    case dataMessageTimeoutOnPeer(appID: String)

    /// Leader did not receive any response from the follower within the timeout.
    case dataMessageNoResponseReceived(appID: String)

    /// Internal implementation error on the follower (e.g. broken XPC session,
    /// deallocated service instance).
    case dataMessageInternalError(appID: String, reason: String)

    /// Send API was called while the ensembler (or TLS connection) is not in the ready
    /// state. `currentStatus` carries the actual state.
    case dataMessageNotReady(appID: String, currentStatus: String)
}

extension EnsemblePorterError: Codable {}

extension EnsemblePorterError: ReportableError {
    public var publicDescription: String {
        switch self {
        case .notRunning:
            return "Not yet running"
        case .invalidStateTransition(let existing, let proposed):
            return "Invalid state transition from \(existing) to \(proposed)"
        case .alreadyRunning:
            return "Already running"
        case .alreadyClosed:
            return "Already closed"
        case .keysNotYetSupplied:
            return "Keys not yet supplied"
        case .invalidKeysSupplied:
            return "Invalid keys supplied to the porter"
        case .keysAlreadySupplied:
            return "Keys have already been supplied to the porter"
        case .invalidMessageReceived:
            return "Ensembleportercontroller received an invalid message"
        case .noKeyForTurn(let turnNumber):
            return "No key available for turn. turn_number=\(turnNumber)"
        case .followerTokensAlreadyFetched:
            return "Follower tokens have already been fetched"
        case .followerTokensDistributionFailed:
            return "Failed to distribute follower tokens to all ensemble nodes"
        case .notLeader:
            return "Operation only valid on leader node"
        case .transportFailed:
            return "Transport failed"
        case .entitlementCheckFailed:
            return "Unable to check entitlements"
        case .missingEntitlement(let missing):
            return "Missing entitlement: \(missing)"
        case .missingRequestID:
            return "Request ID missing/invalid"
        case .ensembledError:
            return "Error from ensembled"
        case .ensemblerSessionUnavailable:
            return "Ensembled not available"
        case .unsupportedXPCRequestType:
            return "Unsupported XPC request type"
        case .launchdManagedJobMismatch(let expected, let actual):
            return "Launchd managed job count mismatch. expected=\(expected) actual=\(actual)"
        case .invalidDataLength(let expected, let actual):
            return "Invalid data length. expected=\(expected) actual=\(actual)"
        case .unexpectedError:
            return "Unexpected error"
        case .heartbeatFailure:
            return "Heartbeat failed too many consecutive times"
        case .instanceNotFound:
            return "Instance not found in controller"
        case .keyAttestationFailed:
            return "ECDH key-attestation failed"
        case .dataMessageNoRegisteredHandler(let appID):
            return "DataMessage.noRegisteredHandler(appID=\(appID))"
        case .dataMessageTimeoutOnPeer(let appID):
            return "DataMessage.timeoutOnPeerHandler(appID=\(appID))"
        case .dataMessageNoResponseReceived(let appID):
            return "DataMessage.noResponseReceived(appID=\(appID))"
        case .dataMessageInternalError(let appID, let reason):
            return "DataMessage.internalError(appID=\(appID), reason=\(reason))"
        case .dataMessageNotReady(let appID, let currentStatus):
            return "DataMessage.notReady(appID=\(appID), currentStatus=\(currentStatus))"
        }
    }

    /// Provides metrics-friendly label strings for error tracking. Exhaustive on purpose so
    /// adding a new case to `EnsemblePorterError` becomes a compile error here, forcing the
    /// author to pick a stable bucket rather than silently defaulting to `OTHER_ERROR`.
    package var metricsLabel: String {
        switch self {
        case .notRunning: return "NOT_RUNNING"
        case .invalidStateTransition: return "INVALID_STATE_TRANSITION"
        case .keysNotYetSupplied: return "NO_KEYS_SUPPLIED"
        case .alreadyRunning: return "ALREADY_RUNNING"
        case .alreadyClosed: return "ALREADY_CLOSED"
        case .invalidKeysSupplied: return "INVALID_KEYS_SUPPLIED"
        case .keysAlreadySupplied: return "KEYS_ALREADY_SUPPLIED"
        case .noKeyForTurn: return "NO_KEY_FOR_TURN"
        case .followerTokensAlreadyFetched: return "TOKENS_ALREADY_FETCHED"
        case .followerTokensDistributionFailed: return "TOKENS_DISTRIBUTION_FAILED"
        case .notLeader: return "NOT_LEADER"
        case .transportFailed: return "TRANSPORT_FAILED"
        case .invalidMessageReceived: return "INVALID_MESSAGE_RECEIVED"
        case .entitlementCheckFailed: return "ENTITLEMENT_CHECK_FAILED"
        case .missingEntitlement: return "MISSING_ENTITLEMENT"
        case .ensemblerSessionUnavailable: return "ENSEMBLER_SESSION_UNAVAILABLE"
        case .missingRequestID: return "MISSING_REQUEST_ID"
        case .ensembledError: return "ENSEMBLED_ERROR"
        case .unsupportedXPCRequestType: return "UNSUPPORTED_XPC_REQUEST_TYPE"
        case .launchdManagedJobMismatch: return "LAUNCHD_MANAGED_JOB_MISMATCH"
        case .invalidDataLength: return "INVALID_DATA_LENGTH"
        case .unexpectedError: return "UNEXPECTED_ERROR"
        case .heartbeatFailure: return "HEARTBEAT_FAILURE"
        case .instanceNotFound: return "INSTANCE_NOT_FOUND"
        case .keyAttestationFailed: return "KEY_ATTESTATION_FAILED"
        case .dataMessageNoRegisteredHandler: return "DATA_MESSAGE_NO_REGISTERED_HANDLER"
        case .dataMessageTimeoutOnPeer: return "DATA_MESSAGE_TIMEOUT_ON_PEER"
        case .dataMessageNoResponseReceived: return "DATA_MESSAGE_NO_RESPONSE_RECEIVED"
        case .dataMessageInternalError: return "DATA_MESSAGE_INTERNAL_ERROR"
        case .dataMessageNotReady: return "DATA_MESSAGE_NOT_READY"
        }
    }
}
