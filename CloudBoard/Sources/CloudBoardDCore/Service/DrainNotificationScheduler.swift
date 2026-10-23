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

import CloudBoardAttestationDAPI
import CloudBoardCommon
import Foundation
import os

/// Drives jittered `connectionShouldBeRecreated` notifications for a single persistent-service
/// connection.
///
/// For each attestation-set update where the current key has rotated away from the connection's
/// `boundKeyID`, the client should recreate the connection. Sending that notification the instant
/// the key rotates means a fleet-synchronized key roll fires every client's reconnection at once,
/// contending on replacement establishment and stranding in-flight queries. This scheduler instead
/// waits a bounded random delay (`DrainJitterPolicy`) before notifying, so recreations smear over
/// time.
///
/// - A newer rotation supersedes any not-yet-sent notification (at most one pending send per
///   connection; the latest set wins). Different connections draw independent delays, which is what
///   spreads a synchronized roll across the fleet.
/// - The delay is bounded by the bound key's remaining runway, so short-lived keys (accelerated
///   test rotation) and keys already near expiry collapse the delay to zero and notify immediately
///   — the client always keeps enough runway to establish a replacement before the key is severed.
///
/// Runs until `updates` finishes or the surrounding task is cancelled. `notify` is best-effort: it
/// is not thrown from here (a failed send means the stream is already broken and will be torn down
/// via the other connection tasks), so the caller wraps its send + logging in the closure.
enum DrainNotificationScheduler {
    private static let logger = os.Logger(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "DrainNotificationScheduler"
    )

    static func run(
        updates: AsyncStream<AttestationSet>,
        boundKeyID: Data,
        config: DrainJitterConfig,
        clock: some DateAwareClock,
        randomFraction: @Sendable @escaping () -> Double = { Double.random(in: 0 ..< 1) },
        notify: @Sendable @escaping (AttestationSet) async -> Void
    ) async {
        // At most one pending (scheduled-but-not-yet-sent) notification. A new rotation cancels it.
        var pending: Task<Void, Never>?
        for await set in updates {
            // Only a rotation of the current key away from ours warrants a recreate notification.
            guard set.currentAttestation.keyID != boundKeyID else { continue }

            pending?.cancel()

            // Runway = how long our bound key still lives. Absent from the set → treated as gone
            // (no runway → no jitter). `DrainJitterPolicy` clamps everything else.
            let runwaySeconds = set.allAttestations
                .first { $0.keyID == boundKeyID }?
                .expiry.timeIntervalSinceNow(clock) ?? 0
            let delay = DrainJitterPolicy.jitterDelay(
                runway: .seconds(runwaySeconds),
                config: config,
                randomFraction: randomFraction()
            )

            pending = Task {
                // Always go through the (cancellable) sleep, even for a zero delay: it is the
                // single checkpoint that lets a newer rotation supersede this notification and
                // lets a connection teardown suppress it. A zero-delay notification with no sleep
                // could run before `pending?.cancel()` takes effect and fire a duplicate or a
                // post-teardown recreate.
                do {
                    try await clock.sleep(for: delay)
                } catch is CancellationError {
                    return // superseded by a newer rotation, or the connection is tearing down
                } catch {
                    // A clock sleep only throws CancellationError today; any other error means an
                    // unexpected clock failure. Drop the notification rather than emit it after an
                    // unknown fault, and surface it.
                    Self.logger.error("drain-jitter sleep failed; dropping notification: \(error, privacy: .public)")
                    return
                }
                await notify(set)
            }
        }
        pending?.cancel()
    }
}
