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

//
//  TDXTCBInfo.swift
//  CloudAttestationV2
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//

import Foundation

public struct TDXTCBInfo: Sendable {
    public let fmspc: String
    public let pceId: String
    public let tdxModule: TDXModule
    public let moduleIdentities: [ModuleIdentity]
    public let tcbLevels: [TCBLevel]

    public init(jsonData: Data) throws {
        let envelope = try JSONDecoder().decode(Envelope.self, from: jsonData)
        self.fmspc = envelope.tcbInfo.fmspc
        self.pceId = envelope.tcbInfo.pceId
        self.tdxModule = envelope.tcbInfo.tdxModule
        self.moduleIdentities = envelope.tcbInfo.tdxModuleIdentities ?? []
        self.tcbLevels = envelope.tcbInfo.tcbLevels
    }

    public func upToDateLevel() -> TCBLevel? {
        tcbLevels.first { $0.tcbStatus == "UpToDate" }
    }

    public func moduleIdentity(id: String) -> ModuleIdentity? {
        moduleIdentities.first { $0.id == id }
    }
}

// MARK: - Public types

extension TDXTCBInfo {
    public struct TDXModule: Codable, Sendable {
        public let mrsigner: String
        public let attributes: String
        public let attributesMask: String
    }

    public struct ModuleIdentity: Codable, Sendable {
        public let id: String
        public let mrsigner: String
        public let attributes: String
        public let attributesMask: String
        public let tcbLevels: [ModuleTCBLevel]?

        public var isvsvn: Int? {
            tcbLevels?.first { $0.tcbStatus == "UpToDate" }?.tcb.isvsvn
        }
    }

    public struct ModuleTCBLevel: Codable, Sendable {
        public let tcb: ModuleTCB
        public let tcbStatus: String
    }

    public struct ModuleTCB: Codable, Sendable {
        public let isvsvn: Int
    }

    public struct TCBLevel: Codable, Sendable {
        public let tcb: TCB
        public let tcbDate: String
        public let tcbStatus: String

        public var pcesvn: Int { tcb.pcesvn }
        public var sgxTCBComponents: [Int] { tcb.sgxtcbcomponents.map(\.svn) }
        public var tdxTCBComponents: [Int] { tcb.tdxtcbcomponents.map(\.svn) }
    }

    public struct TCB: Codable, Sendable {
        public let sgxtcbcomponents: [TCBComponent]
        public let tdxtcbcomponents: [TCBComponent]
        public let pcesvn: Int
    }

    public struct TCBComponent: Codable, Sendable {
        public let svn: Int
        public let category: String?
        public let type: String?

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.svn = try container.decode(Int.self, forKey: .svn)
            self.category = try container.decodeIfPresent(String.self, forKey: .category)
            self.type = try container.decodeIfPresent(String.self, forKey: .type)
        }

        private enum CodingKeys: String, CodingKey {
            case svn, category, type
        }
    }
}

// MARK: - Decoding envelope

extension TDXTCBInfo {
    private struct Envelope: Codable {
        let tcbInfo: TCBInfo
    }

    private struct TCBInfo: Codable {
        let fmspc: String
        let pceId: String
        let tdxModule: TDXModule
        let tdxModuleIdentities: [ModuleIdentity]?
        let tcbLevels: [TCBLevel]
    }
}
