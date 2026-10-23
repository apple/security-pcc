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

import AsyncHTTPClient
import CPAgentMetrics
import Foundation
import Logging
import Metrics
import OpenAPIAsyncHTTPClient
import OpenAPIRuntime

enum HealthServiceClientError: Error, Equatable {
    case invalidURL
    case invalidHostname
    case failed
    case serverError(statusCode: Int)
}

// NOTE: This description is publicly logged and/or included in metric
// dimensions and therefore MUST not contain sensitive data.
extension HealthServiceClientError: ReportableError {
    var publicDescription: String {
        switch self {
        case .invalidURL:
            return "Invalid URL."
        case .invalidHostname:
            return "Invalid hostname."
        case .failed:
            return "Request failed."
        case .serverError(let statusCode):
            return "Received \(statusCode) from server."
        }
    }
}

public final class HealthServiceClient: Sendable {
    private let logger = Logger(label: "CPAgent.HealthServiceClient")

    private let client: Client
    private let nodeId: String

    public typealias NodeStatus = Components.Schemas.NodeStatus
    public typealias AgentCommands = Components.Schemas.AgentCommands
    public typealias AgentCommandType = Components.Schemas.AgentCommandType
    public typealias State = Components.Schemas.State
    public typealias NodeOperationalStatus = Components.Schemas.NodeOperationalStatus

    public init(url urlString: String, computeInstanceId: String, httpClient: HTTPClient) throws {
        self.nodeId = computeInstanceId

        guard let url = URL(string: urlString), url.scheme == "https" else {
            throw HealthServiceClientError.invalidURL
        }

        guard let host = url.host?.lowercased(),
              host.wholeMatch(of: /agent\.compute(-qa)?\.g\.apple\.com/) != nil
        else {
            throw HealthServiceClientError.invalidHostname
        }

        let transport = AsyncHTTPClientTransport(
            configuration: .init(client: httpClient, timeout: .seconds(15)))

        client = Client(serverURL: url, transport: transport)
    }

    /// Polls the health service for the next command(s) to execute.
    /// Returns the commands and the new ETag, or (nil, nil) if the config has not changed (304).
    ///
    /// Retries up to `maxRetries` times with exponential backoff on transient failures
    /// (network errors, 5xx). Non-transient client errors (4xx) are not retried.
    public func getNextCommands(
        bootConfigCksum: String,
        ifNoneMatch: String?,
        nodeStatus: NodeStatus,
        maxRetries: Int = 3
    ) async throws -> (commands: AgentCommands?, etag: String?) {
        try await MetricsSystem.withStatusMetrics(
            labelPrefix: MetricLabel.getNextCommandsRequest
        ) {
            var lastError: Error = HealthServiceClientError.failed
            for attempt in 1...maxRetries {
                do {
                    let result = try await client.getNextCommands(
                        path: .init(assetTag: nodeId),
                        headers: .init(
                            If_hyphen_None_hyphen_Match: ifNoneMatch,
                            X_hyphen_Apple_hyphen_BootConfig_hyphen_Cksum: bootConfigCksum
                        ),
                        body: .json(nodeStatus)
                    )
                    switch result {
                    case .ok(let response):
                        let etag = response.headers.ETag
                        let commands = try response.body.json
                        return (commands, etag)
                    case .notModified:
                        return (nil, nil)
                    case .badRequest:
                        logger.error("getNextCommands request failed", metadata: ["statusCode": "400"])
                        throw HealthServiceClientError.failed
                    case .unauthorized:
                        logger.error("getNextCommands request failed", metadata: ["statusCode": "401"])
                        throw HealthServiceClientError.failed
                    case .forbidden:
                        logger.error("getNextCommands request failed", metadata: ["statusCode": "403"])
                        throw HealthServiceClientError.failed
                    case .notFound:
                        logger.error("getNextCommands request failed", metadata: ["statusCode": "404"])
                        throw HealthServiceClientError.failed
                    case .internalServerError:
                        logger.error("getNextCommands request failed", metadata: ["statusCode": "500"])
                        throw HealthServiceClientError.serverError(statusCode: 500)
                    case .undocumented(let statusCode, _):
                        logger.error("getNextCommands request failed", metadata: ["statusCode": "\(statusCode)"])
                        throw HealthServiceClientError.serverError(statusCode: statusCode)
                    }
                } catch HealthServiceClientError.failed {
                    // Non-transient client error; not retryable.
                    throw HealthServiceClientError.failed
                } catch {
                    lastError = error
                    logger.warning(
                        "getNextCommands request failed, retrying if attempts remain",
                        metadata: [
                            "error": "\(String(reportable: error))",
                            "willRetry": "\(attempt < maxRetries)",
                        ]
                    )
                    if attempt < maxRetries {
                        let sleepMs = UInt64(100 * (1 << (attempt - 1)))
                        logger.debug("Sleeping before retry", metadata: ["sleepMs": "\(sleepMs)ms"])
                        try? await Task.sleep(for: .milliseconds(sleepMs))
                    }
                }
            }

            logger.error(
                "getNextCommands failed after all retries",
                metadata: [
                    "maxRetries": "\(maxRetries)",
                    "lastError": "\(String(reportable: lastError))",
                ]
            )
            throw lastError
        }
    }

    public func heartbeat(healthy: Bool = true) async throws {
        try await MetricsSystem.withStatusMetrics(
            labelPrefix: MetricLabel.heartbeatRequest
        ) {
            let metadata = Components.Schemas.PayloadMetadata()
            let payload = Components.Schemas.HeartbeatPayload(
                timestamp: .now, state: .UP, operationalStatus: .UNKNOWN, metadata: metadata)

            let result = try await client.heartbeat(
                path: .init(source: .CPAGENT, assetType: .NODE, assetId: nodeId),
                body: .json(payload))
            switch result {
            case .accepted:
                return
            case .badRequest:
                logger.error("Heartbeat request failed", metadata: ["statusCode": "400"])
                throw HealthServiceClientError.failed
            case .internalServerError:
                logger.error("Heartbeat request failed", metadata: ["statusCode": "500"])
                throw HealthServiceClientError.failed
            case .undocumented(let statusCode, _):
                logger.error("Heartbeat request failed", metadata: ["statusCode": "\(statusCode)"])
                throw HealthServiceClientError.failed
            }
        }
    }

    public func heartbeat(
        state: Components.Schemas.State,
        operationalStatus: Components.Schemas.NodeOperationalStatus,
        componentStatus: [String: String]?
    ) async throws {
        try await MetricsSystem.withStatusMetrics(
            labelPrefix: MetricLabel.heartbeatRequest
        ) {
            var metadata = Components.Schemas.PayloadMetadata()
            if let componentStatus {
                metadata.additionalProperties = .init(additionalProperties: componentStatus)
            }
            let payload = Components.Schemas.HeartbeatPayload(
                timestamp: .now, state: state, operationalStatus: operationalStatus,
                metadata: metadata)

            let result = try await client.heartbeat(
                path: .init(source: .CPAGENT, assetType: .NODE, assetId: nodeId),
                body: .json(payload))
            switch result {
            case .accepted:
                return
            case .badRequest:
                logger.error("Heartbeat request failed", metadata: ["statusCode": "400"])
                throw HealthServiceClientError.failed
            case .internalServerError:
                logger.error("Heartbeat request failed", metadata: ["statusCode": "500"])
                throw HealthServiceClientError.failed
            case .undocumented(let statusCode, _):
                logger.error("Heartbeat request failed", metadata: ["statusCode": "\(statusCode)"])
                throw HealthServiceClientError.failed
            }
        }
    }

}
