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

extension VRE.Ensemble {
    // Status is used to return info/status of the ensemble cluster (includkng individual member nodes)
    struct Status: Encodable {
        let name: String
        var nodes: [NodeInfo]? = nil
        var health: String = "unknown"
        var status: String = "unknown"
        var ipaddr: String? = nil // leader IP
        var error: String? = nil
    }

    // NodeInfo is used to return info/status of the ensemble member nodes
    struct NodeInfo: Encodable {
        let name: String
        let rank: UInt8
        var status: VRE.VMStatus? = nil
        var role: String { rank == 0 ? "leader" : "follower" }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(rank, forKey: .rank)
            try container.encode(role, forKey: .role)
            try container.encode(status, forKey: .status)
        }

        private enum CodingKeys: String, CodingKey {
            case name, rank, status, role
        }
    }

    // status gathers and returns status of each ensemble node along with the overall cluster status
    //   (according to ensembler status via "cloudremotediagctl get-ensemble-health" against leader node)
    func status(getNodeStatus: Bool = false) -> Status {
        let nodeInfos = nodes.map { node in
            NodeInfo(name: node.instance.name,
                     rank: node.rank,
                     status: getNodeStatus ? node.instance.status() : nil)
        }

        var info = Status(name: name, nodes: nodeInfos)
        guard leaderRunning else {
            info.health = "offline"
            return info
        }

        // use (primary) IP addr of leader node for cluster IP
        info.ipaddr = info.nodes?.first(where: { $0.rank == 0 })?.status?.ipaddr ??
            leader?.instance.status().ipaddr

        do {
            let ensembleHealth = try healthStatus()
            info.health = ensembleHealth.health
            info.status = ensembleHealth.status
        } catch {
            info.health = "unknown"
            info.status = "error"
            info.error = "\(error)"
        }

        return info
    }

    // ensembleHealth calls runCloudRemoteDiag("get-ensemble-health") against leader node and gleans
    //   health/status info from result
    private func healthStatus() throws -> (health: String, status: String) {
        struct ensembleHealth: Decodable {
            var healthState: String = "unknown"
            var metadata: [String: String] = [:]
        }

        guard let leader = leader, leaderRunning else {
            throw VREError("ensemble leader node not running")
        }

        let healthCheckJSON = try leader.instance.runCloudRemoteDiag(commandArgs: ["get-ensemble-health"])
        let healthCheck = try JSONDecoder().decode(ensembleHealth.self,
                                                   from: healthCheckJSON.data(using: .utf8) ?? Data())
        return (health: healthCheck.healthState, status: healthCheck.metadata["ensemblerStatus"] ?? "unknown")
    }
}
