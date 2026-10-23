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
internal import CloudBoardDomain
import CloudBoardJob
import Foundation
import os

/// This functions as a simple trampoline unless configured differently
struct ProxyApp: NullAppRole {
    static var serviceName: NullAppServiceName { NullAppServiceName.proxyApp }

    private let semantics: PCCRequestSemantics
    private let log: Logger
    private let responderFinished = OSAllocatedUnfairLock(initialState: false)

    init(
        log: Logger,
        semantics: PCCRequestSemantics
    ) {
        self.semantics = semantics
        self.log = log
    }

    func run(
        input: InputData,
        responder: ResponseWriter,
        environment: CloudAppEnvironment,
        spanID: UInt64
    ) async throws {
        let requestID = environment.plaintextMetadata.requestID
        do {
            try await self.oneShotTrampoline(
                input: input,
                responder: responder,
                pccClient: environment.pccClient,
                spanID: spanID,
                requestID: requestID
            )
        } catch {
            self.log.error("""
            requestId=\(requestID, privacy: .public)
            message=NullCloudApp proxy error: \(error, privacy: .public)
            """)
        }
    }

    /// Can function with full request and response bypass - just gets a compute node
    /// then gets out of the way
    private func oneShotTrampoline(
        input: InputData,
        responder: ResponseWriter,
        pccClient: PCCClient,
        spanID: UInt64,
        requestID: String,
    ) async throws {
        try await pccClient
            .makePCCRequest(
                serviceName: self.semantics.serviceName,
                routingParameters: self.semantics.parameters,
                // This app was used as a trampoline initially, so it defaults to bypass
                responseBypass: self.semantics.responseBypass ?? true,
                spanID: spanID
            ) { requestSession in
                self.log.log("""
                request.uuid=\(requestID, privacy: .public)
                workerSession.uuid=\(requestSession.sessionID, privacy: .public)
                worker.buildVersion=\(requestSession.workerInfo.buildVersion, privacy: .public)
                worker.releaseType=\(requestSession.workerInfo.releaseType, privacy: .public)
                worker.releaseDigest=\(requestSession.workerInfo.releaseDigest, privacy: .public)
                worker.ensemble=\(requestSession.workerInfo.ensemble, privacy: .public)
                worker.rack=\(requestSession.workerInfo.rack, privacy: .public)
                message=Established worker session
                """)
                try await withThrowingTaskGroup(of: Void.self) { group in
                    // Forward requests
                    group.addTask { @Sendable in
                        try await self.inputDataIterator(
                            input: input,
                            requestSession: requestSession,
                            responder: responder,
                            requestID: requestID
                        )
                    }

                    // Forward responses
                    group.addTask { @Sendable in
                        try await self.workerResponseStreamIterator(
                            requestSession: requestSession,
                            responder: responder,
                            requestID: requestID
                        )
                    }

                    try await group.waitForAll()
                    let isFinished = self.responderFinished.withLock { $0 }
                    if !isFinished {
                        try responder.finish()
                    }
                }
            }
    }

    private func inputDataIterator(
        input: InputData,
        requestSession: PCCClient.PCCRequestSession,
        responder: ResponseWriter,
        requestID: String
    ) async throws {
        let workerRequestWriter = requestSession.requestWriter

        var firstChunk = true
        for try await data in input {
            self.log.debug("""
            request.uuid=\(requestID, privacy: .public)
            workerSession.uuid=\(requestSession.sessionID, privacy: .public)
            message=NullCloudApp proxy - received request, forwarding \(data.count) bytes
            """)
            try await workerRequestWriter.write(data)

            // Try to decode this as null cloud app input, in case the input asks for specific proxy behaviour
            if firstChunk, let input = try? JSONDecoder().decode(Input.self, from: data),
               input.proxySendCloudAppRequestExecutionError ?? false {
                try await workerRequestWriter.finish()
                await responder.finish(CloudAppRequestExecutionError(
                    errorSource: CloudAppRequestExecutionErrorSource.cloudApp,
                    errorMessage: "ProxyApp reportable error",
                    errorCode: 4000,
                ))
                self.responderFinished.withLock { $0 = true }
                return
            }
            firstChunk = false
        }
        try await workerRequestWriter.finish()
    }

    private func workerResponseStreamIterator(
        requestSession: PCCClient.PCCRequestSession,
        responder: ResponseWriter,
        requestID: String
    ) async throws {
        for try await response in requestSession.responseStream {
            switch response {
            case .payload(let chunk):
                self.log.debug("""
                request.uuid=\(requestID, privacy: .public)
                workerSession.uuid=\(requestSession.sessionID, privacy: .public)
                message=NullCloudApp proxy - received response, forwarding \(chunk.count) bytes
                """)
                try await responder.write(chunk)
            case .result(let result):
                self.log.debug("""
                request.uuid=\(requestID, privacy: .public)
                workerSession.uuid=\(requestSession.sessionID, privacy: .public)
                message=NullCloudApp proxy - received worker result
                status=\(result.status, privacy: .public)
                """)
            @unknown default:
                self.log.fault("""
                request.uuid=\(requestID, privacy: .public)
                workerSession.uuid=\(requestSession.sessionID, privacy: .public)
                message=NullCloudApp proxy - unexpected response type
                """)
            }
        }
        self.log.debug("""
        request.uuid=\(requestID, privacy: .public)
        workerSession.uuid=\(requestSession.sessionID, privacy: .public)
        message=NullCloudApp proxy - finished response stream
        """)
    }
}
