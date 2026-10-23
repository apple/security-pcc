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

import CloudBoardMetrics
import os

public enum DaemonStatus: Equatable, Hashable, Sendable {
    case uninitialized
    case initializing
    case waitingForFirstAttestationFetch
    case waitingForFirstHotPropertyUpdate
    case waitingForWorkloadRegistration
    case componentsFailedToRun(Components)
    case serviceDiscoveryUpdateSuccess(Int)
    case serviceDiscoveryUpdateFailure(Int)
    case serviceDiscoveryPublisherDraining
    case daemonDrained
    case daemonExitingOnError
}

public struct Components: OptionSet, Equatable, Hashable, Sendable {
    public let rawValue: Int

    static let serviceDiscoveryPublisher = Components(rawValue: 1 << 0)
    static let grpcServer = Components(rawValue: 1 << 1)
    static let workloadController = Components(rawValue: 1 << 2)

    static let all: Components = [
        .serviceDiscoveryPublisher,
        .grpcServer,
        .workloadController,
    ]

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }
}

public final class StatusMonitor: Sendable {
    public static let logger: os.Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "StatusMonitor"
    )

    struct State {
        var watchers: [Watcher]
        var nextID: Int
        var lastStatus: DaemonStatus
    }

    private let currentState: OSAllocatedUnfairLock<State>

    private let metrics: any MetricsSystem

    public init(metrics: any MetricsSystem) {
        self.currentState = OSAllocatedUnfairLock(initialState: State(
            watchers: [],
            nextID: 0,
            lastStatus: .uninitialized
        ))
        self.metrics = metrics
        self.metrics.emit(Metrics.StatusMonitor.Status(value: 1, daemonStatus: .uninitialized))
    }

    // MARK: State Machine Flow Diagram

    // ┌──────────────────────────────────┐
    // │                                  │
    // │          .uninitialized          │
    // │                                  │
    // └──────────────────────────────────┘
    //                   │
    //                   ▼
    // ┌──────────────────────────────────┐
    // │                                  │
    // │          .initializing           │
    // │                                  │
    // └──────────────────────────────────┘
    //                   │
    //                   ▼
    // ┌──────────────────────────────────┐
    // │                                  │
    // │.waitingForFirstHotPropertyUpdate │
    // │                                  │
    // └──────────────────────────────────┘
    //                   │
    //                   ▼
    // ┌──────────────────────────────────┐
    // │                                  │
    // │ .waitingForFirstAttestationFetch │
    // │                                  │
    // └──────────────────────────────────┘
    //                   │
    //                   ▼
    // ┌──────────────────────────────────┐
    // │                                  │
    // │ .waitingForWorkloadRegistration  │
    // │                                  │
    // └──────────────────────────────────┘
    //                   │
    //                   ├──────────────────────────────────────────────────────────────────────────┐
    //                   │                                                                          │
    //                Publish                                                                       │
    //                success? ──────────────────────────────────────┐                              │
    //                   │                                           │                              │
    //                   ▼                                           ▼                              │
    // ┌──────────────────────────────────┐        ┌──────────────────────────────────┐             │
    // │                                  │        │                                  │             │
    // │  .serviceDiscoveryUpdateSuccess  │◀──────▶│  .serviceDiscoveryUpdateFailure  │             │
    // │                                  │        │                                  │             │
    // └──────────────────────────────────┘        └──────────────────────────────────┘             │
    //                   │  │ │                                      │    │    │                    │
    //                   │  └────────────────────────────────────────┼─────────┴────────────────────┤
    //                   ├────┼──────────────────────────────────────┘    │                         ▼
    //                   │     ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─        ┌──────────────────────────────────┐
    //                   │                                                │       │                                  │
    //                   ▼                                                        │      .componentsFailedToRun      │
    // ┌──────────────────────────────────┐                               │       │                                  │
    // │                                  │                                       └──────────────────────────────────┘
    // │.serviceDiscoveryPublisherDraining│                               │                         │
    // │                                  │                                ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─
    // └──────────────────────────────────┘                                                         │
    //                   │
    //                   ││                                                                         │
    //                   │ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─
    //                   │                                                                          │
    //                   ▼                                                                          ▼
    // ┌──────────────────────────────────┐                                       ┌──────────────────────────────────┐
    // │                                  │                                       │                                  │
    // │          .daemonDrained          │                                       │      .daemonExitingOnError       │
    // │                                  │                                       │                                  │
    // └──────────────────────────────────┘                                       └──────────────────────────────────┘

    private func emitTransitionTelemetry(from old: DaemonStatus, to new: DaemonStatus, category: TransitionCategory) {
        if old == new {
            return
        }

        switch category {
        case .blocked:
            StatusMonitor.logger
                .warning(
                    "Blocked CloudBoardD status transition from: \(old, privacy: .public) to: \(new, privacy: .public))"
                )
            return
        case .expected, .unexpected:
            () // proceed
        }

        switch old {
        case .uninitialized:
            () // no-op
        case .initializing:
            self.metrics.emit(Metrics.StatusMonitor.LegacyStatusInitializing(value: 0))
        case .waitingForFirstAttestationFetch:
            self.metrics.emit(Metrics.StatusMonitor.LegacyStatusWaitingForFirstAttestationFetch(value: 0))
        case .waitingForFirstHotPropertyUpdate:
            self.metrics.emit(Metrics.StatusMonitor.LegacyStatusWaitingForFirstHotPropertyUpdate(value: 0))
        case .waitingForWorkloadRegistration:
            self.metrics.emit(Metrics.StatusMonitor.LegacyStatusWaitingForWorkloadRegistration(value: 0))
        case .componentsFailedToRun(let failedComponents):
            switch new {
            case .componentsFailedToRun:
                // Although we haven't left this state, we need to update the old state's corresponding gauge
                self.metrics.emit(Metrics.StatusMonitor.LegacyStatusComponentsFailedToRun(
                    value: 0,
                    failedComponents: failedComponents
                ))
            case .uninitialized, .initializing, .waitingForFirstAttestationFetch,
                 .waitingForFirstHotPropertyUpdate, .waitingForWorkloadRegistration,
                 .serviceDiscoveryUpdateSuccess, .serviceDiscoveryUpdateFailure, .serviceDiscoveryPublisherDraining,
                 .daemonDrained, .daemonExitingOnError:
                self.metrics.emit(Metrics.StatusMonitor.LegacyStatusComponentsFailedToRun(
                    value: 0,
                    failedComponents: failedComponents
                ))
            }
        case .serviceDiscoveryUpdateSuccess(let knownServiceCount):
            switch new {
            case .serviceDiscoveryUpdateSuccess:
                // Although we haven't left this state, we need to update the old state's corresponding gauge
                self.metrics.emit(Metrics.StatusMonitor.LegacyStatusServiceDiscoveryUpdateSuccess(
                    value: 0,
                    knownServiceCount: knownServiceCount
                ))
            case .uninitialized, .initializing, .waitingForFirstAttestationFetch,
                 .waitingForFirstHotPropertyUpdate, .waitingForWorkloadRegistration,
                 .componentsFailedToRun, .serviceDiscoveryUpdateFailure, .serviceDiscoveryPublisherDraining,
                 .daemonDrained, .daemonExitingOnError:
                self.metrics.emit(Metrics.StatusMonitor.LegacyStatusServiceDiscoveryUpdateSuccess(
                    value: 0,
                    knownServiceCount: knownServiceCount
                ))
            }
        case .serviceDiscoveryUpdateFailure(let knownServiceCount):
            switch new {
            case .serviceDiscoveryUpdateFailure:
                // Although we haven't left this state, we need to update the old state's corresponding gauge
                self.metrics.emit(Metrics.StatusMonitor.LegacyStatusServiceDiscoveryUpdateFailure(
                    value: 0,
                    knownServiceCount: knownServiceCount
                ))
            case .uninitialized, .initializing, .waitingForFirstAttestationFetch,
                 .waitingForFirstHotPropertyUpdate, .waitingForWorkloadRegistration,
                 .componentsFailedToRun, .serviceDiscoveryUpdateSuccess, .serviceDiscoveryPublisherDraining,
                 .daemonDrained, .daemonExitingOnError:
                self.metrics.emit(Metrics.StatusMonitor.LegacyStatusServiceDiscoveryUpdateFailure(
                    value: 0,
                    knownServiceCount: knownServiceCount
                ))
            }
        case .serviceDiscoveryPublisherDraining:
            self.metrics.emit(Metrics.StatusMonitor.LegacyStatusServiceDiscoveryPublisherDraining(value: 0))
        case .daemonDrained:
            self.metrics.emit(Metrics.StatusMonitor.LegacyStatusDaemonDrained(value: 0))
        case .daemonExitingOnError:
            self.metrics.emit(Metrics.StatusMonitor.LegacyStatusDaemonExitingOnError(value: 0))
        }

        switch new {
        case .uninitialized:
            () // no-op
        case .initializing:
            self.metrics.emit(Metrics.StatusMonitor.LegacyStatusInitializing(value: 1))
        case .waitingForFirstAttestationFetch:
            self.metrics.emit(Metrics.StatusMonitor.LegacyStatusWaitingForFirstAttestationFetch(value: 1))
        case .waitingForFirstHotPropertyUpdate:
            self.metrics.emit(Metrics.StatusMonitor.LegacyStatusWaitingForFirstHotPropertyUpdate(value: 1))
        case .waitingForWorkloadRegistration:
            self.metrics.emit(Metrics.StatusMonitor.LegacyStatusWaitingForWorkloadRegistration(value: 1))
        case .componentsFailedToRun(let failedComponents):
            self.metrics.emit(Metrics.StatusMonitor.LegacyStatusComponentsFailedToRun(
                value: 1,
                failedComponents: failedComponents
            ))
        case .serviceDiscoveryUpdateSuccess(let knownServiceCount):
            self.metrics.emit(Metrics.StatusMonitor.LegacyStatusServiceDiscoveryUpdateSuccess(
                value: 1,
                knownServiceCount: knownServiceCount
            ))
        case .serviceDiscoveryUpdateFailure(let knownServiceCount):
            self.metrics.emit(Metrics.StatusMonitor.LegacyStatusServiceDiscoveryUpdateFailure(
                value: 1,
                knownServiceCount: knownServiceCount
            ))
        case .serviceDiscoveryPublisherDraining:
            self.metrics.emit(Metrics.StatusMonitor.LegacyStatusServiceDiscoveryPublisherDraining(value: 1))
        case .daemonDrained:
            self.metrics.emit(Metrics.StatusMonitor.LegacyStatusDaemonDrained(value: 1))
        case .daemonExitingOnError:
            self.metrics.emit(Metrics.StatusMonitor.LegacyStatusDaemonExitingOnError(value: 1))
        }
        self.metrics.emit(Metrics.StatusMonitor.Status(value: 0, daemonStatus: old))
        self.metrics.emit(Metrics.StatusMonitor.Status(value: 1, daemonStatus: new))

        switch category {
        case .expected:
            StatusMonitor.logger
                .log("CloudBoardD status transition from: \(old, privacy: .public) to: \(new, privacy: .public)")
        case .unexpected:
            StatusMonitor.logger
                .warning(
                    "Unexpected CloudBoardD status transition from: \(old, privacy: .public) to: \(new, privacy: .public)"
                )
        case .blocked:
            assertionFailure("Reached status transition when it should have been blocked.")
        }
    }

    public func initializing() {
        let newStatus = DaemonStatus.initializing

        let (oldStatus, transitionCategory) = self.currentState.withLock { state in
            let oldStatus = state.lastStatus
            let transitionCategory: TransitionCategory = switch state.lastStatus {
            case .uninitialized:
                .expected
            case .initializing:
                .unexpected
            case .waitingForFirstAttestationFetch, .waitingForFirstHotPropertyUpdate, .waitingForWorkloadRegistration,
                 .serviceDiscoveryUpdateSuccess, .serviceDiscoveryUpdateFailure, .componentsFailedToRun,
                 .daemonDrained, .daemonExitingOnError, .serviceDiscoveryPublisherDraining:
                .blocked
            }
            state.conditionalUpdate(to: newStatus, category: transitionCategory)
            return (oldStatus, transitionCategory)
        }

        self.emitTransitionTelemetry(from: oldStatus, to: newStatus, category: transitionCategory)
    }

    public func waitingForFirstAttestationFetch() {
        let newStatus = DaemonStatus.waitingForFirstAttestationFetch

        let (oldStatus, transitionCategory) = self.currentState.withLock { state in
            let oldStatus = state.lastStatus
            let transitionCategory: TransitionCategory = switch state.lastStatus {
            case .initializing, .waitingForFirstHotPropertyUpdate:
                .expected
            case .uninitialized, .waitingForFirstAttestationFetch,
                 .waitingForWorkloadRegistration, .serviceDiscoveryUpdateSuccess, .serviceDiscoveryUpdateFailure:
                .unexpected
            case .componentsFailedToRun, .daemonDrained, .daemonExitingOnError, .serviceDiscoveryPublisherDraining:
                .blocked
            }
            state.conditionalUpdate(to: newStatus, category: transitionCategory)
            return (oldStatus, transitionCategory)
        }

        self.emitTransitionTelemetry(from: oldStatus, to: newStatus, category: transitionCategory)
    }

    public func waitingForFirstHotPropertyUpdate() {
        let newStatus = DaemonStatus.waitingForFirstHotPropertyUpdate

        let (oldStatus, transitionCategory) = self.currentState.withLock { state in
            let oldStatus = state.lastStatus
            let transitionCategory: TransitionCategory = switch state.lastStatus {
            case .initializing, .waitingForFirstAttestationFetch,
                 .waitingForFirstHotPropertyUpdate:
                .expected
            case .waitingForWorkloadRegistration, .uninitialized, .serviceDiscoveryUpdateSuccess,
                 .serviceDiscoveryUpdateFailure:
                .unexpected
            case .componentsFailedToRun, .daemonDrained, .daemonExitingOnError, .serviceDiscoveryPublisherDraining:
                .blocked
            }
            state.conditionalUpdate(to: newStatus, category: transitionCategory)
            return (oldStatus, transitionCategory)
        }

        self.emitTransitionTelemetry(from: oldStatus, to: newStatus, category: transitionCategory)
    }

    public func waitingForWorkloadRegistration() {
        let newStatus = DaemonStatus.waitingForWorkloadRegistration

        let (oldStatus, transitionCategory) = self.currentState.withLock { state in
            let oldStatus = state.lastStatus
            let transitionCategory: TransitionCategory = switch state.lastStatus {
            case .initializing, .waitingForFirstAttestationFetch,
                 .waitingForFirstHotPropertyUpdate, .waitingForWorkloadRegistration:
                .expected
            case .uninitialized, .serviceDiscoveryUpdateSuccess, .serviceDiscoveryUpdateFailure:
                .unexpected
            case .componentsFailedToRun, .daemonDrained, .daemonExitingOnError, .serviceDiscoveryPublisherDraining:
                .blocked
            }
            state.conditionalUpdate(to: newStatus, category: transitionCategory)
            return (oldStatus, transitionCategory)
        }

        self.emitTransitionTelemetry(from: oldStatus, to: newStatus, category: transitionCategory)
    }

    public func serviceDiscoveryRunningFailed() {
        self.componentFailedToRun(.serviceDiscoveryPublisher)
    }

    public func grpcServerRunningFailed() {
        self.componentFailedToRun(.grpcServer)
    }

    public func workloadControllerRunningFailed() {
        self.componentFailedToRun(.workloadController)
    }

    private func componentFailedToRun(_ component: Components.Element) {
        let (oldStatus, newStatus, transitionCategory) = self.currentState.withLock { state in
            let oldStatus = state.lastStatus
            let newStatus: DaemonStatus
            let transitionCategory: TransitionCategory
            switch state.lastStatus {
            case .waitingForFirstHotPropertyUpdate, .waitingForWorkloadRegistration, .serviceDiscoveryUpdateSuccess,
                 .serviceDiscoveryUpdateFailure:
                newStatus = .componentsFailedToRun(component)
                transitionCategory = .expected
            case .componentsFailedToRun(var failedComponents):
                if failedComponents.contains(component) {
                    StatusMonitor.logger.warning("Component already reported as failed: \(component, privacy: .public)")
                    transitionCategory = .blocked
                } else {
                    failedComponents.insert(component)
                    transitionCategory = .expected
                }
                newStatus = .componentsFailedToRun(failedComponents)
            case .uninitialized, .initializing, .waitingForFirstAttestationFetch,
                 .serviceDiscoveryPublisherDraining:
                newStatus = .componentsFailedToRun(component)
                transitionCategory = .unexpected
            case .daemonDrained, .daemonExitingOnError:
                newStatus = .componentsFailedToRun(component)
                transitionCategory = .blocked
            }
            state.conditionalUpdate(to: newStatus, category: transitionCategory)
            return (oldStatus, newStatus, transitionCategory)
        }

        self.emitTransitionTelemetry(from: oldStatus, to: newStatus, category: transitionCategory)
    }

    public func serviceRegistrationSucceeded() {
        let (oldStatus, newStatus, transitionCategory) = self.currentState.withLock { state in
            let oldStatus = state.lastStatus
            let (newStatus, transitionCategory): (DaemonStatus, TransitionCategory) = switch state.lastStatus {
            case .waitingForWorkloadRegistration:
                (.serviceDiscoveryUpdateSuccess(1), .expected)
            case .serviceDiscoveryUpdateSuccess(let knownServices), .serviceDiscoveryUpdateFailure(let knownServices):
                (.serviceDiscoveryUpdateSuccess(knownServices + 1), .expected)
            case .uninitialized, .initializing, .waitingForFirstAttestationFetch,
                 .waitingForFirstHotPropertyUpdate:
                (.serviceDiscoveryUpdateSuccess(1), .unexpected)
            case .componentsFailedToRun, .serviceDiscoveryPublisherDraining, .daemonDrained, .daemonExitingOnError:
                (.serviceDiscoveryUpdateSuccess(1), .blocked)
            }
            state.conditionalUpdate(to: newStatus, category: transitionCategory)
            return (oldStatus, newStatus, transitionCategory)
        }

        self.emitTransitionTelemetry(from: oldStatus, to: newStatus, category: transitionCategory)
    }

    public func serviceRegistrationErrored() {
        let (oldStatus, newStatus, transitionCategory) = self.currentState.withLock { state in
            let oldStatus = state.lastStatus
            let (newStatus, transitionCategory): (DaemonStatus, TransitionCategory) = switch state.lastStatus {
            case .waitingForWorkloadRegistration:
                (.serviceDiscoveryUpdateFailure(0), .expected)
            case .serviceDiscoveryUpdateSuccess(let knownServices), .serviceDiscoveryUpdateFailure(let knownServices):
                (.serviceDiscoveryUpdateFailure(knownServices), .expected)
            case .uninitialized, .initializing, .waitingForFirstAttestationFetch,
                 .waitingForFirstHotPropertyUpdate:
                (.serviceDiscoveryUpdateFailure(0), .unexpected)
            case .componentsFailedToRun, .daemonDrained, .daemonExitingOnError, .serviceDiscoveryPublisherDraining:
                (.serviceDiscoveryUpdateFailure(0), .blocked)
            }
            state.conditionalUpdate(to: newStatus, category: transitionCategory)
            return (oldStatus, newStatus, transitionCategory)
        }

        self.emitTransitionTelemetry(from: oldStatus, to: newStatus, category: transitionCategory)
    }

    public func serviceDeregistrationCancelled() {
        // just mark the service as deregistered without indicating an issue with talking to SD
        // the service will age-out soon anyway
        self.serviceDeregistered()
    }

    public func serviceDeregistered() {
        let (oldStatus, newStatus, transitionCategory) = self.currentState.withLock { state in
            let oldStatus = state.lastStatus
            let (newStatus, transitionCategory): (DaemonStatus, TransitionCategory) = switch state.lastStatus {
            case .serviceDiscoveryUpdateSuccess(let knownServices), .serviceDiscoveryUpdateFailure(let knownServices):
                (.serviceDiscoveryUpdateSuccess(knownServices - 1), .expected)
            case .uninitialized, .initializing, .waitingForFirstAttestationFetch,
                 .waitingForFirstHotPropertyUpdate, .waitingForWorkloadRegistration:
                (.serviceDiscoveryUpdateSuccess(0), .unexpected)
            case .componentsFailedToRun, .daemonDrained, .daemonExitingOnError, .serviceDiscoveryPublisherDraining:
                (.serviceDiscoveryUpdateSuccess(0), .blocked)
            }
            state.conditionalUpdate(to: newStatus, category: transitionCategory)
            return (oldStatus, newStatus, transitionCategory)
        }

        self.emitTransitionTelemetry(from: oldStatus, to: newStatus, category: transitionCategory)
    }

    public func serviceDeregistrationErrored() {
        let (oldStatus, newStatus, transitionCategory) = self.currentState.withLock { state in
            let oldStatus = state.lastStatus
            let (newStatus, transitionCategory): (DaemonStatus, TransitionCategory) = switch state.lastStatus {
            case .serviceDiscoveryUpdateSuccess(let knownServices), .serviceDiscoveryUpdateFailure(let knownServices):
                (.serviceDiscoveryUpdateSuccess(knownServices - 1), .expected)
            case .uninitialized, .initializing, .waitingForFirstAttestationFetch,
                 .waitingForFirstHotPropertyUpdate, .waitingForWorkloadRegistration:
                (.serviceDiscoveryUpdateSuccess(0), .unexpected)
            case .componentsFailedToRun, .daemonDrained, .daemonExitingOnError, .serviceDiscoveryPublisherDraining:
                (.serviceDiscoveryUpdateSuccess(0), .blocked)
            }
            state.conditionalUpdate(to: newStatus, category: transitionCategory)
            return (oldStatus, newStatus, transitionCategory)
        }

        self.emitTransitionTelemetry(from: oldStatus, to: newStatus, category: transitionCategory)
    }

    public func serviceDiscoveryPublisherDraining() {
        let newStatus = DaemonStatus.serviceDiscoveryPublisherDraining

        let (oldStatus, transitionCategory) = self.currentState.withLock { state in
            let oldStatus = state.lastStatus
            let transitionCategory: TransitionCategory = switch state.lastStatus {
            case .serviceDiscoveryUpdateSuccess, .serviceDiscoveryUpdateFailure:
                .expected
            case .uninitialized, .initializing, .waitingForFirstAttestationFetch,
                 .waitingForFirstHotPropertyUpdate, .waitingForWorkloadRegistration, .componentsFailedToRun:
                .unexpected
            case .daemonDrained, .daemonExitingOnError, .serviceDiscoveryPublisherDraining:
                .blocked
            }
            state.conditionalUpdate(to: newStatus, category: transitionCategory)
            return (oldStatus, transitionCategory)
        }

        self.emitTransitionTelemetry(from: oldStatus, to: newStatus, category: transitionCategory)
    }

    public func daemonDrained() {
        let newStatus = DaemonStatus.daemonDrained

        let (oldStatus, transitionCategory) = self.currentState.withLock { state in
            let oldStatus = state.lastStatus
            let transitionCategory: TransitionCategory = switch state.lastStatus {
            case .serviceDiscoveryPublisherDraining:
                .expected
            case .uninitialized, .initializing, .waitingForFirstAttestationFetch,
                 .waitingForFirstHotPropertyUpdate, .waitingForWorkloadRegistration, .componentsFailedToRun,
                 .serviceDiscoveryUpdateSuccess, .serviceDiscoveryUpdateFailure, .daemonDrained:
                .unexpected
            case .daemonExitingOnError:
                .blocked
            }
            state.conditionalUpdate(to: newStatus, category: transitionCategory)
            return (oldStatus, transitionCategory)
        }

        self.emitTransitionTelemetry(from: oldStatus, to: newStatus, category: transitionCategory)
    }

    public func daemonExitingOnError() {
        let newStatus = DaemonStatus.daemonExitingOnError

        let oldStatus = self.currentState.withLock { state in
            let oldStatus = state.lastStatus
            switch state.lastStatus {
            case .uninitialized, .initializing, .waitingForFirstAttestationFetch,
                 .waitingForFirstHotPropertyUpdate, .waitingForWorkloadRegistration,
                 .componentsFailedToRun, .serviceDiscoveryUpdateSuccess, .serviceDiscoveryUpdateFailure,
                 .serviceDiscoveryPublisherDraining, .daemonDrained, .daemonExitingOnError:
                state.updateStatus(newStatus)
            }
            return oldStatus
        }
        self.emitTransitionTelemetry(from: oldStatus, to: newStatus, category: .expected)
    }
}

extension StatusMonitor {
    enum TransitionCategory {
        case expected // this transition appears on the state diagram 👍
        case unexpected // we didn't anticipate this transition but it should be benign, let it proceed 🤨
        case blocked // this transition really shouldn't happen, don't allow the state to change 🚫
    }
}

extension StatusMonitor.State {
    mutating func generateID() -> Int {
        defer { self.nextID &+= 1 }
        return self.nextID
    }

    mutating func updateStatus(_ status: DaemonStatus) {
        self.lastStatus = status

        for watcher in self.watchers {
            watcher.continuation.yield(status)
        }
    }

    mutating func conditionalUpdate(to status: DaemonStatus, category: StatusMonitor.TransitionCategory) {
        switch category {
        case .expected:
            self.updateStatus(status)
        case .unexpected:
            self.updateStatus(status)
        case .blocked:
            () // no-op
        }
    }
}

extension StatusMonitor {
    public func terminate() {
        Self.logger.debug("StatusMonitor terminate called")
        // We _must_ call `finish` from outside the lock, otherwise we'll
        // deadlock.
        let watchers = self.currentState.withLock { state in
            defer { state.watchers = [] }
            return state.watchers
        }

        for watcher in watchers {
            watcher.continuation.finish()
        }
    }

    /// Returns the current daemon status synchronously.
    ///
    /// This method directly accesses the stored status without creating a stream,
    /// making it suitable for one-shot status queries like the gRPC check endpoint.
    public func currentStatus() -> DaemonStatus {
        self.currentState.withLock { state in
            state.lastStatus
        }
    }

    public func watch() -> AsyncStream<DaemonStatus> {
        let (stream, continuation) = AsyncStream<DaemonStatus>.makeStream()

        self.currentState.withLock { state in
            let id = state.generateID()
            let watcher = Watcher(continuation: continuation, id: id)

            state.watchers.append(watcher)

            continuation.onTermination = { _ in
                self.watcherTerminated(id: id)
            }

            // Prime the pump with the last value to ensure that order of operations isn't an issue.
            continuation.yield(state.lastStatus)
        }

        return stream
    }

    private func watcherTerminated(id: Int) {
        self.currentState.withLock { state in
            if let index = state.watchers.firstIndex(where: { $0.id == id }) {
                state.watchers.remove(at: index)
            }
        }
    }

    struct Watcher {
        var continuation: AsyncStream<DaemonStatus>.Continuation
        var id: Int
    }
}

extension DaemonStatus: CustomStringConvertible {
    public var description: String {
        switch self {
        case .uninitialized:
            return "uninitialized"
        case .initializing:
            return "initializing"
        case .waitingForFirstAttestationFetch:
            return "waitingForFirstAttestationFetch"
        case .waitingForFirstHotPropertyUpdate:
            return "waitingForFirstHotPropertyUpdate"
        case .waitingForWorkloadRegistration:
            return "waitingForWorkloadRegistration"
        case .componentsFailedToRun(let failed):
            return "componentsFailedToRun: \(failed)"
        case .serviceDiscoveryUpdateSuccess(let knownServices):
            return "serviceDiscoveryUpdateSuccess (known services: \(knownServices))"
        case .serviceDiscoveryUpdateFailure(let knownServices):
            return "serviceDiscoveryUpdateFailure (known services: \(knownServices))"
        case .serviceDiscoveryPublisherDraining:
            return "serviceDiscoveryPublisherDraining"
        case .daemonDrained:
            return "daemonDrained"
        case .daemonExitingOnError:
            return "daemonExitingOnError"
        }
    }
}

extension DaemonStatus {
    // The existing DaemonStatus description returns the nested state of some StatusMonitor states
    // (e.g. knownServiceCount) which is useful for logging but which should be emitted as a separate
    // metric dimension. metricDescription only returns the StatusMonitor's state, without any associated
    // state.
    public var metricDescription: StaticString {
        switch self {
        case .uninitialized:
            return "uninitialized"
        case .initializing:
            return "initializing"
        case .waitingForFirstAttestationFetch:
            return "waitingForFirstAttestationFetch"
        case .waitingForFirstHotPropertyUpdate:
            return "waitingForFirstHotPropertyUpdate"
        case .waitingForWorkloadRegistration:
            return "waitingForWorkloadRegistration"
        case .componentsFailedToRun:
            return "componentsFailedToRun"
        case .serviceDiscoveryUpdateSuccess:
            return "serviceDiscoveryUpdateSuccess"
        case .serviceDiscoveryUpdateFailure:
            return "serviceDiscoveryUpdateFailure"
        case .serviceDiscoveryPublisherDraining:
            return "serviceDiscoveryPublisherDraining"
        case .daemonDrained:
            return "daemonDrained"
        case .daemonExitingOnError:
            return "daemonExitingOnError"
        }
    }
}

extension Components: CustomStringConvertible {
    public var description: String {
        var present: [String] = []
        if self.contains(.serviceDiscoveryPublisher) {
            present.append("serviceDiscoveryPublisher")
        }
        if self.contains(.grpcServer) {
            present.append("grpcServer")
        }
        if self.contains(.workloadController) {
            present.append("workloadController")
        }

        if present.count == 1 {
            return present[0]
        } else {
            return "[\(present.joined(separator: ","))]"
        }
    }
}
