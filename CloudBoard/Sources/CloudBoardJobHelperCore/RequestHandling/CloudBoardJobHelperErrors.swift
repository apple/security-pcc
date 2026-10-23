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

import CloudBoardAttestationDAPI
import CloudBoardCommon
import CloudBoardDomain
import CloudBoardLogging
import Foundation

protocol ResponseStatusConvertible: Error {
    var responseStatus: Proto_PrivateCloudCompute_PrivateCloudComputeResponse.ResponseStatus { get }
}

extension Error {
    var responseStatus: Proto_PrivateCloudCompute_PrivateCloudComputeResponse.ResponseStatus {
        switch self {
        case let convertibleError as ResponseStatusConvertible:
            return convertibleError.responseStatus
        default:
            return .internalError
        }
    }
}

enum WorkloadJobManagerError: ReportableError {
    case unknownWorkerID
    case unknownSubrequestID
    case closedSubrequestID
    case unknownCryptoMaterialHandle
    case workerRequestAfterFinal
    case workerNegotiationFailed(Error)
    case workerValidationFailed(Error)
    case missingResponseBypassContextID
    case missingResponseBypassCapability
    case findWorkerFailed(UUID, UInt32, String?)
    case workerSessionFailure(UUID, UInt32, String?)
    case receivedApplicationPayloadWithRequestBypassEnabled
    case receivedApplicationPayloadWithNewerProtocolVersion
    case receivedSubrequestPayloadWithOlderProtocolVersion
    case receivedDuplicateOpenClientSubrequest
    case receivedSubrequestOnNonProxyNode
    case receivedSubresponseOnNonProxyNode
    case receivedProxyInvokeOnProxyNode
    case cleaningClosedSubrequest
    case cloudAppInternalError
    case uncleanAppTermination
    case supportAppFailure
    case receivedUnsupportedRELFromWorker
    case workerAssetMetadataRELAfterFinal
    case unknownWorkloadType(String)
    case workloadTypeNotAllowed(String)
    case workloadTypeMismatch(expected: String, actual: String)
    case serviceNameNotAllowedByWorkerAttestation(String)

    var publicDescription: String {
        switch self {
        case .unknownWorkerID: "unknownWorkerID"
        case .unknownSubrequestID: "unknownSubrequestID"
        case .closedSubrequestID: "closedSubrequestID"
        case .unknownCryptoMaterialHandle: "unknownCryptoMaterialHandle"
        case .workerRequestAfterFinal: "workerRequestAfterFinal"
        case .workerNegotiationFailed(let error):
            "workerNegotiationFailed(\(String(reportable: error)))"
        case .workerValidationFailed(let error):
            "workerValidationFailed(\(String(reportable: error)))"
        case .missingResponseBypassContextID: "missingResponseBypassContextID"
        case .missingResponseBypassCapability: "missingResponseBypassCapability"
        case .findWorkerFailed(_, let ropesErrorCode, let ropesMessage):
            "findWorkerFailed(ropesErrorCode: \(ropesErrorCode), ropesMessage: \(ropesMessage ?? "nil"))"
        case .workerSessionFailure(_, let ropesErrorCode, let ropesMessage):
            "workerSessionFailure(ropesErrorCode: \(ropesErrorCode), ropesMessage: \(ropesMessage ?? "nil"))"
        case .receivedApplicationPayloadWithRequestBypassEnabled: "receivedApplicationPayloadWithRequestBypassEnabled"
        case .receivedApplicationPayloadWithNewerProtocolVersion: "receivedApplicationPayloadWithNewerProtocolVersion"
        case .receivedSubrequestPayloadWithOlderProtocolVersion: "receivedSubrequestPayloadWithOlderProtocolVersion"
        case .receivedDuplicateOpenClientSubrequest: "receivedDuplicateOpenClientSubrequest"
        case .receivedSubrequestOnNonProxyNode: "receivedSubrequestOnNonProxyNode"
        case .receivedProxyInvokeOnProxyNode: "receivedProxyInvokeOnProxyNode"
        case .receivedSubresponseOnNonProxyNode: "receivedSubresponseOnNonProxyNode"
        case .cleaningClosedSubrequest: "cleaningClosedSubrequest"
        case .cloudAppInternalError: "cloudAppInternalError"
        case .uncleanAppTermination: "uncleanAppTermination"
        case .supportAppFailure: "supportAppFailure"
        case .receivedUnsupportedRELFromWorker: "receivedUnsupportedRELFromWorker"
        case .workerAssetMetadataRELAfterFinal: "workerAssetMetadataRELAfterFinal"
        case .unknownWorkloadType(let workloadType):
            "unknownWorkloadType(\(workloadType))"
        case .workloadTypeNotAllowed(let workloadType):
            "workloadTypeNotAllowed(\(workloadType))"
        case .workloadTypeMismatch(let expected, let actual):
            "workloadTypeMismatch(expected: \(expected), actual: \(actual))"
        case .serviceNameNotAllowedByWorkerAttestation(let serviceName):
            "serviceNameNotAllowedByWorkerAttestation(\(serviceName))"
        }
    }
}

extension WorkloadJobManagerError: ResponseStatusConvertible {
    var responseStatus: Proto_PrivateCloudCompute_PrivateCloudComputeResponse.ResponseStatus {
        switch self {
        case .findWorkerFailed:
            return .proxyFindWorkerError
        case .workerValidationFailed:
            return .proxyWorkerValidationError
        case .receivedApplicationPayloadWithNewerProtocolVersion:
            return .invalidRequest
        case .unknownWorkerID:
            return .internalError
        case .unknownSubrequestID:
            return .internalError
        case .closedSubrequestID:
            return .internalError
        case .unknownCryptoMaterialHandle:
            return .internalError
        case .workerRequestAfterFinal:
            return .internalError
        case .workerNegotiationFailed:
            return .internalError
        case .missingResponseBypassContextID:
            return .internalError
        case .missingResponseBypassCapability:
            return .internalError
        case .workerSessionFailure:
            return .internalError
        case .receivedApplicationPayloadWithRequestBypassEnabled:
            return .internalError
        case .receivedSubrequestPayloadWithOlderProtocolVersion:
            return .internalError
        case .receivedDuplicateOpenClientSubrequest:
            return .internalError
        case .receivedSubrequestOnNonProxyNode:
            return .internalError
        case .receivedSubresponseOnNonProxyNode:
            return .internalError
        case .receivedProxyInvokeOnProxyNode:
            return .internalError
        case .cleaningClosedSubrequest:
            return .internalError
        case .cloudAppInternalError:
            return .internalError
        case .uncleanAppTermination:
            return .internalError
        case .supportAppFailure:
            return .internalError
        case .receivedUnsupportedRELFromWorker:
            return .internalError
        case .workerAssetMetadataRELAfterFinal:
            return .internalError
        case .unknownWorkloadType:
            return .invalidRequest
        case .workloadTypeNotAllowed:
            return .invalidRequest
        case .workloadTypeMismatch:
            return .invalidRequest
        case .serviceNameNotAllowedByWorkerAttestation:
            return .proxyWorkerValidationError
        }
    }
}

extension WorkloadJobManagerError: RequestExecutionErrorProtocol {
    var staticStringRepresentation: StaticString {
        switch self {
        case .unknownWorkerID: "unknownWorkerID"
        case .unknownSubrequestID: "unknownSubrequestID"
        case .closedSubrequestID: "closedSubrequestID"
        case .unknownCryptoMaterialHandle: "unknownCryptoMaterialHandle"
        case .workerRequestAfterFinal: "workerRequestAfterFinal"
        case .workerValidationFailed: "workerValidationFailed"
        case .missingResponseBypassContextID: "missingResponseBypassContextID"
        case .missingResponseBypassCapability: "missingResponseBypassCapability"
        case .findWorkerFailed: "findWorkerFailed"
        case .workerSessionFailure: "workerSessionFailure"
        case .receivedApplicationPayloadWithRequestBypassEnabled: "receivedApplicationPayloadWithRequestBypassEnabled"
        case .receivedApplicationPayloadWithNewerProtocolVersion: "receivedApplicationPayloadWithNewerProtocolVersion"
        case .receivedSubrequestPayloadWithOlderProtocolVersion: "receivedSubrequestPayloadWithOlderProtocolVersion"
        case .receivedDuplicateOpenClientSubrequest: "receivedDuplicateOpenClientSubrequest"
        case .receivedSubrequestOnNonProxyNode: "receivedSubrequestOnNonProxyNode"
        case .receivedProxyInvokeOnProxyNode: "receivedProxyInvokeOnProxyNode"
        case .receivedSubresponseOnNonProxyNode: "receivedSubresponseOnNonProxyNode"
        case .cleaningClosedSubrequest: "cleaningClosedSubrequest"
        case .workerNegotiationFailed: "workerNegotiationFailed"
        case .cloudAppInternalError: "cloudAppInternalError"
        case .uncleanAppTermination: "uncleanAppTermination"
        case .supportAppFailure: "supportAppFailure"
        case .receivedUnsupportedRELFromWorker: "receivedUnsupportedRELFromWorker"
        case .workerAssetMetadataRELAfterFinal: "workerAssetMetadataRELAfterFinal"
        case .unknownWorkloadType: "unknownWorkloadType"
        case .workloadTypeNotAllowed: "workloadTypeNotAllowed"
        case .workloadTypeMismatch: "workloadTypeMismatch"
        case .serviceNameNotAllowedByWorkerAttestation: "serviceNameNotAllowedByWorkerAttestation"
        }
    }

    var errorCode: UInt32 {
        return UInt32(self.responseStatus.rawValue)
    }

    var errorSource: RequestExecutionErrorSource {
        return RequestExecutionErrorSource.jobHelper
    }
}

enum WorkloadJobStateMachineError: ReportableError {
    case jobAbandoned
    case terminating
    case terminated
    case requestBypassed
    case requestBypassStateUnknown
}

extension WorkloadJobStateMachineError: RequestExecutionErrorProtocol {
    var staticStringRepresentation: StaticString {
        switch self {
        case .jobAbandoned: "WorkloadJobStateMachineError.jobAbandoned"
        case .terminating: "WorkloadJobStateMachineError.terminating"
        case .terminated: "WorkloadJobStateMachineError.terminated"
        case .requestBypassed: "WorkloadJobStateMachineError.requestBypassed"
        case .requestBypassStateUnknown: "WorkloadJobStateMachineError.requestBypassStateUnknown"
        }
    }

    var errorCode: UInt32 {
        return UInt32(self.responseStatus.rawValue)
    }

    var errorSource: RequestExecutionErrorSource {
        return RequestExecutionErrorSource.jobHelper
    }
}

enum OneTimeTokenError: ReportableError {
    case missingOneTimeToken
    case receivedOneTimeTokenTwice
}

extension OneTimeTokenError: ResponseStatusConvertible {
    var responseStatus: Proto_PrivateCloudCompute_PrivateCloudComputeResponse.ResponseStatus {
        switch self {
        case .missingOneTimeToken:
            return .unauthenticated
        case .receivedOneTimeTokenTwice:
            return .invalidRequest
        }
    }
}

extension OneTimeTokenError: RequestExecutionErrorProtocol {
    var staticStringRepresentation: StaticString {
        switch self {
        case .missingOneTimeToken: "oneTimeToken.missingOneTimeToken"
        case .receivedOneTimeTokenTwice: "oneTimeToken.receivedOneTimeTokenTwice"
        }
    }

    var errorCode: UInt32 {
        return UInt32(self.responseStatus.rawValue)
    }

    var errorSource: RequestExecutionErrorSource {
        return RequestExecutionErrorSource.jobHelper
    }
}

struct WorkloadJobManagerNoResponseSentError: RequestExecutionErrorProtocol {
    var staticStringRepresentation: StaticString {
        return "WorkloadJobManager.noResponseSent"
    }

    var errorCode: UInt32 {
        return UInt32(responseStatus.rawValue)
    }

    var errorSource: RequestExecutionErrorSource {
        return RequestExecutionErrorSource.jobHelper
    }
}

extension WorkerRackValidationError: ResponseStatusConvertible {
    var responseStatus: Proto_PrivateCloudCompute_PrivateCloudComputeResponse.ResponseStatus {
        switch self {
        case .rackIdChanged:
            return .proxyWorkerValidationError
        }
    }
}

extension WorkerRackValidationError: RequestExecutionErrorProtocol {
    package var staticStringRepresentation: StaticString {
        switch self {
        case .rackIdChanged: "workerRackValidationError.rackIdChanged"
        }
    }

    package var errorCode: UInt32 {
        return UInt32(self.responseStatus.rawValue)
    }

    package var errorSource: RequestExecutionErrorSource {
        return RequestExecutionErrorSource.jobHelper
    }
}

extension LengthPrefixBufferError: RequestExecutionErrorProtocol {
    package var staticStringRepresentation: StaticString {
        switch self {
        case .exceedingMaxMessageSize: "lengthPrefixBuffer.exceedingMaxMessageSize"
        case .receivedAdditionalChunkAfterFinalChunk: "lengthPrefixBuffer.receivedAdditionalChunkAfterFinalChunk"
        case .finalChunkContainsIncompleteMessage: "lengthPrefixBuffer.finalChunkContainsIncompleteMessage"
        }
    }

    package var errorCode: UInt32 {
        return UInt32(self.responseStatus.rawValue)
    }

    package var errorSource: RequestExecutionErrorSource {
        return RequestExecutionErrorSource.jobHelper
    }
}
