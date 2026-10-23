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
import CloudBoardJob
import Foundation
import os

/// Proxy app that emulates the split FT/ET request behavior
struct MultiNodeProxyApp: NullAppRole {
    static var serviceName: NullAppServiceName { NullAppServiceName.multiNodeProxyApp }
    private let log: Logger
    private let useResponseBypass: Bool
    private let semantics: PCCRequestSemantics

    init(
        log: Logger,
        semantics: PCCRequestSemantics
    ) {
        self.log = log
        self.useResponseBypass = semantics.responseBypass ?? true
        self.semantics = semantics
    }

    func run(
        input: InputData,
        responder: ResponseWriter,
        environment: CloudAppEnvironment,
        spanID: UInt64
    ) async throws {
        let requestID = environment.plaintextMetadata.requestID
        let useRequestBypass = environment.requestBypassed
        self.log.info("""
        Starting split FT/ET request bypass flow for request \(requestID)
        useRequestBypass: \(useRequestBypass)
        useResponseBypass: \(self.useResponseBypass)
        """)

        // Handle FT compute node request
        self.log.info("Requesting FT ensemble")
        var ftParameters = environment.plaintextMetadata.workloadParameters
        ftParameters["runMode"] = ["ft"]
        // We shouldn't forward proxy parameters to FT compute node
        ftParameters.removeValue(forKey: "nullapp-proxy-mode")

        try await environment.pccClient.makePCCRequest(
            serviceName: self.semantics.serviceName,
            routingParameters: ftParameters,
            spanID: spanID,
            groupID: "ftet-group-id"
        ) { ftRequestSession in
            let workerRequestWriter = ftRequestSession.requestWriter
            let workerResponseStream = ftRequestSession.responseStream

            // Stream to trigger ET flow once FT response has been received
            let (etRequestStream, etRequestStreamContinuation) = AsyncStream<Data>.makeStream()

            try await withThrowingTaskGroup(of: Void.self) { group in
                // Forward requests to FT compute node
                group.addTask {
                    if !useRequestBypass {
                        self.log.info("No Request bypass. Handling request for FT.")
                        try await self.handleInput(
                            input,
                            forwardTo: workerRequestWriter
                        )
                    } else {
                        self.log.info("Request bypassed for FT worker.")
                        try await workerRequestWriter.finish()
                    }
                }

                // Handle FT response and prepare ET input
                group.addTask {
                    try await self.handleFTResponse(
                        readFrom: workerResponseStream,
                        forwardTo: etRequestStreamContinuation
                    )
                }

                // Handle ET compute node request
                group.addTask {
                    try await self.handleET(
                        environment: environment,
                        useResponseBypass: self.useResponseBypass,
                        etRequestStream,
                        spanID: spanID
                    ) { chunk in
                        try await responder.write(chunk)
                    }
                }

                try await group.waitForAll()
                self.log.info("Completed split FT/ET proxy request handling")
            }
        }
        try responder.finish()
    }

    // MARK: - Private Helper Methods

    private func handleInput(
        _ input: InputData,
        forwardTo workerRequestWriter: PCCClient.PCCRequestSession.RequestWriter
    ) async throws {
        for try await data in input {
            self.log.debug("Received client request. Forwarding to FT.")
            try await workerRequestWriter.write(data)
        }
        try await workerRequestWriter.finish()
    }

    private func handleFTResponse(
        readFrom ftResponseStream: PCCClient.PCCRequestSession.ResponseData,
        forwardTo etRequestStreamContinuation: AsyncStream<Data>.Continuation
    ) async throws {
        var ftResponseReceived = false
        for try await response in ftResponseStream {
            switch response {
            case .payload(let ftResponsePayload):
                if ftResponseReceived {
                    self.log.debug("Received additional FT payload chunk. Ignoring.")
                    continue
                }

                self.log.info("FT processing completed, forwarding result to ET")
                ftResponseReceived = true
                // Forward FT response as input to ET
                etRequestStreamContinuation.yield(ftResponsePayload)
            case .result(let result) where result.status == .ok:
                self.log.info("Received FT compute node success result: status=\(result.status)")
            case .result(let result):
                self.log.error("Received FT compute node error result: status=\(result.status)")
                throw MultiNodeProxyError.ftWorkerFailed
            @unknown default:
                self.log.warning("Unexpected FT response type: \(String(describing: response))")
            }
        }
        etRequestStreamContinuation.finish()
        self.log.info("Finished FT response stream")
    }

    private func handleET(
        environment: CloudAppEnvironment,
        useResponseBypass: Bool,
        _ etRequestStream: AsyncStream<Data>,
        spanID: UInt64,
        chunkHandler: @escaping @Sendable (Data) async throws -> Void
    ) async throws {
        self.log.debug("Waiting for FT response to forward to ET")

        var etRequestIterator = etRequestStream.makeAsyncIterator()
        guard let etRequest = await etRequestIterator.next() else {
            self.log.error("Did not receive FT response (ET request)")
            throw MultiNodeProxyError.missingETRequest
        }

        self.log.info("Received FT response, forwarding as request to ET")

        let serviceName = environment.plaintextMetadata.workloadType
        var etParameters = environment.plaintextMetadata.workloadParameters
        etParameters["runMode"] = ["et"]
        // We shouldn't forward proxy parameters to ET compute node
        etParameters.removeValue(forKey: "nullapp-proxy-mode")

        self.log.info("""
        Requesting ET ensemble:
        serviceName=\(serviceName) 
        routingParameters=\(etParameters)
        responseBypass=\(useResponseBypass)
        """)

        try await environment.pccClient.makePCCRequest(
            serviceName: serviceName,
            routingParameters: etParameters,
            responseBypass: useResponseBypass,
            spanID: spanID,
            groupID: "ftet-group-id"
        ) { [chunkHandler] etRequestSession in
            let workerRequestWriter = etRequestSession.requestWriter
            let workerResponseStream = etRequestSession.responseStream

            self.log.debug("Sending ET Request")
            try await workerRequestWriter.write(etRequest)
            try await workerRequestWriter.finish()

            for try await response in workerResponseStream {
                switch response {
                case .payload(let chunk):
                    self.log.debug("Received ET response chunk")
                    try await chunkHandler(chunk)
                case .result(let result) where result.status == .ok:
                    self.log.info("Received ET worker success result: status=\(result.status)")
                case .result(let result):
                    self.log.error("Received ET worker error result: status=\(result.status)")
                    throw MultiNodeProxyError.etWorkerFailed
                @unknown default:
                    self.log.warning("""
                    Unexpected ET response type: \(String(describing: response))
                    """)
                }
            }
            self.log.debug("Finished ET response stream")
        }
    }
}

enum MultiNodeProxyError: Swift.Error {
    case ftWorkerFailed
    case etWorkerFailed
    case missingETRequest
}
