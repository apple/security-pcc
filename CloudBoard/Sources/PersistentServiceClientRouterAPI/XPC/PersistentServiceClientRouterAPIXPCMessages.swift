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

internal import CloudBoardAsyncXPC
import CloudBoardDomain
import Foundation

// MARK: - Client-to-server messages (cb_jobhelper → client router)

// exposed as package to make testing simpler

internal enum PersistentServiceClientRouterAPIXPCClientToServerMessages {
    internal struct SendQuery: CloudBoardAsyncXPCByteBufferMessage, Equatable {
        internal typealias Success = ExplicitSuccess
        /// We don't throw errors, failures may be returned as responses asyncronously, or the system
        /// may simply rely on the automatic timeouts that are inherent in the protocol
        internal typealias Failure = Never

        internal let payload: Data
        internal let correlationID: PersistentService.QueryCorrelationID
        internal let timeout: Duration?

        internal init(
            payload: Data,
            correlationID: PersistentService.QueryCorrelationID,
            timeout: Duration?
        ) {
            self.payload = payload
            self.correlationID = correlationID
            self.timeout = timeout
        }

        internal func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
            try self.payload.encode(to: &buffer)
            try self.correlationID.encode(to: &buffer)
            try self.timeout.encode(to: &buffer)
        }

        internal init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
            self.payload = try .init(from: &buffer)
            self.correlationID = try .init(from: &buffer)
            self.timeout = try .init(from: &buffer)
        }
    }

    /// Reports a jobhelper's approval or denial of a persistent service node attestation.
    internal struct NodeApproval: CloudBoardAsyncXPCByteBufferMessage, Equatable {
        internal typealias Success = ExplicitSuccess
        internal typealias Failure = Never

        internal let keyID: Data
        internal let approved: Bool

        internal init(keyID: Data, approved: Bool) {
            self.keyID = keyID
            self.approved = approved
        }

        internal func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
            try self.keyID.encode(to: &buffer)
            try self.approved.encode(to: &buffer)
        }

        internal init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
            self.keyID = try .init(from: &buffer)
            self.approved = try .init(from: &buffer)
        }
    }

    /// Reports whether the jobhelper successfully recorded the REL ("use") entry for a persistent
    /// service node identified by `keyID`. The client router gates *reissuing* a query onto a
    /// replacement connection on `success == true` — it never sends a backup to a node whose REL
    /// entry could not be written. First attempts are not gated (REL is open when the jobhelper
    /// first sends the query).
    internal struct RelUseCommitted: CloudBoardAsyncXPCByteBufferMessage, Equatable {
        internal typealias Success = ExplicitSuccess
        internal typealias Failure = Never

        internal let keyID: Data
        internal let success: Bool

        internal init(keyID: Data, success: Bool) {
            self.keyID = keyID
            self.success = success
        }

        internal func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
            try self.keyID.encode(to: &buffer)
            try self.success.encode(to: &buffer)
        }

        internal init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
            self.keyID = try .init(from: &buffer)
            self.success = try .init(from: &buffer)
        }
    }

    /// Sent by a jobhelper immediately after connecting to register itself with the
    /// router. This triggers attestation replay so the helper can begin the approval
    /// flow before sending its first query.
    internal struct Register: CloudBoardAsyncXPCByteBufferMessage, Equatable {
        internal typealias Success = ExplicitSuccess
        internal typealias Failure = Never

        internal let helperID: UUID

        internal init(helperID: UUID) {
            self.helperID = helperID
        }

        internal func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
            try self.helperID.encode(to: &buffer)
        }

        internal init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
            self.helperID = try .init(from: &buffer)
        }
    }

    /// Sent by a jobhelper during clean shutdown so the router can immediately purge
    /// per-helper state without waiting for the disconnect grace period.
    internal struct HelperExiting: CloudBoardAsyncXPCByteBufferMessage, Equatable {
        internal typealias Success = ExplicitSuccess
        internal typealias Failure = Never

        internal init() {}

        internal func encode(to _: inout CloudBoardAsyncXPC.ByteBuffer) throws {}

        internal init(from _: inout CloudBoardAsyncXPC.ByteBuffer) throws {}
    }
}

// MARK: - Server-to-client specific messages (client router → cb_jobhelper)

internal struct PersistentServiceClientRouterResponseMessage: CloudBoardAsyncXPCByteBufferMessage {
    internal typealias Success = ExplicitSuccess
    internal typealias Failure = Never

    internal let response: PersistentService.Response

    internal init(response: PersistentService.Response) {
        self.response = response
    }

    internal func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        try self.response.encode(to: &buffer)
    }

    internal init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        self.response = try .init(from: &buffer)
    }
}

internal struct PersistentServiceClientRouterAttestationUsageReportMessage: CloudBoardAsyncXPCByteBufferMessage {
    // Fire-and-forget (`connection.post`)
    // The jobhelper's `.nodeApproval(jobHelperID:keyID:approved:)` command
    // (router's JobHelperCommand stream, consumed by
    // JobHelperQuorumInstance.handleNodeApproval) is the authoritative
    // end-to-end ack — a per-XPC ExplicitSuccess reply carries no extra
    // information the router acts on.
    // Many of these can be in flight at once.
    internal typealias Success = Never
    internal typealias Failure = Never

    internal let report: PersistentServiceClientRouter.AttestationUsageReport

    internal init(report: PersistentServiceClientRouter.AttestationUsageReport) {
        self.report = report
    }

    internal func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        try self.report.encode(to: &buffer)
    }

    internal init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        self.report = try .init(from: &buffer)
    }
}
