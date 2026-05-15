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

import CloudBoardCommon
import CloudBoardLogging
import CloudBoardPlatformUtilities
import Dispatch
import Foundation
import Network
import NIOCore
import os

enum LocalIPResolution {
    fileprivate static let logger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "LocalIPResolution"
    )
    private static let localIPResolutionQueue = DispatchQueue(label: "com.apple.cloudos.cloudboardd.LocalIPResolution")

    static let defaultGRPCServicePort = 4442

    // Given an IP and port, returns our preferred local GRPC service address.
    static func preferredLocalGRPCServiceAddress(
        ipAddress: String?,
        port: Int?,
        serviceDiscoveryHostname: String?,
        forceIPv6Resolution: Bool = false
    ) async throws -> SocketAddress {
        self.logger
            .log(
                "Resolving service address for IP address \(String(describing: ipAddress), privacy: .public) and port \(String(describing: port), privacy: .public) using service discovery hostname \(String(describing: serviceDiscoveryHostname), privacy: .public)"
            )

        if let ipAddress {
            // Easy choice here.
            return try SocketAddress(ipAddress: ipAddress, port: port ?? self.defaultGRPCServicePort)
        }

        guard let serviceDiscoveryHostname else {
            Self.logger.warning("Unable to guess ideal service discovery location, listening on localhost only.")
            return try SocketAddress(ipAddress: "::1", port: port ?? Self.defaultGRPCServicePort)
        }

        // Harder, we need to find out what IP address we should bind. We assume there is only
        // one dataplane interface, and that our route to service discovery points to the same interface.
        // Here we make a UDP "connection" to find a local endpoint. As we never send any data, this has
        // no network level effect, and the port doesn't really matter.
        let networkParams: NWParameters
        if forceIPv6Resolution {
            Self.logger.log("Forcing use of IPv6 for local IP resolution.")
            let ipv6Parameters = NWParameters.udp
            // IP protocol options are guaranteed to be present for UDP so force-unwrapping/force-casting is okay here
            let ip = ipv6Parameters.defaultProtocolStack.internetProtocol! as! NWProtocolIP.Options
            ip.version = .v6
            networkParams = ipv6Parameters
        } else {
            networkParams = .udp
        }

        let connection = NWConnection(
            host: .init(serviceDiscoveryHostname),
            port: 8080,
            using: networkParams
        )
        defer { connection.cancel() }

        let cancellationStateMachine = CancellationStateMachine()

        let endpoint: NWEndpoint? = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NWEndpoint?, Error>) in
                cancellationStateMachine.gotContinuation(continuation)

                connection.stateUpdateHandler = { state in
                    switch state {
                    case .setup:
                        Self.logger.debug("Setup connection")
                    case .preparing:
                        Self.logger.debug("Preparing connection")
                    case .ready:
                        Self.logger.debug("Connection ready")

                        // Fantastic, we're good to go. Return the local endpoint.
                        cancellationStateMachine.resolve(returning: connection.currentPath?.localEndpoint)
                    case .waiting(let error):
                        Self.logger.warning("Entered waiting state: \(String(unredacted: error), privacy: .public)")
                    case .failed(let error):
                        Self.logger.error("Entered failed state: \(String(unredacted: error), privacy: .public)")
                        cancellationStateMachine.resolve(throwing: error)
                    case .cancelled:
                        Self.logger.warning("Entered cancelled state")
                        cancellationStateMachine.resolve(throwing: CancellationError())
                    @unknown default:
                        Self.logger.warning("Unknown state entered")
                    }
                }

                Self.logger.info("Attempting to find path to service discovery")
                connection.start(queue: Self.localIPResolutionQueue)
            }
        } onCancel: {
            connection.cancel()
            cancellationStateMachine.cancel()
        }

        guard let endpoint else {
            Self.logger.error("Unable to find local endpoint")
            throw IPResolutionError.unableToFindLocalEndpoint
        }

        Self.logger.log("Resolved endpoint \(String(describing: endpoint), privacy: .public)")
        let address = try SocketAddress(endpoint, port: port)
        Self.logger.log("Local service address will be \(address, privacy: .public)")
        return address
    }
}

extension SocketAddress {
    fileprivate init(_ endpoint: NWEndpoint, port: Int?) throws {
        if case .hostPort(host: let host, port: _) = endpoint {
            switch host {
            case .ipv4(let ipv4Address):
                // Converting through a string is inefficient, but we don't do this often.
                self = try .init(
                    ipAddress: String(describing: ipv4Address),
                    port: port ?? LocalIPResolution.defaultGRPCServicePort
                )
            case .ipv6(let ipv6Address):
                // Converting through a string is inefficient, but we don't do this often.
                self = try .init(
                    ipAddress: String(describing: ipv6Address),
                    port: port ?? LocalIPResolution.defaultGRPCServicePort
                )
            case .name:
                LocalIPResolution.logger
                    .error("Unable to convert endpoint \(String(describing: endpoint), privacy: .public)")
                throw IPResolutionError.unableToConvertEndpoint(endpoint)
            @unknown default:
                LocalIPResolution.logger
                    .error("Unable to convert endpoint \(String(describing: endpoint), privacy: .public)")
                throw IPResolutionError.unableToConvertEndpoint(endpoint)
            }
        } else {
            LocalIPResolution.logger
                .error("Unable to convert endpoint \(String(describing: endpoint), privacy: .public)")
            throw IPResolutionError.unableToConvertEndpoint(endpoint)
        }
    }
}

enum IPResolutionError: Error {
    case unableToConvertEndpoint(NWEndpoint)
    case unableToFindLocalEndpoint
}

// Allows us to handle cancellation races around the NWConnection.
//
// Awkwardly, if the NWConnection is cancelled _before_ the state update handler is set, the connection won't set the
// handler at all.
// This can lead to the cancellation being lost and the code hanging, which is clearly not acceptable.
//
// Our only way to handle this is to allow cancellation to sidestep the NWConnection handler and tolerate that not
// firing.
// The downside there is that we have to handle the possibility that cancellation fires _twice_, once from the state
// update
// handler and once from the cancellation handler. To manage the double-spend of the continuation we use this state
// machine
// to allow multiple resolution and to delay the cancellation until the continuation is available.
private struct CancellationStateMachine: Sendable {
    private let state: OSAllocatedUnfairLock<State>

    enum State {
        case idle
        case cancelledAwaitingContinuation
        case continuation(CheckedContinuation<NWEndpoint?, Error>)
        case resolved
    }

    init() {
        self.state = .init(initialState: .idle)
    }

    func gotContinuation(_ continuation: CheckedContinuation<NWEndpoint?, Error>) {
        self.state.withLock {
            switch $0 {
            case .idle:
                $0 = .continuation(continuation)
            case .cancelledAwaitingContinuation:
                // Instant cancel.
                continuation.resume(throwing: CancellationError())
                $0 = .resolved
            case .continuation, .resolved:
                // It is programmer error to get a continuation twice.
                preconditionFailure()
            }
        }
    }

    func cancel() {
        self.state.withLock {
            switch $0 {
            case .idle:
                $0 = .cancelledAwaitingContinuation
            case .cancelledAwaitingContinuation:
                // This should never happen as the cancellation handler shouldn't be called twice.
                // However, we don't want to crash in this case, even though the Swift runtime has
                // severely misbehaved. Instead, we'll fault.
                LocalIPResolution.logger
                    .fault("Double-cancel indicates a Swift Runtime violation, cancellation must only happen once")
            case .continuation(let cont):
                cont.resume(throwing: CancellationError())
                $0 = .resolved
            case .resolved:
                // Also acceptable, ignore.
                ()
            }
        }
    }

    func resolve(with result: Result<NWEndpoint?, Error>) {
        self.state.withLock {
            switch $0 {
            case .idle, .cancelledAwaitingContinuation:
                // Programmer error, we must always have the continuation before we resolve.
                fatalError("Resolving without continuation, state \($0)")
            case .continuation(let cont):
                cont.resume(with: result)
                $0 = .resolved
            case .resolved:
                // Acceptable but unfortunate, we likely cancelled earlier.
                ()
            }
        }
    }

    func resolve(returning value: NWEndpoint?) {
        self.resolve(with: .success(value))
    }

    func resolve(throwing error: Error) {
        self.resolve(with: .failure(error))
    }
}

extension CloudBoardDConfiguration {
    func resolveLocalServiceAddress(cloudAppPort: Int?) async throws -> SocketAddress {
        if self.grpc?.forceIPv6Resolution != nil {
            // os_log doesn't support warnings so let's make this an error to make it more visible.
            LocalIPResolution.logger.error(
                "Using deprecated GRPC.forceIPv6Resolution CFPref. Use secure-config 'com.apple.cloudboard.grpc.forceIPv6Resolution instead."
            )
        }
        return try await LocalIPResolution.preferredLocalGRPCServiceAddress(
            ipAddress: self.grpc?.listeningIP,
            port: cloudAppPort ?? self.grpc?.listeningPort,
            serviceDiscoveryHostname: self.serviceDiscovery?.targetHost,
            forceIPv6Resolution: self.secureConfig.grpcForceIPv6Resolution ?? self.grpc?.forceIPv6Resolution ?? false
        )
    }
}
