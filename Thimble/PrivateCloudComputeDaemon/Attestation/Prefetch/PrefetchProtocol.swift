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
//  PrefetchProtocol.swift
//  PrivateCloudCompute
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//

import Foundation
@_spi(HTTP) import Network
import PrivateCloudCompute

/// Protocol defining the public API for prefetching attestations from ROPES server.
/// This protocol allows different implementations for legacy and V3 attestation stores.
protocol PrefetchProtocol: Sendable {
    associatedtype SystemInfoType: SystemInfoProtocol

    /// System info for building headers
    var systemInfo: SystemInfoType { get }

    /// Configuration for building headers
    var config: any Configuration { get }

    /// Bundle identifier for the request
    var bundleIdentifier: BundleIdentifier? { get }

    /// Feature identifier for the request
    var featureIdentifier: String? { get }

    /// Whether this is a prewarm request
    var prewarm: Bool { get }

    /// Event stream continuation for publishing events
    var eventStreamContinuation: AsyncStream<ThimbledEvent>.Continuation { get }

    /// Sends prefetch request(s) to ROPES server and returns the responses.
    /// - Returns: An array of `Prefetch.Response` containing the prefetched attestations.
    /// - Throws: `PrivateCloudComputeError` if the prefetch fails or if attestations already exist.
    func sendRequest() async throws -> [Prefetch.Response]
}

// MARK: - Shared Helper Methods

extension PrefetchProtocol {
    /// Builds the common HTTP headers for prefetch requests.
    /// - Parameters:
    ///   - prefetchParameters: The workload parameters for the prefetch request.
    ///   - workloadParametersAsString: JSON-encoded workload parameters string.
    /// - Returns: HTTPFields configured for a prefetch request.
    /// - Throws: `PrivateCloudComputeError` if required identifiers are missing for prewarm.
    func makePrefetchRequestHeaders(
        prefetchParameters: Workload,
        workloadParametersAsString: String
    ) throws -> HTTPFields {
        var headers = HTTPFields([
            .init(name: .appleClientInfo, value: self.systemInfo.osInfo),
            .init(name: .appleWorkload, value: prefetchParameters.type),
            .init(name: .appleWorkloadParameters, value: workloadParametersAsString),
            .init(name: .contentType, value: HTTPField.Constants.contentTypeApplicationXProtobuf),
            .init(name: .userAgent, value: HTTPField.Constants.userAgentTrustedCloudComputeD),
        ])

        if prewarm {
            // Caller should have supplied a featureIdentifier and a bundleIdentifier here
            guard let bundleID = bundleIdentifier else {
                throw PrivateCloudComputeError(message: "missing bundleIdentifier")
            }
            guard let featureID = featureIdentifier else {
                throw PrivateCloudComputeError(message: "missing featureIdentifier")
            }
            headers[HTTPField.Name.appleBundleID] = bundleID.redactedValue
            headers[HTTPField.Name.appleFeatureID] = featureID
        } else {
            // Prefetches carry default values for these fields
            headers[HTTPField.Name.appleBundleID] = Bundle.main.bundleIdentifier
            headers[HTTPField.Name.appleFeatureID] = "backgroundActivity.prefetchRequest"
        }

        if let automatedDeviceGroup = self.systemInfo.automatedDeviceGroup {
            headers[.appleAutomatedDeviceGroup] = automatedDeviceGroup
        }

        if let testOptionsHeader = self.config[.testOptions] {
            headers[HTTPField.Name.appleTestOptions] = testOptionsHeader
        }

        if let routingGroupAlias = self.config[.routingGroupAlias] {
            headers[HTTPField.Name.appleRoutingGroupAlias] = routingGroupAlias
        }

        if let value = self.config[.trustedProxyRoutingGroupAlias] {
            headers[HTTPField.Name.appleTrustedProxyRoutingGroupAlias] = value
        }

        headers[.appleTrustedProxy] = "true"

        if let overrideCellID = self.config[.overrideCellID] {
            // if there is an overridden cell id, we want to send the server hint even in prefetch
            headers[HTTPField.Name.appleServerHint] = overrideCellID

            // and we need to mark that this is an override, so server knows to force it.
            headers[HTTPField.Name.appleServerHintForReal] = "true"
        }

        return headers
    }

    /// Creates an attestation verification error metric for reporting.
    /// - Parameters:
    ///   - requestIDForReporting: The request ID to use for reporting (may differ from actual request ID in production).
    ///   - nodeIdentifier: The node identifier for the attestation.
    ///   - error: The error that occurred during verification.
    ///   - validationStartTime: The time when validation started.
    /// - Returns: An `AttestationVerificationErrorMetric` configured for this prefetch.
    func makeAttestationVerificationErrorMetric(
        requestIDForReporting: UUID,
        nodeIdentifier: String,
        error: any Error,
        validationStartTime: Date
    ) -> AttestationVerificationErrorMetric {
        AttestationVerificationErrorMetric(
            eventTime: .now,
            clientRequestId: requestIDForReporting,
            bundleID: self.bundleIdentifier?.redactedValue,
            environment: self.config.environment(systemInfo: self.systemInfo).name,
            systemInfo: self.systemInfo,
            // this is true because we are on prefetch flow here
            isPrefetchedAttestation: true,
            nodeID: nodeIdentifier,
            error: error,
            attestationVerificationTime: .seconds(Date().timeIntervalSince(validationStartTime)),
            featureID: self.featureIdentifier
        )
    }
}
