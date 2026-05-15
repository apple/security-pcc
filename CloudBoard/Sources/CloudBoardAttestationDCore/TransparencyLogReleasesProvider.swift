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

import CloudBoardCommon
import CloudBoardLogging
#if canImport(CloudConfigurationPreferences)
@_weakLinked import CloudConfigurationPreferences
#endif
import os

internal struct ExcludedReleasesHotProperties: Decodable, Sendable, Hashable {
    /// This must match the name used in the upstream configuration service.
    static let domain: String = "com.apple.cloudos.hotproperties.cb_attestationd"

    public var excludedReleaseSet: [String]?
}

enum TransparencyLogReleasesProviderError: ReportableError {
    case releaseFetchCancelled

    var publicDescription: String {
        let errorType = switch self {
        case .releaseFetchCancelled: "releaseFetchCancelled"
        }
        return "\(errorType)"
    }
}

final class TransparencyLogReleasesProvider: ReleasesProviderProtocol {
    public static let logger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "TransparencyLogReleasesProvider"
    )

    let transparencyLog: TransparencyLog
    let releaseDigestsPollingIntervalMinutes: Duration
    let pollingIntervalJitter: Double
    private let stateMachine: OSAllocatedUnfairLock<ReleasesProviderStateMachine>

    init(
        transparencyLog: TransparencyLog,
        releaseDigestsPollingIntervalMinutes: Duration,
        pollingIntervalJitter: Double
    ) {
        self.transparencyLog = transparencyLog
        self.releaseDigestsPollingIntervalMinutes = releaseDigestsPollingIntervalMinutes
        self.pollingIntervalJitter = pollingIntervalJitter
        self.stateMachine = .init(initialState: .init())
    }

    deinit {
        self.stateMachine.withLock { state in
            state.clearCurrentReleases()
        }
    }

    func run() async throws {
        #if canImport(CloudConfigurationPreferences)
        let excludedReleasesUpdates = PreferencesUpdates(
            preferencesDomain: ExcludedReleasesHotProperties.domain,
            maximumUpdateDuration: .seconds(1),
            forType: ExcludedReleasesHotProperties.self
        )

        // For now we will ignore any errors we might get in trying to fetch the
        // excludedReleaseSet. We just default back to [] if we cannot fetch those.
        do {
            try await excludedReleasesUpdates.first(where: { _ in true })!.applyingPreferences {
                let excludedReleases = $0.excludedReleaseSet ?? []
                self.stateMachine.withLock { $0.setExcludedReleases(Set(excludedReleases)) }
            }
        } catch {
            Self.logger.error(
                "Failed to fetch excluded release sets: \(error, privacy: .public). Defaulting to no excluded releases."
            )
        }
        #else
        self.stateMachine.withLock { $0.setExcludedReleases(.init()) }
        #endif

        let releaseSet = try await self.transparencyLog.getReleaseSet()
        self.stateMachine.withLock { $0.setCurrentReleases(releaseSet) }
        try await withThrowingTaskGroup(of: Void.self) { taskGroup in
            taskGroup.addTask {
                while true {
                    let jitter = Double
                        .random(in: (0 - self.pollingIntervalJitter) ... self.pollingIntervalJitter) / 100
                    let sleepTime = self.releaseDigestsPollingIntervalMinutes * (1.0 + jitter)
                    Self.logger.notice(
                        "Sleeping for interval \(sleepTime, privacy: .public) before fetching new release digests"
                    )
                    try await Task.sleep(for: sleepTime)
                    let newReleaseSet = try await self.transparencyLog.getReleaseSet()
                    self.stateMachine.withLock { $0.setCurrentReleases(newReleaseSet) }
                }
            }
            #if canImport(CloudConfigurationPreferences)
            taskGroup.addTask {
                do {
                    var excludedReleasesUpadatesIterator = excludedReleasesUpdates.makeAsyncIterator()
                    while let excludedReleasesUpdates = try await excludedReleasesUpadatesIterator.next() {
                        await excludedReleasesUpdates.applyingPreferences { releasesUpdates in
                            if let excludedReleases = releasesUpdates.excludedReleaseSet {
                                Self.logger.debug(
                                    "Received new release set to exclude: \(String(describing: excludedReleases), privacy: .public)"
                                )
                                self.stateMachine.withLock { $0.setExcludedReleases(Set(excludedReleases)) }
                            }
                        }
                    }
                } catch where !(error is CancellationError) {
                    // For now we will ignore any errors we might get in trying to fetch the
                    // excludedReleaseSet and default to an empty excluded release set.
                    Self.logger.error(
                        "Failure while fetching excluded release set: \(error, privacy: .public). Defaulting to no excluded releases."
                    )
                    self.stateMachine.withLock { $0.setExcludedReleases(.init()) }
                }
            }
            #endif
            while !taskGroup.isEmpty {
                try await taskGroup.next()
            }
        }
    }

    func getCurrentReleaseSet() async throws -> [ReleaseDigestEntry] {
        let releaseState = try self.stateMachine.withLock { try $0.getCurrentReleases() }
        switch releaseState {
        case .useCurrentReleaseSet(let release):
            return release
        case .waitForReleaseSet(let future):
            return try await future.valueWithCancellation
        }
    }

    func trustedReleaseSetUpdates() async throws -> ReleasesUpdatesSubscription {
        let (stream, cont) = AsyncStream<[ReleaseDigestEntry]>.makeStream()
        let id = self.stateMachine.withLock { state in
            state.watchers.addWatcher(cont)
        }
        try await cont.yield(self.getCurrentReleaseSet())
        cont.onTermination = { _ in self.deregister(id) }
        return .init(id: id, updates: stream)
    }

    func deregister(_ id: Int) {
        let _ = self.stateMachine.withLock { state in
            let index = state.watchers.list.firstIndex { $0.id == id }
            if let index {
                state.watchers.list.remove(at: index)
            }
        }
    }
}

internal struct Watcher {
    let continuation: AsyncStream<[ReleaseDigestEntry]>.Continuation
    let id: Int
}

internal struct Watchers {
    private var nextId: Int = 0
    var list: [Watcher] = []

    mutating func addWatcher(_ watcher: AsyncStream<[ReleaseDigestEntry]>.Continuation) -> Int {
        defer { nextId &+= 1 }
        self.list.append(.init(continuation: watcher, id: self.nextId))
        return self.nextId
    }
}

internal struct ReleasesProviderStateMachine {
    internal enum ReleasesState {
        case awaitingFirstReleaseSet(Promise<[ReleaseDigestEntry], Error>)
        case releaseSetAvailable([ReleaseDigestEntry])
    }

    enum ReleasesStateAction {
        case waitForReleaseSet(Future<[ReleaseDigestEntry], Error>)
        case useCurrentReleaseSet([ReleaseDigestEntry])
    }

    private var state: ReleasesState
    private var excludedReleases: Set<String>
    var watchers: Watchers

    init() {
        self.state = .awaitingFirstReleaseSet(.init())
        self.excludedReleases = .init()
        self.watchers = .init()
    }

    mutating func setCurrentReleases(_ releases: [ReleaseDigestEntry]) {
        let filteredReleases = releases.filter { !self.excludedReleases.contains($0.releaseDigestHexString) }

        var updateWatchers = true
        switch self.state {
        case .awaitingFirstReleaseSet(let promise):
            promise.succeed(with: filteredReleases)
            self.state = .releaseSetAvailable(filteredReleases)
        case .releaseSetAvailable(let oldReleases):
            if Set(oldReleases) == Set(filteredReleases) {
                updateWatchers = false
            }
            self.state = .releaseSetAvailable(filteredReleases)
        }

        if updateWatchers {
            for watcher in self.watchers.list {
                watcher.continuation.yield(filteredReleases)
            }
        }
    }

    mutating func clearCurrentReleases() {
        switch self.state {
        case .awaitingFirstReleaseSet(let promise):
            promise.fail(with: TransparencyLogReleasesProviderError.releaseFetchCancelled)
        case .releaseSetAvailable:
            self.setCurrentReleases([])
        }
    }

    mutating func setExcludedReleases(_ excludedReleases: Set<String>) {
        self.excludedReleases = excludedReleases
        if case .releaseSetAvailable(let release) = self.state {
            self.setCurrentReleases(release)
        }
    }

    func getCurrentReleases() throws -> ReleasesStateAction {
        switch self.state {
        case .awaitingFirstReleaseSet(let promise):
            return .waitForReleaseSet(Future(promise))
        case .releaseSetAvailable(let releases):
            return .useCurrentReleaseSet(releases)
        }
    }
}
