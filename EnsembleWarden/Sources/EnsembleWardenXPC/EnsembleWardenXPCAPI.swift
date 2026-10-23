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
//  EnsembleWardenXPCAPI.swift
//  EnsembleWarden
//
//  Created by Oliver Chick (ORAC) on 13/12/2024.
//

package import CryptoKit
package import EnsembleWardenCommon
private import Foundation
@preconcurrency package import IOSurface
@_spi(Private) @preconcurrency package import XPC

package protocol EnsembleWardenXPCRequest: Codable, Sendable {
    associatedtype Response: Codable & Sendable
}

package protocol EnsembleWardenXPCResponse: Codable {}

extension [IOSurface]: @retroactive Encodable {}
extension [IOSurface]: @retroactive Decodable {}
extension [IOSurface]: EnsembleWardenXPCResponse {}

/// Types that we pass across the XPC boundary between the EnsembleWarden framework and daemon.
package enum EnsembleWardenDaemonXPC {

    package struct ExplicitSuccess: EnsembleWardenXPCResponse {
        package init() {}
    }

    package struct Empty: EnsembleWardenXPCRequest {
        package typealias Response = ExplicitSuccess
        package init() {}
    }

    /// Start message supplies the daemon with the handles to the crypto
    /// it will use for encrypting/decrypting.
    package struct Start: EnsembleWardenXPCRequest {
        package typealias Response = CodableResult<[Int: UUID], EnsembleWardenError>
        // xpc_connection_t is not Codable so we have to do this dance with XPCCodableObject.
        package var ensemblePorterConnection: XPCCodableObject?
        package var ensemblePorterEndpoint: XPCEndpoint?
        package var followerToken: UUID?
        package var requestID: UUID
        /// Whether this is a multi-turn request requiring CloudBoard crypto material.
        package var isMultiTurn: Bool

        package init(ensemblePorterConnection: xpc_connection_t?,
                     ensemblePorterEndpoint: XPCEndpoint?,
                     followerToken: UUID?,
                     requestID: UUID,
                     isMultiTurn: Bool = true) {
            if let ensemblePorterConnection {
                let dict = xpc_dictionary_create(nil, nil, 0)
                xpc_dictionary_set_connection(
                    dict,
                    EnsembleWardenConstants.ensemblePorterConnectionNameInXPCDict,
                    ensemblePorterConnection)
                self.ensemblePorterConnection = XPCCodableObject(copying: dict)
            }
            self.ensemblePorterEndpoint = ensemblePorterEndpoint
            self.followerToken = followerToken
            self.requestID = requestID
            self.isMultiTurn = isMultiTurn
        }
    }

    /// Sent from the framework to the daemon to prefault IOSurfaces into memory.
    ///
    /// This encourages the kernel to page in the memory backing the IOSurfaces
    /// before they are needed on the hot path.
    package struct Prefault: EnsembleWardenXPCRequest, Sendable {
        package typealias Response = CodableResult<ExplicitSuccess, EnsembleWardenError>
        package var ioSurfaces: [IOSurface]
        package var requestID: UUID
        package var spanID: UInt64

        package init(ioSurfaces: [IOSurface], requestID: UUID, spanID: UInt64) {
            self.ioSurfaces = ioSurfaces
            self.requestID = requestID
            self.spanID = spanID
        }
    }

    /// Sent from the framework to daemon to drop all cached data in EnsembleTransport.
    package struct DropAll: EnsembleWardenXPCRequest {
        package typealias Response = CodableResult<ExplicitSuccess, EnsembleWardenError>

        package init() {
        }
    }

    package enum TransferPurpose: Codable, Sendable {
        case ftET
        case multiTurn
    }

    package enum Request: Codable, Sendable {
        case empty(Empty)
        case start(Start)
        case prefault(Prefault)
        case dropAll(DropAll)
        case publish2(Publish2)
        case fetch2(Fetch2)
        case fetchMetadata(FetchMetadata)
        case delete(Delete)
    }
}

// Fetch/Publish messages for EnsembleTransport backend. Eventually
// EnsembleTransport will become the only backend and the other
// Publish/Fetch messages can be removed.
extension EnsembleWardenDaemonXPC {
    /// Sent from the framework to the daemon each time KV$s have been produced
    /// that need to be encrypted and sent to EnsembleTransport.
    ///
    /// N.b. the message contains `IOSurface`s. These are references to shared
    /// memory buffers. The reference is quick to move.
    package struct Publish2: EnsembleWardenXPCRequest, Sendable {
        package typealias Response =
            CodableResult<ExplicitSuccess, EnsembleWardenError>
        package var identifier: String
        package var privateData: IOSurface
        package var privateMetadata: IOSurface?
        package var ttl: Duration
        package var purpose: TransferPurpose
        package var requestID: UUID
        package var spanID: UInt64

        package init(
            identifier: String,
            privateData: IOSurface,
            privateMetadata: IOSurface?,
            ttl: Duration,
            purpose: TransferPurpose,
            requestID: UUID,
            spanID: UInt64) {
            self.identifier = identifier
            self.privateData = privateData
            self.privateMetadata = privateMetadata
            self.ttl = ttl
            self.purpose = purpose
            self.requestID = requestID
            self.spanID = spanID
        }
    }

    /// Sent from the framework to daemon whenever an unencrypted KV$ is
    /// required.
    ///
    /// This message encodes the KV$ that is required to be fetched.
    package struct Fetch2: EnsembleWardenXPCRequest {
        package typealias Response =
            CodableResult<EnsembleWardenFetchedData, EnsembleWardenError>
        package var identifier: String
        package var range: ClosedRange<Int>?
        package var host: String
        package var requestID: UUID
        package var spanID: UInt64

        package init(
            identifier: String,
            range: ClosedRange<Int>?,
            host: String,
            requestID: UUID,
            spanID: UInt64
        ) {
            self.identifier = identifier
            self.range = range
            self.host = host
            self.requestID = requestID
            self.spanID = spanID
        }
    }

    /// Sent from the framework to daemon whenever an unencrypted KV$
    /// metadata is required.
    ///
    /// This message encodes the KV$ metadata that is required to be fetched.
    package struct FetchMetadata: EnsembleWardenXPCRequest {
        package typealias Response =
            CodableResult<IOSurface?, EnsembleWardenError>
        package var identifier: String
        package var host: String
        package var requestID: UUID
        package var spanID: UInt64

        package init(
            identifier: String,
            host: String,
            requestID: UUID,
            spanID: UInt64
        ) {
            self.identifier = identifier
            self.host = host
            self.requestID = requestID
            self.spanID = spanID
        }
    }

    package struct Delete: EnsembleWardenXPCRequest {
        package typealias Response =
            CodableResult<ExplicitSuccess, EnsembleWardenError>
        package var identifier: String
        package var host: String?
        package var requestID: UUID
        package var spanID: UInt64

        package init(
            identifier: String,
            host: String?,
            requestID: UUID,
            spanID: UInt64
        ) {
            self.identifier = identifier
            self.host = host
            self.requestID = requestID
            self.spanID = spanID
        }
    }
}

