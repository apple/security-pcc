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

import Configuration
import Foundation
import GRPCNIOTransportHTTP2Posix
import Logging
import NIOSSL

#if canImport(System)
import System
#else
import SystemPackage
#endif

struct CloudAssetDownloaderDConfiguration {
    private static let logger = Logger.forType(CloudAssetDownloaderDConfiguration.self)

    struct TLSConfiguration: Sendable {
        let certChainPath: String
        let keyPath: String
        let caCertPath: String?

        func makeNIOSSLClientConfiguration() throws -> NIOSSL.TLSConfiguration {
            var tlsConfig = NIOSSL.TLSConfiguration.makeClientConfiguration()
            let certChain = try NIOSSLCertificate.fromPEMFile(self.certChainPath)
            tlsConfig.certificateChain = certChain.map { .certificate($0) }
            tlsConfig.privateKey = try .privateKey(NIOSSLPrivateKey(file: self.keyPath, format: .pem))
            if let caCertPath {
                tlsConfig.trustRoots = .file(caCertPath)
            }
            return tlsConfig
        }

        func makeGRPCTransportSecurity() -> HTTP2ClientTransport.Posix.TransportSecurity {
            .mTLS(
                certificateChain: [.file(path: self.certChainPath, format: .pem)],
                privateKey: .file(path: self.keyPath, format: .pem)
            )
        }
    }

    let assetsRootPath: FilePath
    let tls: TLSConfiguration?
    let controlPlaneAgentURL: URL?
    let purgeInterval: Duration
    let apiSocketPath: String
}

enum ConfigurationError: Error, CustomStringConvertible {
    case incompleteTLS(String)
    case timeout(paths: [String], seconds: Int)

    var description: String {
        switch self {
        case let .incompleteTLS(msg):
            "Incomplete TLS configuration: \(msg)"
        case let .timeout(paths, seconds):
            "Timed out after \(seconds)s waiting for files: \(paths.joined(separator: ", "))"
        }
    }
}

extension CloudAssetDownloaderDConfiguration {
    static func fromConfigReader(
        _ configReader: ConfigReader
    ) async throws -> CloudAssetDownloaderDConfiguration {
        let assetsRootPath = configReader.string(forKey: "assets.root.path", default: "/cloud-assets")
        let controlPlaneAgentURL: URL? =
            if let urlString = configReader.string(forKey: "cpagent.url") {
                URL(string: urlString)
            } else {
                nil
            }

        let tlsConfiguration: TLSConfiguration?
        let certChainPath = configReader.string(forKey: "identity.file.certChainPath")
        let keyPath = configReader.string(forKey: "identity.file.keyPath")
        switch (certChainPath, keyPath) {
        case let (certChainPath?, keyPath?):
            let caCertPath = configReader.string(forKey: "identity.file.caCertPath")
            var filesToWait = [certChainPath, keyPath]
            if let caCertPath {
                filesToWait.append(caCertPath)
            }
            try await waitForFiles(filesToWait, timeoutSeconds: 60, logger: self.logger)
            tlsConfiguration = TLSConfiguration(
                certChainPath: certChainPath,
                keyPath: keyPath,
                caCertPath: caCertPath
            )
        case (nil, nil):
            tlsConfiguration = nil
        case (.some, nil):
            throw ConfigurationError.incompleteTLS("certChainPath specified without keyPath")
        case (nil, .some):
            throw ConfigurationError.incompleteTLS("keyPath specified without certChainPath")
        }

        let purgeInterval: Duration = .seconds(
            configReader.int(forKey: "assets.purge.intervalSeconds") ?? 300
        )

        let apiSocketPath = configReader.string(
            forKey: "api.grpc.uds",
            default: "/var/run/cloudassetdownloader/cloudassetdownloader.sock"
        )

        return .init(
            assetsRootPath: .init(assetsRootPath),
            tls: tlsConfiguration,
            controlPlaneAgentURL: controlPlaneAgentURL,
            purgeInterval: purgeInterval,
            apiSocketPath: apiSocketPath
        )
    }
}

private func waitForFiles(_ paths: [String], timeoutSeconds: Int, logger: Logger) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(timeoutSeconds))
    while true {
        let missing = paths.filter { !FileManager.default.fileExists(atPath: $0) }
        if missing.isEmpty { return }
        if ContinuousClock.now >= deadline {
            throw ConfigurationError.timeout(paths: missing, seconds: timeoutSeconds)
        }
        logger.debug("Waiting for files", metadata: ["missing": "\(missing)"])
        try await Task.sleep(for: .seconds(10))
    }
}
