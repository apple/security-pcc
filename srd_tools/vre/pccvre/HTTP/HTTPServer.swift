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

// Copyright © 2025 Apple, Inc. All rights reserved.

@_spi(HTTP) @_spi(CTypeConversion) @_spi(NWConnection) @_spi(nw_http_encoding_type_t) import Network
import Network_Private
import os
import Synchronization
import System

/// A simple HTTP server that accepts requests to serve cryptexes from a given
/// root access directory.
///
/// This HTTP server is thread-safe, but its useful lifecycle begins at the
/// first call to ``HTTPServer/start(_:accessPath:)`` and ends at the first call
/// to ``HTTPServer/shutdown()``. After shutting down, any further requests to
/// the server will be rejected by the operating system.
final class HTTPServer: Sendable {
    static let logger = os.Logger(subsystem: "com.apple.vre.HTTPServer", category: "HTTPServer")
    
    // The interface (either virtual NAT or physical network) that this server's
    // address is derived from.
    private let interface: any HTTPServer.Interface
    // The network listener for this server.
    private let listener: NWListener
    // The live connections that are being processed by server.
    //
    // Keeping track of connections enables this server to destroy
    // connection objects in a timely fashion on `shutdown`, but is otherwise
    // not required. `NWConnection` objects retain themselves throughout their
    // useful lifecycle and release themselves when the underlying connection
    // fails or is cancelled. Care must be taken to call
    // ``HTTPServer/cancelConnection`` instead of ``NWConnection/cancel`` to
    // ensure we don't accumulate zombie connections in this map.
    private let connections: Mutex<[UInt64: NWConnection]>

    private init(interface: any HTTPServer.Interface, listener: NWListener) {
        self.interface = interface
        self.listener = listener
        self.connections = Mutex([:])
    }
}

extension HTTPServer {
    /// Starts a server instance with the given configuration rooted at the
    /// given access path.
    ///
    /// If allocating an endpoint from the values in the configuration fails, or
    /// if the operating system is unable to successfully configure a listener
    /// for the values in the configuration, this method may throw either
    /// ``VirtualInterface/Error`` or `NWError` values.
    ///
    /// - Parameters:
    ///   - configuration: The configuration to apply to the created server.
    ///   - accessPath: The file system path acting as the root directory for
    ///                 file requests made to this server.
    /// - Throws: ``VirtualInterface/Error`` or `NWError` values as appropriate.
    /// - Returns: A configured HTTP server instance.
    static func start(
        _ configuration: HTTPServer.Configuration,
        accessPath: FilePath
    ) async throws -> HTTPServer {
        let interface: any HTTPServer.Interface = switch configuration {
        case .virtual(let virtual):
            try await VirtualInterface(configuration: virtual)
        case .network(let network):
            NetworkInterface(configuration: network)
        }
        
        let tcpOptions = NWProtocolTCP.Options()
        let params = NWParameters(tls: nil, tcp: tcpOptions)
        params.requiredLocalEndpoint = .hostPort(host: interface.host, port: configuration.port)

        // Allow multiple connections to use the same local address and port
        // (SO_REUSEADDR and SO_REUSEPORT).
        nw_parameters_set_reuse_local_address(params.nw, true)

        let nw_parameters = params.nw
        nw_parameters_set_server_mode(nw_parameters, true)
        nw_parameters_set_attach_protocol_listener(nw_parameters, true)

        let httpOptions = nw_http_messaging_create_options()
        let listenerProtocolStack = nw_parameters_copy_default_protocol_stack(nw_parameters)
        nw_protocol_stack_prepend_application_protocol(listenerProtocolStack, httpOptions)
        
        let queue = DispatchQueue(label: "com.apple.vre.HTTPServer.listener", autoreleaseFrequency: .workItem)
        let listener = try NWListener(using: params)
        let server = HTTPServer(interface: interface, listener: listener)

        listener.newConnectionHandler = { [weak server] newConnection in
            newConnection.stateUpdateHandler = { [weak server] state in
                switch state {
                case .setup, .waiting(_), .preparing:
                    HTTPServer.logger.log("Connection[\(newConnection.identifier)] transitioning to state: \(String(describing: state))")
                case .ready:
                    HTTPServer.logger.log("Connection[\(newConnection.identifier)] transitioning to ready state")
                    server?.ready(newConnection, accessPath: accessPath)
                case .failed(_):
                    HTTPServer.logger.log("Connection[\(newConnection.identifier)] failed; cancelling")
                    server?.cancelConnection(newConnection)
                case .cancelled:
                    HTTPServer.logger.log("Connection[\(newConnection.identifier)] cancelled successfully")
                @unknown default:
                    HTTPServer.logger.log("Connection[\(newConnection.identifier)] transitioning to unknown state: \(String(describing: state)); cancelling")
                    server?.cancelConnection(newConnection)
                }
            }
            
            HTTPServer.logger.log("Connection[\(newConnection.identifier)] Received new connection")
            server?.connections.withLock { connections in
                connections[newConnection.identifier] = newConnection
            }
            // N.B. `NWConnection.start(queue:)` retains the connection until we
            // `cancel` it.
            newConnection.start(queue: queue)
        }

        return try await withCheckedThrowingContinuation { cont in
            // If NWListener didn't start with a non-zero port, it will only be
            // assigned one by the OS after it transitions to its `ready` state
            // for the first time. We listen for this first state transition
            // and only then do we yield control back to the caller so they
            // always see a valid port number.
            listener.stateUpdateHandler = { [weak listener] state in
                switch state {
                case .setup, .waiting(_), .cancelled:
                    break
                case .ready:
                    listener?.stateUpdateHandler = nil
                    let endpoint = "\(String(describing: server.host)):\(server.port ?? 0)"
                    HTTPServer.logger.log("Starting server instance \(endpoint, privacy: .public)")
                    cont.resume(returning: server)
                case .failed(let error):
                    listener?.stateUpdateHandler = nil
                    let endpoint = "\(String(describing: server.host)):\(server.port ?? 0)"
                    HTTPServer.logger.log("Failed to start server instance \(endpoint, privacy: .public): \(error.localizedDescription)")
                    cont.resume(throwing: error)
                @unknown default:
                    let endpoint = "\(String(describing: server.host)):\(server.port ?? 0)"
                    HTTPServer.logger.log("Server instance \(endpoint, privacy: .public) transitioned to an unknown state \(String(describing: state))")
                    break
                }
            }

            listener.start(queue: queue)
        }
    }
}

// MARK: - Shutdown

extension HTTPServer {
    private func cancelConnection(_ connection: NWConnection) {
        self.connections.withLock { connections in
            connections.removeValue(forKey: connection.identifier)?.cancel()
        }
    }

    consuming func shutdown() throws {
        let endpoint = "\(String(describing: self.host)):\(self.port ?? 0)"
        HTTPServer.logger.log("Shutting down server instance \(endpoint, privacy: .public)")

        self.listener.cancel()
        self.connections.withLock { connections in
            for key in connections.keys {
                connections.removeValue(forKey: key)?.cancel()
            }
        }
        try self.interface.shutdown()
    }
}

// MARK: - Connection Events

extension HTTPServer {
    private func ready(_ connection: NWConnection, accessPath: FilePath) {
        connection.receiveMessage { content, contentContext, isComplete, error in
            guard let context = contentContext, error == nil else {
                return
            }

            guard
                let metadata = nw_content_context_copy_protocol_metadata(context.nw, nw_protocol_copy_http_definition()),
                let request = nw_http_metadata_copy_request(metadata)
            else {
                return self.respond(on: connection, withError: .permissionDenied)
            }

            var requestPath = ""
            nw_http_request_access_path(request) { rawPath in
                requestPath = rawPath.map { String(cString: $0) } ?? ""
            }

            // Strip any percent-encoding required by HTTP.
            requestPath = requestPath.removingPercentEncoding ?? requestPath

            HTTPServer.logger.log("Connection[\(connection.identifier)] received request for file at path '\(requestPath)'")

            // Only GETs
            guard nw_http_request_has_method(request, nw_http_request_method_get) else {
                return self.respond(on: connection, withError: .permissionDenied)
            }

            // Disallow any attempts to break out of the root access path
            guard !requestPath.contains("..") else {
                return self.respond(on: connection, withError: .permissionDenied)
            }

            // Form the complete access path and make sure it's
            // actually a file we can serve.
            let path = accessPath.appending(requestPath)
            guard Globals.computer.fileSystem.fileExists(atPath: path.string) else {
                return self.respond(on: connection, withError: .noSuchFileOrDirectory)
            }

            // Make sure the file is actually a file and not e.g. a symbolic
            // link or a directory.
            let pathURL = URL(fileURLWithPath: path.string)
            guard
                (try? pathURL.resourceValues(forKeys: [URLResourceKey.isRegularFileKey]))?.isRegularFile ?? false
            else {
                return self.respond(on: connection, withError: .invalidArgument)
            }

            guard
                let size = try? FileManager.default.attributesOfItem(atPath: path.string)[.size] as? Int,
                size >= 0
            else {
                return self.respond(on: connection, withError: .invalidArgument)
            }

            return self.respond(on: connection, withFileAt: path, size: size)
        }
    }

    private func respond(on connection: NWConnection, withError error: Errno) {
        let (http_status, errorBody) = switch error {
        case .noSuchFileOrDirectory:
            (nw_http_response_status_not_found, "IOError (not found)")
        case .permissionDenied:
            (nw_http_response_status_forbidden, "Forbidden")
        case .invalidArgument:
            (nw_http_response_status_not_found, "IOError (other): not a file")
        default:
            (nw_http_response_status_internal_server_error, error.description)
        }

        HTTPServer.logger.log("Connection[\(connection.identifier)] delivering error response '\(http_status.rawValue)' for error \(error.localizedDescription)")
        let httpResponse = nw_http_response_create_well_known(http_status)

        let nwContext = nw_content_context_create("context")
        nw_content_context_set_metadata_for_protocol(nwContext, nw_http_create_metadata_for_response(httpResponse))
        nw_content_context_set_is_final(nwContext, true)
        let context = Network.NWConnection.ContentContext(nw: nwContext)
        connection.send(content: errorBody.data(using: .isoLatin1), contentContext: context, isComplete: true, completion: .contentProcessed({ [weak self] error in
            if let error {
                HTTPServer.logger.log("Connection[\(connection.identifier)] received error while sending its own error response: \(error.localizedDescription)")
            }
            self?.cancelConnection(connection)
        }))
    }

    private func respond(on connection: NWConnection, withFileAt path: FilePath, size: Int) {
        HTTPServer.logger.log("Connection[\(connection.identifier)] delivering file of size '\(size)' at path: '\(path.string, privacy: .sensitive)'")

        let httpResponse = nw_http_response_create_well_known(nw_http_response_status_ok)
        nw_http_fields_append(httpResponse, nw_http_field_name_content_length, "\(size)")
        nw_http_fields_append(httpResponse, nw_http_field_name_content_type, "application/octet-stream")

        let nwContext = nw_content_context_create("context")
        nw_content_context_set_metadata_for_protocol(nwContext, nw_http_create_metadata_for_response(httpResponse))
        nw_content_context_set_is_final(nwContext, false)
        let context = Network.NWConnection.ContentContext(nw: nwContext)

        let url = URL(fileURLWithPath: path.string)
        connection.sendFile(at: url, contentContext: context, is_complete: false) { [weak self] totalBytesSent, isComplete, error in
            if let error {
                HTTPServer.logger.log("Connection[\(connection.identifier)] received error while transferring file: \(error.localizedDescription)")
                // Halt the transfer
                return false
            }

            // FIXME: This needs to respect 'keep-alive' for HTTP 1.1 requests.
            if isComplete {
                self?.cancelConnection(connection)
            }
            return true
        }
    }
}


// MARK: - Properties

extension HTTPServer {
    /// The host address of this HTTP server.
    ///
    /// This address may be allocated by the underlying interface if no address
    /// is specified by the server configuration value.
    var host: NWEndpoint.Host {
        self.interface.host
    }

    /// The port this HTTP server is listening on.
    ///
    /// This port may be allocated by the operating system if no port is
    /// specified by the server configuration value.
    var port: UInt16? {
        self.listener.port?.rawValue
    }
    
    // baseURL returns root (base) endpoint for this HTTPServer instance
    func baseURL() -> URL? {
        let bindAddr = String(describing: self.host)
        var baseURL = "http://\(bindAddr)"
        if let bindPort = self.port {
            baseURL += ":\(bindPort)"
        }
        
        return URL(string: baseURL)
    }
    
    // makeURL returns URL of path relative to baseURL; if path already represents a URL,
    //  it is returned instead
    func makeURL(path: String) -> URL? {
        if let baseURL = baseURL() {
            return URL(string: path, relativeTo: baseURL)
        }
        
        return nil
    }
}

// MARK: - Configuration

extension HTTPServer {
    enum Configuration: Codable {
        case network(Network)
        case virtual(Virtual)
    }
}

extension HTTPServer.Configuration {
    struct Network: Codable {
        var host: NWEndpoint.Host
        var port: UInt16?
        
        init(host: NWEndpoint.Host, port: UInt16? = nil) {
            self.host = host
            self.port = port
        }
        
        private enum CodingKeys: String, CodingKey {
            case address
            case port
        }
        
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let addressData = try container.decode(Data.self, forKey: .address)

            let decodedAddress: NWEndpoint.Host
            if let ipv4Address = IPv4Address(addressData) {
                decodedAddress = .ipv4(ipv4Address)
            } else if let ipv6Address = IPv6Address(addressData) {
                decodedAddress = .ipv6(ipv6Address)
            } else {
                throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unsupported address format"))
            }
            self.host = decodedAddress
            self.port = try container.decodeIfPresent(UInt16.self, forKey: .port)
        }
        
        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self.host {
            case .ipv4(let ipv4):
                try container.encode(ipv4.rawValue, forKey: .address)
            case .ipv6(let ipv6):
                try container.encode(ipv6.rawValue, forKey: .address)
            default:
                throw EncodingError.invalidValue(self.host, EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "Unsupported address format"))
            }
            try container.encodeIfPresent(self.port, forKey: .port)
        }
    }
    
    struct Virtual: Codable {
        enum NetworkMode: Codable {
            case nat
            case hostOnly
        }
        
        var mode: NetworkMode
        var port: UInt16?
    }
}

extension HTTPServer.Configuration {
    var port: NWEndpoint.Port {
        let rawPort = switch self {
        case .network(let network):
            network.port
        case .virtual(let virtual):
            virtual.port
        }
        return rawPort.flatMap { rawPort in
            NWEndpoint.Port(rawValue: rawPort)
        } ?? .any
    }
}

extension HTTPServer {
    protocol Interface: Sendable  {
        var host: NWEndpoint.Host { get }

        consuming func shutdown() throws
    }
}
