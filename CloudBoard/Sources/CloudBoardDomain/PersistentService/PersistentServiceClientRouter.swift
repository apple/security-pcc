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
package import CloudBoardAsyncXPC

// Kept at package level (not public) so it can change without ABI-compatibility concerns.
// This restriction can be relaxed once tooling moves to its own repo and targets.

/// Namespace for types specific to the persistent service client router.
package enum PersistentServiceClientRouter: Sendable {}

package extension PersistentServiceClientRouter {
    /// Report from a client router to cb_jobhelper about attestation key usage.
    /// Fed into the Request Execution Log.
    package struct AttestationUsageReport: Sendable, Equatable {
        /// Whether this report is for prevalidation (early trust check) or actual use (triggers REL entry).
        package enum Purpose: UInt8, Sendable, Equatable {
            case prevalidation = 0
            case use = 1
        }

        package let keyID: Data
        package let attestationData: Data
        package let purpose: Purpose

        package init(keyID: Data, attestationData: Data, purpose: Purpose) {
            self.keyID = keyID
            self.attestationData = attestationData
            self.purpose = purpose
        }

        // MARK: ByteBufferCodable without declaration

        package func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
            try self.keyID.encode(to: &buffer)
            try self.attestationData.encode(to: &buffer)
            try self.purpose.encode(to: &buffer)
        }

        package init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
            self.keyID = try .init(from: &buffer)
            self.attestationData = try .init(from: &buffer)
            self.purpose = try .init(from: &buffer)
        }
    }
}

package extension PersistentServiceClientRouter {
    /// Per-helper tracking of which nodes (by keyID) this helper has approved or denied.
    /// Client routers key this by helperID. Quorum is evaluated per-helper.
    ///
    /// Quorum enforcement (e.g. requiring *k-of-n* helpers to approve a node before
    /// it is considered trusted) is future work. For now, ``coversAll(requiredKeyIDs:)``
    /// is the intended check for whether a single helper has approved every required node.
    package struct HelperNodeApprovals: Sendable {
        package let helperID: UUID
        package private(set) var approvedKeyIDs: Set<Data>
        package private(set) var deniedKeyIDs: Set<Data>
        /// Set of keyIDs for which the router emitted an attestation-usage
        /// report but did not receive a `.nodeApproval` command within the
        /// configured reaper window (`PrivateFilterQuorumConfig.maxAttestationAttempts`
        /// retries × `attestationResendInterval`). These are treated like
        /// `deniedKeyIDs` for quorum selection, but a *later* `recordApproval`
        /// — positive or negative — will move the keyID out into the
        /// corresponding set.
        package private(set) var unresponsiveKeyIDs: Set<Data>

        package init(helperID: UUID) {
            self.helperID = helperID
            self.approvedKeyIDs = []
            self.deniedKeyIDs = []
            self.unresponsiveKeyIDs = []
        }

        /// Explicit-state init for tests.
        /// Callers are responsible for ensuring the invariants they rely on;
        /// routing code uses ``effectiveApprovedKeyIDs`` (not ``approvedKeyIDs``
        /// directly) so any overlap between the sets is handled safely.
        package init(
            helperID: UUID,
            approvedKeyIDs: Set<Data>,
            deniedKeyIDs: Set<Data>,
            unresponsiveKeyIDs: Set<Data>
        ) {
            self.helperID = helperID
            self.approvedKeyIDs = approvedKeyIDs
            self.deniedKeyIDs = deniedKeyIDs
            self.unresponsiveKeyIDs = unresponsiveKeyIDs
        }

        /// `approvedKeyIDs` minus `unresponsiveKeyIDs` — the set of keyIDs
        /// that should actually participate in routing / quorum decisions.
        /// Today `recordUnresponsive` removes from `approvedKeyIDs`, so the
        /// two sets are disjoint under normal use, but all routing code
        /// should consult this property so the invariant is enforced at the
        /// point of use (and so overlap produced by a future API change or
        /// externally-constructed state still routes safely).
        package var effectiveApprovedKeyIDs: Set<Data> {
            self.approvedKeyIDs.subtracting(self.unresponsiveKeyIDs)
        }

        /// Record an approval or denial for a specific node key.
        ///
        /// A keyID can only be in one of `approved` / `denied` / `unresponsive`
        /// at a time. A later approval/denial wins and moves the keyID out of
        /// `unresponsiveKeyIDs` if it was there.
        package mutating func recordApproval(keyID: Data, approved: Bool) {
            self.unresponsiveKeyIDs.remove(keyID)
            if approved {
                self.approvedKeyIDs.insert(keyID)
                self.deniedKeyIDs.remove(keyID)
            } else {
                self.deniedKeyIDs.insert(keyID)
                self.approvedKeyIDs.remove(keyID)
            }
        }

        /// Record that the jobhelper never responded to an attestation for
        /// this keyID within the reaper window. Excludes the keyID from the
        /// approved set for quorum purposes. If a later `recordApproval`
        /// arrives the keyID will be re-promoted (see ``recordApproval``).
        package mutating func recordUnresponsive(keyID: Data) {
            self.approvedKeyIDs.remove(keyID)
            self.unresponsiveKeyIDs.insert(keyID)
        }

        /// True if this helper has approved all the given keyIDs.
        package func coversAll(requiredKeyIDs: Set<Data>) -> Bool {
            requiredKeyIDs.isSubset(of: self.effectiveApprovedKeyIDs)
        }
    }
}
