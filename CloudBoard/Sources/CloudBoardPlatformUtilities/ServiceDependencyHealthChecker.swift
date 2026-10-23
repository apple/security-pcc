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

#if RC_IS_CLOUDOS_ENABLED && os(iOS)
import SystemServiceMonitor
#elseif canImport(SystemServiceMonitor)
@_weakLinked import SystemServiceMonitor
#else
#warning("SystemServiceMonitor not available at compile time")
#endif

import CloudBoardLogging
import CloudBoardMetrics
import Foundation
import OSLog
import Synchronization

// MARK: - Protocol

public protocol ServiceDependencyHealthChecker: Sendable {
    func waitForHealthyState() async throws
    func isWaitForHealthyStateRequired() -> Bool
}

// MARK: - Error Types

public enum ServiceDependencyHealthCheckerError: Error, CustomStringConvertible {
    case serviceNotFound(String)
    case errorFetchingServiceStatus

    public var description: String {
        switch self {
        case .serviceNotFound(let service):
            "SSM service \(service) not found"
        case .errorFetchingServiceStatus:
            "Error fetching service status"
        }
    }
}

// MARK: - Service State

enum ServiceState: String, Sendable {
    case invalid, unavailable, notPresented, presented, ready, failed

    init(from state: Service.State) {
        self = switch state {
        case .failed: .failed
        case .presented: .presented
        case .ready: .ready
        default: .invalid
        }
    }

    var statusCode: Int {
        switch self {
        case .invalid: 0
        case .unavailable: 1
        case .notPresented: 2
        case .failed: 3
        case .presented: 4
        case .ready: 5
        }
    }
}

// MARK: - Health Checker Implementation

#if canImport(SystemServiceMonitor)
@available(iOS 26.0, macOS 15.6, *)
public struct ControlPlaneHealthDHealthChecker: ServiceDependencyHealthChecker {
    private enum Constants {
        static let serviceIdentifier = "com.apple.cloudos.controlplanehealthd"
        static let clientName = "com.apple.cloudos.cloudboardd"
        static let serviceWaitTimeout = 5.0
        static let healthCheckInterval: Duration = .seconds(1)
        static let metricsInterval: Duration = .minutes(1)
    }

    private let requestClient: RequestClient
    private let metrics: MetricsSystem
    private let waitForHealthyState: Bool

    private static let logger = Logger(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "ControlPlaneHealthDHealthChecker"
    )

    // MARK: - Initialization

    public init(metrics: MetricsSystem, waitForHealthyState: Bool) {
        self.metrics = metrics
        self.waitForHealthyState = waitForHealthyState
        self.requestClient = RequestClient(identifier: Constants.clientName)
        Self.logger.log("ControlPlaneHealthDHealthChecker requestClient initialized")
    }

    // MARK: - Public Methods

    public func isWaitForHealthyStateRequired() -> Bool {
        self.waitForHealthyState
    }

    public func waitForHealthyState() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            // Health check task
            group.addTask {
                let service = try await self.obtainService()
                try await self.monitorServiceState(service)
            }

            // Metrics emission
            group.addTask {
                while true {
                    Self.logger
                        .debug("Waiting for \(Constants.serviceIdentifier, privacy: .public) to switch to ready state")
                    self.metrics.emit(
                        Metrics.ControlPlaneHealthDHealthChecker
                            .CloudBoardWaitingForControlPlaneHealthDReadyStatus(value: 1)
                    )
                    try await Task.sleep(for: Constants.metricsInterval)
                }
            }

            // Wait for first task to complete
            _ = try await group.next()!
            group.cancelAll()
        }
        self.metrics.emit(
            Metrics.ControlPlaneHealthDHealthChecker.CloudBoardWaitingForControlPlaneHealthDReadyStatus(value: 0)
        )
    }

    // MARK: - Private Methods

    private func obtainService() async throws -> Service {
        Self.logger.log("""
        Waiting for service (\(Constants.serviceIdentifier, privacy: .public)) to present
        """)
        do {
            let service = try await self.requestClient.waitUntilServicePresented(
                identifiedBy: Constants.serviceIdentifier,
                within: Constants.serviceWaitTimeout
            )
            self.emitControlPlaneHealthDStatusMetric(state: .presented)
            Self.logger.log("Service presented: \(Constants.serviceIdentifier, privacy: .public)")
            return service
        } catch {
            Self.logger.error("Service not presented: \(String(unredacted: error), privacy: .public)")
            self.emitControlPlaneHealthDStatusMetric(state: .notPresented)
            throw ServiceDependencyHealthCheckerError.serviceNotFound(Constants.serviceIdentifier)
        }
    }

    private func monitorServiceState(
        _ service: Service,
    ) async throws {
        let isContinuationResumed = Mutex(false)
        var serviceMonitor: ServiceMonitor?

        defer { serviceMonitor = nil }

        try await withCheckedThrowingContinuation { continuation in
            do {
                serviceMonitor = try Service.createMonitor(
                    service,
                    onUnavailable: {
                        self.emitControlPlaneHealthDStatusMetric(state: .unavailable)
                        Self.logger.warning("""
                        Service (\(Constants.serviceIdentifier, privacy: .public)) became unavailable
                        """)
                    },
                    onStateChange: { state in
                        Self.logger.log("""
                        Service (\(Constants.serviceIdentifier, privacy: .public)) state changed
                        to: \(String(describing: state), privacy: .public)
                        """)
                        self.emitControlPlaneHealthDStatusMetric(state: .init(from: state))

                        // Return success when BMC node is healthy
                        if case .ready = state {
                            isContinuationResumed.withLock {
                                if !$0 {
                                    continuation.resume()
                                    $0 = true
                                }
                            }
                        }
                    }
                )
            } catch {
                Self.logger.error("""
                Error fetching service (\(Constants.serviceIdentifier, privacy: .public)) status 
                error: \(error, privacy: .public).
                """)
                self.emitControlPlaneHealthDStatusMetric(state: .failed)
                continuation.resume(throwing: ServiceDependencyHealthCheckerError.errorFetchingServiceStatus)
            }
        }

        Self.logger.info("Service (\(Constants.serviceIdentifier, privacy: .public)) healthy!")
    }

    private func emitControlPlaneHealthDStatusMetric(state: ServiceState) {
        self.metrics.emit(
            Metrics.ControlPlaneHealthDHealthChecker.ControlPlaneHealthdStatus(
                value: state.statusCode
            )
        )
    }
}
#endif
