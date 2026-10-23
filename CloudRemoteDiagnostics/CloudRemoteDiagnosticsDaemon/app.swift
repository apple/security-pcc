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
//  main.swift
//  CloudRemoteDiagnosticsDaemon
//
//  Created by Marco Magdy on 11/29/23.
//

import CloudRemoteDiagnosticsCore
import OSLog
import RemoteXPC
import XPCPrivate

private let logger = Logger(subsystem: "cloudremotediagd", category: "all")

@main
class CloudRemoteDiagnosticsDaemon {
    static func main() {
        let d = CloudRemoteDiagnosticsDaemon()
        d.listen()
        dispatchMain()
    }

    private let handler: CloudRemoteDiagnosticsHandler
    private let listener: xpc_remote_connection_t
    private let workQueue: DispatchSerialQueue
    private let queue = DispatchQueue(label: "com.apple.cloudRemoteDiagnostics.listenerQueue")
    init() {
        handler = CloudRemoteDiagnosticsHandler()
        workQueue = DispatchSerialQueue(label: "com.apple.cloudRemoteDiagnostics.workSerialQueue")
        self.listener = xpc_remote_connection_create_remote_service_listener(kCloudRemoteDiagnosticsRemoteServiceName, queue, 0)
    }

    func listen() {
        xpc_remote_connection_set_event_handler(listener) { event in
            guard let peer = event as? xpc_remote_connection_t else {
                logger.error("Received xpc object that is not a remote_connection.")
                return
            }

            xpc_remote_connection_set_event_handler(peer) { [weak self] message in
                if (xpc_get_type(message) == XPC_TYPE_ERROR) {
                    let errorString = xpc_dictionary_get_string(message, XPC_ERROR_KEY_DESCRIPTION)
                    let err = errorString.map(String.init(cString:)) ?? ""
                    let descriptionString = xpc_copy_description(message)
                    let desc = String(cString: descriptionString)
                    free(descriptionString)
                    logger.info("Cancelling connection due to error message: \(desc, privacy: .public) : \(err, privacy: .public)")
                    xpc_remote_connection_cancel(peer);
                    return
                }
                guard let messageType: String = getMessageType(message: message) else {
                    // log error unknown message
                    logger.warning("Received unknown xpc message.")
                    return
                }

                guard let this = self else {
                    return
                }

                switch messageType {
                case "GetProcessStats":
                    this.onProcessStatsMessage(message: message)
                case "PingMessage":
                    this.onPingMessage(message: message)
                case "TcpdumpMessage":
                    this.onTcpdump(message: message)
                case "SpindumpMessage":
                    this.onSpindump(message: message)
                case "GetEnsembleStatusMessage":
                    this.onGetEnsembleStatus(message: message)
                case "GetEnsembleHealthMessage":
                    this.onGetEnsembleHealth(message: message)
                case "GetDenaliStatusMessage":
                    this.onGetDenaliStatus(message: message)
                case "DenaliProtoTraceMessage":
                    this.onProtoTrace(message: message)
                case "GetCloudBoardHealthMessage":
                    this.onGetCloudBoardHealth(message: message)
                case "GetCloudMetricsHealthMessage":
                    this.onGetCloudMetricsHealth(message: message)
                default:
                    logger.error("Unhandled message type: \(messageType)")
                    return
                }

            }
            xpc_remote_connection_activate(peer)

        }
        xpc_remote_connection_activate(self.listener)
    }

    private func onProcessStatsMessage(message: xpc_object_t) {
        guard let val = xpc_dictionary_get_value(message, GetProcessStats.samplesPerSecond.rawValue) else {
            return
        }
        let samplesPerSecond = xpc_uint64_get_value(val)

        guard let val = xpc_dictionary_get_value(message, GetProcessStats.numberOfSeconds.rawValue) else {
            return
        }
        let numberOfSeconds = xpc_uint64_get_value(val)

        self.workQueue.async { [weak self] in
            guard let this = self else {
                logger.warning("daemon lifetime has expired; exiting.")
                return
            }
            logger.log("Handling ProcessStats request with samplesPerSecond=\(samplesPerSecond, privacy: .public), numberOfSeconds=\(numberOfSeconds, privacy: .public)")
            let result = this.handler.handleGetProcessStats(samplesPerSecond: samplesPerSecond, durationSeconds: numberOfSeconds)
            sendReply(original: message, reply: result)
        }
    }

    private func onPingMessage(message: xpc_object_t) {
        guard let val = xpc_dictionary_get_value(message, PingMessage.endpoint.rawValue), xpc_get_type(val) == XPC_TYPE_STRING else {
            logger.error("'endpoint' not found in message")
            return
        }

        guard let cstring = xpc_string_get_string_ptr(val) else {
            logger.error("Failed to extract 'endpoint' as a string")
            return
        }
        let endpoint = String(cString: cstring)


        guard let val = xpc_dictionary_get_value(message, PingMessage.iterations.rawValue), xpc_get_type(val) == XPC_TYPE_UINT64 else {
            logger.error("'iterations' not found in message")
            return
        }
        let iterations = xpc_uint64_get_value(val)

        self.workQueue.async { [weak self] in
            guard let this = self else {
                logger.warning("daemon lifetime has expired; exiting.")
                return
            }
            logger.log("Handling ping request with endpoint=\(endpoint, privacy: .public), iterations=\(iterations, privacy: .public)")
            let result = this.handler.handlePing(endpoint: endpoint, iterations: iterations)
            logger.debug("Sending ping reply")
            sendReply(original: message, reply: result)
            logger.debug("Sent a ping reply")
        }
    }

    private func onTcpdump(message: xpc_object_t) {
        guard let val = xpc_dictionary_get_value(message, TcpdumpMessage.interfaceName.rawValue), xpc_get_type(val) == XPC_TYPE_STRING else {
            logger.error("'interfaceName' not found in message")
            return
        }

        guard let cstring = xpc_string_get_string_ptr(val) else {
            logger.error("Failed to extract 'interfaceName' as a string")
            return
        }
        let interfaceName = String(cString: cstring)

        guard let val = xpc_dictionary_get_value(message, TcpdumpMessage.tcpPortNumber.rawValue), xpc_get_type(val) == XPC_TYPE_UINT64 else {
            logger.error("'tcpPortNumber' not found in message")
            return
        }
        let port = xpc_uint64_get_value(val)
        if port > UInt16.max {
            logger.error("Invalid TCP port number: \(port)")
            return
        }
        let tcpPortNumber = UInt16(port)

        guard let val = xpc_dictionary_get_value(message, TcpdumpMessage.maxPackets.rawValue), xpc_get_type(val) == XPC_TYPE_UINT64 else {
            logger.error("'maxPackets' not found in message")
            return
        }
        let maxPackets = xpc_uint64_get_value(val)

        guard let val = xpc_dictionary_get_value(message, TcpdumpMessage.timeoutSeconds.rawValue), xpc_get_type(val) == XPC_TYPE_UINT64 else {
            logger.error("'timeoutSeconds' not found in message")
            return
        }
        let timeoutSeconds = xpc_uint64_get_value(val)

        self.workQueue.async { [weak self] in
            guard let this = self else {
                logger.warning("daemon lifetime has expired; exiting.")
                return
            }
            logger.log("Handling tcpdump request with tcpPortNumber=\(tcpPortNumber, privacy: .public), maxPackets=\(maxPackets, privacy: .public), timeoutSeconds=\(timeoutSeconds, privacy: .public)")
            guard let result = this.handler.handleTcpdump(interfaceName: interfaceName, tcpPortNumber: tcpPortNumber, maxPackets: maxPackets, timeoutSeconds: timeoutSeconds) else {
                return
            }
            guard let replyDict = xpc_dictionary_create_reply(message) else {
                logger.error("Failed to create a reply dictionary.")
                return
            }
            xpc_dictionary_set_value(replyDict, "reply", result)
            xpc_dictionary_send_reply(replyDict)
        }
    }

    private func onSpindump(message: xpc_object_t) {
        guard let val = xpc_dictionary_get_value(message, SpindumpMessage.pid.rawValue), xpc_get_type(val) == XPC_TYPE_INT64 else {
            logger.error("'pid' not found in message")
            return
        }
        let pid = xpc_int64_get_value(val)

        self.workQueue.async { [weak self] in
            guard let this = self else {
                logger.warning("daemon lifetime has expired; exiting.")
                return
            }

            guard let replyDict = xpc_dictionary_create_reply(message) else {
                logger.error("Failed to create a reply dictionary.")
                return
            }

            logger.log("Handling spindump request for pid=\(pid, privacy: .public)")
            switch this.handler.handleSpindump(pid: pid) {
            case .success(let result):
                xpc_dictionary_set_value(replyDict, "reply", result)
            case .throttled:
                xpc_dictionary_set_string(replyDict, "reply", "throttled")
            case .failure:
                xpc_dictionary_set_string(replyDict, "reply", "failed")
            }
            xpc_dictionary_send_reply(replyDict)
        }
    }

    private func onGetEnsembleStatus(message: xpc_object_t) {
        self.workQueue.async { [weak self] in
            guard let this = self else {
                logger.warning("daemon lifetime has expired; exiting.")
                return
            }

            logger.log("Handling ensemble status request")
            let result = this.handler.handleGetEnsembleStatus()
            sendReply(original: message, reply: result)
        }
    }

    private func onGetEnsembleHealth(message: xpc_object_t) {
        self.workQueue.async { [weak self] in
            guard let this = self else {
                logger.warning("daemon lifetime has expired; exiting.")
                return
            }

            logger.log("Handling ensemble health request")
            let result = this.handler.handleGetEnsembleHealth()
            sendReply(original: message, reply: result)
        }
    }

    private func onGetDenaliStatus(message: xpc_object_t) {
        self.workQueue.async { [weak self] in
            guard let this = self else {
                logger.warning("daemon lifetime has expired; exiting.")
                return
            }

            logger.log("Handling denali status request")
            let result = this.handler.handleGetDenaliStatus()
            sendReply(original: message, reply: result)
        }
    }

    private func onGetCloudBoardHealth(message: xpc_object_t) {
        logger.log("Handling CloudBoard health request")
        self.handler.handleGetCloudBoardHealth(
            queue: self.workQueue) { result in
            sendReply(original: message, reply: result)
        }
    }

    private func onGetCloudMetricsHealth(message: xpc_object_t) {
        logger.log("Handling CloudMetrics health request")
        self.handler.handleGetCloudMetricsHealth(queue: self.workQueue) 
        { result in
            sendReply(original: message, reply: result)
        }
    }

    private func onProtoTrace(message: xpc_object_t) {
        // Read sourceIPAddress as a string
        guard let val = xpc_dictionary_get_value(message, DenaliProtoTraceMessage.sourceIPAddress.rawValue), xpc_get_type(val) == XPC_TYPE_STRING else {
            logger.error("'sourceIPAddress' not found in message")
            return
        }

        guard let cstring = xpc_string_get_string_ptr(val) else {
            logger.error("Failed to extract 'sourceIPAddress' as a string")
            return
        }
        let sourceIPAddress = String(cString: cstring)

        // Read destinationIPAddress as a string
        guard let val = xpc_dictionary_get_value(message, DenaliProtoTraceMessage.destinationIPAddress.rawValue), xpc_get_type(val) == XPC_TYPE_STRING else {
            logger.error("'destinationIPAddress' not found in message")
            return
        }

        guard let cstring = xpc_string_get_string_ptr(val) else {
            logger.error("Failed to extract 'destinationIPAddress' as a string")
            return
        }
        let destinationIPAddress = String(cString: cstring)

        // Read sourcePort as a UInt64
        guard let val = xpc_dictionary_get_value(message, DenaliProtoTraceMessage.sourcePortNumber.rawValue), xpc_get_type(val) == XPC_TYPE_UINT64 else {
            logger.error("'sourcePortNumber' not found in message")
            return
        }
        var port = xpc_uint64_get_value(val)
        let sourcePort = UInt16(port)

        // Read destinationPort as a UInt64
        guard let val = xpc_dictionary_get_value(message, DenaliProtoTraceMessage.destinationPortNumber.rawValue), xpc_get_type(val) == XPC_TYPE_UINT64 else {
            logger.error("'DestinationPort' not found in message")
            return
        }
        port = xpc_uint64_get_value(val)
        let destinationPort = UInt16(port)

        // Read networkProtocol as a string
        guard let val = xpc_dictionary_get_value(message, DenaliProtoTraceMessage.networkProtocol.rawValue), xpc_get_type(val) == XPC_TYPE_STRING else {
            logger.error("'networkProtocol' not found in message")
            return
        }
        guard let cstring = xpc_string_get_string_ptr(val) else {
            logger.error("Failed to extract 'networkProtocol' as a string")
            return
        }
        let networkProtocol = String(cString: cstring)

        self.workQueue.async { [weak self] in
            guard let this = self else {
                logger.warning("daemon lifetime has expired; exiting.")
                return
            }

            logger.log("""
Handling proto trace request with sourceIPAddress=\(sourceIPAddress, privacy: .public),
"destinationIPAddress=\(destinationIPAddress, privacy: .public), sourcePort=\(sourcePort, privacy: .public),
"destinationPort=\(destinationPort, privacy: .public)
""")

            let result = this.handler.handleDenaliProtoTrace(sourceIPAddress: sourceIPAddress,
                                                             destinationIPAddress: destinationIPAddress,
                                                             networkProtocol: networkProtocol,
                                                             sourcePort: sourcePort,
                                                             destinationPort: destinationPort)

            guard let result = result else {
                // errors are logged in the handler
                return
            }

            guard let replyDict = xpc_dictionary_create_reply(message) else {
                logger.error("Failed to create a reply dictionary.")
                return
            }
            xpc_dictionary_set_value(replyDict, "reply", result)
            xpc_dictionary_send_reply(replyDict)
        }
    }
}

private func sendReply(original: xpc_object_t, reply: String) {
    guard let replyDict = xpc_dictionary_create_reply(original) else {
        logger.error("Failed to create a reply dictionary.")
        return
    }
    xpc_dictionary_set_string(replyDict, "reply", reply)
    xpc_dictionary_send_reply(replyDict)
}

private func getMessageType(message: xpc_object_t) -> String? {
    guard xpc_get_type(message) == XPC_TYPE_DICTIONARY else {
        return nil
    }
    guard let msgType = xpc_dictionary_get_string(message, "crd-message-type") else {
        return nil
    }
    return String(cString: msgType)
}
