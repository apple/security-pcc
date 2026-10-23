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
//  EnsembleWardenServerHandler.swift
//  EnsembleWarden
//
//  Created by Oliver Chick (ORAC) on 20/01/2025.
//

public import CryptoKit
internal import EnsembleWardenCommon
public import EnsembleWardenXPC
public import Foundation
public import IOSurface
private import OSLog

/// Describes the behaviour required for handling reuests as an EnsembleWardenServer
///
/// Adopters wishing to receieve messages from EnsembleWarden should create a type that conforms to this
/// protocol and pass that to ``EnsembleWardenServer``.
public protocol EnsembleWardenServerHandler {

    @available(*, deprecated)
    func start(keyID: UUID, requestID: UUID, spanID: UUID)

    // Exists for us to use internally in the daemon.
    @available(*, deprecated)
    func start(keyEncryptionKey: SymmetricKey?, keyID: UUID, requestID: UUID, spanID: UInt64)

    /// Called when a new EnsembleWarden instance is created with a new keyID.
    ///
    /// N.b. Adopting this is not usually required and the API is not usually called.
    func start(ensembleWardenCryptoHandles: EnsembleWardenCryptoHandles,
               requestID: UUID, spanID: UInt64) async throws -> FollowerTokens

    /// Called whenever new ioSurfaces are published.
    func onPublish(serializedXPCRequest: Data, privateData: [IOSurface], requestID: UUID, spanID: UUID) async throws

    /// Called whenever new ioSurfaces are published.
    func onPublish(serializedXPCRequest: Data, privateData: [IOSurface], purpose: KVCacheTransferPurpose,
                   requestID: UUID, spanID: UInt64) async throws

    /// Called whenever ioSurfaces are being fetched.
    func onFetch(serializedXPCRequest: Data, requestID: UUID, spanID: UUID) async throws -> [IOSurface]

    /// Called to prefault IOSurfaces into memory
    func onPrefault(ioSurfaces: [IOSurface], requestID: UUID, spanID: UInt64) async throws

    /// Called whenever new ioSurfaces are published.
    /// This version is for the new EnsembleTransport backend.
    /// Eventually, this should replace the other onPublish.
    func onPublish2(
        identifier: String,
        privateData: IOSurface,
        privateMetadata: IOSurface?,
        ttl: Duration,
        purpose: KVCacheTransferPurpose,
        requestID: UUID,
        spanID: UInt64) async throws

    /// Called whenever ioSurfaces are being fetched.
    /// This version is for the new EnsembleTransport backend.
    /// Eventually, this should replace the other onFetch.
    func onFetch2(
        identifier: String,
        range: ClosedRange<Int>?,
        host: String,
        requestID: UUID,
        spanID: UInt64) async throws -> EnsembleWardenFetchedData

    /// Called whenever ioSurfaces metadata are being fetched.
    /// This is only supported with EnsembleTransport backend.
    func onFetchMetadata(
        identifier: String,
        host: String,
        requestID: UUID,
        spanID: UInt64) async throws -> IOSurface?

    func onDelete(
        identifier: String,
        host: String?,
        requestID: UUID,
        spanID: UInt64) async throws

    /// Called whenever the client indicates it has finished
    func onFinish() async throws

    func onCancellation() throws

    /// Called to drop all cached data in EnsembleTransport
    func onDropAll() async throws
}

extension EnsembleWardenServerHandler {

    @available(*, deprecated)
    public func start(keyID: UUID, requestID: UUID, spanID: UUID)  {
        // TODO: Delete this function - we need to co-ordinate a build with TIE to delete this though.
        fatalError("Function should be dead. Pls file a radar")
    }

    @available(*, deprecated)
    public func start(keyEncryptionKey: SymmetricKey?, keyID: UUID, requestID: UUID, spanID: UInt64)  {
        // TODO: Delete this function - we need to co-ordinate a build with TIE to delete this though.
        fatalError("Function should be dead. Pls file a radar")
    }

    public func onPublish(serializedXPCRequest: Data, privateData: [IOSurface], requestID: UUID, spanID: UUID) async throws {
        Logger(subsystem: "com.apple.cloudos.ensemblewarden", category: "EnsembleWardenServerHandler")
            .warning("onPublish(serializedXPCRequest:privateData:requestID:spanID:) is no longer supported")
    }

    /// Called whenever new ioSurfaces are published.
    public func onPublish(serializedXPCRequest: Data, privateData: [IOSurface], purpose: KVCacheTransferPurpose,
                          requestID: UUID, spanID: UInt64) async throws {
        Logger(subsystem: "com.apple.cloudos.ensemblewarden", category: "EnsembleWardenServerHandler")
            .warning("onPublish(serializedXPCRequest:privateData:purpose:requestID:spanID:) is no longer supported")
    }

    public func onFetch(serializedXPCRequest: Data, requestID: UUID, spanID: UUID) async throws -> [IOSurface] {
        Logger(subsystem: "com.apple.cloudos.ensemblewarden", category: "EnsembleWardenServerHandler")
            .warning("onFetch(serializedXPCRequest:requestID:spanID:) is no longer supported")
        return []
    }

    // MARK: New publish/fetch API

    public func onPublish2(
        identifier: String,
        privateData: IOSurface,
        privateMetadata: IOSurface?,
        ttl: Duration,
        purpose: KVCacheTransferPurpose,
        requestID: UUID,
        spanID: UInt64
    ) async throws {
        fatalError("\(#function) not implemented")
    }

    public func onFetch2(
        identifier: String,
        range: ClosedRange<Int>?,
        host: String,
        requestID: UUID,
        spanID: UInt64
    ) async throws -> EnsembleWardenFetchedData {
        fatalError("\(#function) not implemented")
    }

    public func onFetchMetadata(
        identifier: String,
        host: String,
        requestID: UUID,
        spanID: UInt64
    ) async throws -> IOSurface? {
        fatalError("\(#function) not implemented")
    }

    public func onDelete(
        identifier: String,
        host: String?,
        requestID: UUID,
        spanID: UInt64
    ) async throws {
        fatalError("\(#function) not implemented")
    }

    // MARK: Permanent

    public func start(ensembleWardenCryptoHandles: EnsembleWardenCryptoHandles, requestID: UUID, spanID: UInt64) async throws -> FollowerTokens {
        // Don't require adopters to provide an implementation.
        return .init(nodeRanks: [])
    }

    public func onPrefault(ioSurfaces: [IOSurface], requestID: UUID, spanID: UInt64) async throws {
        // Default implementation calls prefault on each IOSurface
        for ioSurface in ioSurfaces {
            try ioSurface.prefault()
        }
    }

    public func onFinish() async throws {
        // Don't require adopters to provide an implementation.
    }

    public func onCancellation() throws {
        // Don't require adopters to provide an implementation.
    }

    public func onDropAll() async throws {
        // Default no-op implementation
    }

}
