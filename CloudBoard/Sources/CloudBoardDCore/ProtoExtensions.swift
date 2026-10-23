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


import CloudBoardCommon
import CloudBoardDomain
import CloudBoardJobHelperAPI
import CloudBoardPlatformUtilities
import Foundation
import InternalSwiftProtobuf

// There is quite a lot of short and simple code mapping between proto generated types and our internal ones
// They can go here to keep the core logic files simpler

extension Com_Apple_Cloudboard_Api_V1_EnsembleNegotiation {
    internal init(_ negotiation: EnsembleNegotiation) {
        self.ensembles = negotiation.ensembles.map {
            var proto = Proto_Ropes_Common_EnsembleInstanceId()
            proto.ensembleID = $0.ensembleId
            proto.bootID = $0.bootId
            return proto
        }
    }
}

extension EnsembleNegotiation {
    internal init(_ negotiation: Com_Apple_Cloudboard_Api_V1_EnsembleNegotiation) throws {
        try self.init(
            negotiation.ensembles.map {
                // any negotiation would have fail later, this just lets us fail fast
                var missingFields: [String] = []
                if $0.ensembleID.isEmpty {
                    missingFields.append("ensembleID")
                }
                if $0.bootID.isEmpty {
                    missingFields.append("bootID")
                }
                guard missingFields.isEmpty else {
                    throw InvokeProxyDialBackError.negotiationMissingInformation(missingFields: missingFields)
                }
                return EnsembleInstanceId(ensembleId: $0.ensembleID, bootId: $0.bootID)
            }
        )
    }
}

extension Proto_Ropes_Common_EnsembleInstanceId {
    internal init(_ ensemble: EnsembleInstanceId) {
        self.ensembleID = ensemble.ensembleId
        self.bootID = ensemble.bootId
    }
}

extension Com_Apple_Cloudboard_Api_V1_InvokeProxyInitiate.NegotiateEnsembleChoice.Pick {
    internal init(_ pick: PickOptions) {
        self.numProvidedChoices = UInt32(pick.requiredEnsemblesFromROPES)
        self.numSelectedChoices = UInt32(pick.allowedEnsemblesFromProxy)
        self.ratioCanScaleTo = UInt32(pick.ratioCanScaleTo)
    }
}

extension Com_Apple_Cloudboard_Api_V1_LoadResponse {
    init(
        _ loadLevel: ServiceHealthMonitor.Status.LoadLevel,
        affinityKeysInProgress: [Com_Apple_Cloudboard_Api_V1_AffinityKey] = []
    ) {
        self = .with {
            $0.currentBatchSize = UInt32(loadLevel.currentBatchSize)
            $0.maxBatchSize = UInt32(loadLevel.maxBatchSize)
            $0.optimalBatchSize = UInt32(loadLevel.optimalBatchSize)
            $0.affinityKeysInProgress = affinityKeysInProgress
        }
    }
}

extension Com_Apple_Cloudboard_Api_V1_AffinityKey: CustomStringConvertible {
    var description: String {
        "\(self.category)/\(self.data)"
    }
}

func extractRequestID(
    from request: Com_Apple_Cloudboard_Api_V1_InvokeWorkloadRequest
) -> String? {
    switch request.type {
    case .parameters(let parameters):
        return parameters.requestID
    default:
        return nil
    }
}

extension CloudBoardDaemonToJobHelperMessage {
    init?(from cloudBoardRequest: Com_Apple_Cloudboard_Api_V1_InvokeWorkloadRequest) {
        switch cloudBoardRequest.type {
        case .parameters(let parameters):
            // validation was handled elsewhere, we just fail to parse
            let responseBypassMode = try? ResponseBypassMode(from: parameters)
            guard let responseBypassMode else {
                return nil
            }
            self = .parameters(.init(
                requestID: parameters.requestID,
                oneTimeToken: parameters.oneTimeToken,
                encryptedKey: .init(
                    keyID: parameters.decryptionKey.keyID,
                    key: parameters.decryptionKey.encryptedPayload
                ),
                parametersReceived: .now,
                plaintextMetadata: .init(tenantInfo: parameters.tenantInfo, workload: parameters.workload),
                responseBypassMode: responseBypassMode,
                requestBypassed: parameters.requestBypassed,
                requestedNack: parameters.requestNack,
                traceContext: .init(
                    traceID: parameters.traceContextV1.traceID,
                    spanID: TraceContextCache.singletonCache
                        .getSpanID(
                            forKeyWithID: parameters.requestID,
                            forKeyWithSpanIdentifier: SpanIdentifier.invokeWorkload
                        ) ?? UInt64.random(in: 0 ..< UInt64.max)
                ),
                patIssuer: parameters.hasPatIssuer ? parameters.patIssuer : nil
            ))
        case .requestChunk(let requestChunk):
            self = .requestChunk(requestChunk.encryptedPayload, isFinal: requestChunk.isFinal)
        case .none, .setup, .terminate:
            return nil
        }
    }
}

extension Parameters.PlaintextMetadata {
    init(
        tenantInfo: Proto_Ropes_Common_TenantInfo,
        workload: Proto_Ropes_Common_Workload
    ) {
        self.init(
            bundleID: tenantInfo.bundleID,
            bundleVersion: tenantInfo.bundleVersion,
            featureID: tenantInfo.featureID,
            clientInfo: tenantInfo.clientInfo,
            workloadType: workload.type,
            workloadParameters: Dictionary(parameters: workload.param),
            automatedDeviceGroup: tenantInfo.automatedDeviceGroup
        )
    }
}

extension [Proto_Ropes_Common_Workload.Parameter] {
    init(_ tags: [String: [String]]) {
        self = tags.map { key, values in
            .with {
                $0.key = key
                $0.value = values
            }
        }
    }
}

extension Proto_Ropes_Common_RequestExecutionError.Source {
    init(from source: RequestExecutionErrorSource) {
        switch source {
        case .cloudApp:
            self = .cloudApp
        case .jobHelper:
            self = .jobHelper
        case .cloudAppFramework:
            self = .cloudAppFramework
        case .bridged:
            // We do not need to report bridged errors to Client currently, so marking it undefined
            self = .undefined
        case .undefined:
            self = .undefined
        }
    }
}

extension [String: [String]] {
    init(parameters: [Proto_Ropes_Common_Workload.Parameter]) {
        self = [:]

        for parameter in parameters {
            self[parameter.key, default: []].append(contentsOf: parameter.value)
        }
    }
}

extension ResponseBypassMode {
    init(from parameters: Com_Apple_Cloudboard_Api_V1_InvokeWorkloadRequest.Parameters) throws {
        // so old it doesn't know about it
        guard parameters.hasTrustedProxyMetadata else {
            self = .none
            return
        }
        // new but not specified at all
        guard parameters.trustedProxyMetadata.hasResponseBypassMode else {
            self = .none
            return
        }
        switch parameters.trustedProxyMetadata.responseBypassMode {
        case .none:
            self = .none
        case .matchRequestCiphersuiteSharedAeadState:
            self = .matchRequestCiphersuiteSharedAeadState
        case .UNRECOGNIZED(let value):
            // we don't know what this version is, so we fail safe
            throw GRPCTransformableError.bypassVersionInvalid(value: value)
        }
    }
}
