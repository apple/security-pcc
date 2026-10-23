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
//  LaunchManagerActor.swift
//  EnsembleWarden
//
//  Created by Oliver Chick (ORAC) on 30/07/2025.
//

private import CryptoKit
internal import Distributed
package import EnsemblePorterCommon
package import EnsembleWardenServer
@preconcurrency package import Foundation
private import OSLog
@_spi(WorkAroundResolvableCrash) @_weakLinked private import XPCDistributed

/// Distributed actor implementation for handling cryptographic data provision.
///
/// This actor receives an opaque blob from CloudBoard that it deserialises into an array of turn keys.
package distributed actor EnsemblePorterServerProvideActor<IntraEnsembleTransponder: EnsembleTransponder>: EnsemblePorterProvideActor {

    private let logic: EnsemblePorterLogic<IntraEnsembleTransponder>

    /// XPC peer requirement specifying that clients must have the provide keys entitlement.
    package nonisolated var peerRequirement: XPCPeerRequirement {
        .entitlement(EnsemblePorterConstants.provideKeysEntitlement, matches: true)
    }

    private let logger = Logger(subsystem: EnsemblePorterConstants.loggerSubsystem, category: "EnsemblePorterServerProvideActor")

    internal init(logic: EnsemblePorterLogic<IntraEnsembleTransponder>, actorSystem: ActorSystem) {
        self.logic = logic
        self.actorSystem = actorSystem
    }

    /// Provides the turn keys to the porter.
    ///
    /// Called from CloudBoard
    ///
    /// - Parameters:
    ///   - auxiliaryCryptoBlob: The opaque blob that contains the turn keys
    ///   - requestID: requestID
    ///   - spanID: spanID
    /// - Returns: A result indicating success or failure of the operation
    package distributed func provide(auxiliaryCryptoBlob: Data, requestID: UUID, spanID: UInt64) async -> CodableResult<Empty, EnsemblePorterError> {
        logger.log("""
            Provide called. \
            request_id=\(requestID, privacy: .public) \
            span_id=\(spanID, privacy: .public)
            """)
        let logic = self.logic
        let logger = self.logger
        return await PrismTracing.withResumed(requestID: requestID, spanID: spanID) {
            do {
                try await logic.provide(additionalCryptoPayload: auxiliaryCryptoBlob)
                return .success(.init())
            } catch let error as EnsemblePorterError {
                return .failure(error)
            } catch {
                logger.error("""
                    Unexpected error during provide. \
                    error=\(String(reportable: error), privacy: .public) \
                    request_id=\(requestID, privacy: .public) \
                    span_id=\(spanID, privacy: .public)
                    """)
                return .failure(.unexpectedError)
            }
        }
    }

    /// Call when this turn only uses the FT/ET key (no multi-turn keys from CloudBoard).
    /// Signals EnsemblePorter that this is a non-multi-turn request.
    ///
    /// - Parameters:
    ///   - requestID: requestID
    ///   - spanID: spanID
    /// - Returns: A result indicating success or failure of the operation
    package distributed func ftETOnlyTurn(requestID: UUID, spanID: UInt64) async -> CodableResult<Empty, EnsemblePorterError> {
        logger.log("""
            ftETOnlyTurn called. \
            request_id=\(requestID, privacy: .public) \
            span_id=\(spanID, privacy: .public)
            """)
        let logic = self.logic
        return await PrismTracing.withResumed(requestID: requestID, spanID: spanID) {
            await logic.ftETOnlyTurn()
            return .success(.init())
        }
    }

}

/// Distributed actor implementation for fetching turn keys.
///
/// This provides the functionality for EnsembleWarden to fetch turn keys.
///
/// Note: fetching keys requires an entitlement that is only given to EnsembleWarden, thus preventing
/// random other processes fetching the turn key.
package distributed actor EnsemblePorterServerFetchActor<IntraEnsembleTransponder: EnsembleTransponder>: EnsemblePorterFetchActor {

    private let logic: EnsemblePorterLogic<IntraEnsembleTransponder>

    /// Entitlement that ensures that only EnsembleWarden can fetch the turn keys.
    package nonisolated var peerRequirement: XPCPeerRequirement {
        .entitlement(EnsemblePorterConstants.fetchKeysEntitlement, matches: true)
    }

    private let logger = Logger(subsystem: EnsemblePorterConstants.loggerSubsystem, category: "EnsemblePorterServerFetchActor")


    internal init(logic: EnsemblePorterLogic<IntraEnsembleTransponder>, actorSystem: ActorSystem) {
        self.logic = logic
        self.actorSystem = actorSystem
    }

    /// Retrieves a turn key
    ///
    /// - Parameter turnNumber: The turn-based key identifier for the data to retrieve
    /// - Returns: A result containing either the requested data or an error
    package distributed func fetchKey(forTurnNumber turnNumber: Int) -> CodableResult<Data, EnsemblePorterError> {
        // TODO: Actually implement this.
        logger.log("fetchKey(forTurnNumber:) called")
        return .success(.init(count: 0))
    }

    /// Gets the number of available turn keys
    ///
    /// - Returns: A result containing either the number of turn keys or an error
    package distributed func getNumberOfTurnKeys() -> CodableResult<Int, EnsemblePorterError> {
        logger.log("getNumberOfTurnKeys called")
        do {
            let count = try logic.getNumberOfTurnKeys()
            return .success(count)
        } catch let error as EnsemblePorterError {
            return .failure(error)
        } catch {
            logger.error("Unexpected error during getNumberOfTurnKeys. error=\(String(reportable: error), privacy: .public)")
            return .failure(.unexpectedError)
        }
    }

    package distributed func fetchFollowerTokens(requestID: UUID, spanID: UInt64) async -> EnsemblePorterCommon.CodableResult<FollowerTokens, EnsemblePorterCommon.EnsemblePorterError> {
        let logic = self.logic
        let logger = self.logger
        return await PrismTracing.withResumed(requestID: requestID, spanID: spanID) {
            do {
                let tokens = try await logic.fetchEnsembleFollowerPorterInstanceUUIDs()
                return .success(tokens)
            } catch let error as EnsemblePorterError {
                return .failure(error)
            } catch {
                logger.error("Unexpected error during fetchFollowerTokens. error=\(String(reportable: error), privacy: .public)")
                return .failure(.unexpectedError)
            }
        }
    }

    package distributed func fetchFTETKey(requestID: UUID, spanID: UInt64) async -> EnsemblePorterCommon.CodableResult<Data, EnsemblePorterCommon.EnsemblePorterError> {
        let logic = self.logic
        let logger = self.logger
        return await PrismTracing.withResumed(requestID: requestID, spanID: spanID) {
            do {
                PrismTracing.logCheckpoint(name: "FetchFTETKey")
                let key = try logic.keySafe.retrieveKey(turnNumber: Int.max)
                let data = key.withUnsafeBytes { Data($0) }
                return .success(data)
            } catch let error as EnsemblePorterError {
                logger.error("""
                    Error fetching FT/ET key. \
                    error=\(String(reportable: error), privacy: .public) \
                    request_id=\(requestID, privacy: .public) \
                    span_id=\(spanID, privacy: .public)
                    """)
                return .failure(error)
            } catch {
                logger.error("""
                    Error fetching FT/ET key. \
                    error=\(String(reportable: error), privacy: .public) \
                    request_id=\(requestID, privacy: .public) \
                    span_id=\(spanID, privacy: .public)
                    """)
                return .failure(.unexpectedError)
            }
        }
    }
}
