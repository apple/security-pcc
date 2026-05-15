// Copyright © 2025 Apple Inc. All Rights Reserved.

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
//  EnsemblePorterFramework.swift
//  EnsemblePorterFramework
//
//  Created by Oliver Chick (ORAC) on 2025-08-01.
//

private import Distributed
package import EnsemblePorterCommon
package import Foundation
private import OSLog
private import Synchronization

/// Main client interface for clients of EnsemblePorter who will provide keys. E.g. CloudBoard.
public final class EnsemblePorterCryptoProvider: Sendable {

    private let impl = EnsemblePorterCryptoProviderImpl(client: EnsemblePorterXPCSessionClient())

    /// Creates a new crypto provider instance with default XPC transport.
    public init() {}

    /// Provides additional cryptographic payload to the EnsemblePorter service.
    ///
    /// - Parameters:
    ///   - additionalCryptoPayload: The cryptographic data to provide
    ///   - requestID: Unique identifier for tracking this request
    ///   - spanID: Span identifier for distributed tracing
    /// - Throws: EnsemblePorterError if the operation fails
    package func provide(additionalCryptoPayload: Data, requestID: UUID, spanID: UInt64) async throws {
        try await impl.provide(additionalCryptoPayload: additionalCryptoPayload, requestID: requestID, spanID: spanID)
    }
}

/// Generic implementation of the EnsemblePorter crypto provider.
///
/// This class implements the core cryptographic operations using a pluggable
/// transport layer, allowing for different communication mechanisms.
final package class EnsemblePorterCryptoProviderImpl<Client: EnsemblePorterClient & Sendable>: Sendable {

    private let client: Client
    private let logger = Logger(OSLog(subsystem: EnsemblePorterConstants.loggerSubsystem, category: "EnsemblePorterCryptoProvider"))

    /// Creates a new crypto provider implementation with the specified client.
    /// - Parameter client: The client mechanism to use for communication
    package init(client: Client) {
        self.client = client
    }

    /// Creates a new crypto provider implementation using an existing XPC connection.
    /// - Parameter existingConnection: The XPC connection to use for communication
    /// - Throws: If the XPC session creation fails
    package init(existingConnection: xpc_connection_t) throws where Client == EnsemblePorterXPCSessionClient {
        self.client = try EnsemblePorterXPCSessionClient(existingConnection: existingConnection)
    }

    /// Properly shuts down the client connection
    package func shutdown() async throws where Client == EnsemblePorterXPCSessionClient {
        try await client.stop()
    }

    /// Provides additional cryptographic payload using the configured client.
    ///
    /// - Parameters:
    ///   - additionalCryptoPayload: The cryptographic data to provide
    ///   - requestID: Unique identifier for tracking this request
    ///   - spanID: Span identifier for distributed tracing
    /// - Throws: Any client-related errors that occur
    package func provide(additionalCryptoPayload: Data, requestID: UUID, spanID: UInt64) async throws {
        logger.log("""
            provide(additionalCryptoPayload:) called. \
            request_id=\(requestID) \
            span_id=\(spanID, privacy: .public)
            """)
        defer {
            logger.log("""
                provide(additionalCryptoPayload:) end. \
                request_id=\(requestID) \
                span_id=\(spanID, privacy: .public)
                """)
        }
        do {
            try await self.client.provide(additionalCryptoPayload: additionalCryptoPayload, requestID: requestID, spanID: spanID)
        } catch {
            logger.error("Error during provide. error=\(String(reportable: error), privacy: .public)")
            throw error
        }
    }

    package func getIntraEnsemblePublicKey() async throws -> Data where Client == EnsemblePorterXPCSessionClient {
        logger.log("getIntraEnsemblePublicKey() called.")
        defer {
            logger.log("getIntraEnsemblePublicKey() end.")
        }
        do {
            return try await PrismTracing.withResumed(requestID: UUID(), spanID: 0) {
                return try await self.client.getIntraEnsemblePublicKey()
            }
        } catch {
            logger.error("Error during getIntraEnsemblePublicKey. error=\(String(reportable: error), privacy: .public)")
            throw error
        }
    }

    package func provide(encryptedCryptoMaterial: Data, leaderPublicKey: Data, requestID: UUID, spanID: UInt64) async throws where Client == EnsemblePorterXPCSessionClient {
        logger.log("""
            provide(encryptedCryptoMaterial:) called. \
            encrypted_size=\(encryptedCryptoMaterial.count) \
            request_id=\(requestID) \
            span_id=\(spanID, privacy: .public)
            """)
        defer {
            logger.log("""
                provide(encryptedCryptoMaterial:) end. \
                request_id=\(requestID) \
                span_id=\(spanID, privacy: .public)
                """)
        }
        do {
            try await self.client.provide(encryptedCryptoMaterial: encryptedCryptoMaterial, leaderPublicKey: leaderPublicKey,
                                          requestID: requestID, spanID: spanID)
        } catch {
            logger.error("Error during provide(encryptedCryptoMaterial:). error=\(String(reportable: error), privacy: .public)")
            throw error
        }
    }
}
