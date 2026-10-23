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
//  ImageMeasurements.swift
//  CloudAttestationV2
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//

import Common
import Foundation

public struct ImageMeasurements: Codable, Sendable {
    public var shim: Data
    public var grub: Data
    public var vmlinuzA: Data
    public var vmlinuzB: Data?
    public var kernelCmdlineADigest: Data
    public var kernelCmdlineBDigest: Data
    public var kernelCmdlineA: String
    public var kernelCmdlineB: String
    public var nvidiaDriverVersion: String?

    internal init(
        shim: Data,
        grub: Data,
        vmlinuzA: Data,
        vmlinuzB: Data? = nil,
        kernelCmdlineADigest: Data,
        kernelCmdlineBDigest: Data,
        kernelCmdlineA: String,
        kernelCmdlineB: String,
        nvidiaDriverVersion: String? = nil
    ) {
        self.shim = shim
        self.grub = grub
        self.vmlinuzA = vmlinuzA
        self.vmlinuzB = vmlinuzB
        self.kernelCmdlineADigest = kernelCmdlineADigest
        self.kernelCmdlineBDigest = kernelCmdlineBDigest
        self.kernelCmdlineA = kernelCmdlineA
        self.kernelCmdlineB = kernelCmdlineB
        self.nvidiaDriverVersion = nvidiaDriverVersion
    }

    private enum CodingKeys: String, CodingKey {
        case shim
        case grub
        case vmlinuzA = "vmlinuz_a"
        case vmlinuzB = "vmlinuz_b"
        case kernelCmdlineADigest = "kernel_cmdline_a_hash"
        case kernelCmdlineBDigest = "kernel_cmdline_b_hash"
        case kernelCmdlineA = "kernel_cmdline_a"
        case kernelCmdlineB = "kernel_cmdline_b"
        case nvidiaDriverVersion = "nvidia_driver_version"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shim = try container.decodeHex(forKey: .shim)
        grub = try container.decodeHex(forKey: .grub)
        vmlinuzA = try container.decodeHex(forKey: .vmlinuzA)
        vmlinuzB = try container.decodeHexIfPresent(forKey: .vmlinuzB)
        kernelCmdlineADigest = try container.decodeHex(forKey: .kernelCmdlineADigest)
        kernelCmdlineBDigest = try container.decodeHex(forKey: .kernelCmdlineBDigest)
        kernelCmdlineA = try container.decode(String.self, forKey: .kernelCmdlineA)
        kernelCmdlineB = try container.decode(String.self, forKey: .kernelCmdlineB)
        nvidiaDriverVersion = try container.decodeIfPresent(String.self, forKey: .nvidiaDriverVersion)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeHex(shim, forKey: .shim)
        try container.encodeHex(grub, forKey: .grub)
        try container.encodeHex(vmlinuzA, forKey: .vmlinuzA)
        try container.encodeHexIfPresent(vmlinuzB, forKey: .vmlinuzB)
        try container.encodeHex(kernelCmdlineADigest, forKey: .kernelCmdlineADigest)
        try container.encodeHex(kernelCmdlineBDigest, forKey: .kernelCmdlineBDigest)
        try container.encode(kernelCmdlineA, forKey: .kernelCmdlineA)
        try container.encode(kernelCmdlineB, forKey: .kernelCmdlineB)
        try container.encodeIfPresent(nvidiaDriverVersion, forKey: .nvidiaDriverVersion)
    }
}

extension KeyedDecodingContainer {
    fileprivate func decodeHex(forKey key: Key) throws -> Data {
        let hex = try decode(String.self, forKey: key)
        guard let data = Data(hexString: hex) else {
            throw ImageMeasurementError.invalidHexString(hex)
        }
        return data
    }

    fileprivate func decodeHexIfPresent(forKey key: Key) throws -> Data? {
        guard let hex = try decodeIfPresent(String.self, forKey: key) else { return nil }
        return Data(hexString: hex)
    }
}

extension KeyedEncodingContainer {
    fileprivate mutating func encodeHex(_ data: Data, forKey key: Key) throws {
        try encode(data.hexString, forKey: key)
    }

    fileprivate mutating func encodeHexIfPresent(_ data: Data?, forKey key: Key) throws {
        try encodeIfPresent(data?.hexString, forKey: key)
    }
}
