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
import CloudBoardLogging
import CloudBoardMetrics
#if RC_IS_CLOUDOS_ENABLED
import CloudConfigurationPreferences
#elseif canImport(CloudConfigurationPreferences)
@_weakLinked import CloudConfigurationPreferences
#else
#warning("CloudConfigurationPreferences not available at compile time")
#endif
import Foundation
import os

/// The values that can be updated while cloudboardd is running.
public struct CloudBoardHotProperties: Decodable, Sendable, Hashable {
    /// The hot properties domain name for cloudboardd.
    ///
    /// This must match the name used in the upstream configuration service.
    static let domain: String = "com.apple.cloudos.hotproperties.cloudboardd"

    /// A canary value used for verifying the integration with the hot properties daemon.
    ///
    /// It is only logged and reported as a metric, but the value isn't used directly.
    public var canary: Int?

    /// The maximum number of bytes we may receive on a single GRPC stream
    public var maxCumulativeRequestBytes: Int?

    /// The idle timeout we'll apply to RPCs, measured in milliseconds.
    ///
    /// Defaults to 30s.
    public var idleTimeoutMilliseconds: Int?
}

public struct PreferencesVersionProvider: Sendable {
    public var version: String? {
        get async {
            await self.getCurrentVersion()
        }
    }

    private let getCurrentVersion: @Sendable () async -> String?

    init(versionGetter: @escaping @Sendable () async -> String?) {
        self.getCurrentVersion = versionGetter
    }

    static var current: PreferencesVersionProvider {
        #if canImport(CloudConfigurationPreferences)
        .init(versionGetter: {
            await PreferencesVersionInfo.current.appliedVersion?.description
        })
        #else
        .init(versionGetter: { nil })
        #endif
    }
}

/// A type storing the current latest received hot property values.
///
/// Note that when using `HotPropertiesController`, every received update is immediately considered
/// successfully applied.
///
/// If your configuration update can be slow or fail, use the `CloudConfigurationPreferences` APIs directly.
public actor HotPropertiesController {
    private static let logger: os.Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "HotPropertiesController"
    )

    /// A stream of updates to the hot property values.
    private let updates: Updates

    /// A getter for the current version info.
    private let versionProvider: PreferencesVersionProvider

    /// The last published value.
    public private(set) var currentValue: CloudBoardHotProperties? {
        didSet {
            Self.logger
                .log(
                    "HotPropertiesController updated: \(self.currentValue.map(String.init(describing:)) ?? "<nil>", privacy: .public)."
                )
        }
    }

    /// The promise for the `firstUpdateReceived` future.
    ///
    /// Nil'd out once it's been fulfilled.
    private var firstUpdateReceivedPromise: Promise<Void, Error>?

    /// A method that only returns with the first update received by the controller.
    public func waitForFirstUpdate() async throws {
        try await withLogging(operation: "waitForFirstUpdate", sensitiveError: false, logger: Self.logger) {
            if self.currentValue != nil {
                Self.logger.info("currentValue is already present, returning early")
                return
            }
            Self.logger.info("currentValue is still nil, suspending to wait for it")
            let promise: Promise<Void, Error>
            if let firstUpdateReceivedPromise {
                promise = firstUpdateReceivedPromise
            } else {
                promise = .init()
                self.firstUpdateReceivedPromise = promise
            }
            try await Future(promise).valueWithCancellation
        }
    }

    /// Creates a new controller that uses CloudConfigurationPreferences to subscribe to preference updates.
    public init() {
        #if canImport(CloudConfigurationPreferences)
        if #_hasSymbol(PreferencesUpdates<CloudBoardHotProperties>.self) {
            let updates = PreferencesUpdates(
                preferencesDomain: CloudBoardHotProperties.domain,
                maximumUpdateDuration: .seconds(15),
                forType: CloudBoardHotProperties.self
            )
            let stream = updates.map { update in
                await update.successfullyApplied()
                return update.newValue
            }
            self.init(
                wrapping: stream,
                initialValue: nil,
                versionProvider: PreferencesVersionProvider.current
            )
        } else {
            let (stream, _) = AsyncStream<CloudBoardHotProperties>.makeStream()
            self.init(
                wrapping: stream,
                initialValue: nil,
                versionProvider: PreferencesVersionProvider.current
            )
        }
        #else
        Self.logger.warning("CloudConfigurationPreferences is unavailable, providing empty stream")
        let (stream, _) = AsyncStream<CloudBoardHotProperties>.makeStream()
        self.init(
            wrapping: stream,
            initialValue: nil,
            versionProvider: PreferencesVersionProvider.current
        )
        #endif
    }

    /// Returns the current preferences version information.
    public var version: String? {
        get async {
            await self.versionProvider.version
        }
    }

    /// Creates a new controller with the provided stream continuation.
    private init<S: AsyncSequence & Sendable>(
        wrapping upstream: S,
        initialValue: CloudBoardHotProperties?,
        versionProvider: PreferencesVersionProvider
    ) where S.Element == CloudBoardHotProperties {
        self.updates = .init { upstream.makeAsyncIterator() }
        self.currentValue = initialValue
        self.versionProvider = versionProvider
    }

    /// Creates a controller and an async stream continuation appropriate for testing.
    static func makeForTesting(
        initialValue: CloudBoardHotProperties? = nil,
        versionProvider: PreferencesVersionProvider = .init(versionGetter: { nil })
    )
        -> (HotPropertiesController, AsyncStream<CloudBoardHotProperties>.Continuation) {
        let (stream, continuation) = AsyncStream<CloudBoardHotProperties>.makeStream()
        let controller = HotPropertiesController(
            wrapping: stream,
            initialValue: initialValue,
            versionProvider: versionProvider
        )
        return (controller, continuation)
    }

    /// The underlying type-erased async sequence.
    private struct Updates: AsyncSequence, Sendable {
        typealias Element = CloudBoardHotProperties

        let makeUpstream: @Sendable () -> any AsyncIteratorProtocol

        func makeAsyncIterator() -> Iterator {
            Iterator(upstream: self.makeUpstream())
        }

        struct Iterator: AsyncIteratorProtocol {
            var upstream: any AsyncIteratorProtocol
            mutating func next() async throws -> CloudBoardHotProperties? {
                try await self.upstream.next() as? CloudBoardHotProperties
            }
        }
    }
}

extension HotPropertiesController {
    /// Runs a task that consumes hot properties, logs/emits metrics for any updates, and
    /// keeps the `currentValue` updated.
    public func run(metrics: MetricsSystem) async throws {
        try await withTaskCancellationHandler {
            for try await update in self.updates {
                self.currentValue = update
                let canary = update.canary ?? -1
                Self.logger.info("Hot property canary changed to: \(canary, privacy: .public).")
                metrics.emit(Metrics.HotPropertiesController.HotPropertiesCanaryValue(value: Double(canary)))
                if let firstUpdateReceivedPromise = self.firstUpdateReceivedPromise {
                    firstUpdateReceivedPromise.succeed()
                    self.firstUpdateReceivedPromise = nil
                }
            }
        } onCancel: {
            Task {
                await self.firstUpdateReceivedPromise?.fail(with: CancellationError())
            }
        }
    }
}
