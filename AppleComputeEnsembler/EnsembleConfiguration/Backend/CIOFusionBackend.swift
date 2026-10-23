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
//  CIOFusionBackend.swift
//  AppleComputeEnsembler
//
//  Created by Dhanasekar Thangavel on 1/28/26.
//

#if canImport(AppleCIOFusionConfig)
import AppleCIOFusionConfig
import Foundation
import OSLog

fileprivate let logger = Logger(subsystem: kEnsemblerPrefix, category: "CIOFusionBackend")

@available(iOS 26.4, *)
final class CIOFusionBackend: CIOFusionBackendProtocol {
    let configuration: BackendConfiguration
    let fusionConfig: AppleCIOFusionConfig
    let _activatedLockQueue = DispatchQueue(label: "activated.lock.queue")
    var _activated = false

    var activated: Bool {
        get {
            self._activatedLockQueue.sync {
                return self._activated
            }
        }
        set {
            self._activatedLockQueue.sync {
                self._activated = newValue
            }
        }
    }

    init(configuration: BackendConfiguration) throws {
        self.configuration = configuration

        // Convert the nodes dictionary to a sorted array by rank
        let sortedNodes = configuration.ensemble.nodes.values.sorted { $0.rank < $1.rank }

        // Extract hostnames from sorted nodes and validate they exist
        let hostnames: [String] = try sortedNodes.map { node in
            guard let hostname = node.hostName else {
                throw EnsembleError.internalError(
                    error: "CIOFusionBackend: Missing hostname for node with rank \(node.rank)"
                )
            }
            return hostname
        }

        // Create AppleCIOFusionConfig instance with extracted parameters
        fusionConfig = try AppleCIOFusionConfig(
            nodeRank: UInt32(configuration.node.rank),
            nodeCount: UInt32(configuration.ensemble.nodes.count),
            mode: CIOFUSIONCONFIG_MODE_MESH.rawValue,
            hostnames: hostnames
        )

        logger.info("""
                    CIOFusionBackend FusionConfig:
                    nodeRank: \(self.fusionConfig.nodeRank),
                    nodeCount: \(self.fusionConfig.nodeCount),
                    mode: \(self.fusionConfig.mode),
                    hostnames: \(self.fusionConfig.hostnames)
                    """)

        // Configure and initialize the CIO Fusion system
        try fusionConfig.reset()

        try fusionConfig.setEnsembleInfo()
    }

    func activate() throws {
        logger.info("CIOFusionBackend.activate(): Call into CIOFusionConfig to activate the node.")
        try self.fusionConfig.activate()
        self.activated = true
        logger.info("CIOFusionBackend.activate(): fusionConfig.activateCIO() returned OK")
    }

    func deactivate() throws {
        logger.info("CIOFusionBackend.deactivate(): Call into CIOFusionConfig to reset the node.")
        try self.fusionConfig.reset()
        self.activated = false
        logger.info("CIOFusionBackend.deactivate(): fusionConfig.reset() returned OK")
    }

    func setActivatedFlag() {
        self.activated = true
    }

    func isLocked() -> Bool {
        // When the Fusion is activated, it is locked implicitly
        return self.activated
    }

    func lock() throws {
        // CIOFusion locks implicitly on activation; nothing to do here
        logger.info("CIOFusionBackend: lock is implicit on activation, no-op")
    }

    func setCryptoKey(key: Data, flags: UInt32) throws {
        logger.info("CIOFusionBackend.setCryptoKey(): Call into CIOFusionConfig to set the crypto key.")

        logger.info("Key size is \(key.count)")
        guard key.count == CIOFUSIONCONFIG_CRYPTO_KEY_SIZE else {
            throw EnsembleError.internalError(error: "CIOFusionBackend.setCryptoKey - invalid key size, expected: \(CIOFUSIONCONFIG_CRYPTO_KEY_SIZE) key size")
        }

        try self.fusionConfig.setCryptoKey(bytes: [UInt8](key))
        logger.info("CIOFusionBackend.setCryptoKey(): Successfully set the key into CIOFusionConfig.")
    }
}

enum CIOFusionError: Error {
    case apiError(code: Int32, function: String)
}

@available(iOS 26.4, *)
class AppleCIOFusionConfig {
    let nodeRank: UInt32
    let nodeCount: UInt32
    let mode: UInt32
    let hostnames: [String]
    init(nodeRank: UInt32, nodeCount: UInt32, mode: UInt32, hostnames: [String]) throws {
        // Validate parameters
        guard hostnames.count <= CIOFUSIONCONFIG_MAX_NODE_COUNT else {
            throw EnsembleError.internalError(error: "Error setting ensemble info:Too many hostnames")
        }

        guard hostnames.count == nodeCount else {
            throw EnsembleError.internalError(error: "Error setting ensemble info:Hostname count must match node count")
        }

        self.nodeRank = nodeRank
        self.nodeCount = nodeCount
        self.mode = mode
        self.hostnames = hostnames
    }

    func reset() throws {
        let result = ciofusionconfig_reset()
        guard result == 0 else {
            throw EnsembleError.internalError(error: "AppleCIOFusionConfig.reset failed with error code: \(result) when calling ciofusionconfig_reset function ")
        }
    }

    func setEnsembleInfo() throws {
        guard hostnames.count <= CIOFUSIONCONFIG_MAX_NODE_COUNT else {
            throw EnsembleError.internalError(error: "Error setting ensemble info:Too many hostnames")
        }

        guard hostnames.count == nodeCount else {
            throw EnsembleError.internalError(error: "Error setting ensemble info:Hostname count must match node count")
        }

        /* Convert Swift strings to C strings */
        let cStrings = try hostnames.map { hostname in
            guard let cString = strdup(hostname) else {
                throw EnsembleError.internalError(error: "Failed to allocate memory for hostname: \(hostname)")
            }

            logger.info("C String after strdup: \(String(cString: cString, encoding: .utf8) ?? "Invalid UTF8")")
            return cString
        }
        var cStringPointers: [UnsafePointer<CChar>?] = cStrings.map { UnsafePointer($0) }

        defer {
            cStrings.forEach { free($0) }
        }

        let count: Int = Int(nodeCount)
        for i in 0..<count {
            logger.info("Original hostnames[\(i)]: \(self.hostnames[i])")
            logger.info("C String Pointer[\(i)] : \(String(cString: cStringPointers[i]!, encoding: .utf8) ?? "Invalid UTF8")")
        }

        try cStringPointers.withUnsafeMutableBufferPointer { buffer in
            var ensembleInfo = CIOFusionConfigEnsembleInfo(
                node_rank: nodeRank,
                node_count: nodeCount,
                mode: mode,
                hostnames: buffer.baseAddress!)
            let result = ciofusionconfig_set_ensemble_info(&ensembleInfo)
            guard result == 0 else {
                logger.error("Error setting ensemble info: \(result)")
                throw EnsembleError.internalError(error: "...")
            }
        }

        logger.info("Successfully set ensemble info")
    }

    private func setCryptoKey(_ key: CIOFusionConfigEncryptionKey) throws {
        var mutableKey = key
        let result = withUnsafePointer(to: &mutableKey) { ciofusionconfig_set_crypto_key($0) }
        guard result == 0 else {
            throw EnsembleError.internalError(error: "AppleCIOFusionConfig.setCryptoKey failed with error code: \(result) when calling ciofusionconfig_set_crypto_key function ")
        }
    }

    func setCryptoKey(bytes: [UInt8]) throws {
        let key = CIOFusionConfigEncryptionKey(bytes: bytes)
        try setCryptoKey(key)
    }

    func activate(timeout: UInt64 = 500000) throws {
        let result = ciofusionconfig_activate(timeout)
        guard result == 0 else {
            throw EnsembleError.internalError(error: "AppleCIOFusionConfig.activate failed with error code: \(result) when calling ciofusionconfig_activate function ")
        }
    }
}

@available(iOS 26.4, *)
extension CIOFusionConfigEncryptionKey {
    init(bytes: [UInt8]) {
        self.init()

        withUnsafeMutableBytes(of: &self.data) { (keyBytes: UnsafeMutableRawBufferPointer) in
            bytes.withUnsafeBytes { (srcBytes: UnsafeRawBufferPointer) in
                guard let keyBaseAddress = keyBytes.baseAddress,
                      let srcBaseAddress = srcBytes.baseAddress else {
                    fatalError("CIOFusionConfigEncryptionKey: Failed to get base address of memory")
                }
                keyBaseAddress.copyMemory(from: srcBaseAddress, byteCount: Int(CIOFUSIONCONFIG_CRYPTO_KEY_SIZE))
            }
        }
    }
}
#endif
