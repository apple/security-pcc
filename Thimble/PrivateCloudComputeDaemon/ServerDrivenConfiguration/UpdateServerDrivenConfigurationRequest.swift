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

//
//  UpdateServerDrivenConfigurationRequest.swift
//  PrivateCloudCompute
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

import CFNetwork_Private
import Foundation
import InternalSwiftProtobuf
@_spi(HTTP) import Network
import OSPrivate
import PrivateCloudCompute
import Security
import os.lock

final class UpdateServerDrivenConfigurationRequest<
    ServerDrivenConfiguration: ServerDrivenConfigurationProtocol,
    SystemInfo: SystemInfoProtocol
>: Sendable {

    enum Error: Swift.Error {
        case urlSessionError
        case responseDataDecodeError
        case responseBase64DecodeError
    }

    private let logger = tc2Logger(forCategory: .updateServerDrivenConfiguration)
    private let logPrefix: String
    private let requestID: UUID
    private let config: any Configuration
    private let decoder = tc2JSONDecoder()
    private let systemInfo: SystemInfo
    private let serverDrivenConfiguration: ServerDrivenConfiguration

    struct BagContainerModel: Codable, Sendable {
        // var signature: String // Design not yet final
        // var certs: [String] // Design not yet final
        var bag: String

        enum CodingKeys: String, CodingKey {
            // case signature = "signature"
            // case certs = "certs"
            case bag = "bag"
        }
    }

    init(
        serverDrivenConfiguration: ServerDrivenConfiguration,
        systemInfo: SystemInfo,
        requestID: UUID,
        config: any Configuration
    ) {
        self.logPrefix = "\(requestID):"
        self.serverDrivenConfiguration = serverDrivenConfiguration
        self.systemInfo = systemInfo
        self.requestID = requestID
        self.config = config
    }

    func sendRequest() async throws {
        self.logger.log("\(self.logPrefix) executing configbag request")
        defer {
            self.logger.log("\(self.logPrefix) finished configbag request")
        }

        // Set up the request
        var urlRequest = URLRequest(url: config.environment(systemInfo: self.systemInfo).configUrl)
        urlRequest.addValue(self.requestID.uuidString, forHTTPHeaderField: HTTPField.Name.appleRequestUUID.rawName)
        urlRequest.addValue(self.systemInfo.osInfo, forHTTPHeaderField: HTTPField.Name.appleClientInfo.rawName)
        urlRequest.addValue(HTTPField.Constants.userAgentTrustedCloudComputeD, forHTTPHeaderField: HTTPField.Name.contentType.rawName)
        if let automatedDeviceGroup = systemInfo.automatedDeviceGroup {
            urlRequest.addValue(automatedDeviceGroup, forHTTPHeaderField: HTTPField.Name.appleAutomatedDeviceGroup.rawName)
        }
        urlRequest.addValue("application/json", forHTTPHeaderField: HTTPField.Name.accept.rawName)
        self.logger.debug("\(self.logPrefix) request ready, request=\(urlRequest)")

        // Set up the session
        let urlSessionConfig = URLSessionConfiguration.ephemeral
        // Allow the session to run over OHTTP
        urlSessionConfig.usesClassicLoadingMode = false
        let urlSession = URLSession(configuration: urlSessionConfig)
        self.logger.debug("\(self.logPrefix) session ready, session=\(urlSession)")

        let data: Data
        let response: URLResponse
        do {
            self.logger.debug("\(self.logPrefix) running session async")
            (data, response) = try await urlSession.data(for: urlRequest)
            self.logger.debug("\(self.logPrefix) response returning, response=\(response) data=\(String(describing: data))")
        } catch {
            self.logger.error("\(self.logPrefix) response throwing, error=\(error)")
            throw Error.urlSessionError
        }

        let model: BagContainerModel
        do {
            model = try self.decoder.decode(BagContainerModel.self, from: data)
            self.logger.debug("\(self.logPrefix) model decoded, model=\(String(describing: model))")
        } catch {
            logger.error("\(self.logPrefix) unable to decode json response data, error=\(error)")
            throw Error.responseDataDecodeError
        }

        // TODO: Work with server team to understand what is going on with signing, and
        // how we are expected to verify the bag. Currently the bag contains "certs"
        // and "signature" but we have not worked together on a spec for this. Right now
        // we just take the bag bytes, which are base64 encoded utf8 json.

        guard let utf8jsonBag = Data(base64Encoded: model.bag) else {
            logger.error("\(self.logPrefix) unable to decode base64 bag")
            throw Error.responseBase64DecodeError
        }
        self.logger.debug("\(self.logPrefix) base64 bag decoded, pushing update of utf8jsonBag=\(utf8jsonBag)")

        await self.serverDrivenConfiguration.updateJsonModel(utf8jsonBag)

        // We also need to drive the proposed liveon env back to our config
        // But Configuration is in the framework, which does not know about
        // the SystemInfo computations, so the division of labor here is odd.
        // Also contributing to the weirdness here is that our config code is
        // simply not designed to be mutated, and changing that is going to
        // be pervasive because of the way we use value types and pass the
        // single config around. I prefer not to undertake that at this point,
        // instead simply writing to prefs when I need them.
        DefaultConfiguration.writeBackProposedLiveOnEnvironment(
            serverDrivenConfiguration: self.serverDrivenConfiguration,
            systemInfo: systemInfo
        )
    }
}

extension DefaultConfiguration {
    static func writeBackProposedLiveOnEnvironment<
        ServerDrivenConfiguration: ServerDrivenConfigurationProtocol
    >(
        serverDrivenConfiguration: ServerDrivenConfiguration,
        systemInfo: any SystemInfoProtocol
    ) {
        let logger = tc2Logger(forCategory: .updateServerDrivenConfiguration)

        // We only ever write this proposal for internal builds.
        guard os_variant_has_internal_content(privateCloudComputeOsVariantSubsystem) else {
            return
        }

        let index = ConfigurationIndex<String?>.proposedLiveOnEnvironment

        if let spillOver = serverDrivenConfiguration.liveOnProdSpillover, (0.0...1.0).contains(spillOver) {
            // We were given a valid spillover. Write it!
            assert(spillOver >= 0.0 && spillOver <= 1.0)
            let p = systemInfo.uniqueDeviceIDPercentile

            let proposal: String
            if p < spillOver {
                proposal = TC2Environment.production.name
            } else {
                proposal = TC2Environment.carry.name
            }
            logger.log("With device_p=\(p), spillover=\(spillOver), proposed environment=\(proposal)")

            let index = ConfigurationIndex<String?>.proposedLiveOnEnvironment
            logger.log("DefaultConfiguration wrote \(index.domain) \(index.name) = \(proposal)")
            proposal.defaultsWrite(defaultsDomain: index.domain, name: index.name)
        } else {
            logger.log("With no spillover, deleted environment proposal")
            // We were given no spillover. Delete it!
            logger.log("DefaultConfiguration deleted \(index.domain) \(index.name)")
            Optional<String>.none.defaultsWrite(defaultsDomain: index.domain, name: index.name)
        }
    }
}
