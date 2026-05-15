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

internal import AppServerSupport.OSLaunchdJob
import CloudBoardLogging
import CloudBoardMetrics
import Foundation
import os
import System

internal struct LaunchdJobInstanceInitiator: LaunchdJobInstanceInitiatorProtocol {
    typealias State = LaunchdJobEvents.State

    // note: this log name looks a little weird, but it retains the naming of the previous system for now
    private static let log: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "LaunchdJobInstanceInitiator"
    )

    private let managedJob: ManagedLaunchdJob
    private let jobActor: LaunchdJobActor
    public var uuid: UUID { self.jobActor.uuid }

    public var attributes: CloudBoardJobAttributes { self.managedJob.jobAttributes }

    public var instanceHandleIfCreated: (any LaunchdJobInstanceHandleProtocol)? {
        get async {
            return await self.jobActor.instanceHandle.map {
                LaunchdJobInstanceHandle($0, attributes: self.managedJob.jobAttributes)
            }
        }
    }

    internal init(_ managedJob: ManagedLaunchdJob, uuid: UUID, metrics: (any MetricsSystem)? = nil) {
        self.managedJob = managedJob
        self.jobActor = LaunchdJobActor(managedJob, uuid: uuid, metrics: metrics)
    }

    func startAndWatch() -> any AsyncSequence<LaunchdJobEvents.State, Never> {
        return TransformingAsyncSequence(jobActor: self.jobActor)
    }

    func findRunningLinkedInstances(
        type: CloudBoardJobType,
        logger: Logger
    ) -> [any LaunchdJobInstanceHandleProtocol] {
        precondition(
            self.managedJob.jobAttributes.cloudBoardJobType != type,
            "Attempt to find a linked instance of \(type) which matches our own type"
        )
        let linkedJobs = LaunchdJobHelper.fetchManagedLaunchdJobs(
            type: type, logger: logger
        ).filter {
            $0.jobHandle.getCurrentJobInfo()?.instance == self.uuid
        }
        return linkedJobs.map { LaunchdJobInstanceHandle($0.jobHandle, attributes: $0.jobAttributes) }
    }

    /// This actor converts the LaunchdJobActor events into the public form
    /// It maintains some other state as well.
    /// In theory LaunchdJobActor and this could merge
    private struct TransformingAsyncSequence: AsyncSequence {
        typealias AsyncIterator = TransformingAsyncIterator
        typealias Element = State

        let jobActor: LaunchdJobActor

        public nonisolated func makeAsyncIterator() -> AsyncIterator {
            return AsyncIterator(self.jobActor)
        }
    }

    /// This actor converts the LaunchdJobActor events into the public form
    /// It maintains some other state as well.
    /// In theory LaunchdJobActor and this could merge
    private actor TransformingAsyncIterator: AsyncIteratorProtocol {
        private static let log: Logger = .init(
            subsystem: "com.apple.cloudos.cloudboard",
            category: "LaunchdJobInstanceInitiatorEvents"
        )

        internal var job: LaunchdJobActor
        private var state: State
        private var seenInitialNeverRanEvent: Bool = false
        private var sigkillTask: Task<Void, Error>?

        public typealias Element = State
        public typealias Failure = Never

        init(_ job: LaunchdJobActor) {
            self.job = job
            self.state = .initialized
        }

        public func next() async throws -> State? {
            let uuid = self.job.uuid
            guard !self.state.isFinal() else {
                Self.log.debug("Job \(uuid, privacy: .public) reached final state")
                return nil
            }

            switch self.state {
            case .initialized:
                var newState: State
                Self.log.debug("Job \(uuid, privacy: .public) initialized, creating")
                do {
                    try await self.job.create()
                    newState = .created
                } catch LaunchdJobError.submitFailed {
                    newState = .neverRan
                    Self.log.error(
                        "Job \(uuid, privacy: .public) creation failed: \(String(reportable: LaunchdJobError.submitFailed), privacy: .public)"
                    )
                } catch LaunchdJobError.createFailed(let error) {
                    Self.log.error(
                        "Job \(uuid, privacy: .public) creation failed: \(String(reportable: LaunchdJobError.createFailed(error)), privacy: .public)"
                    )
                    newState = .neverRan
                } catch {
                    Self.log.error(
                        "Job \(uuid, privacy: .public) creation failed: \(String(reportable: error), privacy: .public)"
                    )
                    newState = .neverRan
                }
                await self.transition(to: newState)
                return self.state
            case .created:
                var newState: State
                Self.log.debug("Job \(uuid, privacy: .public) created, running")
                do {
                    try await self.job.run()
                    newState = .starting
                } catch LaunchdJobError.spawnFailed(let errNo) {
                    Self.log.error(
                        "Failed to run job \(uuid, privacy: .public): \(String(reportable: LaunchdJobError.spawnFailed(errNo)), privacy: .public)"
                    )
                    newState = .terminated(.spawnFailed(errNo))
                } catch LaunchdJobError.exited(let status) {
                    Self.log.error(
                        "Failed to run job \(uuid, privacy: .public): \(String(reportable: LaunchdJobError.exited(status)), privacy: .public)"
                    )
                    newState = .terminated(.exited(LaunchdJobEvents.ExitStatus(from: status)))
                } catch LaunchdJobError.neverRan {
                    Self.log.error(
                        "Failed to run job \(uuid, privacy: .public): \(String(reportable: LaunchdJobError.neverRan), privacy: .public)"
                    )
                    newState = .neverRan
                } catch {
                    Self.log.error(
                        "Failed to run job \(uuid, privacy: .public): \(String(reportable: error), privacy: .public)"
                    )
                    newState = .terminated(.failedToRun)
                }
                await self.transition(to: newState)
                return self.state
            default:
                for await (jobInfo, errno) in self.job {
                    await self.handleLaunchdJobEvent(jobInfo: jobInfo, errno: errno)
                    return self.state
                }
            }
            return nil
        }

        private func handleLaunchdJobEvent(jobInfo: OSLaunchdJobInfo?, errno: Int32) async {
            let errno = Errno(rawValue: errno)
            let uuid = self.job.uuid
            guard let jobInfo else {
                // This is unexpected. Assume the job no longer exists. Once an
                // error is returned, we won't receive any more updates.
                Self.log.error("""
                \(uuid, privacy: .public): Received launchd job event without \
                context: \(errno, privacy: .public)
                """)
                await self.transition(to: .terminated(.launchdError(errno)))
                return
            }
            let stateString = OSLaunchdJobStateStringConversion.description(jobInfo.state)
            Self.log.info("""
            \(uuid, privacy: .public): Received launchd job event with state: \
            \(stateString, privacy: .public)
            """)

            switch jobInfo.state {
            case OSLaunchdJobState.running:
                switch self.state {
                case .starting:
                    let pid = await (self.job.instanceHandle?.getCurrentJobInfo()?.pid).map { Int($0) }
                    await self.transition(to: .running(pid: pid))
                default:
                    fatalError("""
                    \(uuid): Unexpectedly received notification that launchd job is now \
                    running with stashed/previous MonitoredLaunchdJobInstance state: \(self.state))
                    """)
                }
            case OSLaunchdJobState.exited:
                let exitStatus = LaunchdJobEvents.ExitStatus(from: jobInfo.lastExitStatus)
                Self.log.log("""
                \(uuid, privacy: .public): Job exited with status \
                \(exitStatus, privacy: .public)
                """)
                // Cancel monitoring for exited job. Required to avoid mach port leak.
                await self.transition(to: .terminated(.exited(exitStatus)))
            case OSLaunchdJobState.spawnFailed:
                let errNo = Errno(rawValue: jobInfo.lastSpawnError)
                await self.transition(to: .terminated(.spawnFailed(errNo)))
            case OSLaunchdJobState.neverRan:
                // if we've never seen
                if !self.seenInitialNeverRanEvent {
                    Self.log.debug("\(uuid, privacy: .public): Ignoring initial NeverRanEvent")
                    self.seenInitialNeverRanEvent = true
                    break
                }
                await self.transition(to: .neverRan)
            }
        }

        private func transition(to state: State) async {
            let uuid = self.job.uuid
            let initialState = self.state
            Self.log.info("""
            Job \(uuid, privacy: .public) transitioning from \
            '\(initialState, privacy: .public)' to \
            '\(state, privacy: .public)'
            """)
            if state.isFinal() {
                // Cancel monitoring for failed/terminated jobs. As per the
                // OSLaunchdJobMonitorHandler documentation, the monitor will not
                // be called again in case of an error. Required to avoid mach
                // port leak.
                switch self.state {
                case .starting, .running:
                    await self.job.stopMonitoring()
                    self.sigkillTask?.cancel()
                default:
                    // Nothing to do
                    ()
                }
            }
            self.state = state
        }
    }
}
