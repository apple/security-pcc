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

//  Copyright © 2024 Apple, Inc. All rights reserved.
//

import CryptoKit
import Foundation
import InternalSwiftProtobuf

extension TransparencyLog {
    // Decode (AT) Log Leaf node headers from LogLeaves request
    //  (LogLeavesResponse and LogLeavesForRevisionResponse have slightly different Leaf defs)
    struct ATLeaf: Leaf, Hashable {
        static let serializationVersion = SerializationVersion.V1

        let nodeType: TxPB_NodeType
        let nodeBytes: Data
        let nodeData: ATLeafData
        let index: UInt64 // or .nodePosition
        let hashesOfPeersInPathToRoot: [Data]?
        let mergeGroup: UInt32?
        let rawData: Data
        let metadata: Data

        // isExpired yields true if leaf node expiration has passed current time
        var isExpired: Bool { nodeData.expiryMs / 1000 <= UInt64(Date().timeIntervalSince1970) }

        init?(nodeType: TxPB_NodeType,
              nodeBytes: Data,
              index: UInt64,
              hashesOfPeersInPathToRoot: [Data]? = nil,
              mergeGroup: UInt32? = nil,
              rawData: Data? = nil,
              metadata: Data? = nil)
        {
            // only process atlNodes
            guard nodeType == .atlNode, let nodeData = try? ATLeaf.decodeNodeData(nodeBytes) else {
                return nil
            }

            // digest of rawData payload (if present) must digest in nodeData
            if let rawData {
                guard !rawData.isEmpty, SHA256.hash(data: rawData) == nodeData.dataHash else {
                    TransparencyLog.logger.error("payload digest mismatch (ATLeaf index=\(index, privacy: .public))")
                    return nil
                }
            }

            self.nodeType = nodeType
            self.nodeBytes = nodeBytes
            self.nodeData = nodeData
            self.index = index
            self.hashesOfPeersInPathToRoot = hashesOfPeersInPathToRoot
            self.mergeGroup = mergeGroup
            self.rawData = rawData ?? Data()
            self.metadata = metadata ?? Data()
        }

        init?(_ leaf: TxPB_LogLeavesResponse.Leaf) {
            self.init(
                nodeType: leaf.nodeType,
                nodeBytes: leaf.nodeBytes,
                index: leaf.index,
                mergeGroup: leaf.mergeGroup,
                rawData: leaf.rawData.isEmpty ? nil : leaf.rawData,
                metadata: leaf.metadata.isEmpty ? nil : leaf.metadata
            )
        }

        init?(_ leaf: TxPB_LogLeavesForRevisionResponse.Leaf) {
            self.init(
                nodeType: leaf.nodeType,
                nodeBytes: leaf.nodeBytes,
                index: leaf.nodePosition,
                hashesOfPeersInPathToRoot: leaf.hashesOfPeersInPathToRoot,
                rawData: leaf.rawData.isEmpty ? nil : leaf.rawData,
                metadata: leaf.metadata.isEmpty ? nil : leaf.metadata
            )
        }

        func isNodeType(_ istype: ATLeafType) -> Bool {
            return nodeData.type == istype
        }

        func isNodeType(_ istype: TxPB_ATLogDataType) -> Bool {
            return nodeData.type == ATLeafType(rawValue: UInt8(istype.rawValue))
        }

        /*
         struct ATLeafData {
             var version: SerializationVersion
             var type: ATLeafType
             var ATDescription : Data
             var dataHash : Data  (digest of rawData payload)
             var expiryMs : UInt64
             var extensions: Array<TransparencyExtension>
         }
         */
        static func decodeNodeData(_ data: Data) throws -> ATLeafData {
            let changeLogNode = try TxPB_ChangeLogNodeV2(serializedBytes: data)
            var nodeBytes = TransparencyByteBuffer(data: changeLogNode.mutation)
            let atLeafData = try ATLeafData(bytes: &nodeBytes)
            guard atLeafData.version == TransparencyLog.ATLeaf.serializationVersion else {
                throw TransparencyLogError("unsupported version (\(atLeafData.version))")
            }

            return atLeafData
        }
    }
}
