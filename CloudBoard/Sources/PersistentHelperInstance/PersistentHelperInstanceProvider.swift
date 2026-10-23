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

import CloudBoardCommon
import CloudBoardJobHelperAPI
import CloudBoardLogging
import Foundation
import os
import Synchronization

package enum PersistentHelperInstanceProviderError: Error {
    case atCapacity
}

/// Manages creation and lifecycle of persistent helper instances.
///
/// Unlike `JobHelperInstanceProvider` which maintains prewarmed pools, this is a simple registry.
/// Instances are created on-demand per key, not pooled.
package final class PersistentHelperInstanceProvider: PersistentHelperInstanceProviderProtocol, Sendable {
    private static let log: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard", category: "PersistentHelperInstanceProvider"
    )

    private let helperLaunchdJob: any LaunchdJobDefinitionProtocol
    private let helperXPCClientFactory: any PersistentHelperAPIClientFactoryProtocol
    private let teardownTimeout: Duration
    private let maxConcurrentInstances: Int
    private let minStartupInterval: Duration

    private struct State {
        var instances: [UUID: PersistentHelperInstance] = [:]
        var nextAllowedStart: ContinuousClock.Instant = .now
    }

    private let state: Mutex<State> = Mutex(State())

    package init(
        helperLaunchdJob: any LaunchdJobDefinitionProtocol,
        helperXPCClientFactory: any PersistentHelperAPIClientFactoryProtocol,
        teardownTimeout: Duration = .seconds(30),
        maxConcurrentInstances: Int,
        minStartupInterval: Duration = .milliseconds(50)
    ) {
        self.helperLaunchdJob = helperLaunchdJob
        self.helperXPCClientFactory = helperXPCClientFactory
        self.teardownTimeout = teardownTimeout
        self.maxConcurrentInstances = maxConcurrentInstances
        self.minStartupInterval = minStartupInterval
    }

    /// Throws `atCapacity` if the instance count has reached the limit.
    private func ensureCapacity(_ state: State, keyID: Data) throws {
        guard state.instances.count < self.maxConcurrentInstances else {
            Self.log.warning(
                "At capacity (\(self.maxConcurrentInstances, privacy: .public) instances), rejecting new helper for keyID: \(keyID.base64EncodedString(), privacy: .public)"
            )
            throw PersistentHelperInstanceProviderError.atCapacity
        }
    }

    /// Creates a new persistent helper instance bound to the given key.
    ///
    /// - Parameters:
    ///   - keyID: The key this instance is bound to
    ///   - delegate: Delegate to receive responses from the helper
    /// - Returns: The created instance, which must be started by calling `run()` in a task
    /// - Throws: `PersistentHelperInstanceProviderError.atCapacity` if `maxConcurrentInstances` is reached
    package func createInstance(
        keyID: Data,
        delegate: PersistentHelperAPIClientDelegateProtocol
    ) async throws -> PersistentHelperInstance {
        // Fast-fail capacity check before reserving a rate-limit slot
        try self.state.withLock { state in
            try self.ensureCapacity(state, keyID: keyID)
        }

        // Reserve a startup slot to avoid thundering herd
        let sleepUntil: ContinuousClock.Instant? = self.state.withLock { state in
            let now = ContinuousClock.now
            let target = state.nextAllowedStart
            // Advance the next slot (if we're past it, start from now)
            state.nextAllowedStart = max(target, now) + self.minStartupInterval
            // Only sleep if the slot is in the future
            return target > now ? target : nil
        }
        if let sleepUntil {
            try await Task.sleep(until: sleepUntil, clock: .continuous)
        }

        // Check capacity and create instance under lock (authoritative check)
        let instance: PersistentHelperInstance = try self.state.withLock { state in
            try self.ensureCapacity(state, keyID: keyID)

            let instance = PersistentHelperInstance(
                self.helperLaunchdJob,
                keyID: keyID,
                helperXPCClientFactory: self.helperXPCClientFactory,
                delegate: delegate,
                teardownTimeout: self.teardownTimeout
            )

            state.instances[instance.id] = instance
            return instance
        }

        Self.log.info(
            "Created persistent helper instance \(instance.id, privacy: .public) for keyID: \(keyID.base64EncodedString(), privacy: .public)"
        )

        return instance
    }

    /// Removes and tears down a persistent helper instance.
    package func removeInstance(uuid: UUID) async {
        let instance = self.state.withLock { state -> PersistentHelperInstance? in
            let instance = state.instances[uuid]
            state.instances[uuid] = nil
            return instance
        }

        if let instance {
            Self.log.info("Removing persistent helper instance \(uuid, privacy: .public)")
            await instance.triggerTeardown()
            await instance.awaitTeardownTriggerAndComplete()
        } else {
            Self.log.warning(
                "Attempted to remove nonexistent persistent helper instance \(uuid, privacy: .public)"
            )
        }
    }

    /// Returns the instance for the given UUID, if it exists.
    package func instance(for uuid: UUID) -> PersistentHelperInstance? {
        self.state.withLock { $0.instances[uuid] }
    }

    /// Returns all active instance UUIDs.
    package var activeInstanceIDs: [UUID] {
        self.state.withLock { Array($0.instances.keys) }
    }

    /// Tears down all active instances. Called when the gRPC server exits to ensure
    /// no helper processes are left running.
    package func teardownAllInstances() async {
        let uuids = self.state.withLock { Array($0.instances.keys) }

        guard !uuids.isEmpty else { return }

        Self.log.warning(
            "Tearing down all \(uuids.count, privacy: .public) persistent helper instances"
        )

        // Use Task.detached per instance to avoid inheriting cancellation from caller,
        // ensuring teardown completes even if the parent task is cancelled.
        await withTaskGroup(of: Void.self) { group in
            for uuid in uuids {
                group.addTask {
                    Self.log.info("Force tearing down instance \(uuid, privacy: .public)")
                    await Task.detached {
                        await self.removeInstance(uuid: uuid)
                    }.value
                }
            }
        }
    }
}
