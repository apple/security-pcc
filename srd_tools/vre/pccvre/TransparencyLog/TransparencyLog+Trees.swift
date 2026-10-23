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

import Foundation

extension TransparencyLog {
    typealias Tree = TxPB_ListTreesResponse.Tree

    // TransparencyLog.Trees provides interface for retrieving list of Log Trees via ListTreesRequest call
    //  Response contains list of treeIDs and public keys for the logheads associated with an application
    struct Trees {
        /*
         public struct ListTreesResponse {
           public var status: Status
           public var trees: [Tree]

           public struct Tree {
             public var treeID: UInt64
             public var logBeginningMs: UInt64
             public var type: ListTreesResponse.Tree.OneOf_Type?  [.logType, .mapType]
             public var logType: LogType
             public var mapType: MapType
             public var application: Application
             public var state: State
             public var mergeGroups: UInt64
             public var publicKeyBytes: Data // SPKI
           }
         }
         */
        let nodes: TxPB_ListTreesResponse

        // init performs the request and parses response
        init(
            endpoint: URL, // KTInitBag: at-researcher-list-trees
            useIdentity: Bool = false,
            requestUUID: UUID = UUID()
        ) async throws {
            let listTreesReq = TxPB_ListTreesRequest.with { builder in
                builder.version = TransparencyLog.protocolVersion
                builder.requestUuid = requestUUID.uuidString
            }

            let (respData, _) = try await TransparencyLog.urlPostProtbuf(
                url: endpoint,
                useIdentity: useIdentity,
                requestBody: listTreesReq.serializedData(),
                headers: [TransparencyLog.requestUUIDHeader: requestUUID.uuidString]
            )

            self.nodes = try TxPB_ListTreesResponse(serializedBytes: respData)
            if self.nodes.status != .ok {
                throw TransparencyLogError("response: status=\(self.nodes.status.rawValue)")
            }
        }
    }
}

extension TransparencyLog.Trees {
    // select returns first (active) Tree node matching logType and application
    func select(
        logType: TxPB_LogType,
        application: TxPB_Application
    ) -> TransparencyLog.Tree? {
        for tree in nodes.trees where
            tree.state == .active &&
            tree.logType == logType &&
            tree.application == application
        {
            return tree
        }

        return nil
    }

    // debugDump outputs Tree nodes to logger debug
    func debugDump() {
        func _dlog(_ msg: String) {
            TransparencyLog.logger.debug("\(msg, privacy: .public)")
        }

        _dlog("Log Trees contents:")
        _dlog("  Status: \(nodes.status.rawValue)")
        _dlog("  Count: \(nodes.trees.count)")
        for (idx, tree) in nodes.trees.enumerated() {
            _dlog("[\(idx)]")
            _dlog("  treeID: \(tree.treeID)")
            _dlog("  logBeginningMs: \(tree.logBeginningMs) [\(dateAsString(tree.logBeginningMs))]")
            switch tree.type {
            case .logType:
                _dlog("  logType: \(tree.logType.rawValue)")
                if tree.logType != .topLevelTree {
                    _dlog("  application: \(tree.application.rawValue)")
                }
            case .mapType:
                _dlog("  mapType: \(tree.mapType.rawValue)")
                _dlog("  application: \(tree.application.rawValue)")
            default:
                _dlog("  <unknown type>")
            }
            _dlog("  state: \(tree.state.rawValue)")
            _dlog("  mergeGroups: \(tree.mergeGroups)")
        }
    }
}
