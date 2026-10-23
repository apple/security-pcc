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

import Foundation
internal import InternalSwiftProtobuf

// Contains various static functions for creating InvokeWorkload request protobuf messages
extension PCCHarness.ProtoInvokeWorkloadRequest {
    static func makeSetup() -> PCCHarness.ProtoInvokeWorkloadRequest {
        let request = PCCHarness.ProtoInvokeWorkloadRequest.with {
            $0.setup = .init()
        }
        return request
    }

    static func makeParameters(
        decryptionKey: Proto_Ropes_Common_DecryptionKey,
        requestID: UUID,
        metadata: PCCHarness.InvokeWorkloadRequestMetadata,
        requestBypassed: Bool,
        responseBypass: PCCHarness.ProtoResponseBypassMode? = nil,
        requestNack: Bool = false
    ) -> PCCHarness.ProtoInvokeWorkloadRequest {
        return PCCHarness.ProtoInvokeWorkloadRequest.with {
            $0.parameters = .with {
                $0.decryptionKey = decryptionKey
                $0.tenantInfo = .with {
                    // Set the ADG to clearly identify LocalCloudBoardClient
                    $0.automatedDeviceGroup = "local-cloudboard-client"
                    $0.bundleID = metadata.bundleID ?? "local-cloudboard-client"

                    if let bundleVersion = metadata.bundleVersion {
                        $0.bundleVersion = bundleVersion
                    }
                    if let featureID = metadata.featureID {
                        $0.featureID = featureID
                    }
                    if let clientInfo = metadata.clientInfo {
                        $0.clientInfo = clientInfo
                    }
                }
                $0.workload = .init(type: metadata.workloadType, parameters: metadata.workloadParameters)
                $0.requestID = requestID.uuidString
                $0.requestBypassed = requestBypassed
                $0.requestNack = requestNack
                $0.patIssuer = metadata.patIssuer
                if let responseBypass {
                    $0.trustedProxyMetadata = .with {
                        $0.responseBypassMode = responseBypass
                    }
                }
                $0.traceContextV1 = .with {
                    $0.traceID = requestID.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                    $0.spanID = UInt64.random(in: UInt64.min ... UInt64.max).hexEncoded
                }
            }
        }
    }

    static func makeTerminate(code: Terminate.Code, reason: String? = nil) -> PCCHarness.ProtoInvokeWorkloadRequest {
        let request = PCCHarness.ProtoInvokeWorkloadRequest.with {
            $0.terminate = .with {
                $0.code = code
                if let reason {
                    $0.reason = reason
                }
            }
        }
        return request
    }

    static func makeChunk(data: Data, isFinal: Bool) -> PCCHarness.ProtoInvokeWorkloadRequest {
        let requestChunk = Proto_Ropes_Common_Chunk.with {
            $0.encryptedPayload = data
            $0.isFinal = isFinal
        }
        let request = PCCHarness.ProtoInvokeWorkloadRequest.with {
            $0.requestChunk = requestChunk
        }
        return request
    }

    static func makeAuthToken(_ encryptedAuthToken: Data) -> PCCHarness.ProtoInvokeWorkloadRequest {
        return self.makeChunk(data: encryptedAuthToken, isFinal: false)
    }
}

extension Proto_Ropes_Common_DecryptionKey {
    static func makeDecryptionKey(keyID: Data, key: Data) -> Self {
        return Proto_Ropes_Common_DecryptionKey.with {
            $0.keyID = keyID
            $0.encryptedPayload = key
        }
    }
}

extension UInt64 {
    fileprivate var hexEncoded: String {
        String(format: "%016llx", self)
    }
}
