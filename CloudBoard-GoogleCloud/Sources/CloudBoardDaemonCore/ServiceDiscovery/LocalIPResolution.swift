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

import CloudBoardUtilities
import Configuration
import Logging
import NIOCore
import NIOPosix

enum LocalIPResolution {
    fileprivate static let logger = Logger(label: "cloudboardd.LocalIPResolution")

    static let defaultGRPCServicePort = 4442

    // Given a service discovery hostname, returns our preferred local GRPC service address.
    static func preferredLocalGRPCServiceAddress(
        serviceDiscoveryHostname: String?,
        port: Int?,
    ) async throws -> SocketAddress {
        self.logger.info(
            "Resolving service address",
            metadata: [
                "port": "\(String(describing: port))",
                "serviceDiscoveryHostname": "\(String(describing: serviceDiscoveryHostname))",
            ]
        )

        // Check for cancellation early
        try Task.checkCancellation()

        guard let serviceDiscoveryHostname else {
            Self.logger.warning("Unable to guess ideal service discovery location, listening on localhost only.")
            return try SocketAddress(ipAddress: "::1", port: port ?? Self.defaultGRPCServicePort)
        }

        // Harder, we need to find out what IP address we should bind. We assume there is only
        // one data plane interface, and that our route to service discovery points to the same interface.
        // Here we make a UDP "connection" to find a local endpoint. As we never send any data, this has no network
        // level effect, and the port doesn't really matter.
        Self.logger.info("Attempting to find path to service discovery")

        try Task.checkCancellation()

        // Resolve the service discovery hostname to an address
        let targetAddress = try SocketAddress.makeAddressResolvingHost(
            serviceDiscoveryHostname,
            port: 8080
        )

        Self.logger.info(
            "Resolved service discovery",
            metadata: [
                "address": "\(targetAddress)"
            ]
        )

        let bindAddress = try SocketAddress(ipAddress: "0.0.0.0", port: 0)
        Self.logger.debug(
            "Creating UDP socket",
            metadata: [
                "address": "\(bindAddress)"
            ]
        )

        let bootstrap = DatagramBootstrap(group: .singletonMultiThreadedEventLoopGroup)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        let channel = try await bootstrap.bind(to: bindAddress).get()

        // Connect to the target to establish routing (doesn't send any data)
        Self.logger.debug(
            "Connecting to target",
            metadata: [
                "address": "\(targetAddress)"
            ]
        )
        try await channel.connect(to: targetAddress).get()
        Self.logger.debug("Connection ready")

        guard let localAddress = channel.localAddress else {
            try await channel.close()
            Self.logger.error("Unable to find local endpoint")
            throw IPResolutionError.unableToFindLocalEndpoint
        }

        Self.logger.info(
            "Resolved endpoint",
            metadata: [
                "address": "\(localAddress)"
            ]
        )

        // Extract just the IP address and use the requested port
        guard let localIP = localAddress.ipAddress else {
            try await channel.close()
            Self.logger.error(
                "Unable to extract IP address",
                metadata: [
                    "address": "\(localAddress)"
                ]
            )
            throw IPResolutionError.unableToExtractIPAddress
        }

        let serviceAddress = try SocketAddress(
            ipAddress: localIP,
            port: port ?? Self.defaultGRPCServicePort
        )

        // Clean up resources
        try await channel.close()

        Self.logger.info(
            "Local service address will be",
            metadata: [
                "address": "\(serviceAddress)"
            ]
        )
        return serviceAddress
    }
}

enum IPResolutionError: Error {
    case unableToFindLocalEndpoint
    case unableToExtractIPAddress
}

extension IPResolutionError: ReportableError {
    var publicDescription: String {
        switch self {
        case .unableToFindLocalEndpoint: "IPResolutionError.unableToFindLocalEndpoint"
        case .unableToExtractIPAddress: "IPResolutionError.unableToExtractIPAddress"
        }
    }
}
