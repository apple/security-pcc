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

/// Error codes used when synthesizing persistent service query error responses.
///
/// Each case's `rawValue` is the integer code sent in ``PersistentService.ErrorInfo``
/// payloads so that cloud apps can programmatically distinguish framework-generated errors
/// from errors originating in the persistent service itself.
package enum PersistentServiceQueryErrorCode: Int, Sendable {
    /// The query exceeded its specified timeout without receiving a response from the persistent service.
    ///
    /// Wire code **1** — included in the synthesized error payload so the cloud app
    /// can differentiate a timeout from a service-side failure.
    case timeout = 1

    /// The requested persistent service is not configured on this node.
    /// The service name is not in persistentServiceClients.
    case serviceNotConfigured = 2

    /// The persistent service is configured but no XPC connection to the
    /// client router is currently available (e.g. router process not running).
    case noClientRouterConnection = 3

    /// The Request Execution Log has been finalized; no further persistent
    /// service queries are accepted for this request.
    case relFinalized = 4

    /// No cb_pclienthelper in `.ready` state serves the requested filter.
    case noClientHelperAvailable = 5

    /// The query payload could not be parsed (e.g. invalid protobuf).
    case malformedQuery = 6

    /// OHTTP encryption or decryption failed.
    case encryptionFailure = 7

    /// A cb_pclienthelper serves the requested filter but the requesting
    /// cb_jobhelper has not approved its attestation.
    case attestationNotApproved = 8

    /// The cb_pclienthelper was removed, the bridge disconnected, or the
    /// XPC connection to the helper failed.
    case clientHelperConnectionLost = 9

    /// A response was received but no pending query matched its correlation ID.
    /// Used to track metric emissions that could not be correlated to a query.
    case noMatchingCorrelationID = 10

    /// A required REL entry could not be sent after a persistent service
    /// attestation was marked as used. All persistent service queries are
    /// blocked for the remainder of this request.
    case relSendFailed = 11

    /// Ready helpers serve the requested filter and some have been approved,
    /// but the number of approved nodes is below the required quorum threshold
    /// and no sticky protection applies.
    case quorumNotMet = 12

    /// Ready helpers serve the requested filter but none have approved
    /// attestations — zero nodes are available toward quorum.
    case quorumZeroApproved = 13

    /// The filter is configured for local serving but the local query path
    /// is not yet implemented.
    case localFilterNotImplemented = 14

    /// Quorum could not be reached because one or more jobhelpers did not
    /// respond to router-emitted attestation-usage reports within the
    /// configured retry window
    /// (`PrivateFilterQuorumConfig.attestationResendInterval` ×
    /// `maxAttestationAttempts`). Distinct from ``quorumNotMet`` (under
    /// threshold despite responses) and ``attestationNotApproved``
    /// (explicit deny).
    case quorumAttestationTimedOut = 15

    /// The client router reached an internal state the selection code believed
    /// was unreachable (e.g. a helper-selection helper returning a sentinel the
    /// caller was supposed to have filtered out upstream). Surfacing this as a
    /// distinct error lets ops tell it apart from ordinary selection failures.
    case internalRouterError = 16
}
