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
import Foundation
import Logging
import OpenAPIAsyncHTTPClient
import OpenAPIRuntime

// MARK: - Errors

/// Errors from the Whisper secret provider.
package enum WhisperError: Error, CustomStringConvertible, Sendable {
    /// The response did not contain a secret value.
    case missingSecretContent

    package var description: String {
        switch self {
        case .missingSecretContent:
            return "Whisper response did not contain a secret value"
        }
    }
}

// MARK: - WhisperSecretProvider

/// Fetches secrets from the Whisper secret management service.
///
/// Uses a generated OpenAPI client for the `GET /v1/my-secrets/{secret_name}`
/// endpoint. The caller provides an externally-managed ``HTTPClient`` (typically
/// configured for mTLS) and a server URL.
package struct WhisperSecretProvider: Sendable {
    private let client: Client
    private let logger: Logger

    /// Creates a Whisper secret provider.
    ///
    /// - Parameters:
    ///   - httpClient: An ``HTTPClient`` configured for mTLS.
    ///   - serverURL: The base URL of the Whisper service (e.g. `https://whisper.iss.apple.com`).
    ///   - logger: Logger for diagnostic output.
    package init(
        httpClient: HTTPClient,
        serverURL: URL,
        logger: Logger
    ) {
        let transport = AsyncHTTPClientTransport(configuration: .init(client: httpClient))
        let configuration = Configuration(dateTranscoder: LenientISO8601DateTranscoder())
        self.client = Client(
            serverURL: serverURL,
            configuration: configuration,
            transport: transport
        )
        self.logger = logger
    }

    /// Fetches the raw bytes of a secret from Whisper.
    ///
    /// - Parameters:
    ///   - name: The secret name.
    ///   - namespace: Optional namespace; if nil, the server derives it from the client certificate.
    /// - Returns: The decoded secret bytes.
    /// - Throws: ``WhisperError/missingSecretContent`` if the response has no secret,
    ///   or the underlying OpenAPI `ClientError` for non-200 responses.
    package func fetchSecret(name: String, namespace: String? = nil) async throws -> [UInt8] {
        logger.debug(
            "Fetching Whisper secret",
            metadata: ["name": "\(name)", "namespace": "\(namespace ?? "<derived>")"]
        )

        let response = try await client.MySecret(
            path: .init(secret_name: name),
            query: .init(namespace: namespace)
        )

        let body = try response.ok.body.json
        guard let secretData = body.secret else {
            throw WhisperError.missingSecretContent
        }
        let bytes = Array(secretData.data)
        logger.debug("Whisper secret fetched", metadata: ["byteCount": "\(bytes.count)"])
        return bytes
    }
}
