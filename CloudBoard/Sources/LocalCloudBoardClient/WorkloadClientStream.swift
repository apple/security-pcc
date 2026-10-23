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

internal import Combine
import Foundation
internal import InternalGRPC
internal import InternalSwiftProtobuf

typealias InvokeWorkloadRequest = Com_Apple_Cloudboard_Api_V1_InvokeWorkloadRequest
typealias InvokeWorkloadResponse = Com_Apple_Cloudboard_Api_V1_InvokeWorkloadResponse
typealias InvokeWorkloadClientStreamCall = BidirectionalStreamingCall<InvokeWorkloadRequest, InvokeWorkloadResponse>

enum CloudBoardResponseChunk {
    case apiChunk(Proto_Ropes_Common_Chunk)
    case stringChunk(String)
}

class WorkloadAsyncClientStream {
    private let client: LocalCloudBoardGRPCAsyncClient.CloudBoardGrpcClient

    public init(client: LocalCloudBoardGRPCAsyncClient.CloudBoardGrpcClient) {
        self.client = client
    }

    /// This does a very simplistic mode without streaming and without proxy support
    /// You likely should use ``startWorkload`` and explicitly send the auth token and
    /// request chunks
    public func submitWorkload(
        keyID: Data,
        key: Data,
        chunks: [Data],
        requestID: String,
        metaData: InvokeWorkloadRequestMetaData
    ) -> GRPCAsyncResponseStream<Com_Apple_Cloudboard_Api_V1_InvokeWorkloadResponse> {
        let (requestContinuation, responseStream) = self.startWorkload(
            decryptionKey: .helper(keyID: keyID, key: key),
            requestID: requestID,
            metaData: metaData,
            requestBypassed: false,
            responseByPass: nil
        )

        requestContinuation.yield(self.makeAuthToken(.init()))

        // send request chunks
        for (index, chunk) in chunks.enumerated() {
            requestContinuation.yield(self.chunkRequest(data: chunk, isFinal: index == chunks.count - 1))
        }
        requestContinuation.finish()
        return responseStream
    }

    enum DecryptionKeySpecification {
        /// A convenience function that tales what we currently know is required
        case helper(keyID: Data, key: Data)
        /// so we can pass through _exactly_ what the proxy sends like ROPES should
        case explicit(dek: Proto_Ropes_Common_DecryptionKey)

        func toProto() -> Proto_Ropes_Common_DecryptionKey {
            switch self {
            case .helper(keyID: let keyID, key: let key):
                return Proto_Ropes_Common_DecryptionKey.with {
                    $0.keyID = keyID
                    $0.encryptedPayload = key
                }
            case .explicit(dek: let dek):
                return dek
            }
        }
    }

    /// Sends the setup request *nothing* else
    public func startSetup()
        -> (
            AsyncStream<InvokeWorkloadRequest>.Continuation,
            GRPCAsyncResponseStream<Com_Apple_Cloudboard_Api_V1_InvokeWorkloadResponse>
        ) {
        let (requestStream, requestContinuation) = AsyncStream.makeStream(
            of: InvokeWorkloadRequest.self
        )

        let responseStream = self.client.invokeWorkload(requestStream)

        // send setup request to start warming process
        requestContinuation.yield(self.setupRequest())
        return (requestContinuation, responseStream)
    }

    /// Sends the setup request and the parameters, nothing else
    public func startWorkload(
        decryptionKey: DecryptionKeySpecification,
        requestID: String,
        metaData: InvokeWorkloadRequestMetaData,
        requestBypassed: Bool = false,
        // nil is not the same as none, nil is what (very) old requests would have
        responseByPass: Com_Apple_Cloudboard_Api_V1_ResponseBypassMode? = nil
    )
        -> (
            AsyncStream<InvokeWorkloadRequest>.Continuation,
            GRPCAsyncResponseStream<Com_Apple_Cloudboard_Api_V1_InvokeWorkloadResponse>
        ) {
        let (requestContinuation, responseStream) = self.startSetup()

        // send parameters with decryption key
        requestContinuation.yield(self.parametersRequest(
            decryptionKey: decryptionKey,
            requestID: requestID,
            metaData: metaData,
            requestBypassed: requestBypassed,
            responseBypass: responseByPass
        ))
        return (requestContinuation, responseStream)
    }

    /// Deliberately not providing a send for this, it needs to be handled along with the rest of the
    /// encrypted request stream for request bypass
    public func makeAuthToken(
        _ encryptedAuthToken: Data
    ) -> InvokeWorkloadRequest {
        return self.chunkRequest(data: encryptedAuthToken, isFinal: false)
    }

    private func setupRequest() -> InvokeWorkloadRequest {
        let request = InvokeWorkloadRequest.with {
            $0.setup = Com_Apple_Cloudboard_Api_V1_InvokeWorkloadRequest.Setup()
        }
        return request
    }

    internal func makeParameters(
        decryptionKey: DecryptionKeySpecification,
        requestID: String,
        metaData: InvokeWorkloadRequestMetaData,
        requestBypassed: Bool,
        responseBypass: Com_Apple_Cloudboard_Api_V1_ResponseBypassMode? = nil,
        requestNack: Bool = false
    ) -> InvokeWorkloadRequest.Parameters {
        return Com_Apple_Cloudboard_Api_V1_InvokeWorkloadRequest.Parameters.with {
            $0.decryptionKey = decryptionKey.toProto()
            // set the tenant info values to clearly identify LocalCloudBoardClient traffic
            $0.tenantInfo = .with {
                $0.bundleID = "local-cloudboard-client"
                $0.automatedDeviceGroup = "local-test-device"
            }
            $0.workload = .init(type: metaData.workloadType, parameters: metaData.workloadParameters)
            $0.requestID = requestID
            $0.traceContextV1 = .with {
                $0.traceID = requestID
            }
            $0.requestBypassed = requestBypassed
            $0.requestNack = requestNack
            $0.patIssuer = metaData.patIssuer
            if let responseBypass {
                $0.trustedProxyMetadata = .with {
                    $0.responseBypassMode = responseBypass
                }
            }
        }
    }

    internal func wrapParameters(
        _ parameters: InvokeWorkloadRequest.Parameters
    ) -> InvokeWorkloadRequest {
        return InvokeWorkloadRequest.with {
            $0.parameters = parameters
        }
    }

    private func parametersRequest(
        decryptionKey: DecryptionKeySpecification,
        requestID: String,
        metaData: InvokeWorkloadRequestMetaData,
        requestBypassed: Bool,
        responseBypass: Com_Apple_Cloudboard_Api_V1_ResponseBypassMode? = nil
    ) -> InvokeWorkloadRequest {
        let parameters = self.makeParameters(
            decryptionKey: decryptionKey,
            requestID: requestID,
            metaData: metaData,
            requestBypassed: requestBypassed,
            responseBypass: responseBypass
        )
        return self.wrapParameters(parameters)
    }

    private func chunkRequest(data: Data, isFinal: Bool) -> InvokeWorkloadRequest {
        let requestChunk = Proto_Ropes_Common_Chunk.with {
            $0.encryptedPayload = data
            $0.isFinal = isFinal
        }
        let request = InvokeWorkloadRequest.with {
            $0.requestChunk = requestChunk
        }
        return request
    }
}

extension Proto_PrivateCloudCompute_PrivateCloudComputeRequest {
    typealias PrivateCloudComputeRequest = Proto_PrivateCloudCompute_PrivateCloudComputeRequest
    typealias PrivateCloudComputeRequestType = PrivateCloudComputeRequest.OneOf_Type

    static func serialized(with type: PrivateCloudComputeRequestType) throws -> Data {
        var request = try PrivateCloudComputeRequest.with {
            $0.type = type
        }.serializedData()
        request.prependLength()
        return request
    }
}

extension Proto_PrivateCloudCompute_PrivateCloudComputeResponse {
    typealias PrivateCloudComputeResponse = Proto_PrivateCloudCompute_PrivateCloudComputeResponse
    typealias PrivateCloudComputeResponseType = PrivateCloudComputeResponse.OneOf_Type

    static func serialized(with type: PrivateCloudComputeResponseType) throws -> Data {
        var request = try PrivateCloudComputeResponse.with {
            $0.type = type
        }.serializedData()
        request.prependLength()
        return request
    }
}

extension InvokeWorkloadRequest {
    static func serialized(with type: InvokeWorkloadRequest.OneOf_Type) throws -> Data {
        return try InvokeWorkloadRequest.with { $0.type = type }.serialized()
    }

    func serialized() throws -> Data {
        var request = try self.serializedData()
        request.prependLength()
        return request
    }
}
