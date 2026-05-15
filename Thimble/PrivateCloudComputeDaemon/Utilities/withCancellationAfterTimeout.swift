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
//  withCancellationAfterTimeout.swift
//  PrivateCloudCompute
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

import Foundation

// This must be private. That way, we can ensure that
// it correctly marks the timeout child task. In other
// words, the operation child task cannot possibly
// produce such an error.
private struct TimeoutChildTaskCompletedError: Error {}

/// Runs the given throwing operation as part of a new child task, and cancels that child task after
/// `duration` if it has not completed
///
/// - Throws: The error thrown by the operation
/// - Returns: The return value of the operation
///
/// The operation given to this function will be run right away as a child task of the current task.
/// If it has not completed by the time duration has passed, then it will be cancelled. In any case,
/// the return value will be the return value of the operation, unless the operation throws, in which
/// case this will throw that error. This function does not indicate whether the timeout was used or
/// not. Please note that Task cancellation does not provide a way to end the execution of the
/// operation, and therefore any given operation may proceed as long as it likes, possibly much
/// longer than the timeout specified, depending on how it handles cancellation.
func withCancellationAfterTimeout<T: Sendable, Clock: _Concurrency.Clock>(duration: Duration, clock: Clock = ContinuousClock(), operation: @Sendable () async throws -> T) async rethrows -> T where Clock.Duration == Duration {
    return try await withoutActuallyEscaping(operation) { escapingClosure in
        try await withThrowingTaskGroup(of: T.self, returning: T.self) { group in
            group.addTask {
                return try await escapingClosure()
            }

            group.addTask {
                // The `try?` suppresses errors from Task.sleep,
                // which will throw CancellationError if cancelled.
                try? await clock.sleep(for: duration)
                // Therefore this block will always throw this error
                // which will allow us to identify it regardless of
                // how it ends or how long it took.
                throw TimeoutChildTaskCompletedError()
            }

            // NB: The "main" operation child task, and this method, may take
            // longer than the specified duration, depending on how the code
            // in operation() responds to being cancelled.

            // At this point, if the sleeping task runs to completion first,
            // then `group.next()!` will throw its exception, which we recognize.
            // If that happens, then we manually cancel the group (and therefore
            // the "main" child task) and await its completion so it can give
            // its result.

            // On the other hand, if the "main" child task runs to completion
            // first, we will simply give its result. The sleeping task will
            // be cancelled immediately and we ignore its result anyway.

            // Note that ensuring that we always give the result of the main
            // operation is a trade-off. On the one hand, the caller cannot really
            // tell if the timeout occurred. Not for sure. But on the other hand,
            // they couldn't anyway--if we tried to design a "this got cancelled"
            // result it would be a race when both child tasks completed, in which
            // case you might have gotten a "this got cancelled" error when in
            // fact it did not.

            do {
                let ret = try await group.next()!
                group.cancelAll()  // cancel the timeout task
                return ret
            } catch is TimeoutChildTaskCompletedError {
                // This means that in the do block, the timeout
                // finished first. We want to surface the result
                // of the other task being cancelled.
                group.cancelAll()
                return try await group.next()!
            }
        }
    }
}
