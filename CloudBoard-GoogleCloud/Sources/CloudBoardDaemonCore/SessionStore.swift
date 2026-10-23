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

import CloudBoardJobHelperCore
import CloudBoardUtilities
import GRPCCore
import Metrics
import Synchronization

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

enum SessionError: Error, Equatable {
    case invalidKeyMaterial
    case sessionReplayed
    case unknownKeyID
}

/// Session store to keep track of requests CloudBoard has seen to prevent replay attacks that might allow an adversary
/// to exfiltrate sensitive information by replaying a request. CloudBoard prevents this by expecting the encapsulated
/// key material provided by the client that is used to derive a session key to be unique.
///
/// This store will reject new sessions identified by their key material that are already present when attempted to be
/// added.
///
/// To prevent unbounded growth, sessions expire once the corresponding attested node key expires since `cb_jobhelper`
/// will reject any request that contain key material wrapped to an expired node key anyway which allows us to safely
/// remove the session from the store.
final class SessionStore: Sendable {
    private struct State {
        var storedSessions = [Data: Set<Data>]()
        var sessionCount: Int {
            self.storedSessions.reduce(into: 0) { currentValue, sessionSetPair in
                currentValue += sessionSetPair.value.count
            }
        }
    }

    private let state = Mutex(State())
    private let attestationProvider: any AttestationProvider
    private let metricsFactory: any MetricsFactory

    init(attestationProvider: any AttestationProvider, metricsFactory: any MetricsFactory = MetricsSystem.factory) {
        self.attestationProvider = attestationProvider
        self.metricsFactory = metricsFactory
    }

    func addSession(keyMaterial: Data, keyID: Data) async throws {
        Counter(label: "cloudboard_session_added_total", factory: self.metricsFactory).increment()

        // Reject key material where the OHTTP key identifier (first byte, see RFC 9458 Section 3.1) is not 0x00.
        // Legitimate clients always use 0x00; other values could allow replaying the same request up to 256 times.
        guard !keyMaterial.isEmpty, keyMaterial[keyMaterial.startIndex] == 0x00 else {
            throw SessionError.invalidKeyMaterial
        }

        let currentAttestationSet = try await attestationProvider.currentAttestationSet()
        let validKeyIDs = currentAttestationSet.allAttestations
            .filter { $0.expiry >= .now }
            .map { $0.keyID }

        try self.state.withLock { state in
            Self.removeExpiredKeys(state: &state, validKeyIDs: validKeyIDs, metricsFactory: self.metricsFactory)

            guard validKeyIDs.contains(keyID) else {
                throw SessionError.unknownKeyID
            }

            var sessionSet = state.storedSessions[keyID] ?? []

            if sessionSet.contains(keyMaterial) {
                Counter(label: "cloudboard_session_replayed_total", factory: self.metricsFactory).increment()
                throw SessionError.sessionReplayed
            }

            sessionSet.insert(keyMaterial)
            state.storedSessions[keyID] = sessionSet
            Gauge(label: "cloudboard_stored_sessions", factory: self.metricsFactory).record(state.sessionCount)
        }
    }

    private static func removeExpiredKeys(
        state: inout State,
        validKeyIDs: [Data],
        metricsFactory: any MetricsFactory
    ) {
        for keyID in state.storedSessions.keys where !validKeyIDs.contains(keyID) {
            state.storedSessions.removeValue(forKey: keyID)
        }
        Gauge(label: "cloudboard_stored_sessions", factory: metricsFactory).record(state.sessionCount)
    }
}

extension SessionError: ReportableError {
    var publicDescription: String {
        switch self {
        case .invalidKeyMaterial:
            "SessionError.invalidKeyMaterial"
        case .sessionReplayed:
            "SessionError.sessionReplayed"
        case .unknownKeyID:
            "SessionError.unknownKeyID"
        }
    }
}

extension SessionError: RPCErrorConvertible {
    var rpcErrorCode: RPCError.Code {
        switch self {
        case .invalidKeyMaterial:
            .invalidArgument
        case .sessionReplayed:
            .permissionDenied
        case .unknownKeyID:
            .invalidArgument
        }
    }

    var rpcErrorMessage: String {
        switch self {
        case .invalidKeyMaterial:
            "Rejected because the key material did not match the specifications"
        case .sessionReplayed:
            "Rejected because of suspected replay attack"
        case .unknownKeyID:
            "Rejected because the node/key ID is unknown or the corresponding key has expired"
        }
    }
}
