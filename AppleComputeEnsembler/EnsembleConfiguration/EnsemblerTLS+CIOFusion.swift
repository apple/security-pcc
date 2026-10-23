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
//  EnsemblerTLS+CIOFusion.swift
//  AppleComputeEnsembler
//
//  Created by Dhanasekar Thangavel on 1/23/26.
//
//

// we need to weaklink since we wanted to run xctest on skywagon which might not contain the
// symbols.
@_weakLinked import CloudAttestation
import CryptoKit
import Foundation
import Network
import notify
import os
import OSPrivate.os.transactionPrivate // Make the Ensembler dirty

@_spi(Daemon) import AppleComputeEnsembler // Helper functions

public class EnsemblerTLSCIOFusion: EnsemblerTLS {
 
    /// Read preferences if no configuration is offered
    public convenience init(
        autoRestart: Bool = false,
        skipDarwinInitCheckOpt: Bool? = false,
        darwinInitTimeout: Int? = nil,
        useStubAttestation: Bool = false,
        allowDefaultOneNodeConfig: Bool = false,
        dataKeyDeleteTimeout: Double? = nil,
        skipWaitingForDenali: Bool = false,
        ensemblerTimeout: Int? = nil,
        traceID: String? = nil,
        spanID: String? = nil
    ) throws {
        let ensembleConfig: EnsembleConfiguration
        var skipDarwinInitCheck: Bool
        var skipWaitingForDenaliProvisioning = skipWaitingForDenali
        do {
            ensembleConfig = try readEnsemblerPreferences()
            skipDarwinInitCheck = false
        } catch {
            EnsemblerTLS.logger.error(
                """
                Failed to read ensemble config from CFPrefs: \
                \(String(reportableError: error), privacy: .public))
                """
            )
            if !allowDefaultOneNodeConfig {
                throw error
            }
            EnsemblerTLS.logger.info("Proceeding with default 1-node ensemble config.")
            ensembleConfig = try getDefaultOneNodePreferences()
            
            skipDarwinInitCheck = true
            skipWaitingForDenaliProvisioning = true
        }
        if let skipDarwinInitCheckOpt {
            skipDarwinInitCheck = skipDarwinInitCheckOpt
        } else {
            EnsemblerTLS.logger.info(
                """
                Did not find \(kSkipDarwinInitCheckPreferenceKey, privacy: .public) preference, \
                defaulting to \(skipDarwinInitCheck, privacy: .public).
                """
            )
        }
        try self.init(
            ensembleConfig: ensembleConfig,
            autoRestart: autoRestart,
            skipDarwinInitCheck: skipDarwinInitCheck,
            darwinInitTimeout: darwinInitTimeout,
            useStubAttestation: useStubAttestation,
            dataKeyDeleteTimeout: dataKeyDeleteTimeout,
            skipWaitingForDenali: skipWaitingForDenaliProvisioning,
            ensemblerTimeout: ensemblerTimeout,
            traceID: traceID,
            spanID: spanID
        )
    }
    
    init(
        ensembleConfig: EnsembleConfiguration,
        autoRestart: Bool = false,
        skipDarwinInitCheck: Bool = false,
        darwinInitTimeout: Int? = nil,
        useStubAttestation: Bool = false,
        currentUDID: String? = nil,
        skipJobQuiescence: Bool = false,
        dataKeyDeleteTimeout: Double? = nil,
        skipWaitingForDenali: Bool = false,
        ensemblerTimeout: Int? = nil,
        traceID: String? = nil,
        spanID: String? = nil
    ) throws {
        
        try super.init(ensembleConfig: ensembleConfig,
                       autoRestart: autoRestart,
                       skipDarwinInitCheck: skipDarwinInitCheck,
                       darwinInitTimeout: darwinInitTimeout,
                       useStubAttestation: useStubAttestation,
                       currentUDID: currentUDID,
                       skipJobQuiescence: skipJobQuiescence,
                       dataKeyDeleteTimeout: dataKeyDeleteTimeout,
                       skipWaitingForDenali: skipWaitingForDenali,
                       ensemblerTimeout: ensemblerTimeout,
                       traceID: traceID,
                       spanID: spanID)
        
        // Create the `StateMachine`, used to track the ensemble.
        if self.isLeader {
            self.stateMachine = try LeaderStateMachineTLS(singleNode: self.nodeMap.count == 1)

        } else {
            self.stateMachine = try FollowerStateMachineTLS(singleNode: self.nodeMap.count == 1)
        }

        let backendConfig = BackendConfiguration(
            queue: EnsemblerTLS.toBackendQ,
            node: self.currentNodeConfig,
            ensemble: self.ensembleConfig,
            delegate: nil
        )

        let backendType: BackendType
        // We use stub backend if node count is 1
        // For all other cases, we assume CIOBackend if nothing is provided
        if self.nodeMap.count == 1 {
            backendType = .StubBackend

            // For a one-node ensemble, out of an abundance of caution, lock the backend.
            do {
                let tmpBackend = try CIOBackend(configuration: backendConfig)
                try tmpBackend.lock()
            } catch {
                Self.logger.error(
                    """
                    Oops: Failed to lock CIO backend for 1-node ensemble: \
                    Maybe this system doesn't have a CIO backend? Ignoring error: \(error, privacy: .public)
                    """
                )
            }
        } else {
            backendType = ensembleConfig.backendType ?? .CIOFusionBackend
        }
        EnsemblerTLS.logger.info(
            "Initalizing ensembler: backendType: \(backendType, privacy: .public)"
        )
        
        switch backendType {
        case .CIOFusionBackend:
#if canImport(AppleCIOFusionConfig)
            if #available(iOS 26.4, *) {
                self.backend = try CIOFusionBackend(configuration: backendConfig)
            } else {
                EnsemblerTLS.logger.error(
                    "CIOFusionBackend requires iOS 26.4 or later. Current system is not supported."
                )
                throw InitializationError.invalidBackend
            }
#else
            EnsemblerTLS.logger.error("AppleCIOFusionConfig Framework is not available.")
            throw InitializationError.invalidBackend
#endif
                
    
        case .StubBackend:
            self.backend = try StubBackend(configuration: backendConfig)
        default:
            EnsemblerTLS.logger.error(
                "Invalid backend: \(backendType, privacy: .public)"
            )
            throw InitializationError.invalidBackend
        }

        guard let backend = self.backend else {
            EnsemblerTLS.logger.error("Initalizing ensembler: nil backend: This should never happen!")
            throw InitializationError.invalidBackend
        }

    }

    deinit {
        self.tlsChannel?.stopServer()
    }
    
    /// Override setCryptoKey to use 64-byte keys for CIO Fusion
    public override func setCryptoKey() {
        setCryptoKeyInternal(outputSize: 64)
    }
    
        public override func checkConnectivity() throws -> [String] {
        throw EnsembleError.internalError(error: "checkConnectivity function not available")
    }
    
    override func singleNodeActivation() throws -> Bool {
        if self.nodeMap.count == 1 {
            EnsemblerTLS.logger.info(
                "It's a single node ensemble configuration. Mark ensemble as ready."
            )
            self.goToReady()
            self.dumpEnsembleDebugMap()
            return true
        }
        
        return false
    }
    /// Activate the mesh in the underlying backend
    /// This function should NOOP if mesh is already active
    public override func activateMesh() throws {
        guard self.status == .distributedCIOKey || self.status == .keyAccepted else {
            EnsemblerTLS.logger.error(
                "Oops: Attempted to activate from an illegal state: \(self.status, privacy: .public)"
            )
            throw InitializationError.invalidActivationState
        }

        guard let backend = self.backend else {
            EnsemblerTLS.logger.error(
                "Oops: No backend specified"
            )
            throw EnsembleError.internalError(error: "No backend specified")
        }

        do {
            if !backend.isLocked() {
                // This is the expected case in production where we activate the ensemble after
                // rebooting and install the "[ACDC|Trusted] Support" cryptex.
                self.setStatus(.activating)
                try backend.activate()

                // For CIOFusion, as long as activate returns success, we know that the activation was
                // successful, so we can call ensembleReady.
                ensembleReady()

            } else if self.autoRestart {
                // TODO: rdar://123743845 (Auto restart should check isActivate() when it becomes available)
                // TODO: And looking at the surrounding code, the check above should also check it.
                EnsemblerTLS.logger.error(
                    """
                    The ensemble has already been activated. Attempting to auto-restart it. \
                    This should never happen in production!
                    """
                )
                backend.setActivatedFlag()
                goToNodeReady()
            } else {
                // If we're initializing but locked, the process probably restarted. We're toast.
                EnsemblerTLS.logger.error("Ensembler initialized in unrecoverable state, failing!")
                throw InitializationError.ensembleAlreadyActive
            }

        } catch {
            self.ensembleFailed(failMsg: "EnsemblerTLS.activateMesh: Error when activating mesh, error = \(error)")
            throw error
        }
    }
}


// Functions which invokes backend.
extension EnsemblerTLSCIOFusion {

    /// Deactivate the mesh in the underlying backend
    /// This function should NOOP if mesh is already deactivated
    public func deactivate() throws {
        try self.backend?.deactivate()
    }

    /// Is the mesh currently locked?
    ///  - Returns: `Bool` with lock status  or `false` if no backend found
    private func isLocked() -> Bool {
        let locked = self.backend?.isLocked() ?? false
        EnsemblerTLS.logger.info(
            "Backend locked status: \(locked ? "LOCKED" : "unlocked", privacy: .public)"
        )
        return locked
    }
}

