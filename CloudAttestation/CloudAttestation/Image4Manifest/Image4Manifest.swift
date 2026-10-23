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
//  Image4Manifest.swift
//  CloudAttestation
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

import CryptoKit
@_implementationOnly import image4_workarounds
import image4

@_spi(Private)
public struct Image4Manifest: Equatable {
    public let data: Data
    public let kind: Kind

    public init(data: some DataProtocol, kind: Kind) {
        self.data = Data(data)
        self.kind = kind
    }

    public init(file: URL, kind: Kind) throws {
        self.data = try Data(contentsOf: file)
        self.kind = kind
    }

    public enum Kind {
        case ap
        case cryptex
        case pdi
        case pdiOrCryptex
    }

    public func canonicalize(evaluateTrust: Bool = true) throws -> Image4Manifest {
        try self.canonicalize(evaluateTrust: evaluateTrust, allowVMs: false)
    }

    private func canonicalize(evaluateTrust: Bool, allowVMs: Bool) throws -> Image4Manifest {
        guard !self.data.isEmpty else {
            throw Error.empty
        }

        let coproc: OpaquePointer
        let handle: image4_coprocessor_handle_t

        switch (evaluateTrust, self.kind) {
        case (true, .ap):
            coproc = SWIFT_IMAGE4_COPROCESSOR_AP
            handle =
                allowVMs
                ? image4_coprocessor_handle_ap_t.IMAGE4_COPROCESSOR_HANDLE_AP_ACDC.rawValue
                : image4_coprocessor_handle_ap_t.IMAGE4_COPROCESSOR_HANDLE_AP.rawValue

        case (true, .pdi):
            coproc = SWIFT_IMAGE4_COPROCESSOR_AP
            handle = image4_coprocessor_handle_ap_t.IMAGE4_COPROCESSOR_HANDLE_AP_PDI.rawValue

        case (true, .cryptex):
            coproc = SWIFT_IMAGE4_COPROCESSOR_CRYPTEX1
            handle = image4_coprocessor_handle_cryptex1_t.IMAGE4_COPROCESSOR_HANDLE_CRYPTEX1_GENERIC.rawValue

        case (true, .pdiOrCryptex):
            do {
                let cryptex = Image4Manifest(data: self.data, kind: .cryptex)
                return try cryptex.canonicalize(evaluateTrust: evaluateTrust)
            } catch {
                let pdi = Image4Manifest(data: self.data, kind: .pdi)
                return try pdi.canonicalize(evaluateTrust: evaluateTrust)
            }
        case (false, _):
            coproc = SWIFT_IMAGE4_COPROCESSOR_BOOTPC
            handle = image4_coprocessor_handle_bootpc_t.IMAGE4_COPROCESSOR_HANDLE_BOOTPC_SHA2_384.rawValue
        }

        guard var environment = image4_environment_new(coproc, handle) else {
            throw Error.environmentCreationFailure
        }

        defer {
            image4_environment_destroy(&environment)
        }

        return try data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            guard
                var trust = image4_trust_new(
                    environment,
                    SWIFT_IMAGE4_TRUST_EVALUATION_NORMALIZE,
                    ptr.assumingMemoryBound(to: UInt8.self).baseAddress!,
                    data.count,
                    image4_trust_flags_t()
                )
            else {
                throw Error.trustCreationFailure
            }

            defer {
                image4_trust_destroy(&trust)
            }

            struct Context: Sendable {
                var result: Result<Data, Error>?
            }

            var ctx = Context()

            withUnsafeMutablePointer(to: &ctx) { ptr in
                image4_trust_evaluate(trust, ptr) { (trust: OpaquePointer, r: UnsafeRawPointer?, rLen: Int, error: errno_t, ctx: UnsafeMutableRawPointer?) in
                    guard let ctx = ctx else {
                        return
                    }

                    let ptrCtx = ctx.assumingMemoryBound(to: Context.self)

                    guard let r = r else {
                        ptrCtx.pointee.result = .failure(.trustEvaluationFailure(errno: error))
                        return
                    }

                    ptrCtx.pointee.result = .success(Data(bytes: r, count: rLen))
                }
            }

            switch ctx.result {
            case .success(let success):
                return Image4Manifest(data: success, kind: self.kind)
            case .failure(let failure):
                #if os(macOS) && DEBUG
                if !allowVMs,
                    handle == image4_coprocessor_handle_ap_t.IMAGE4_COPROCESSOR_HANDLE_AP.rawValue,
                    coproc == SWIFT_IMAGE4_COPROCESSOR_AP
                {
                    // try again while allowing VMs
                    return try self.canonicalize(evaluateTrust: evaluateTrust, allowVMs: true)
                }
                #endif
                throw failure
            case .none:
                throw Error.trustEvaluationExecutionFailure
            }
        }
    }

    @inlinable
    public func digest<Hash: HashFunction>(using: Hash.Type = SHA256.self) -> Hash.Digest {
        return Hash.hash(data: data)
    }
}

extension Image4Manifest {
    public enum Error: Swift.Error, Hashable {
        case empty
        case environmentCreationFailure
        case trustCreationFailure
        case trustEvaluationFailure(errno: Int32)
        case trustEvaluationExecutionFailure
        case invalidManifest(reason: String)
    }
}

extension Image4Manifest: CustomStringConvertible {
    public var description: String {
        digest().compactMap { String(format: "%02x", $0) }.joined()
    }
}
