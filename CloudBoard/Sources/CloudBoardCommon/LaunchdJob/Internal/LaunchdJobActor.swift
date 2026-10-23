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

internal import AppServerSupport.OSLaunchdJob
import CloudBoardLogging
import CloudBoardMetrics
import Foundation
import os
import System

internal enum LaunchdJobError: ReportableError {
    case submitFailed
    case createFailed(Error?)
    case spawnFailed(Errno)
    case exited(OSLaunchdJobExitStatus?)
    case neverRan
    case missingInstanceHandle

    var publicDescription: String {
        return switch self {
        case .submitFailed: "submitFailed"
        case .createFailed(let error): "createFailed\(error.map { "(\(String(reportable: $0)))" } ?? "")"
        case .spawnFailed(let errno): "spawnFailed(\(errno))"
        case .exited(let oSLaunchdJobExitStatus): "exited\(oSLaunchdJobExitStatus.map { "(\($0))" } ?? "")"
        case .neverRan: "neverRan"
        case .missingInstanceHandle: "missingInstanceHandle"
        }
    }
}

/// Provides an isolation domain for interacting with the underlying instance
/// It provides low level stream of events
internal actor LaunchdJobActor: AsyncSequence {
    public typealias Element = (OSLaunchdJobInfo?, Int32)

    private let baseJobHandle: OSLaunchdJob
    public var instanceHandle: OSLaunchdJob?
    public let uuid: UUID
    private let stream: AsyncStream<Element>
    private let continuation: AsyncStream<Element>.Continuation
    private let monitoringQueue: DispatchQueue
    private let metrics: LaunchdJobMetrics

    public static let log: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "LaunchdJobActor"
    )

    public init(_ managedJob: ManagedLaunchdJob, uuid: UUID = UUID(), metrics: (any MetricsSystem)? = nil) {
        self.baseJobHandle = managedJob.jobHandle
        self.uuid = uuid
        (self.stream, self.continuation) = AsyncStream.makeStream(
            of: Element.self
        )
        self.monitoringQueue = DispatchQueue(
            label: "com.apple.cloudos.cloudboardd-\(uuid)",
            qos: DispatchQoS.userInitiated
        )
        self.metrics = LaunchdJobMetrics(metrics: metrics, jobName: managedJob.jobAttributes.cloudBoardJobName)
    }

    public func create() throws {
        var uuid = self.uuid
        Self.log.info("Creating job \(uuid, privacy: .public)")
        self.metrics.jobCreate()
        do {
            try withUnsafeMutablePointer(to: &uuid) { uuidPointer in
                self.instanceHandle = try self.baseJobHandle.createInstance(uuidPointer)
            }
        } catch {
            let composedError = LaunchdJobError.createFailed(error)
            Self.log.error("""
            Failed to create launchd job instance: \
            \(String(reportable: error), privacy: .public) (\(error))
            """)
            self.metrics.jobCreateError(composedError)
            throw composedError
        }

        guard self.instanceHandle != nil else {
            let composedError = LaunchdJobError.createFailed(nil)
            Self.log.error("Failed to create launchd job instance: unknown error")
            self.metrics.jobCreateError(composedError)
            throw composedError
        }

        Self.log.info(
            "Created job instance with UUID: \(uuid, privacy: .public)"
        )
    }

    private func startMonitoring() throws {
        guard let handle = self.instanceHandle else {
            throw LaunchdJobError.missingInstanceHandle
        }
        Self.log.info("Start monitoring job \(self.uuid, privacy: .public)")
        handle.monitor(on: self.monitoringQueue) { launchdJobInfo, errno in
            self.continuation.yield((launchdJobInfo, errno))
        }
    }

    public func stopMonitoring() {
        Self.log.info("Stop monitoring job \(self.uuid, privacy: .public)")
        self.instanceHandle?.cancelMonitor()
    }

    public func run() throws {
        let uuid = self.uuid
        Self.log.info("Run job \(uuid, privacy: .public)")
        self.metrics.jobRun()

        guard let handle = self.instanceHandle else {
            let error = LaunchdJobError.missingInstanceHandle
            self.metrics.jobRunError(error)
            throw error
        }

        try self.startMonitoring()
        let startResult = try handle.start()

        switch startResult.state {
        case OSLaunchdJobState.running:
            break
        case OSLaunchdJobState.spawnFailed:
            let errNo = Errno(rawValue: startResult.lastSpawnError)
            Self.log.error("""
            Failed to spawn launchd job: spawn error \(errNo, privacy: .public)
            """)
            let error = LaunchdJobError.spawnFailed(errNo)
            self.metrics.jobRunError(error)
            throw error
        case OSLaunchdJobState.exited:
            let status = startResult.lastExitStatus
            Self.log.error("""
            Failed to spawn launchd job: job exited with status \
            \(status, privacy: .public)
            """)
            let error = LaunchdJobError.exited(status)
            self.metrics.jobRunError(error)
            throw error
        case OSLaunchdJobState.neverRan:
            Self.log.error("Failed to spawn launchd job: job never ran")
            let error = LaunchdJobError.neverRan
            self.metrics.jobRunError(error)
            throw error
        }

        Self.log.debug("Started launchd job")
    }

    public nonisolated func makeAsyncIterator() -> AsyncStream<Element>.Iterator {
        // This violates swift 6 language mode - the previous code did too
        self.stream.makeAsyncIterator()
    }
}

// This can't be a CustomStringConvertible extension as it results in
// requiring `import AppServerSupport.OSLaunchdJob` and thence
// it 'leaking' into the API (which we do not allow)
internal enum OSLaunchdJobStateStringConversion {
    static func description(_ state: OSLaunchdJobState) -> String {
        switch state {
        case .exited: return "Exited"
        case .neverRan: return "NeverRan"
        case .running: return "Running"
        case .spawnFailed: return "SpawnFailed"
        }
    }
}
