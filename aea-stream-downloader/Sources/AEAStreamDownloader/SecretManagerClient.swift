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
import NIOCore

// MARK: - Secret Manager response

private struct SecretManagerResponse: Decodable {
    let payload: Payload?

    struct Payload: Decodable {
        let data: String?
    }
}

// MARK: - Project ID lookup

/// Fetches the GCE project ID from the metadata service.
///
/// The result is the same value `gcloud config get-value project` returns when
/// running on a GCE VM.
func fetchGCEProjectID(
    logger: Logger,
    httpClient: HTTPClient,
    metadataBaseURL: String,
    retryConfiguration: RetryConfiguration = .default
) async throws -> String {
    try await withRetry(
        configuration: retryConfiguration,
        logger: logger,
        operation: .secretFetch
    ) {
        var request = HTTPClientRequest(
            url: "\(metadataBaseURL)/computeMetadata/v1/project/project-id"
        )
        request.headers.add(name: "Metadata-Flavor", value: "Google")

        logger.debug("Fetching GCE project ID")
        let response = try await httpClient.execute(request, timeout: .seconds(10))
        guard response.status == .ok else {
            logger.error(
                "GCE project ID fetch failed",
                metadata: ["httpStatus": "\(response.status.code)"]
            )
            throw AEADownloaderError.secretFetchFailed(status: Int(response.status.code))
        }
        let body = try await response.body.collect(upTo: 64 * 1024)
        let projectID = String(buffer: body)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !projectID.isEmpty else {
            throw AEADownloaderError.secretPayloadInvalid("project ID response was empty")
        }
        return projectID
    }
}

// MARK: - Secret Manager fetch

/// Fetches a secret payload from Google Secret Manager.
///
/// `secretName` may be either:
/// - A full resource name like `projects/123/secrets/foo/versions/latest`, used verbatim.
/// - A short name like `foo`, in which case the project ID is looked up from the
///   GCE metadata service and the version defaults to `latest`.
///
/// The `Authorization: Bearer ...` header is taken from `tokenProvider`. The
/// response is decoded as `{"payload": {"data": "<base64>"}}` and the base64
/// payload is decoded to raw bytes before returning.
func fetchSecretManagerPayload(
    secretName: String,
    projectID: String? = nil,
    tokenProvider: TokenProvider,
    httpClient: HTTPClient,
    secretManagerBaseURL: String = "https://secretmanager.googleapis.com",
    metadataBaseURL: String,
    logger: Logger,
    retryConfiguration: RetryConfiguration = .default
) async throws -> Data {
    let resourceName = try await resolveSecretResourceName(
        secretName: secretName,
        projectID: projectID,
        httpClient: httpClient,
        metadataBaseURL: metadataBaseURL,
        logger: logger,
        retryConfiguration: retryConfiguration
    )

    let normalizedBase =
        secretManagerBaseURL.hasSuffix("/")
        ? String(secretManagerBaseURL.dropLast()) : secretManagerBaseURL
    let url = "\(normalizedBase)/v1/\(resourceName):access"

    return try await withRetry(
        configuration: retryConfiguration,
        logger: logger,
        operation: .secretFetch
    ) {
        var request = HTTPClientRequest(url: url)
        request.headers.add(name: "Authorization", value: "Bearer \(tokenProvider.token)")

        logger.debug("Fetching Secret Manager payload", metadata: ["url": "\(url)"])
        let response = try await httpClient.execute(request, timeout: .seconds(30))
        guard response.status == .ok else {
            logger.error(
                "Secret Manager fetch failed",
                metadata: ["httpStatus": "\(response.status.code)"]
            )
            throw AEADownloaderError.secretFetchFailed(status: Int(response.status.code))
        }

        let body = try await response.body.collect(upTo: 1024 * 1024)
        let decoded: SecretManagerResponse
        do {
            decoded = try JSONDecoder().decode(SecretManagerResponse.self, from: body)
        } catch {
            throw AEADownloaderError.secretPayloadInvalid(
                "response was not valid JSON"
            )
        }
        guard let base64 = decoded.payload?.data else {
            throw AEADownloaderError.secretPayloadInvalid("payload.data is missing")
        }
        guard let data = Data(base64Encoded: base64) else {
            throw AEADownloaderError.secretPayloadInvalid(
                "payload.data is not valid base64"
            )
        }
        logger.debug("Secret Manager payload fetched", metadata: ["byteCount": "\(data.count)"])
        return data
    }
}

private func resolveSecretResourceName(
    secretName: String,
    projectID: String?,
    httpClient: HTTPClient,
    metadataBaseURL: String,
    logger: Logger,
    retryConfiguration: RetryConfiguration
) async throws -> String {
    if secretName.hasPrefix("projects/") {
        // Caller supplied a full resource name; honor it verbatim, but ensure
        // it has a version suffix.
        if secretName.contains("/versions/") {
            return secretName
        }
        return "\(secretName)/versions/latest"
    }
    let project: String
    if let projectID, !projectID.isEmpty {
        project = projectID
    } else {
        project = try await fetchGCEProjectID(
            logger: logger,
            httpClient: httpClient,
            metadataBaseURL: metadataBaseURL,
            retryConfiguration: retryConfiguration
        )
    }
    return "projects/\(project)/secrets/\(secretName)/versions/latest"
}

// MARK: - High-level credential resolution

/// Fetches HMAC credentials from Google Secret Manager for use with SigV4
/// signing.
///
/// Builds a short-lived ``HTTPClient`` and ``TokenProvider``, fetches the
/// secret payload, decodes the s5cmd-format JSON, and returns the
/// ``SigV4Credentials``. All transient resources are torn down before
/// returning.
func resolveSigV4Credentials(
    secretName: String,
    logger: Logger,
    metadataBaseURL: String = "http://metadata.google.internal",
    secretManagerBaseURL: String = "https://secretmanager.googleapis.com",
    httpConnectTimeoutSeconds: Int = 10,
    httpReadTimeoutSeconds: Int = 30,
    retryConfiguration: RetryConfiguration = .default
) async throws -> SigV4Credentials {
    try await withHTTPClient(
        connectTimeout: .seconds(Int64(httpConnectTimeoutSeconds)),
        readTimeout: .seconds(Int64(httpReadTimeoutSeconds))
    ) { httpClient in
        let tokenProvider = try await TokenProvider.create(
            logger: logger,
            httpClient: httpClient,
            metadataBaseURL: metadataBaseURL,
            retryConfiguration: retryConfiguration
        )
        defer { tokenProvider.cancel() }

        let payload = try await fetchSecretManagerPayload(
            secretName: secretName,
            tokenProvider: tokenProvider,
            httpClient: httpClient,
            secretManagerBaseURL: secretManagerBaseURL,
            metadataBaseURL: metadataBaseURL,
            logger: logger,
            retryConfiguration: retryConfiguration
        )
        return try SigV4Credentials.decode(payload)
    }
}
