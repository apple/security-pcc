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

import Foundation

// MARK: - State

/// Pure state for fragment download tracking.
///
/// This enum captures the logical state of a fragment download without any
/// effectful objects (no URLSession, no file handles). The pure
/// ``nextState(from:on:)`` transition function returns the new state and
/// a list of ``FragmentDownloadAction``s describing the side effects.
package enum FragmentDownloadState: Equatable, CustomStringConvertible {
    case pendingDownload
    case downloading(ActiveDownload)
    case downloadFailed(FailedDownload)
    case ready

    package var description: String {
        switch self {
        case .pendingDownload:
            return "pendingDownload"
        case .downloading(let active):
            let chunkDesc = active.isChunked ? ", chunk: \(active.chunkIndex)" : ""
            return "downloading (\(active.progress.bytesWritten)/\(active.progress.bytesExpected)\(chunkDesc))"
        case .downloadFailed(let failure):
            return "downloadFailed (hasResumeData: \(failure.hasResumeData))"
        case .ready:
            return "ready"
        }
    }
}

/// In-progress download state.
package struct ActiveDownload: Equatable {
    package var progress: DownloadProgress
    /// Current chunk index. Always 0 for non-chunked downloads.
    package var chunkIndex: Int
    /// Whether this download uses chunked range requests.
    package var isChunked: Bool

    package init(progress: DownloadProgress = .zero, chunkIndex: Int = 0, isChunked: Bool = false) {
        self.progress = progress
        self.chunkIndex = chunkIndex
        self.isChunked = isChunked
    }
}

/// Byte progress for threshold-based logging.
package struct DownloadProgress: Equatable {
    package var bytesWritten: Int64
    package var bytesExpected: Int64

    package static let zero = DownloadProgress(bytesWritten: 0, bytesExpected: 0)

    package init(bytesWritten: Int64, bytesExpected: Int64) {
        self.bytesWritten = bytesWritten
        self.bytesExpected = bytesExpected
    }
}

/// State after a download attempt has failed.
package struct FailedDownload: Equatable {
    /// Whether URLSession provided resume data for this failure.
    package var hasResumeData: Bool

    package init(hasResumeData: Bool) {
        self.hasResumeData = hasResumeData
    }
}

// MARK: - Events

/// Events that drive state transitions.
package enum FragmentDownloadEvent: Equatable {
    /// Start or retry a download attempt.
    case attemptDownload(hasResumeData: Bool, resumeChunkIndex: Int, isChunked: Bool)
    /// URLSession reported download progress.
    case progressUpdate(bytesWritten: Int64, bytesExpected: Int64)
    /// A full-file download completed (HTTP 200 or non-chunked).
    case fullDownloadSuccess
    /// A single chunk completed (HTTP 206).
    case chunkSuccess(totalChunks: Int)
    /// The download failed.
    case downloadFailure(hasResumeData: Bool)
}

// MARK: - Actions

/// Side effects the effectful interpreter must execute after a transition.
package enum FragmentDownloadAction: Equatable {
    /// Start a URLSession download task.
    case startDownloadTask(chunkIndex: Int?, useResumeData: Bool)
    /// Fulfil the promise with success.
    case succeedPromise
    /// Fulfil the promise with failure.
    case failPromise
    /// Verify SHA-256 and move the file to its final destination.
    /// When `usePartialFile` is true, verify the assembled `.partial` file
    /// instead of the staging URL (used after chunked downloads).
    case verifyAndFinalize(usePartialFile: Bool)
    /// Append chunk data to the partial file and record progress in the store.
    case appendChunkAndRecordProgress
    /// Delete sidecar files (.partial, .download-db, etc.).
    case cleanupSidecarFiles
    /// Log a warning that the server returned a full file despite a Range request.
    case logWarningRangeFallback
}

// MARK: - Errors

/// An invalid event was sent to the state machine for its current state.
package struct InvalidStateTransitionError: Error, CustomStringConvertible {
    package let state: FragmentDownloadState
    package let event: FragmentDownloadEvent

    package var description: String {
        "Invalid state transition: event \(self.event) in state \(self.state)"
    }
}

// MARK: - Transition function

/// Pure state transition: given the current state and an event, returns the
/// new state and a list of actions for the interpreter to execute.
///
/// Throws ``InvalidStateTransitionError`` if the event is not valid for the current state.
package func nextState(
    from state: FragmentDownloadState,
    on event: FragmentDownloadEvent,
    progressThreshold: Int64 = 100 * 1024 * 1024
) throws -> (state: FragmentDownloadState, actions: [FragmentDownloadAction]) {
    switch (state, event) {
    // MARK: Start / retry download

    case (.pendingDownload, .attemptDownload(let hasResumeData, let resumeChunkIndex, let isChunked)),
         (.downloadFailed, .attemptDownload(let hasResumeData, let resumeChunkIndex, let isChunked)):
        let active = ActiveDownload(
            progress: .zero,
            chunkIndex: resumeChunkIndex,
            isChunked: isChunked
        )
        return (
            state: .downloading(active),
            actions: [
                .startDownloadTask(
                    chunkIndex: isChunked ? resumeChunkIndex : nil,
                    useResumeData: hasResumeData
                ),
            ]
        )

    // MARK: Progress update
    case (.downloading(let active), .progressUpdate(let bytesWritten, let bytesExpected)):
        if bytesWritten - active.progress.bytesWritten < progressThreshold {
            // Below threshold — no state change.
            return (state: state, actions: [])
        }
        var updated = active
        updated.progress = DownloadProgress(bytesWritten: bytesWritten, bytesExpected: bytesExpected)
        return (state: .downloading(updated), actions: [])

    // MARK: Full download success (HTTP 200 or non-chunked)
    case (.downloading(let active), .fullDownloadSuccess):
        var actions: [FragmentDownloadAction] = []
        if active.isChunked {
            actions.append(.logWarningRangeFallback)
        }
        actions.append(contentsOf: [.verifyAndFinalize(usePartialFile: false), .cleanupSidecarFiles, .succeedPromise])
        return (state: .ready, actions: actions)

    // MARK: Chunk success (HTTP 206)
    case (.downloading(let active), .chunkSuccess(let totalChunks)):
        let newCompletedChunks = active.chunkIndex + 1

        if newCompletedChunks >= totalChunks {
            // Last chunk — finalize.
            return (
                state: .ready,
                actions: [
                    .appendChunkAndRecordProgress,
                    .verifyAndFinalize(usePartialFile: true),
                    .cleanupSidecarFiles,
                    .succeedPromise,
                ]
            )
        } else {
            // More chunks to go.
            var updated = active
            updated.chunkIndex = newCompletedChunks
            updated.progress = .zero
            return (
                state: .downloading(updated),
                actions: [
                    .appendChunkAndRecordProgress,
                    .startDownloadTask(chunkIndex: newCompletedChunks, useResumeData: false),
                ]
            )
        }

    // MARK: Download failure
    case (.downloading, .downloadFailure(let hasResumeData)):
        return (
            state: .downloadFailed(FailedDownload(hasResumeData: hasResumeData)),
            actions: [.failPromise]
        )

    // MARK: Invalid transitions
    // Explicitly exhaustive — new states or events must be handled in full.
    // pendingDownload: only attemptDownload is valid
    case (.pendingDownload, .progressUpdate): // not downloading yet
        throw InvalidStateTransitionError(state: state, event: event)
    case (.pendingDownload, .fullDownloadSuccess): // not downloading yet
        throw InvalidStateTransitionError(state: state, event: event)
    case (.pendingDownload, .chunkSuccess): // not downloading yet
        throw InvalidStateTransitionError(state: state, event: event)
    case (.pendingDownload, .downloadFailure): // not downloading yet
        throw InvalidStateTransitionError(state: state, event: event)
    // downloadFailed: only attemptDownload (retry) is valid
    case (.downloadFailed, .progressUpdate): // no active download
        throw InvalidStateTransitionError(state: state, event: event)
    case (.downloadFailed, .fullDownloadSuccess): // no active download
        throw InvalidStateTransitionError(state: state, event: event)
    case (.downloadFailed, .chunkSuccess): // no active download
        throw InvalidStateTransitionError(state: state, event: event)
    case (.downloadFailed, .downloadFailure): // already failed
        throw InvalidStateTransitionError(state: state, event: event)
    // ready: terminal state, no events valid
    case (.ready, .attemptDownload): // already complete
        throw InvalidStateTransitionError(state: state, event: event)
    case (.ready, .progressUpdate): // already complete
        throw InvalidStateTransitionError(state: state, event: event)
    case (.ready, .fullDownloadSuccess): // already complete
        throw InvalidStateTransitionError(state: state, event: event)
    case (.ready, .chunkSuccess): // already complete
        throw InvalidStateTransitionError(state: state, event: event)
    case (.ready, .downloadFailure): // already complete
        throw InvalidStateTransitionError(state: state, event: event)
    // downloading: only attemptDownload is invalid
    case (.downloading, .attemptDownload): // already downloading
        throw InvalidStateTransitionError(state: state, event: event)
    }
}
