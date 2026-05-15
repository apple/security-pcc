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

import CloudBoardDomain
import CloudBoardJobAPI
import CloudBoardJobHelperAPI
import CryptoKit
import Foundation

// input and output on the inbound path
enum PipelinePayload: Equatable, Sendable {
    case warmup(ManagedWarmupInfo)
    // Provided only when running within a proxy, once and only once
    // before *any* non warmup message, and no more mesages will be sent after it
    case nackAndExit(ParametersData)
    // for the cloud app, this is only a subset of the data associated with the actual parameters
    case parameters(ParametersData)
    // extracted from the parameters and sent separately
    case oneTimeToken(Data)
    case chunk(FinalizableChunk<Data>)
    case openClientSubrequest(
        clientSubrequestId: UInt32,
        cryptoMaterialHandles: [CryptoMaterialHandle],
        isDiscardable: Bool
    )
    case subrequestPayload(clientSubrequestId: UInt32, chunk: Data)
    case closeSubrequest(clientSubrequestId: UInt32)
    case cancelSubrequest(clientSubrequestId: UInt32)
    // Only used between WorkloadJobManager and cloud app
    case endOfInput
    /// Provided only when running within a proxy, once and only once, before any worker messages.
    /// The `keyID` is the identifier for the attestation (and associated key) used for the request
    /// extracted from the parameters and sent separately.
    /// The `workload` is the workload parameters the request is being run with.
    case parametersMetaData(keyID: Data, workload: [String: [String]])
    /// ROPES wishes to negotiate a newly trusted worker
    case workerNegotiatePick(
        providedByRopes: WorkerNegotiatePickInfo
    )
    /// A worker has been chosen by ROPES
    case selectedWorker(
        info: WorkerAttestationInfo,
        dek: SymmetricKey,
        workloadParameters: [String: [String]]
    )
    // Currently represents both encoded PrivateCloudCompute response chunks between CloudBoardMessenger and
    // WorkloadJobManager, and actual application payload chunks between WorkloadJobManager and the cloud app
    case workerResponseChunk(UUID, FinalizableChunk<Data>)
    // Only used between WorkloadJobManager and cloud app. For now we only indicate to the cloud app whether the
    // PrivateCloudCompute response summary (or in absence of a response summary the gRPC response status) from the
    // worker indicated the request was handled successfuly or not.
    case workerResponseSummary(UUID, status: WorkerResponseStatus)
    // Only used between CloudBoardMessenger and WorkloadJobManager
    case workerResponseClose(
        UUID,
        grpcStatus: Int,
        grpcMessage: String?,
        ropesErrorCode: UInt32?,
        ropesMessage: String?
    )
    case workerResponseEOF(UUID)
    // Only used between WorkloadJobManager and cloud app
    case workerFound(UUID, info: WorkerFoundInfo, spanID: UInt64?)
    case teardown
    case abandon
    case applicationDataChunkingConfig(ApplicationDataChunkingConfiguration)
    // Only used within jobhelper for CloudboardMessenger to notify WorkloadJobManager
    case readyToSendAssetsMetadataRELEntry
}

extension PipelinePayload {
    static func chunk(_ chunk: Data, isFinal: Bool = false) -> Self {
        .chunk(.init(chunk: chunk, isFinal: isFinal))
    }
}
