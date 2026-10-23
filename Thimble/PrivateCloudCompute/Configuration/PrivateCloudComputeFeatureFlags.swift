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
//  PrivateCloudComputeFeatureFlags.swift
//  PrivateCloudCompute
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

import FeatureFlags

package enum PrivateCloudComputeFeatureFlags: FeatureFlagsKey {
    /// During prewarm, issue a token fetch for its side effects
    case fetchAuthTokenOnPrewarm

    /// Submit ``FeatureUsageSummaryMetric`` events generated by successful requests
    case featureUsageAnalyzer

    /// Enable chunked data transfer for memory optimization
    case applicationDataChunking

    /// Enable chunked data transfer on non-production environments.
    /// Mutually exclusive with `applicationDataChunking`: on pre-production, this flag alone
    /// controls chunking; on production, `applicationDataChunking` controls it.
    /// Setting `applicationDataChunkingSize` to 0 disables chunking regardless of environment.
    case applicationDataChunkingPreProduction

    /// When enabled, client info header as well as telemetry events, will include an identification of whether the
    /// build is seed or not.
    case identifySeedBuildsInClientInfo

    /// When enabled, it changes how cancellations are handled. Instead of canceling a TrustedRequest in the daemon right away, it will
    /// signal to the server if possible, and then it will attempt to wait for the request to finish before eventually canceling the task.
    case requestCancellationV2

    /// Enable the new V3 AttestationStore with reusable pool model and two-phase commit
    case attestationStoreV3

    /// Enable fetching of rate limits from the vault.
    case vaultConfiguration

    /// When enabled, enforce the required inline attestation count for anti-targetability on production.
    case enforceAntiTargetability

    /// When enabled, enforce the required inline attestation count for anti-targetability on non-production
    /// environments (e.g. carry).
    case enforceAntiTargetabilityOnPreProduction

    /// When enabled, enforce the required attestation count for anti-targetability during prefetch.
    case enforceAntiTargetabilityOnPrefetch

    /// When enabled, we would send `routing-key` inside of workload params on the invoke and prefetch.
    case routingKey

    /// Enable reputation tokens. When enabled, pccd would send reputation token request
    /// to the server and handle a corresponding response from the server.
    case reputationTokens

    /// When enabled, pccd would fetch
    case waitlistTokens

    /// When enabled, pccd runs its own watchdog timer around communications with the server and times out the
    /// request after inactivity.
    case clientTimeout

    /// Resolve bundle identifiers using the SecTask framework for code-signing verification.
    case secTaskBundleIDResolution

    /// Cap NWConnection reads to reduce peak memory usage during large responses (e.g. attestation prefetch).
    case boundedNetworkReads2

    /// Store the daemon's state in a data-vaulted Protected System container on macOS.
    case protectedSystemContainerMacOS

    /// Store the daemon's state in a data-vaulted Protected System container on embedded platforms.
    case protectedSystemContainerEmbedded

    /// When enabled, supported REL compression algorithms are announced as part of Cababilities message.
    case requestExecutionLogCompression

    package var domain: StaticString {
        return "PrivateCloudCompute"
    }

    package var feature: StaticString {
        switch self {
        case .fetchAuthTokenOnPrewarm: return "fetchAuthTokenOnPrewarm"
        case .featureUsageAnalyzer: return "featureUsageAnalyzer"
        case .applicationDataChunking: return "applicationDataChunking"
        case .applicationDataChunkingPreProduction: return "applicationDataChunkingPreProduction"
        case .identifySeedBuildsInClientInfo: return "identifySeedBuildsInClientInfo"
        case .requestCancellationV2: return "requestCancellationV2"
        case .attestationStoreV3: return "attestationStoreV3"
        case .vaultConfiguration: return "vaultConfiguration"
        case .enforceAntiTargetabilityOnPreProduction: return "enforceAntiTargetabilityOnPreProduction"
        case .enforceAntiTargetability: return "enforceAntiTargetability"
        case .enforceAntiTargetabilityOnPrefetch: return "enforceAntiTargetabilityOnPrefetch"
        case .routingKey: return "routingKey"
        case .reputationTokens: return "reputationTokens"
        case .waitlistTokens: return "waitlistTokens"
        case .clientTimeout: return "clientTimeout"
        case .secTaskBundleIDResolution: return "secTaskBundleIDResolution"
        case .boundedNetworkReads2: return "boundedNetworkReads2"
        case .protectedSystemContainerMacOS: return "protectedSystemContainerMacOS"
        case .protectedSystemContainerEmbedded: return "protectedSystemContainerEmbedded"
        case .requestExecutionLogCompression: return "requestExecutionLogCompression"
        }
    }
}
