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

import CloudBoardProtos
import GRPCCore
import GRPCNIOTransportHTTP2
import Synchronization

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

package struct CloudAppSubRequestID: Hashable & Equatable & Sendable {
    package let id: UInt32

    package init(id: UInt32) {
        self.id = id
    }
}

struct CloudAppRequest: Sendable {
    let id: CloudAppSubRequestID
    let input: InputData
    let output: ResponseWriter
    let context: RequestContext
}

package typealias RPCWarmupContext = WarmupContext
extension RPCWarmupContext {
    package init(_ warmupContext: Proto_CloudApp_InvokeWorkloadRequest.WarmupContext) {
        let rid = warmupContext.nodeResourceID
        let nodeResourceID =
            if rid != 0 {
                NodeResourceID(rid)
            } else {
                // For backward compatibility, if the id isn't available, we pick one randomly, but in an easily recognisable range
                NodeResourceID(Int64.random(in: 1_000_000_000...Int64.max))
            }
        self.init(nodeResourceID: nodeResourceID)
    }
}

extension RPCWarmupContext {
    package init?(_ invokeWorkloadRequest: Proto_CloudApp_InvokeWorkloadRequest?) {
        guard let type = invokeWorkloadRequest?.type else {
            return nil
        }
        switch type {
        case .warmupContext(let warmupContext):
            self = .init(warmupContext)
            return
        default:
            return nil
        }
    }
}

extension Proto_CloudApp_InvokeWorkloadRequest {
    package init(_ warmupContext: RPCWarmupContext) {
        self = .with {
            $0.type = .warmupContext(
                .with { ctx in
                    ctx.nodeResourceID = warmupContext.nodeResourceID.rawValue
                }
            )
        }
    }
}

package typealias RPCConnectionContext = ConnectionContext
extension RPCConnectionContext {
    package init(_ connectionContext: Proto_CloudApp_InvokeWorkloadRequest.ConnectionContext) {
        self.requestID = connectionContext.requestID
        self.bundleID = connectionContext.bundleID
        self.bundleVersion = connectionContext.bundleVersion
        self.featureID = connectionContext.featureID
        self.clientInfo = connectionContext.clientInfo
        self.workloadType = connectionContext.workloadType
        self.workloadParameters = Dictionary(parameters: connectionContext.workloadParameters)
        self.automatedDeviceGroup = connectionContext.automatedDeviceGroup
        self.traceContext = connectionContext.hasTraceContext ? TraceContext(connectionContext.traceContext) : nil
    }
}

extension RPCConnectionContext {
    package init?(_ invokeWorkloadRequest: Proto_CloudApp_InvokeWorkloadRequest?) {
        guard let type = invokeWorkloadRequest?.type else {
            return nil
        }
        switch type {
        case .connectionContext(let connectionContext):
            self = .init(connectionContext)
            return
        default:
            return nil
        }
    }
}

extension Proto_CloudApp_InvokeWorkloadRequest {
    package init(_ connectionContext: RPCConnectionContext) {
        self = .with {
            $0.type = .connectionContext(
                .with {
                    $0.requestID = connectionContext.requestID
                    $0.bundleID = connectionContext.bundleID
                    $0.bundleVersion = connectionContext.bundleVersion
                    $0.featureID = connectionContext.featureID
                    $0.clientInfo = connectionContext.clientInfo
                    $0.workloadType = connectionContext.workloadType
                    $0.workloadParameters = connectionContext.workloadParameters.map { parameter in
                        .with {
                            $0.key = parameter.key
                            $0.value = parameter.value
                        }
                    }
                    $0.automatedDeviceGroup = connectionContext.automatedDeviceGroup
                    if let traceContext = connectionContext.traceContext {
                        $0.traceContext = Proto_CloudApp_TraceContext(traceContext)
                    }
                }
            )
        }
    }
}

extension KeyDerivationCoordinator.Result {
    package init(_ result: Proto_CloudApp_InvokeWorkloadRequest.KeyDerivationResult) {
        switch result.outcome {
        case .derivedKey(let derivedKey):
            self = .derivedKey(derivedKey)
        case .error(let message):
            self = .failure(message)
        case nil:
            self = .failure("cb_jobhelper returned a key derivation result with no outcome")
        }
    }
}

package struct RPCSubRequestContext {
    package let subRequestID: UInt32
    package let opaqueCryptoMaterial: [OpaqueCryptoMaterial]

    package init(subRequestID: UInt32, opaqueCryptoMaterial: [OpaqueCryptoMaterial] = []) {
        self.subRequestID = subRequestID
        self.opaqueCryptoMaterial = opaqueCryptoMaterial
    }
}

extension RPCSubRequestContext {
    package init(_ subRequestContext: Proto_CloudApp_InvokeWorkloadRequest.SubRequestContext) {
        self.subRequestID = subRequestContext.subRequestID
        self.opaqueCryptoMaterial = subRequestContext.opaqueCryptoMaterial.map(OpaqueCryptoMaterial.init)
    }
}

extension RPCSubRequestContext {
    package init?(_ invokeWorkloadRequest: Proto_CloudApp_InvokeWorkloadRequest?) {
        guard let type = invokeWorkloadRequest?.type else {
            return nil
        }
        switch type {
        case .subRequestContext(let subRequestContext):
            self = .init(subRequestContext)
            return
        default:
            return nil
        }
    }
}

extension Proto_CloudApp_InvokeWorkloadRequest {
    package init(_ subRequestContext: RPCSubRequestContext) {
        self = .with {
            $0.type = .subRequestContext(
                .with {
                    $0.subRequestID = subRequestContext.subRequestID
                    $0.opaqueCryptoMaterial = subRequestContext.opaqueCryptoMaterial.map { material in
                        .with {
                            $0.id = material.id
                            $0.material = material.material
                        }
                    }
                }
            )
        }
    }
}

extension RequestContext {
    package init(
        subRequestContext: RPCSubRequestContext,
        connectionContext: ConnectionContext,
        keyDeriver: any KeyDeriving
    ) {
        self.connectionContext = connectionContext
        self.opaqueCryptoMaterial = subRequestContext.opaqueCryptoMaterial
        self.keyDeriver = keyDeriver
    }
}

package struct RPCSubRequestInputData {
    let subRequestID: UInt32
    let message: Data

    package init(subRequestID: UInt32, message: Data) {
        self.subRequestID = subRequestID
        self.message = message
    }
}

extension RPCSubRequestInputData {
    package init(_ subRequestInputData: Proto_CloudApp_InvokeWorkloadRequest.SubRequestInputData) {
        self.subRequestID = subRequestInputData.subRequestID
        self.message = subRequestInputData.message
    }
}

extension RPCSubRequestInputData {
    package init?(_ invokeWorkloadRequest: Proto_CloudApp_InvokeWorkloadRequest?) {
        guard let type = invokeWorkloadRequest?.type else {
            return nil
        }
        switch type {
        case .subRequestInputData(let subRequestInputData):
            self = .init(subRequestInputData)
            return
        default:
            return nil
        }
    }
}

extension Proto_CloudApp_InvokeWorkloadRequest {
    package init(_ subRequestInputData: RPCSubRequestInputData) {
        self = .with {
            $0.type = .subRequestInputData(
                .with {
                    $0.subRequestID = subRequestInputData.subRequestID
                    $0.message = subRequestInputData.message
                }
            )
        }
    }
}

package struct RPCSubRequestEndOfInput {
    let subRequestID: UInt32

    package init(subRequestID: UInt32) {
        self.subRequestID = subRequestID
    }
}

extension RPCSubRequestEndOfInput {
    package init(_ subRequestEndOfInput: Proto_CloudApp_InvokeWorkloadRequest.SubRequestEndOfInput) {
        self.subRequestID = subRequestEndOfInput.subRequestID
    }
}

extension RPCSubRequestEndOfInput {
    package init?(_ invokeWorkloadRequest: Proto_CloudApp_InvokeWorkloadRequest?) {
        guard let type = invokeWorkloadRequest?.type else {
            return nil
        }
        switch type {
        case .subRequestEndOfInput(let subRequestEndOfInput):
            self = .init(subRequestEndOfInput)
            return
        default:
            return nil
        }
    }
}

extension Proto_CloudApp_InvokeWorkloadRequest {
    package init(_ subRequestEndOfInput: RPCSubRequestEndOfInput) {
        self = .with {
            $0.type = .subRequestEndOfInput(
                .with {
                    $0.subRequestID = subRequestEndOfInput.subRequestID
                }
            )
        }
    }
}

package struct RPCWarmupComplete {
}

extension RPCWarmupComplete {
    package init(_ warmupComplete: Proto_CloudApp_InvokeWorkloadResponse.WarmupComplete) {
    }
}

extension RPCWarmupComplete {
    package init?(_ invokeWorkloadResponse: Proto_CloudApp_InvokeWorkloadResponse?) {
        guard let type = invokeWorkloadResponse?.type else {
            return nil
        }
        switch type {
        case .warmupComplete(let warmupComplete):
            self = .init(warmupComplete)
            return
        default:
            return nil
        }
    }
}

extension Proto_CloudApp_InvokeWorkloadResponse {
    package init(_ warmupComplete: RPCWarmupComplete) {
        self = .with {
            $0.type = .warmupComplete(
                .with { _ in
                }
            )
        }
    }
}

package struct RPCResponseOutputData {
    let subRequestID: UInt32
    let message: Data
}

extension RPCResponseOutputData {
    package init(_ responseOutputData: Proto_CloudApp_InvokeWorkloadResponse.ResponseOutputData) {
        self.subRequestID = responseOutputData.subRequestID
        self.message = responseOutputData.message
    }
}

extension RPCResponseOutputData {
    package init?(_ invokeWorkloadResponse: Proto_CloudApp_InvokeWorkloadResponse?) {
        guard let type = invokeWorkloadResponse?.type else {
            return nil
        }
        switch type {
        case .responseOutputData(let responseOutputData):
            self = .init(responseOutputData)
            return
        default:
            return nil
        }
    }
}

extension Proto_CloudApp_InvokeWorkloadResponse {
    package init(_ responseOutputData: RPCResponseOutputData) {
        self = .with {
            $0.type = .responseOutputData(
                .with {
                    $0.subRequestID = responseOutputData.subRequestID
                    $0.message = responseOutputData.message
                }
            )
        }
    }
}

package struct RPCResponseEndOfOutput {
    enum `Type` {
        case success
        case error(message: String)
        case unspecified
    }

    let subRequestID: UInt32
    let type: `Type`
}

extension RPCResponseEndOfOutput {
    package init(_ responseEndOfOutput: Proto_CloudApp_InvokeWorkloadResponse.ResponseEndOfOutput) {
        self.subRequestID = responseEndOfOutput.subRequestID
        guard let type = responseEndOfOutput.type else {
            self.type = .unspecified
            return
        }
        switch type {
        case .success:
            self.type = .success
            return
        case .error(let errorMessage):
            self.type = .error(message: errorMessage.message)
        }
    }
}

extension RPCResponseEndOfOutput {
    package init?(_ invokeWorkloadResponse: Proto_CloudApp_InvokeWorkloadResponse?) {
        guard let type = invokeWorkloadResponse?.type else {
            return nil
        }
        switch type {
        case .responseEndOfOutput(let responseEndOfOutput):
            self = .init(responseEndOfOutput)
            return
        default:
            return nil
        }
    }
}

extension Proto_CloudApp_InvokeWorkloadResponse {
    package init(_ responseEndOfOutput: RPCResponseEndOfOutput) {
        self = .with {
            $0.type = .responseEndOfOutput(
                .with {
                    $0.subRequestID = responseEndOfOutput.subRequestID
                    switch responseEndOfOutput.type {
                    case .success:
                        $0.type = .success(
                            .with { _ in
                            }
                        )
                    case .error(let message):
                        $0.type = .error(
                            .with {
                                $0.message = message
                            }
                        )
                    case .unspecified:
                        $0.type = nil
                    }
                }
            )
        }
    }
}

package struct RPCCloudAppComplete {
    enum `Type` {
        case success
        case error(message: String)
        case unspecified
    }
    let type: `Type`
}

extension RPCCloudAppComplete {
    package init(_ cloudAppComplete: Proto_CloudApp_InvokeWorkloadResponse.CloudAppComplete) {
        guard let type = cloudAppComplete.type else {
            self.type = .unspecified
            return
        }
        switch type {
        case .success:
            self.type = .success
            return
        case .error(let errorMessage):
            self.type = .error(message: errorMessage.message)
        }
    }
}

extension RPCCloudAppComplete {
    package init?(_ invokeWorkloadResponse: Proto_CloudApp_InvokeWorkloadResponse?) {
        guard let type = invokeWorkloadResponse?.type else {
            return nil
        }
        switch type {
        case .cloudAppComplete(let cloudAppComplete):
            self = .init(cloudAppComplete)
            return
        default:
            return nil
        }
    }
}

extension Proto_CloudApp_InvokeWorkloadResponse {
    package init(_ cloudAppComplete: RPCCloudAppComplete) {
        self = .with {
            $0.type = .cloudAppComplete(
                .with {
                    switch cloudAppComplete.type {
                    case .success:
                        $0.type = .success(
                            .with { _ in
                            }
                        )
                    case .error(let message):
                        $0.type = .error(
                            .with {
                                $0.message = message
                            }
                        )
                    case .unspecified:
                        $0.type = nil
                    }
                }
            )
        }
    }
}

extension [String: [String]] {
    package init(parameters: [Proto_CloudApp_InvokeWorkloadRequest.ConnectionContext.WorkloadParameter]) {
        self = [:]

        for parameter in parameters {
            self[parameter.key, default: []].append(contentsOf: parameter.value)
        }
    }
}

extension TraceContext {
    package init(_ proto: Proto_CloudApp_TraceContext) {
        self.init(
            traceIDMostSigBits: proto.traceID.mostSigBits,
            traceIDLeastSigBits: proto.traceID.leastSigBits,
            spanID: proto.spanID,
            parentSpanID: proto.hasParentSpanID ? proto.parentSpanID : nil
        )
    }

    package init(_ proto: Proto_CloudBoard_TraceContext) {
        self.init(
            traceIDMostSigBits: proto.traceID.mostSigBits,
            traceIDLeastSigBits: proto.traceID.leastSigBits,
            spanID: proto.spanID,
            parentSpanID: proto.hasParentSpanID ? proto.parentSpanID : nil
        )
    }
}

extension Proto_CloudApp_TraceContext {
    package init(_ traceContext: TraceContext) {
        self = .with {
            $0.traceID = .with {
                $0.mostSigBits = traceContext.traceIDMostSigBits
                $0.leastSigBits = traceContext.traceIDLeastSigBits
            }
            $0.spanID = traceContext.spanID
            if let parentSpanID = traceContext.parentSpanID {
                $0.parentSpanID = parentSpanID
            }
        }
    }
}

extension OpaqueCryptoMaterial {
    package init(_ proto: Proto_CloudApp_InvokeWorkloadRequest.OpaqueCryptoMaterial) {
        self.init(id: proto.id, material: proto.material)
    }
}

enum EarlyShutdownDecision {
    @TaskLocal
    static var decision = DecisionBox()
}

final class DecisionBox: Sendable {
    let cancelTask: Mutex<Bool> = Mutex(false)
}
