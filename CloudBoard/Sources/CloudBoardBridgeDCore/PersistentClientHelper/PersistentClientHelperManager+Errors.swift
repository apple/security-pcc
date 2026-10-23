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

import Foundation

extension PersistentClientHelperManager {
    enum ConnectionError: Error, CustomStringConvertible {
        case noAttestationReceived(connectionID: String)
        case idleTimeout(connectionID: String)
        case unknownResponseType(connectionID: String)
        case noActiveHelper(connectionID: String)
        case helperSetupFailed(connectionID: String, underlyingError: Error)
        case nodeNotFound(connectionID: String)
        case reconnectRequested(connectionID: String)
        case metadataValidationFailed(connectionID: String)
        case missingServiceDefinedMetadata(connectionID: String)
        /// The stream coordinator in `runNodeConnection` exited with no per-stream
        /// error — e.g. after server-initiated drain, or after the
        /// primary/replacement chain ended. We throw this so the retry loop opens
        /// a fresh stream; SD removal is what stops the retry loop, not this
        /// signal. Carries the node `address` rather than a single stream's
        /// connectionID: the coordinator outlives any one stream.
        case streamCoordinatorExited(address: String)
        /// The active attestation key has hard-expired. The helper is provably
        /// useless past this point — any further query would fail at the
        /// server's AEAD step. We force teardown to reclaim the stream slot
        /// rather than waiting on a drain-complete or idle-timeout that may
        /// never fire.
        case helperKeyExpired(connectionID: String)
        /// The outer wrapper around `establishConnection` tripped its hard
        /// timeout. gRPC-Swift's own `connectionPool.maxWaitTime` knob has
        /// been observed not to bound real-world failures (closed-on-accept
        /// listeners, HTTP/2 mid-handshake RST), so we wrap with explicit
        /// structured-concurrency cancellation. Retryable: the swap-on-
        /// early-failure path picks this up via the same retry filter that
        /// handles other establishment errors.
        case establishmentTimeout(host: String, port: Int, after: Duration)

        var isRetryable: Bool {
            switch self {
            case .noAttestationReceived:
                true // transient: stream ended before attestation arrived
            case .idleTimeout:
                true // transient: server may have been temporarily unresponsive
            case .unknownResponseType:
                true // transient: reconnect to get a fresh stream
            case .noActiveHelper:
                true // transient: state machine allowed chunk but helper is missing
            case .helperSetupFailed:
                true // transient: helper process may have crashed; retry with new helper
            case .nodeNotFound:
                true // transient: node may have been removed concurrently
            case .reconnectRequested:
                true // server requested reconnection (e.g. attestation rotated)
            case .metadataValidationFailed:
                true // transient: SD metadata may be stale; retry with fresh metadata
            case .missingServiceDefinedMetadata:
                true // transient: metadata may arrive after SD re-publishes
            case .streamCoordinatorExited:
                true // not really an error: stream ended cleanly, reopen
            case .helperKeyExpired:
                true // expected past key expiry; reconnect with fresh keys
            case .establishmentTimeout:
                true // transient: outer cap on connection establishment
            }
        }

        var description: String {
            switch self {
            case .noAttestationReceived(let id):
                "No attestation received for connectionID: \(id)"
            case .idleTimeout(let id):
                "Idle timeout exceeded for connectionID: \(id)"
            case .unknownResponseType(let id):
                "Received unknown response type for connectionID: \(id)"
            case .noActiveHelper(let id):
                "No active helper for connectionID: \(id)"
            case .helperSetupFailed(let id, let error):
                "Helper setup failed for connectionID: \(id): \(error)"
            case .nodeNotFound(let id):
                "Node already removed for connectionID: \(id)"
            case .reconnectRequested(let id):
                "Server requested reconnection for connectionID: \(id)"
            case .metadataValidationFailed(let id):
                "In-stream metadata validation failed for connectionID: \(id)"
            case .missingServiceDefinedMetadata(let id):
                "No serviceDefinedMetadata available for connectionID: \(id)"
            case .streamCoordinatorExited(let address):
                "Stream coordinator exited cleanly for address: \(address); reconnecting"
            case .helperKeyExpired(let id):
                "Helper attestation key hard-expired for connectionID: \(id); reconnecting with fresh keys"
            case .establishmentTimeout(let host, let port, let after):
                "Connection establishment to \(host):\(port) did not complete within \(after); cancelling"
            }
        }
    }
}
