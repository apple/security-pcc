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

//
//  Client+Data.swift
//  AppleComputeEnsembler
//
//  Created by Dhanasekar Thangavel on 4/8/26.
//
import Foundation
import Network
import OSLog
import Security_Private
import Security_Private.SecCertificateRequest
import Security_Private.SecIdentityPriv
@_spi(Daemon) import AppleComputeEnsembler

private let logger = Logger(subsystem: kEnsemblerPrefix, category: "TLSChannelDataClient")

// functions specifically for data messaging.
extension ClientImpl {
    
    // send message and wait for response data from the server
    public func sendAndWaitForResponse(
        appID: String,
        data: Data,
        currentNode: Int,
        timeout: TimeInterval = 2.0,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        do {

            let messageID = UUID()
            // callbackTimeout gives the follower's app callback 80% of the total timeout,
            // leaving headroom for the response to travel back across the TLS wire.
            let callbackTimeout = timeout * 0.8
            let msg = EnsembleControlMessage.dataMessageRequest(
                appID: appID,
                data: data,
                requestID: messageID,
                callbackTimeout: callbackTimeout
            )
            let msgData = try JSONEncoder().encode(msg)
            let controlData = EnsembleControlData(rank: currentNode, data: msgData)

            let encoder = JSONEncoder()
            let data = try encoder.encode(controlData)
            var lengthPrefix = UInt32(data.count).bigEndian
            let lengthData = Data(bytes: &lengthPrefix, count: 4)

            var messageData = Data()
            messageData.append(lengthData)
            messageData.append(data)

            self.attemptSendForResponse(
                appID: appID,
                messageID: messageID,
                messageData: messageData,
                controlData: msgData,
                rank: currentNode,
                timeout: timeout,
                completion: completion
            )


        } catch {
            logger.error("sendAndWaitForResponse: error sending message \(error, privacy: .public)")
            completion(.failure(error))
        }
    }

    func handleResponseError(messageID: String, error: Error) {
        // Capture the completion handler inside the lock, then invoke it outside.
        // Calling completions inside the lock extends hold time and blocks concurrent
        // response/timeout handlers that also need the lock.
        let completion: ((Result<Data, Error>) -> Void)? = pendingCompletionLock.sync {
            if let timeout = pendingTimeouts[messageID] {
                timeout.cancel()
                pendingTimeouts[messageID] = nil
            }
            pendingAppIDs[messageID] = nil
            defer { pendingCompletion[messageID] = nil }
            return pendingCompletion[messageID]
        }
        if let completion {
            completion(.failure(error))
        } else {
            logger.warning(
                "ClientImpl.handleResponseError: completion already consumed for messageID \(messageID, privacy: .public), dropping error: \(error, privacy: .public)"
            )
        }
    }

    func handleResponse(messageID: String, message: Data) {
        // Capture the completion handler inside the lock, then invoke it outside.
        // Calling completions inside the lock extends hold time and blocks concurrent
        // response/timeout handlers that also need the lock.
        let completion: ((Result<Data, Error>) -> Void)? = pendingCompletionLock.sync {
            if let timeout = pendingTimeouts[messageID] {
                timeout.cancel()
                pendingTimeouts[messageID] = nil
            }
            pendingAppIDs[messageID] = nil
            defer { pendingCompletion[messageID] = nil }
            return pendingCompletion[messageID]
        }
        if let completion {
            completion(.success(message))
        } else {
            logger.warning(
                "ClientImpl.handleResponse: response arrived for messageID \(messageID, privacy: .public) but timeout already fired — discarding late response"
            )
        }
    }
    
    private func attemptSendForResponse(appID: String,
                                        messageID: UUID,
                                        messageData: Data,
                                        controlData: Data,
                                        rank: Int,
                                        timeout: TimeInterval,
                                        completion: @escaping (Result<Data, Error>) -> Void) {

        logger.debug("Client.attemptSendForResponse: Sending message to \(appID, privacy: .public) and waiting for response")

        guard self.state == .ready else {
            logger.error(
                "Client.attemptSendForResponse: connection to rank \(self.target, privacy: .public) not ready, dropping send for appID: \(appID, privacy: .public) messageID: \(messageID, privacy: .public)"
            )
            let error = ClientError
                .ClientError(
                    message: "Cannot send data to \(appID), since connection to \(self.target) is not in ready state."
                )
            completion(.failure(error))
            return
        }

        // Set up timeout work item
        let timeoutItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            logger.error(
                "Client: response timeout fired for appID: \(appID, privacy: .public) messageID: \(messageID.uuidString, privacy: .public) rank: \(self.target, privacy: .public)"
            )
            self.handleResponseError(
                messageID: messageID.uuidString,
                error: DataMessageError.noResponseReceived(appID: appID)
            )
        }

        // Register the completion handler, timeout item, and appID under the lock
        pendingCompletionLock.sync {
            logger.debug("Client.attemptSendForResponse: saving completion handler for appID: \(appID, privacy: .public) messageID: \(messageID.uuidString)")
            pendingCompletion[messageID.uuidString] = completion
            pendingTimeouts[messageID.uuidString] = timeoutItem
            pendingAppIDs[messageID.uuidString] = appID
        }

        // Schedule the timeout
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

        // we send the message to the destination. The receive loop will parse any incoming responses and based on
        // the messageID, it will call the appropriate completion handler.
        self.connection?.send(content: messageData, completion: .contentProcessed { [weak self] error in
            guard let self = self else { return }

            if let error {
                logger.error("Client.attemptSendForResponse: error sending message for appID \(appID, privacy:.public), error: \(error, privacy: .public)")
                // Cancel timeout since we're handling the error now
                self.handleResponseError(messageID: messageID.uuidString, error: error)
                return
            }
            // Message sent successfully - timeout will handle if no response arrives
         })
    }
    
    public func startReceiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: MTU) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            // we received some data, process it to see if we got a response.
            if let data = data {
                self.parsingQueue.async { [weak self] in
                    guard let self else { return }
                    self.recieveBuffer.append(data)
                    self.processBuffer()
                }
            }

            if error == nil && !isComplete {
                self.startReceiveLoop()   // continue reading
            } else {
                let pendingCount = self.pendingCompletionLock.sync { self.pendingCompletion.count }
                logger.error(
                    "ClientImpl.startReceiveLoop: receive loop terminated on rank \(self.target, privacy: .public) — error: \(String(describing: error), privacy: .public), isComplete: \(isComplete, privacy: .public). Pending completions: \(pendingCount, privacy: .public)"
                )
                if pendingCount > 0 {
                    let terminationError: Error
                    if let error {
                        terminationError = error
                    } else {
                        terminationError = ClientError.ClientError(message: "Connection closed")
                    }
                    let messageIDs = self.pendingCompletionLock.sync { Array(self.pendingCompletion.keys) }
                    for id in messageIDs {
                        self.handleResponseError(messageID: id, error: terminationError)
                    }
                }
            }
        }
    }
    
    func readUInt32BE(from data: Data) -> UInt32 {
        var value: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &value) { dst in
            data.copyBytes(to: dst)
        }
        return UInt32(bigEndian: value)
    }
    
    func peekLength() -> UInt32 {
        return recieveBuffer.withUnsafeBytes { ptr in
            ptr.load(as: UInt32.self).bigEndian
        }
    }

    func readMessage(length: Int) -> Data {
        let msg = recieveBuffer.prefix(length)
        recieveBuffer.removeFirst(length)
        return msg
    }

    func processBuffer() {
        while recieveBuffer.count >= 4 {
            let length = readUInt32BE(from: recieveBuffer.prefix(4))

            // Now make sure we got enough length to read.
            guard recieveBuffer.count >= Int(length) + 4 else {
                return
            }

            guard length > 0 && length <= MTU else {
                logger.error("processBuffer: Invalid message length: \(length). Discarding corrupt data.")
                // Remove the corrupt length prefix to prevent infinite loop
                recieveBuffer.removeFirst(4)
                continue
            }

            // First remove the length prefix.
            recieveBuffer.removeFirst(4)
            let messageData = readMessage(length: Int(length))

            // Now decode the actual control message (server sends raw EnsembleControlMessage)
            do {
                let controlMsg = try EnsembleControlMessage.decode(from: messageData)
                switch controlMsg {
                case .dataMessageResponse(let appID, let data, let requestID):
                    // Dispatch completion off parsingQueue so the buffer loop can continue
                    // processing the next message immediately, rather than serialising the
                    // entire continuation-resume + XPC-reply chain for all 50 responses.
                    let msgID = requestID.uuidString
                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        self?.handleResponse(messageID: msgID, message: data)
                    }

                case .dataMessageError(let error, let requestID):
                    logger.error("processBuffer: Received data error for requestID: \(requestID), error: \(error, privacy: .public)")
                    let msgID = requestID.uuidString
                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        self?.handleResponseError(messageID: msgID, error: error)
                    }

                // For other failure cases we dont have requestID, so we let the timer expire and caller will get failure based on timeout.

                default:
                    logger.warning("processBuffer: Got a different message other than response or acknowledge")
                }
            } catch {
                logger.warning("processBuffer: Control message decoding failed: \(error, privacy: .public)")
            }
            // Loop continues to process any further messages coalesced in the buffer.
        }
    }
}
