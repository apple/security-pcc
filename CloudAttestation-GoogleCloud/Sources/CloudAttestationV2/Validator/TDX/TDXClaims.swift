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
//  TDXClaimsGenerator.swift
//  CloudAttestationV2
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//

import Crypto
import Foundation
import Logging
import SwiftEventLog
import SwiftTDX

// MARK: - TDXClaims
public struct TDXClaims: Claims.ValueProtocol {
    public var verified: Bool? = nil
    public var mrtd: Data? = nil
    public var mrSeam: Data? = nil
    public var mrSignerSeam: Data? = nil
    public var mrConfigId: Data? = nil
    public var mrOwner: Data? = nil
    public var mrOwnerConfig: Data? = nil
    public var seamAttributes: Data? = nil
    public var tdAttributes: TDXClaims.TDAttributes? = nil
    public var teeTcbSvn: Data? = nil
    public var rtmr0: Data? = nil
    public var rtmr1: Data? = nil
    public var rtmr2: Data? = nil
    public var rtmr3: Data? = nil
    public var xfam: TDXClaims.XFAM? = nil
    public var pckCertificate: Data? = nil
    public var reportData: Data? = nil
    public var qeMREnclave: Data? = nil
    public var qeMRSigner: Data? = nil
    public var qeISVProdId: Int? = nil
    public var qeISVSVN: Int? = nil
    public var qeAttributes: TDXClaims.QEAttributes? = nil
    public var sgxTcbCompSvn: Data? = nil
    public var fmspc: Data? = nil
    public var pcesvn: Int? = nil

    public init() {}
}

enum TDXClaimsError: Swift.Error {
    case rtmrMismatch(index: Int)
}

// MARK: - Generator

extension TDXClaims {
    /// Generates TDX attestation claims from raw TDX evidence (quote + event logs).
    ///
    /// This generator is independent of any wire format or bundle type — it operates
    /// on the raw TDX data directly. The caller is responsible for extracting these
    /// bytes from whatever container they arrive in (e.g. a GCPv1 AttestationBundle).
    public struct Generator: ClaimsGenerator, Sendable {
        private static let logger = Logger(label: "com.apple.CloudAttestation.TDXClaims")

        public typealias Input = SwiftTDX.Quote

        public init() {}

        public func generateClaims(for quoteData: Data) async throws -> TDXClaims {
            var buffer = [UInt8](quoteData)[...]
            let quote: V4.Quote
            do {
                quote = try V4.Quote(from: &buffer)
            } catch {
                Self.logger.warning(
                    "TDX V4 Quote parse failed; returning empty claims",
                    metadata: [
                        "quoteBytes": .stringConvertible(quoteData.count),
                        "error": .string(String(describing: error)),
                    ]
                )
                return TDXClaims()
            }
            return try await self.generateClaims(for: .v4(quote))
        }

        /// Generates claims from raw TDX attestation evidence.
        ///
        /// - Parameters:
        ///   - tdQuote: The serialized TDX Quote V4 binary.
        /// - Returns: Claims extracted from the TDX quote body
        public func generateClaims(
            for tdQuote: SwiftTDX.Quote,
        ) async throws -> TDXClaims {
            var claims = TDXClaims()

            // Parse and verify the TDX Quote (only v4 supported right now)
            guard case .v4(let quote) = tdQuote else {
                return claims
            }
            do {
                // Extract quote body claims, and then verify so we have a debuggable view.
                extractQuoteBodyClaims(from: quote, into: &claims)

                try await quote.verify()
                claims.verified = true
            } catch {
                Self.logger.debug(
                    "TDX quote verification failed; marking claim unverified",
                    metadata: ["error": .string(String(describing: error))]
                )
                claims.verified = false
            }

            return claims
        }
    }
}

// MARK: - Quote Body Claims

extension TDXClaims.Generator {
    private func extractQuoteBodyClaims(from quote: V4.Quote, into claims: inout TDXClaims) {
        claims.mrtd = Data(quote.body.mrtd.bytes)
        claims.mrSeam = Data(quote.body.mrSeam.bytes)
        claims.mrSignerSeam = Data(quote.body.mrSignerSeam.bytes)
        claims.mrConfigId = Data(quote.body.mrConfigId.bytes)
        claims.mrOwner = Data(quote.body.mrOwner.bytes)
        claims.mrOwnerConfig = Data(quote.body.mrOwnerConfig.bytes)
        claims.teeTcbSvn = Data(quote.body.teeTcbSvn.bytes)
        claims.rtmr0 = Data(quote.body.rtmr0.bytes)
        claims.rtmr1 = Data(quote.body.rtmr1.bytes)
        claims.rtmr2 = Data(quote.body.rtmr2.bytes)
        claims.rtmr3 = Data(quote.body.rtmr3.bytes)
        claims.seamAttributes = Data(quote.body.seamAttributes.bytes)
        claims.tdAttributes = .init(quote.body.tdAttributes)
        claims.xfam = .init(quote.body.xfam)
        claims.pckCertificate = try? quote.pckCertificate?.certificate.derRepresentation
        claims.reportData = Data(quote.body.reportData.bytes)

        if let qe = quote.qeReportIdentity {
            claims.qeMREnclave = qe.mrEnclave
            claims.qeMRSigner = qe.mrSigner
            claims.qeISVProdId = Int(qe.isvProdId)
            claims.qeISVSVN = qe.isvSvn
            claims.qeAttributes = .init(qe.attributes)
        }

        if let pck = quote.pckCertificate {
            claims.sgxTcbCompSvn = pck.sgxTcbCompSvn
            claims.fmspc = pck.fmspc
            claims.pcesvn = pck.pcesvn
        }
    }
}

// MARK: - Bitmaps

extension TDXClaims {
    public struct TDAttributes: Claims.ValueProtocol {
        public var debug: Bool
        public var septVeDisable: Bool
        public var migratable: Bool
        public var pks: Bool
        public var perfMon: Bool
        public var kl: Bool

        package init(_ attr: V4.TDAttributes) {
            self.debug = attr.contains(V4.TDAttributes.TUD.debug)
            self.septVeDisable = attr.contains(V4.TDAttributes.SEC.septVeDisable)
            self.migratable = attr.contains(V4.TDAttributes.SEC.migratable)
            self.pks = attr.contains(V4.TDAttributes.SEC.pks)
            self.perfMon = attr.contains(V4.TDAttributes.OTHER.perfMon)
            self.kl = attr.contains(V4.TDAttributes.SEC.kl)
        }
    }

    public struct XFAM: Claims.ValueProtocol {
        public var pt: Bool
        public var prku: Bool
        public var cetU: Bool
        public var cetS: Bool
        public var lbr: Bool

        package init(_ xfam: V4.XFAM) {
            self.pt = xfam.contains(.pt)
            self.prku = xfam.contains(.prku)
            self.cetU = xfam.contains(V4.XFAM.CET.cetU)
            self.cetS = xfam.contains(V4.XFAM.CET.cetS)
            self.lbr = xfam.contains(.lbr)
        }
    }

    public struct QEAttributes: Claims.ValueProtocol {
        public var initialized: Bool
        public var debug: Bool
        public var mode64Bit: Bool
        public var provisionKey: Bool
        public var einitTokenKey: Bool
        public var cet: Bool
        public var kss: Bool
        public var aexNotify: Bool

        package init(_ attr: V4.EnclaveAttributes) {
            self.initialized = attr.flags.contains(.initialized)
            self.debug = attr.flags.contains(.debug)
            self.mode64Bit = attr.flags.contains(.mode64Bit)
            self.provisionKey = attr.flags.contains(.provisionKey)
            self.einitTokenKey = attr.flags.contains(.einitTokenKey)
            self.cet = attr.flags.contains(.cet)
            self.kss = attr.flags.contains(.kss)
            self.aexNotify = attr.flags.contains(.aexNotify)
        }
    }
}
