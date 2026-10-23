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
//  EnsemblePorterKeyFetcher.swift
//  EnsembleWarden
//
//  Created by Oliver Chick (ORAC) on 2025-08-26.
//

package import CryptoKit
package import EnsemblePorterCommon
package import EnsembleWardenServer
package import Foundation
private import OSLog
package import XPC

/// Client interface for fetching cryptographic keys from EnsemblePorter.
///
/// Used for EnsembleWarden to get keys from EnsemblePorter.
package final class EnsemblePorterKeyFetcher: Sendable {

    private let impl: EnsemblePorterKeyFetcherImpl<EnsemblePorterXPCSessionClient>

    package init(existingConnection: xpc_connection_t) throws {
        let client = try EnsemblePorterXPCSessionClient(existingConnection: existingConnection)
        self.impl = EnsemblePorterKeyFetcherImpl(client: client)
    }

    package init(endpoint: XPCEndpoint) {
        let client = EnsemblePorterXPCSessionClient(endpoint: endpoint)
        self.impl = EnsemblePorterKeyFetcherImpl(client: client)
    }

    /// Fetches a turn key from EnsemblePorter.
    ///
    /// - Parameters:
    ///   - forTurnNumber: The turn number for the key to fetch
    ///   - requestID: Unique identifier for tracking this request
    ///   - spanID: Span identifier for distributed tracing
    /// - Returns: The retrieved cryptographic data
    /// - Throws: EnsemblePorterError if the operation fails
    package func fetchKey(forTurnNumber: Int, requestID: UUID, spanID: UInt64) async throws -> SymmetricKey {
        return try await impl.fetchKey(forTurnNumber: forTurnNumber, requestID: requestID, spanID: spanID)
    }

    /// Gets the number of available turn keys.
    ///
    /// - Parameters:
    ///   - requestID: Unique identifier for tracking this request
    ///   - spanID: Span identifier for distributed tracing
    /// - Returns: The number of available turn keys
    /// - Throws: EnsemblePorterError if the operation fails
    package func getNumberOfTurnKeys(requestID: UUID, spanID: UInt64) async throws -> Int {
        return try await impl.getNumberOfTurnKeys(requestID: requestID, spanID: spanID)
    }

    /// Fetches the per-process tokens that were generated for follower nodes.
    ///
    /// - Parameters:
    ///   - requestID: Unique identifier for tracking this request
    ///   - spanID: Span identifier for distributed tracing
    /// - Returns: FollowerTokens containing per-process tokens for each node rank
    /// - Throws: EnsemblePorterError if the operation fails
    package func fetchFollowerTokens(requestID: UUID, spanID: UInt64) async throws -> FollowerTokens {
        return try await impl.fetchFollowerTokens(requestID: requestID, spanID: spanID)
    }

    /// Fetches the FT/ET key from EnsemblePorter.
    ///
    /// - Parameters:
    ///   - requestID: Unique identifier for tracking this request
    ///   - spanID: Span identifier for distributed tracing
    /// - Returns: The FT/ET symmetric key
    /// - Throws: EnsemblePorterError if the operation fails
    package func fetchFTETKey(requestID: UUID, spanID: UInt64) async throws -> SymmetricKey {
        return try await impl.fetchFTETKey(requestID: requestID, spanID: spanID)
    }

    /// Call when this turn only uses the FT/ET key (no multi-turn keys from CloudBoard).
    ///
    /// Signals EnsemblePorter that this is a non-multi-turn request.
    /// The key supply is handled internally by EnsemblePorter's orchestration.
    /// For multi-turn requests, don't call this - the system will wait for CloudBoard keys.
    ///
    /// - Parameters:
    ///   - requestID: Unique identifier for tracking this request
    ///   - spanID: Span identifier for distributed tracing
    /// - Throws: EnsemblePorterError if the operation fails
    package func ftETOnlyTurn(requestID: UUID, spanID: UInt64) async throws {
        return try await impl.ftETOnlyTurn(requestID: requestID, spanID: spanID)
    }
}

final package class EnsemblePorterKeyFetcherImpl<Client: EnsemblePorterClient>: Sendable {

    private let client: Client
    private let logger = Logger(OSLog(subsystem: EnsemblePorterConstants.loggerSubsystem, category: "EnsemblePorterKeyFetcher"))

    /// Creates a new key fetcher implementation with the specified client.
    /// - Parameter client: The client mechanism to use for communication
    package init(client: Client) {
        self.client = client
    }

    /// Fetches cryptographic data using the configured client.
    ///
    /// - Parameter forTurnNumber: The turn number for the key to fetch
    /// - Returns: The retrieved cryptographic data
    /// - Throws: Any client-related errors that occur
    package func fetchKey(forTurnNumber turnNumber: Int, requestID: UUID, spanID: UInt64) async throws -> SymmetricKey {
        do {
            return try await self.client.fetchKey(forTurnNumber: turnNumber, requestID: requestID, spanID: spanID)
        } catch {
            logger.error("""
                Error fetchingKey. \
                error=\(String(reportable: error), privacy: .public) \
                turn_number=\(turnNumber, privacy: .public) \
                request_id=\(requestID, privacy: .public) \
                span_id=\(spanID, privacy: .public)
                """)
            throw error
        }
    }

    /// Gets the number of available turn keys.
    ///
    /// - Parameters:
    ///   - requestID: Unique identifier for tracking this request
    ///   - spanID: Span identifier for distributed tracing
    /// - Returns: The number of available turn keys
    /// - Throws: Any client-related errors that occur
    package func getNumberOfTurnKeys(requestID: UUID, spanID: UInt64) async throws -> Int {
        do {
            return try await self.client.getNumberOfTurnKeys(requestID: requestID, spanID: spanID)
        } catch {
            logger.error("""
                Error getting number of turn keys. \
                error=\(String(reportable: error), privacy: .public) \
                request_id=\(requestID, privacy: .public) \
                span_id=\(spanID, privacy: .public)
                """)
            throw error
        }
    }

    /// Fetches the per-process tokens that were generated for follower nodes.
    ///
    /// This is just called by EnsembleWarden on the leader, which will take those tokens and give
    /// them to TIE for TIE to identify the ensemblefollowerporter instances it is using on each follower.
    ///
    /// - Parameters:
    ///   - requestID: Unique identifier for tracking this request
    ///   - spanID: Span identifier for distributed tracing
    /// - Returns: FollowerTokens containing per-process tokens for each node rank
    package func fetchFollowerTokens(requestID: UUID, spanID: UInt64) async throws -> FollowerTokens {
        logger.log("""
            fetchFollowerTokens called. \
            request_id=\(requestID, privacy: .public) \
            span_id=\(spanID, privacy: .public)
            """)
        defer {
            logger.log("""
                fetchFollowerTokens end. \
                request_id=\(requestID, privacy: .public) \
                span_id=\(spanID, privacy: .public)
                """)
        }
        do {
            return try await self.client.fetchFollowerTokens(requestID: requestID, spanID: spanID)
        } catch {
            logger.error("""
                Error fetching follower tokens. \
                error=\(String(reportable: error), privacy: .public) \
                request_id=\(requestID, privacy: .public) \
                span_id=\(spanID, privacy: .public)
                """)
            throw error
        }
    }

    /// Fetches the FT/ET key from EnsemblePorter.
    ///
    /// - Parameters:
    ///   - requestID: Unique identifier for tracking this request
    ///   - spanID: Span identifier for distributed tracing
    /// - Returns: The FT/ET symmetric key
    /// - Throws: Any client-related errors that occur
    package func fetchFTETKey(requestID: UUID, spanID: UInt64) async throws -> SymmetricKey {
        do {
            return try await self.client.fetchFTETKey(requestID: requestID, spanID: spanID)
        } catch {
            logger.error("""
                Error fetching FT/ET key. \
                error=\(String(reportable: error), privacy: .public) \
                request_id=\(requestID, privacy: .public) \
                span_id=\(spanID, privacy: .public)
                """)
            throw error
        }
    }

    /// Call when this turn only uses the FT/ET key (no multi-turn keys from CloudBoard).
    ///
    /// Signals EnsemblePorter that this is a non-multi-turn request.
    /// The key supply is handled internally by EnsemblePorter's orchestration.
    /// For multi-turn requests, don't call this - the system will wait for CloudBoard keys.
    ///
    /// - Parameters:
    ///   - requestID: Unique identifier for tracking this request
    ///   - spanID: Span identifier for distributed tracing
    /// - Throws: Any client-related errors that occur
    package func ftETOnlyTurn(requestID: UUID, spanID: UInt64) async throws {
        logger.log("""
            ftETOnlyTurn called. \
            request_id=\(requestID, privacy: .public) \
            span_id=\(spanID, privacy: .public)
            """)
        do {
            try await self.client.ftETOnlyTurn(requestID: requestID, spanID: spanID)
        } catch {
            logger.error("""
                Error calling ftETOnlyTurn. \
                error=\(String(reportable: error), privacy: .public) \
                request_id=\(requestID, privacy: .public) \
                span_id=\(spanID, privacy: .public)
                """)
            throw error
        }
    }
}

