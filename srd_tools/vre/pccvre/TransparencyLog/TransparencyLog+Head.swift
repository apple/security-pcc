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
    // TransparencyLog.Head provides interface for retrieving the Log Head of specified Log Trees via
    //  LogHeadRequest call. Response includes current size (number of nodes), revision, and timestamps
    //  of the requested Log
    struct Head: Hashable {
        /*
         public struct LogHead {
           public var logBeginningMs: UInt64 = 0
           public var logSize: UInt64 = 0 // endindex
           public var logHeadHash: Data = Data()
           public var revision: UInt64 = 0
           public var logType: LogType = .unknownLog
           public var application: Application = .unknownApplication // !TLT
           public var treeID: UInt64 = 0
           public var timestampMs: UInt64 = 0
         }
         */
        private let node: TxPB_LogHead

        // accessor attributes to retrieved loghead
        var beginning: Date { Date(timeIntervalSince1970: Double(node.logBeginningMs) / 1000) }
        var size: UInt64 { node.logSize } // last logLeaf index
        var hash: Data { node.logHeadHash }
        var revision: UInt64 { node.revision }
        var type: TxPB_LogType { node.logType }
        var application: TxPB_Application { node.application }
        var treeID: UInt64 { node.treeID }
        var timestamp: Date { Date(timeIntervalSince1970: Double(node.timestampMs) / 1000) }

        init(_ head: TxPB_LogHead) {
            self.node = head
        }

        init(
            endpoint: URL, // KTInitBag: at-researcher-log-head
            useIdentity: Bool = false,
            logTree: TxPB_ListTreesResponse.Tree,
            appCerts: [SecCertificate]?,
            requestUUID: UUID = UUID()
        ) async throws {
            let logHeadReq = TxPB_LogHeadRequest.with { builder in
                builder.version = TransparencyLog.protocolVersion
                builder.treeID = logTree.treeID
                builder.revision = -1
                builder.requestUuid = requestUUID.uuidString
            }

            let (respData, _) = try await TransparencyLog.urlPostProtbuf(
                url: endpoint,
                useIdentity: useIdentity,
                requestBody: logHeadReq.serializedData(),
                headers: [TransparencyLog.requestUUIDHeader: requestUUID.uuidString]
            )

            let response = try TxPB_LogHeadResponse(serializedBytes: respData)
            if response.status != .ok {
                throw TransparencyLogError("response: status=\(response.status.rawValue)")
            }

            guard response.hasLogHead else {
                throw TransparencyLogError("response: no payload")
            }

            let signedObj = SignedObject(response.logHead)
            
            /*
              guard let signerCert = logTree.signerCert() else {
                  throw TransparencyLogError("cannot obtain pubkey from signerCert")
              }
              guard try signedObj.verify(certs: [signerCert]) else {
                  throw TransparencyLogError("cannot verify log head")
              }
              if let appCerts {
                  guard try signedObj.verify(certs: appCerts) else {
                      throw TransparencyLogError("cannot verify log head")
                  }
              }
             */

            self.node = try TxPB_LogHead(serializedBytes: signedObj.data)

            guard application == logTree.application, treeID == logTree.treeID else {
                throw TransparencyLogError("logHead application/treeID does not match request")
            }
        }
    }
}
