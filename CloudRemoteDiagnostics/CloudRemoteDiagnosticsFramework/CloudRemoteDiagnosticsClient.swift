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
//  CloudRemoteDiagnostics.swift
//  CloudRemoteDiagnosticsFramework
//
//  Created by Marco Magdy on 11/15/23.
//

import Foundation
@preconcurrency import RemoteXPC
import XPCPrivate
import os

private let logger = Logger(subsystem: "cloudremotediagnostics", category: "client")

internal struct SendableWrapper<T>: @unchecked Sendable {
    let value: T
}

@available(macOS 14.0, iOS 17.0, *)
public func createRemoteDiagnosticsClient(device: String) throws -> CloudRemoteDiagnosticsClient {
    guard let rsdDevice = remote_device_copy_device_with_name(device) else {
        throw CloudRemoteDiagnosticsApiError.rsdDeviceNotFound("Failed to find device with the name \(device)")
    }

    if remote_device_get_state(rsdDevice) != REMOTE_DEVICE_STATE_CONNECTED {
        throw CloudRemoteDiagnosticsApiError.rsdDeviceNotConnected("\(device)")
    }

    guard let remoteService = remote_device_copy_service(rsdDevice, "com.apple.acdc.cloudremotediagd") else {
        if errno == ESRCH {
            throw CloudRemoteDiagnosticsApiError.connectionFailed("ESRCH")
        }
        else if errno == EDEVERR {
            throw CloudRemoteDiagnosticsApiError.connectionFailed("EDEVERR")
        }
        else {
            throw CloudRemoteDiagnosticsApiError.connectionFailed("Error: \(errno)")
        }
    }

    let connection = xpc_remote_connection_create_with_remote_service(remoteService, nil, 0)
    let client = CloudRemoteDiagnosticsClient(connection: connection)
    client.connect()
    return client
}

public final class CloudRemoteDiagnosticsClient: Sendable {
    private let connection: xpc_remote_connection_t
    init(connection: xpc_remote_connection_t) {
        self.connection = connection
    }

    deinit {
        xpc_remote_connection_cancel(connection)
    }

    func connect() {
        xpc_remote_connection_set_event_handler(self.connection) { event in
            let _ = xpc_copy_description(event)
        }
        xpc_remote_connection_activate(self.connection)
    }

    private func sendMsgWithCancellation(message: xpc_object_t) async -> SendableWrapper<xpc_object_t> {
        return await withTaskCancellationHandler {
             await withCheckedContinuation { continuation in
                let callback: xpc_handler_t = { reply in
                    // This should be OK to wrap in this unchecked sendable because we do not
                    // mutate the xpc_object in this execution context, and specifically beyond
                    // resuming the continuation.
                    let sendableReply = SendableWrapper(value: reply)
                    continuation.resume(returning: sendableReply)
                }
                xpc_remote_connection_send_message_with_reply(self.connection, message, nil, callback)
            }
        } onCancel: { [connection = self.connection] in
            logger.notice("Task cancelled, cancelling rxpc connection.")
            xpc_remote_connection_cancel(connection)
        }
    }

    private func transferFileWithCancellation(reply: xpc_object_t, filename: String) async -> Bool {
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                xpc_file_transfer_write_to_path(reply, filename) { error in
                    if (error == 0) {
                        logger.info("File transferred successfully. File: \(filename)")
                    }
                    else {
                        logger.error("Failed to transfer file. Error: \(error)")
                    }
                    continuation.resume(returning: error == 0)
                }
            }
        } onCancel: { [connection = self.connection] in
            logger.info("Task cancelled, cancelling rxpc connection.")
            xpc_remote_connection_cancel(connection)
        }
    }


    public func deviceGetProcessStats(samplesPerSecond: UInt64, numberOfSeconds: UInt64) throws -> String {
        let message = xpc_dictionary_create_empty()
        xpc_dictionary_set_string(message, "crd-message-type", String(describing: GetProcessStats.self))
        xpc_dictionary_set_uint64(message, GetProcessStats.numberOfSeconds.rawValue, numberOfSeconds)
        xpc_dictionary_set_uint64(message, GetProcessStats.samplesPerSecond.rawValue, samplesPerSecond)
        let reply = xpc_remote_connection_send_message_with_reply_sync(self.connection, message)
        guard let reply = extractJsonReply(message: reply) else {
            throw CloudRemoteDiagnosticsApiError.invalidXpcReply
        }
        return reply
    }

    public func deviceGetProcessStats(samplesPerSecond: UInt64, numberOfSeconds: UInt64) async throws -> String {
        let message = xpc_dictionary_create_empty()
        xpc_dictionary_set_string(message, "crd-message-type", String(describing: GetProcessStats.self))
        xpc_dictionary_set_uint64(message, GetProcessStats.numberOfSeconds.rawValue, numberOfSeconds)
        xpc_dictionary_set_uint64(message, GetProcessStats.samplesPerSecond.rawValue, samplesPerSecond)
        
        let reply = await self.sendMsgWithCancellation(message: message).value

        guard let reply = extractJsonReply(message: reply) else {
            throw CloudRemoteDiagnosticsApiError.invalidXpcReply
        }
        return reply
    }

    public func sendPing(domain: String, iterations: UInt64) throws -> String {
        let message = xpc_dictionary_create_empty()
        xpc_dictionary_set_string(message, "crd-message-type", String(describing: PingMessage.self))
        xpc_dictionary_set_uint64(message, PingMessage.iterations.rawValue, iterations)
        xpc_dictionary_set_string(message, PingMessage.endpoint.rawValue, domain)
        let reply = xpc_remote_connection_send_message_with_reply_sync(self.connection, message)
        guard let reply = extractJsonReply(message: reply) else {
            throw CloudRemoteDiagnosticsApiError.invalidXpcReply
        }
        return reply
    }

    public func sendPing(domain: String, iterations: UInt64) async throws -> String {
        let message = xpc_dictionary_create_empty()
        xpc_dictionary_set_string(message, "crd-message-type", String(describing: PingMessage.self))
        xpc_dictionary_set_uint64(message, PingMessage.iterations.rawValue, iterations)
        xpc_dictionary_set_string(message, PingMessage.endpoint.rawValue, domain)
        let reply = await self.sendMsgWithCancellation(message: message).value

        guard let reply = extractJsonReply(message: reply) else {
            throw CloudRemoteDiagnosticsApiError.invalidXpcReply
        }

        return reply
    }

    public func tcpdump(interfaceName: String, tcpPortNumber: UInt16, maxPackets: UInt64, timeoutSeconds: UInt64) async throws ->  String {
        let message = xpc_dictionary_create_empty()
        xpc_dictionary_set_string(message, "crd-message-type", String(describing: TcpdumpMessage.self))
        xpc_dictionary_set_string(message, TcpdumpMessage.interfaceName.rawValue, interfaceName)
        xpc_dictionary_set_uint64(message, TcpdumpMessage.tcpPortNumber.rawValue, UInt64(tcpPortNumber))
        xpc_dictionary_set_uint64(message, TcpdumpMessage.maxPackets.rawValue, maxPackets)
        xpc_dictionary_set_uint64(message, TcpdumpMessage.timeoutSeconds.rawValue, timeoutSeconds)
        let reply = await self.sendMsgWithCancellation(message: message).value
        guard let reply = extractXpcObjectReply(message: reply) else {
            throw CloudRemoteDiagnosticsApiError.invalidXpcReply
        }

        let filename = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).path()

        if await self.transferFileWithCancellation(reply: reply, filename: filename) == false {
            throw CloudRemoteDiagnosticsApiError.fileTransferFailed
        }

        return filename
    }

    public func tcpdump(interfaceName: String, filter: String, maxPackets: UInt64, timeoutSeconds: UInt64) async throws ->  String {
        // TODO: rdar://129609347 deprecate and remove this function
        throw CloudRemoteDiagnosticsApiError.notImplemented
    }

    public func spindump(pid: Int?) async throws -> String {
        let message = xpc_dictionary_create_empty()
        xpc_dictionary_set_string(message, "crd-message-type", String(describing: SpindumpMessage.self))
        let pid = pid ?? -1
        xpc_dictionary_set_int64(message, SpindumpMessage.pid.rawValue, Int64(pid))
        let reply = await self.sendMsgWithCancellation(message: message).value

        guard let reply = extractXpcObjectReply(message: reply) else {
            throw CloudRemoteDiagnosticsApiError.invalidXpcReply
        }

        let filename = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).path()

        if await self.transferFileWithCancellation(reply: reply, filename: filename) == false {
            throw CloudRemoteDiagnosticsApiError.fileTransferFailed
        }

        return filename
    }

    public func denaliProtoTrace(sourceIPAddress: String, destinationIPAddress: String, sourcePort: UInt64, destinationPort: UInt64, networkProtocol: String) async throws -> String {
        let message = xpc_dictionary_create_empty()
        xpc_dictionary_set_string(message, "crd-message-type", String(describing: DenaliProtoTraceMessage.self))
        xpc_dictionary_set_string(message, DenaliProtoTraceMessage.sourceIPAddress.rawValue, sourceIPAddress)
        xpc_dictionary_set_string(message, DenaliProtoTraceMessage.destinationIPAddress.rawValue, destinationIPAddress)
        xpc_dictionary_set_uint64(message, DenaliProtoTraceMessage.sourcePortNumber.rawValue, sourcePort)
        xpc_dictionary_set_uint64(message, DenaliProtoTraceMessage.destinationPortNumber.rawValue, destinationPort)
        xpc_dictionary_set_string(message, DenaliProtoTraceMessage.networkProtocol.rawValue, networkProtocol)
        let reply = await self.sendMsgWithCancellation(message: message).value
        guard let reply = extractXpcObjectReply(message: reply) else {
            throw CloudRemoteDiagnosticsApiError.invalidXpcReply
        }

        let filename = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).path()

        if await self.transferFileWithCancellation(reply: reply, filename: filename) == false {
            throw CloudRemoteDiagnosticsApiError.fileTransferFailed
        }

        return filename
    }

    public func getEnsembleStatus() async throws -> String? {
        let message = xpc_dictionary_create_empty()
        xpc_dictionary_set_string(message, "crd-message-type", GetEnsembleStatusMessage)
        let reply = await self.sendMsgWithCancellation(message: message).value

        guard let reply = extractJsonReply(message: reply) else {
            throw CloudRemoteDiagnosticsApiError.invalidXpcReply
        }

        return reply
    }

    public func getEnsembleHealth() async throws -> String? {
        let message = xpc_dictionary_create_empty()
        xpc_dictionary_set_string(message, "crd-message-type", GetEnsembleHealthMessage)
        let reply = await self.sendMsgWithCancellation(message: message).value

        guard let reply = extractJsonReply(message: reply) else {
            throw CloudRemoteDiagnosticsApiError.invalidXpcReply
        }

        return reply
    }

    public func getCloudBoardHealth() async throws -> String {
        let message = xpc_dictionary_create_empty()
        xpc_dictionary_set_string(message, "crd-message-type", GetCloudBoardHealthMessage)
        let reply = await self.sendMsgWithCancellation(message: message).value

        guard let reply = extractJsonReply(message: reply) else {
            throw CloudRemoteDiagnosticsApiError.invalidXpcReply
        }

        return reply
    }

    public func getCloudMetricsHealth() async throws -> String {
        let message = xpc_dictionary_create_empty()
        xpc_dictionary_set_string(message, "crd-message-type", GetCloudMetricsHealthMessage)
        let reply = await self.sendMsgWithCancellation(message: message).value

        guard let reply = extractJsonReply(message: reply) else {
            throw CloudRemoteDiagnosticsApiError.invalidXpcReply
        }

        return reply
    }

    // Remove the following function after updating chassisd to use the async version
    public func getEnsembleStatus(completionHandler: @escaping (String?, CloudRemoteDiagnosticsApiError?) -> Void) {
        let xpcCompletionHandler: xpc_handler_t = { reply in
            guard let reply = extractJsonReply(message: reply) else {
                completionHandler(nil, CloudRemoteDiagnosticsApiError.invalidXpcReply)
                return
            }
            completionHandler(reply, nil)
        }

        let message = xpc_dictionary_create_empty()
        xpc_dictionary_set_string(message, "crd-message-type", GetEnsembleStatusMessage)
        xpc_remote_connection_send_message_with_reply(self.connection, message, nil, xpcCompletionHandler)
    }

    public func getDenaliStatus() async throws -> String {
        let message = xpc_dictionary_create_empty()
        xpc_dictionary_set_string(message, "crd-message-type", GetDenaliStatusMessage)
        let reply = await self.sendMsgWithCancellation(message: message).value

        guard let reply = extractJsonReply(message: reply) else {
            throw CloudRemoteDiagnosticsApiError.invalidXpcReply
        }

        return reply
    }
}

private func checkXPCDictionary(message: xpc_object_t) -> Bool {
    guard xpc_get_type(message) == XPC_TYPE_DICTIONARY else {
        let msgType = String(cString: xpc_type_get_name(xpc_get_type(message)))
        logger.error("Received unexpected message type \(msgType). Message is \(String(describing: message)) Not an XPC Dictionary")
        return false
    }
    return true
}

private func extractJsonReply(message: xpc_object_t ) -> String? {
    guard checkXPCDictionary(message: message) else {
        return nil
    }
    guard let reply = xpc_dictionary_get_string(message, "reply") else {
        return nil
    }
    return String(cString: reply)
}

private func extractXpcObjectReply(message: xpc_object_t ) -> xpc_object_t? {
    guard checkXPCDictionary(message: message) else {
        return nil
    }

    guard let reply = xpc_dictionary_get_value(message, "reply") else {
        return nil
    }
    return reply
}
