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

import CAppleArchive
import Synchronization

#if canImport(System)
import System
#else
import SystemPackage
#endif

package enum ArchiveError: Error, ReportableError {
    case ioError

    package var reportableDescription: String {
        switch self {
        case .ioError:
            return "Archive I/O error"
        }
    }
}

// MARK: - Callback type aliases

typealias AEAContextCallback = @Sendable (__AEAContext) -> Int32
typealias AEAEntryMessageCallback =
    @Sendable (__AAEntryMessage, UnsafePointer<CChar>, UnsafeMutableRawPointer?) -> Int32
typealias AEAProgressCallback = @Sendable (Float) -> Int32

// MARK: - AEAAsyncDecryptionStream

/// Wraps the C `__AAAsyncByteStream` returned by `__AEADecryptAndExtractChunkAsyncStreamOpen`,
/// keeping callback closures alive for the lifetime of the stream.
///
/// This replaces the buggy `decryptAndExtractAsyncStreamOpen` method in AppleArchiveSwift,
/// which passes an unretained `CommonCallbackWrapper` to the C API. That wrapper goes out
/// of scope immediately, leaving the C library with a dangling pointer.
///
/// Instead, we:
/// 1. Store callbacks as properties on this class.
/// 2. Pass a *retained* `Unmanaged` reference to the C API.
/// 3. Use static trampoline functions that recover `self` via `takeUnretainedValue()`.
/// 4. Release the retained reference in `close()`.
final class AEAAsyncDecryptionStream: Sendable {
    /// Mutable state protected by a Mutex.
    /// `stream` is nil after `close()` has been called.
    private struct State: @unchecked Sendable {
        var stream: __AAAsyncByteStream?
        var retainedSelf: UnsafeMutableRawPointer?
    }

    private let state: Mutex<State>

    // Callbacks stored as properties so they stay alive for the C library.
    private let contextCallback: AEAContextCallback?
    private let entryMessageCallback: AEAEntryMessageCallback?
    private let progressCallback: AEAProgressCallback?

    /// Creates and opens an async decryption stream.
    ///
    /// Uses a static helper to create the C stream before `self` exists,
    /// then stores the result. The retained `Unmanaged` reference to `self`
    /// is created after all stored properties are initialized.
    init(
        extractTo path: FilePath,
        chunkSize: Int = 0,
        allocLimit: Int = 0,
        threadCount: Int = 0,
        skipPaddingCheck: Bool = false,
        contextCallback: AEAContextCallback? = nil,
        entryMessageCallback: AEAEntryMessageCallback? = nil,
        progressCallback: AEAProgressCallback? = nil
    ) throws {
        self.contextCallback = contextCallback
        self.entryMessageCallback = entryMessageCallback
        self.progressCallback = progressCallback

        // Create the C stream using a temporary opaque pointer (nil for now).
        // We pass nil as the callback context initially, then fix it up below.
        // Actually, we can't do that — the C API may invoke callbacks during open.
        //
        // Instead, we use a two-step approach:
        // 1. Initialize state with an empty State (no stream yet).
        // 2. After self is fully initialized, create the retained pointer and C stream.
        // 3. Store the stream into the mutex.
        self.state = Mutex(State())

        // Now self is fully initialized, so Unmanaged.passRetained(self) is safe.
        let retained = Unmanaged.passRetained(self).toOpaque()

        let flags: UInt64 =
            skipPaddingCheck ? __AA_FLAG_ENCRYPTED_STREAM_NO_PADDING_CHECK.rawValue : 0

        let maybeStream: __AAAsyncByteStream? = path.withCString { cPath in
            __AEADecryptAndExtractChunkAsyncStreamOpen(
                cPath,
                nil,
                retained,
                Self.cContextCallback(contextCallback),
                Self.cEntryMessage(entryMessageCallback),
                Self.cProgressCallback(progressCallback),
                chunkSize,
                allocLimit,
                flags,
                Int32(threadCount)
            )
        }

        guard let stream = maybeStream else {
            // Release the retained reference on failure since close() won't be called.
            Unmanaged<AEAAsyncDecryptionStream>.fromOpaque(retained).release()
            throw ArchiveError.ioError
        }

        // Store into the mutex. This is safe because init is single-threaded —
        // no other thread can access state yet.
        let initialState = State(stream: stream, retainedSelf: retained)
        state.withLock { state in
            state = initialState
        }
    }

    // MARK: - Static trampoline functions

    /// Handles the context callback by recovering `self` from the opaque pointer.
    /// Returns `-1` if `arg` is nil.
    static func handleContextCallback(
        arg: UnsafeMutableRawPointer?,
        context: __AEAContext
    ) -> Int32 {
        guard let arg else { return -1 }
        let wrapper = Unmanaged<AEAAsyncDecryptionStream>.fromOpaque(arg).takeUnretainedValue()
        return wrapper.contextCallback!(context)
    }

    /// Handles the entry message callback by recovering `self` from the opaque pointer.
    /// Returns `-1` if `arg` is nil.
    static func handleEntryMessageCallback(
        arg: UnsafeMutableRawPointer?,
        message: __AAEntryMessage,
        path: UnsafePointer<CChar>,
        data: UnsafeMutableRawPointer?
    ) -> Int32 {
        guard let arg else { return -1 }
        let wrapper = Unmanaged<AEAAsyncDecryptionStream>.fromOpaque(arg).takeUnretainedValue()
        return wrapper.entryMessageCallback!(message, path, data)
    }

    /// Handles the progress callback by recovering `self` from the opaque pointer.
    /// Returns `-1` if `arg` is nil.
    static func handleProgressCallback(
        arg: UnsafeMutableRawPointer?,
        percent: Float
    ) -> Int32 {
        guard let arg else { return -1 }
        let wrapper = Unmanaged<AEAAsyncDecryptionStream>.fromOpaque(arg).takeUnretainedValue()
        return wrapper.progressCallback!(percent)
    }

    /// Returns a C function pointer for the context callback, or nil if the callback is nil.
    private static func cContextCallback(
        _ callback: AEAContextCallback?
    ) -> __AEADecryptAsyncContextProc? {
        guard callback != nil else { return nil }
        return { AEAAsyncDecryptionStream.handleContextCallback(arg: $0, context: $1) }
    }

    /// Returns a C function pointer for the entry message callback, or nil if the callback is nil.
    private static func cEntryMessage(
        _ callback: AEAEntryMessageCallback?
    ) -> __AAEntryMessageProc? {
        guard callback != nil else { return nil }
        return { AEAAsyncDecryptionStream.handleEntryMessageCallback(arg: $0, message: $1, path: $2, data: $3) }
    }

    /// Returns a C function pointer for the progress callback, or nil if the callback is nil.
    private static func cProgressCallback(
        _ callback: AEAProgressCallback?
    ) -> __AEADecryptProgressProc? {
        guard callback != nil else { return nil }
        return { AEAAsyncDecryptionStream.handleProgressCallback(arg: $0, percent: $1) }
    }

    // MARK: - Stream operations

    /// Asks the C library what byte range it needs next.
    ///
    /// - Returns: A tuple of (rc, nbyte, offset) where:
    ///   - rc < 0: error
    ///   - rc == 0, nbyte == 0: busy, drain results and retry
    ///   - rc == 1, nbyte == 0: done
    ///   - rc == 1, nbyte > 0: fetch bytes at offset
    func getRange() -> (rc: Int32, nbyte: size_t, offset: off_t) {
        let stream = state.withLock { $0.stream! }
        var nbyte: size_t = 0
        var offset: off_t = 0
        let rc = __AAAsyncByteStreamGetRange(stream, &nbyte, &offset)
        return (rc, nbyte, offset)
    }

    /// Feeds downloaded data back to the C library for decryption/extraction.
    func process(data: UnsafeMutableRawPointer, count: Int, offset: off_t) -> Int32 {
        let stream = state.withLock { $0.stream! }
        return __AAAsyncByteStreamProcess(stream, data, count, offset)
    }

    /// Cancels the async byte stream.
    func cancel() {
        let stream = state.withLock { $0.stream! }
        __AAAsyncByteStreamCancel(stream)
    }

    /// Closes the async byte stream and releases the retained reference to self.
    ///
    /// - Returns: The close result code (< 0 on error).
    @discardableResult
    func close() -> Int32 {
        let (stream, retained) = state.withLock { state -> (__AAAsyncByteStream?, UnsafeMutableRawPointer?) in
            guard let s = state.stream else { return (nil, nil) }
            state.stream = nil
            let r = state.retainedSelf
            state.retainedSelf = nil
            return (s, r)
        }

        guard let stream else { return 0 }

        let rc = __AAAsyncByteStreamClose(stream)

        // Release the retained reference that was created in init.
        if let retained {
            Unmanaged<AEAAsyncDecryptionStream>.fromOpaque(retained).release()
        }

        return rc
    }

    deinit {
        let stream = state.withLock { $0.stream }
        if let stream {
            // Don't release retainedSelf here — if deinit is running, the retain count
            // is already going to zero. Releasing again would over-release.
            _ = __AAAsyncByteStreamClose(stream)
        }
    }
}
