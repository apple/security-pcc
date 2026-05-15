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

//
//  ScheduledTask.swift
//  PrivateCloudCompute
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

@preconcurrency import BackgroundSystemTasks
import Foundation
import OSLog
import PrivateCloudCompute

/// Scheduled activities are run based on their schedule and system's conditions. The system may decide to expire our
/// task while it's running. When that happens, the enclosing Task that runs `performScheduledWork` will be
/// canceled. And types conforming to this protocol must handle Task cancellation. Additionally, the interrupted task will be
/// given an opportunity to request to be run again after a minimum delay it provides.
protocol ScheduledActivity: Sendable {
    /// Called when the task has been expired by the system and provides the task with an opportunity to request to be
    /// rescheduled. Return `nil` if the task doesn't need to be rescheduled.
    var retryPolicy: ScheduledTaskRetryPolicy? { get }
    var shouldPerformScheduledWork: Bool { get }
    func performScheduledWork() async
}

extension ScheduledActivity {
    var retryPolicy: ScheduledTaskRetryPolicy? {
        nil
    }
}

protocol ScheduledTaskStore: AnyObject, Sendable {
    /// Stores last time a scheduled task has been requested to be re-run after it being expired.
    var lastTimeScheduledTaskHasBeenRequestedToReRun: [ScheduledTask.TaskIdentifier: Date] { get set }
}

final class ScheduledTask<Store: ScheduledTaskStore>: Sendable {
    typealias TaskIdentifier = String

    private let work: any ScheduledActivity
    private let identifier: TaskIdentifier
    private let logger = tc2Logger(forCategory: .scheduledTask)
    private let logPrefix: String
    private let store: Store

    init(preregisteredIdentifier identifier: TaskIdentifier, work: any ScheduledActivity, store: Store) {
        self.identifier = identifier
        self.work = work
        self.logPrefix = "\(self.identifier):"
        self.store = store
    }

    func register() {
        #if os(tvOS)
        self.logger.log("\(self.logPrefix) not registering scheduled task identifier=\(self.identifier)")
        return
        #else
        self.logger.log("\(self.logPrefix) registering scheduled task identifier=\(self.identifier)")
        BGSystemTaskScheduler.shared.registerForTask(withIdentifier: self.identifier, using: .global(qos: .background)) { task in
            guard self.work.shouldPerformScheduledWork else {
                self.skip(task: task)
                return
            }

            let workTask = Task(priority: .background) {
                self.logger.log("\(self.logPrefix) performing scheduled task")
                await self.work.performScheduledWork()
                if Task.isCancelled {
                    if let retryPolicy = self.work.retryPolicy,
                        let delay = retryPolicy.delayBeforeNextRetry(
                            lastRetryRequestedAt: self.store.lastTimeScheduledTaskHasBeenRequestedToReRun[self.identifier]
                        )
                    {
                        self.store.lastTimeScheduledTaskHasBeenRequestedToReRun[self.identifier] = Date()
                        self.cancelWithRetryAfter(minimumDelay: delay, task: task)
                    } else {
                        self.cancelWithoutRetry(task: task)
                    }
                } else {
                    self.finish(task: task)
                }
            }

            task.expirationHandlerWithReason = { reason in
                self.logger.log("\(self.logPrefix) scheduled task is being expired reason=\(reason.rawValue)")
                workTask.cancel()
            }
        }
        #endif
    }

    private func cancelWithRetryAfter(minimumDelay: TimeInterval, task: BGSystemTask) {
        do {
            self.logger.log("\(self.logPrefix) scheduled task has been canceled retryAfter=\(minimumDelay)")
            try task.setTaskExpiredWithRetryAfter(Double(minimumDelay))
        } catch {
            self.logger.log("\(self.logPrefix) scheduled task has been canceled and can't be scheduled for retry error=\(error)")
        }
    }

    private func cancelWithoutRetry(task: BGSystemTask) {
        self.logger.log("\(self.logPrefix) scheduled task has been canceled with no retry")
        task.setTaskCompleted()
    }

    private func finish(task: BGSystemTask) {
        self.logger.log("\(self.logPrefix) scheduled task finished")
        task.setTaskCompleted()
    }

    private func skip(task: BGSystemTask) {
        self.logger.log("\(self.logPrefix) scheduled task skipped")
        task.setTaskCompleted()
    }
}
