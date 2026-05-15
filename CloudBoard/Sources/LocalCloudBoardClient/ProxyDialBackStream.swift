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

import Foundation
internal import InternalGRPC
internal import InternalSwiftProtobuf

class ProxyDialBackStream {
    typealias InvokeProxyDialBackRequest = Com_Apple_Cloudboard_Api_V1_InvokeProxyDialBackRequest
    typealias ComputeNodeAttestation = Com_Apple_Cloudboard_Api_V1_FetchAttestationResponse.Attestation
    typealias ComputeNodeWorkLoadResponse = Com_Apple_Cloudboard_Api_V1_InvokeWorkloadResponse

    private let proxyClient: LocalCloudBoardGRPCAsyncClient.CloudBoardGrpcClient

    init(client: LocalCloudBoardGRPCAsyncClient.CloudBoardGrpcClient) {
        self.proxyClient = client
    }

    /// Start GRPC stream between LocalCloudBoardClient and the Proxy App
    /// - Parameters:
    ///   - workerId: The worker ID which was provided by Proxy App in the ProxyDialBackInitiate
    /// - Returns: Tuple with continuation for Proxy App to send chunks to compute node and the Response stream back
    /// from the compute node
    public func startDialBackStream(workerId: String) -> (
        AsyncStream<InvokeProxyDialBackRequest>.Continuation,
        GRPCAsyncResponseStream<Com_Apple_Cloudboard_Api_V1_InvokeProxyDialBackResponse>
    ) {
        let (requestStream, requestContinuation) = AsyncStream.makeStream(of: InvokeProxyDialBackRequest.self)
        let dialBackResponseStream = self.proxyClient.invokeProxyDialBack(requestStream)
        requestContinuation.yield(self.workerIdDialBackRequest(workerId))

        return (requestContinuation, dialBackResponseStream)
    }

    public func workerNotFound(workerId: String, errorCode: UInt32) {
        let (requestContinuation, _) = self.startDialBackStream(workerId: workerId)
        requestContinuation.yield(self.findWorkerFailure(errorCode: errorCode))
        requestContinuation.finish()
    }

    private func workerIdDialBackRequest(_ workerId: String) -> InvokeProxyDialBackRequest {
        return InvokeProxyDialBackRequest.with {
            $0.initiate.taskID = workerId
        }
    }

    /// Handles the basic routing v1 vs v2 logic here
    /// v1 gets an attestation ``Proto_Ropes_Common_Attestation``
    /// v2 gets an selectedEnsemble ``Com_Apple_Cloudboard_Api_V1_ComputeToProxyMessage.SelectedEnsemble``
    public static func initiateProxyWorkerSelected(
        attestation: ComputeNodeAttestation,
        workload: Proto_Ropes_Common_Workload,
        isResponseBypass: Bool
    ) -> InvokeProxyDialBackRequest {
        let attestationMessage = Proto_Ropes_Common_Attestation.with {
            $0.nodeIdentifier = attestation.keyID.base64EncodedString()
            $0.attestationBundle = attestation.attestationBundle
            if isResponseBypass {
                // Mandatory field required by proxy when in response by pass mode
                // For our purposes, the value is not important at the moment
                $0.ohttpContext = 1234
            }
        }

        return InvokeProxyDialBackRequest.with {
            $0.computeToProxyMessage = Com_Apple_Cloudboard_Api_V1_ComputeToProxyMessage.with {
                $0.selectedEnsemble = Com_Apple_Cloudboard_Api_V1_ComputeToProxyMessage.SelectedEnsemble.with {
                    $0.attestation = attestationMessage
                    $0.computeEnsembleWorkload = workload
                }
            }
        }
    }

    private func findWorkerFailure(errorCode: UInt32) -> InvokeProxyDialBackRequest {
        return InvokeProxyDialBackRequest.with {
            $0.close = .with {
                $0.ropesErrorCode = errorCode
            }
        }
    }
}
