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
//  EnsemblerService.swift
//  ensembled
//
//  Created by Alex T Newman on 12/21/23.
//

import DarwinPrivate.os.variant
import EnsembleConfiguration
import Foundation
import OSLog
@_weakLinked import SecureConfigDB
import Security
import MobileGestaltPrivate

@_spi(Daemon) import AppleComputeEnsembler // _spi interface used for mach service name, protocol

import CryptoKit
@_spi(Private) import XPC // Private/_spi interfaces used for entitlement-checking
import XPCPrivate

let kEnsemblerEntitlementPrefix = "com.apple.private.AppleComputeEnsembler"
let kEnsemblerStatusEntitlement = kEnsemblerEntitlementPrefix + ".read"
let kEnsemblerControlEntitlement = kEnsemblerEntitlementPrefix + ".control"
let kEnsemblerHealthEntitlement = kEnsemblerEntitlementPrefix + ".health"
let kEnsemblerCoordinationServiceEntitlement = kEnsemblerEntitlementPrefix + ".coordination-service"

public enum EnsemblerServiceError: Error {
	case unentitledCaller
	case unauthorizedOrUnknownOperation
	/// Most likely configuration failure
	case ensemblerInitializationError
	case notImplemented
	case serviceInitializationFailure(error: Error? = nil)
	case configurationError(error: Error? = nil)
	case ensemblerInFailedState
}

/// XPC server for EnsemblerService
struct EnsemblerService {
	static var ensembler: EnsemblerInterface?

	static let logger = Logger(subsystem: kEnsemblerPrefix, category: "Service")
	let kEnsembleActivationPreferenceKey = "AutoActivation"
	let kEnsembleAutoRestartPreferenceKey = "AutoRestartForDevOnly"
    let kEnsembleUseCIOFusionBackendPreferenceKey = "UseCIOFusion"
	let kSkipDarwinInitCheckPreferenceKey = "SkipDarwinInitCheck"
	let kSkipWaitingForDenaliPreferenceKey = "SkipWaitingForDenali"
	let kDarwinInitTimeoutPreferenceKey = "DarwinInitTimeout"
	let kEnsemblerTimeoutPreferenceKey = "EnsemblerTimeout"
	let kDataKeyDeleteTimeoutPreferenceKey = "DataKeyDeleteTimeout"
	let kEnsembleUseStubAttestationPreferenceKey = "UseStubAttestation"
	let kEnsembleUseMTLSPreferenceKey = "UseMTLS"

	// If we did not suppress activation in the daemon, we should assume that it is needed
	private func checkPrefsForActivation() -> Bool {
		guard let activate = CFPreferencesCopyValue(
			kEnsembleActivationPreferenceKey as CFString,
			kEnsemblerPrefix as CFString,
			kCFPreferencesAnyUser,
			kCFPreferencesAnyHost
		) as? Bool else {
			EnsemblerService.logger.info(
                """
                Did not find \(self.kEnsembleActivationPreferenceKey, privacy: .public) preference, \
                proceeding to activate...
                """
			)
			return true
		}
		return activate
	}
    
    func checkPrefsForCIOFusionBackend() -> Bool {
        guard let useCIOFusion = CFPreferencesCopyValue(
            kEnsembleUseCIOFusionBackendPreferenceKey as CFString,
            kEnsemblerPrefix as CFString,
            kCFPreferencesAnyUser,
            kCFPreferencesAnyHost
        ) as? Bool else {
            EnsemblerService.logger.info(
                """
                Did not find \(self.kEnsembleUseCIOFusionBackendPreferenceKey, privacy: .public) preference, \
                defaulting to false...
                """
            )
            return false
        }
      
        return useCIOFusion
    }
    
	func checkPrefsForAutoRestart() -> Bool {
		guard let enableAutoRestart = CFPreferencesCopyValue(
			kEnsembleAutoRestartPreferenceKey as CFString,
			kEnsemblerPrefix as CFString,
			kCFPreferencesAnyUser,
			kCFPreferencesAnyHost
		) as? Bool else {
			EnsemblerService.logger.info(
				"""
				Did not find \(self.kEnsembleAutoRestartPreferenceKey, privacy: .public) preference, \
				defaulting to false...
				"""
			)
			return false
		}
		if enableAutoRestart,
		   !os_variant_allows_internal_security_policies(kEnsemblerEntitlementPrefix) {
			EnsemblerService.logger.warning(
				"""
				Oops: \(self.kEnsembleAutoRestartPreferenceKey, privacy: .public) \
				can only be set to true on an internal \
				OS variant. Forcing to false.
				"""
			)
			return false
		}
		return enableAutoRestart
	}

	func checkPrefsForSkipDarwinInitCheck() -> Bool? {
		guard let skipDarwinInitCheck = CFPreferencesCopyValue(
			kSkipDarwinInitCheckPreferenceKey as CFString,
			kEnsemblerPrefix as CFString,
			kCFPreferencesAnyUser,
			kCFPreferencesAnyHost
		) as? Bool else {
			return nil
		}
		if skipDarwinInitCheck,
		   !os_variant_allows_internal_security_policies(kEnsemblerEntitlementPrefix) {
			EnsemblerService.logger.warning(
				"""
				Oops: \(self.kSkipDarwinInitCheckPreferenceKey, privacy: .public) \
				can only be set to true on an internal \
				OS variant. Forcing to false.
				"""
			)
			return false
		}
		return skipDarwinInitCheck
	}

	func checkPrefsForSkipWaitingForDenali() throws -> Bool? {
		guard let skipWaitingForDenali = CFPreferencesCopyValue(
			kSkipWaitingForDenaliPreferenceKey as CFString,
			kEnsemblerPrefix as CFString,
			kCFPreferencesAnyUser,
			kCFPreferencesAnyHost
		) as? Bool else {
			EnsemblerService.logger.warning(
				"""
				\(self.kSkipWaitingForDenaliPreferenceKey, privacy: .public) \
				not found.
				"""
			)
			return nil
		}
        
		return skipWaitingForDenali
	}

	func checkPrefsForDarwinInitTimeout() -> Int? {
		guard let darwinInitTimeout = CFPreferencesCopyValue(
			kDarwinInitTimeoutPreferenceKey as CFString,
			kEnsemblerPrefix as CFString,
			kCFPreferencesAnyUser,
			kCFPreferencesAnyHost
		) as? Int else {
			EnsemblerService.logger.info(
				"""
				Did not find \(self.kDarwinInitTimeoutPreferenceKey, privacy: .public) preference, \
				ignoring...
				"""
			)
			return nil
		}
		return darwinInitTimeout
	}

	func checkPrefsForEnsemberTimeout() -> Int? {
		guard let ensemblerTimeout = CFPreferencesCopyValue(
			kEnsemblerTimeoutPreferenceKey as CFString,
			kEnsemblerPrefix as CFString,
			kCFPreferencesAnyUser,
			kCFPreferencesAnyHost
		) as? Int else {
			EnsemblerService.logger.info(
				"""
				Did not find \(self.kEnsemblerTimeoutPreferenceKey, privacy: .public) preference, \
				ignoring...
				"""
			)
			return nil
		}
		return ensemblerTimeout
	}
    
    func checkPrefsForTraceID() throws -> String {
        let traceIDSecureConfig = "com.apple.cloudos.tracing.traceID"
       
        
        do {
            let configParams = try SecureConfigParameters.loadContents()
            // Pull the configuration value down
            let traceID = try configParams.unvalidatedStringParameter(traceIDSecureConfig)
            return traceID
        }
        catch {
            EnsemblerService.logger.info(
                """
                Did not find \(traceIDSecureConfig, privacy: .public) preference, \
                ignoring...
                """
            )
            return ""
        }
    }

    func checkPrefsForSpanID() throws -> String {
        let spanIDSecureConfig = "com.apple.cloudos.tracing.spanID"
        
        do {
            let configParams = try SecureConfigParameters.loadContents()
            // Pull the configuration value down
            let spanID = try configParams.unvalidatedStringParameter(spanIDSecureConfig)
            return spanID
        }
        catch {
            EnsemblerService.logger.info(
                """
                Did not find \(spanIDSecureConfig, privacy: .public) secureconfig, \
                ignoring...
                """
            )
            return ""
        }
    }

    
	private func checkPrefsForUseStubAttestation() -> Bool {
		#if os(iOS)
		guard let useStubAttestation = CFPreferencesCopyValue(
			kEnsembleUseStubAttestationPreferenceKey as CFString,
			kEnsemblerPrefix as CFString,
			kCFPreferencesAnyUser,
			kCFPreferencesAnyHost
		) as? Bool else {
			EnsemblerService.logger.info(
				"""
				Did not find \(self.kEnsembleUseStubAttestationPreferenceKey, privacy: .public) preference, \
				defaulting to false for iOS
				"""
			)
			return false
		}

		if useStubAttestation,
		   !os_variant_allows_internal_security_policies(kEnsemblerEntitlementPrefix) {
			EnsemblerService.logger.warning(
				"""
				Oops: \(self.kEnsembleUseStubAttestationPreferenceKey, privacy: .public) \
				can only be set to true on an internal \
				OS variant. Forcing to false.
				"""
			)
			return false
		}

		return useStubAttestation
		#elseif os(macOS)
		return true
		#else
		fatalError("Oops: Unsupported OS.")
		#endif
	}

	func checkPrefsForDataKeyDeleteTimeout() -> Double? {
		guard let dataKeyDeleteTiemout = CFPreferencesCopyValue(
			kDataKeyDeleteTimeoutPreferenceKey as CFString,
			kEnsemblerPrefix as CFString,
			kCFPreferencesAnyUser,
			kCFPreferencesAnyHost
		) as? Double else {
			EnsemblerService.logger.info(
				"""
				Did not find \(self.kDataKeyDeleteTimeoutPreferenceKey, privacy: .public) preference, \
				ignoring...
				"""
			)
			return nil
		}
		return dataKeyDeleteTiemout
	}

	private func checkforAllowDefaultOneNodeConfig() throws -> Bool {
        let secureConfigParameters = try SecureConfigParameters.loadContents()
                // for customer policy this parameter can only be set to true if the code is running in VRE
                let disableAppleInfrastructureEnforcementForResearch =
                    secureConfigParameters.research_disableAppleInfrastrucutureEnforcement ?? false

		// we should allow default one node config if either the secure config is set or if it is internal
		// variant.
		return disableAppleInfrastructureEnforcementForResearch ||
			os_variant_allows_internal_security_policies(
				kEnsemblerEntitlementPrefix
			)
	}

    private func getHWModelStr() throws -> String {
        guard let hwModelStr = MGGetStringAnswer("HWModelStr" as CFString) as? String else {
            throw EnsembleError.internalError(error: "cannot find HWModelStr")
        }
        return hwModelStr
    }

    
	init() {
		EnsemblerService.logger.info("Initializing EnsemblerService.")

		initCloudMetricsFrameworkBackend()

		// Attempt an early initialization of our configuration to avoid colliding with our
		// listener down the line
		do {
			let autoRestart = self.checkPrefsForAutoRestart()
			let skipDarwinInitCheck = self.checkPrefsForSkipDarwinInitCheck()
            let skipWaitingForDenali = try self.checkPrefsForSkipWaitingForDenali() ?? false
			let darwinInitTimeout = self.checkPrefsForDarwinInitTimeout()
			let useStubAttestation = self.checkPrefsForUseStubAttestation()
            let allowDefaultOneNodeConfig = try self.checkforAllowDefaultOneNodeConfig()
			let dataKeyDeleteTimeout = self.checkPrefsForDataKeyDeleteTimeout()
			let ensemblerTimeout = self.checkPrefsForEnsemberTimeout()
            let traceID = try self.checkPrefsForTraceID()
            let spanID = try self.checkPrefsForSpanID()
            let useCIOBackend = self.checkPrefsForCIOFusionBackend()
            let hwModelStr = try self.getHWModelStr()
            
            EnsemblerService.logger.info("Initializing EnsemblerService which uses mTLS.")
            EnsemblerService.logger.info("HW Platform detected is \(hwModelStr).")
            
            // Load CIOFusion for 226
            if hwModelStr.uppercased() == "J226CAP" {
                EnsemblerService.logger.info("Detected J226CAP. Initializing EnsemblerService with CIOFusion backend")
                EnsemblerService.ensembler = try EnsemblerTLSCIOFusion(
                    autoRestart: autoRestart,
                    skipDarwinInitCheckOpt: skipDarwinInitCheck,
                    darwinInitTimeout: darwinInitTimeout,
                    useStubAttestation: useStubAttestation,
                    allowDefaultOneNodeConfig: allowDefaultOneNodeConfig,
                    dataKeyDeleteTimeout: dataKeyDeleteTimeout,
                    skipWaitingForDenali: skipWaitingForDenali,
                    ensemblerTimeout: ensemblerTimeout,
                    traceID: traceID,
                    spanID: spanID
                )
            }
            else if hwModelStr.uppercased() == "J236CAP"{
                EnsemblerService.logger.info("Detected J236CAP. Initializing EnsemblerService with CIOMesh backend")
                EnsemblerService.ensembler = try EnsemblerTLSCIO(
                    autoRestart: autoRestart,
                    skipDarwinInitCheckOpt: skipDarwinInitCheck,
                    darwinInitTimeout: darwinInitTimeout,
                    useStubAttestation: useStubAttestation,
                    allowDefaultOneNodeConfig: allowDefaultOneNodeConfig,
                    dataKeyDeleteTimeout: dataKeyDeleteTimeout,
                    skipWaitingForDenali: skipWaitingForDenali,
                    ensemblerTimeout: ensemblerTimeout,
                    traceID: traceID,
                    spanID: spanID
                )
            }
            else { // default handling, include VRE use case
                EnsemblerService.logger.info("Default: Initializing EnsemblerService with CIOMesh backend")
                EnsemblerService.ensembler = try EnsemblerTLSCIO(
                    autoRestart: autoRestart,
                    skipDarwinInitCheckOpt: skipDarwinInitCheck,
                    darwinInitTimeout: darwinInitTimeout,
                    useStubAttestation: useStubAttestation,
                    allowDefaultOneNodeConfig: allowDefaultOneNodeConfig,
                    dataKeyDeleteTimeout: dataKeyDeleteTimeout,
                    skipWaitingForDenali: skipWaitingForDenali,
                    ensemblerTimeout: ensemblerTimeout,
                    traceID: traceID,
                    spanID: spanID
                )
            }
			
			if self.checkPrefsForActivation() == true {
				try EnsemblerService.ensembler?.activate()
			}
		} catch {
			// This state is technically not fatal. We just won't initialize.
			EnsemblerService.logger.warning(
				"Failed to initialize ensembler service at load: \(error, privacy: .public)"
			)
		}
	}

	class SessionHandler: XPCPeerHandler {

        private var session: XPCSession?
        private var registeredAppIDs: [String] = []

        init(session: XPCSession) {
            self.session = session
        }
        
		/// Get status of ensemble
		/// This information can be provided regardless of whether a configuration has been loaded
		func getStatus() -> Encodable {
			EnsemblerService.logger.debug("Fetching status")
			guard let status = EnsemblerService.ensembler?.getStatus() else {
				EnsemblerService.logger.error("Ensembler NOT configured! Initialization error?")
				return EnsemblerResponse(result: true, status: .uninitialized)
			}
			// If the ensembler is initialized, we fetch the status
			EnsemblerService.logger.debug("Found ensembler, returning status: \(status)")
			return EnsemblerResponse(result: true, status: status)
		}

		/// Get the draining state of the ensemble
		/// This information can be provided regardless of whether a configuration has been loaded
		func getDraining() -> Encodable {
			EnsemblerService.logger.debug("Fetching draining state")
			guard EnsemblerService.ensembler != nil else {
				EnsemblerService.logger.error("Ensembler NOT configured! Initialization error?")
				return EnsemblerResponse(result: false, draining: nil)
			}
			// If the ensembler is initialized, we fetch the draining state
			EnsemblerService.logger.debug("Found ensembler, returning draining state...")
			return EnsemblerResponse(result: true, draining: EnsemblerService.ensembler?.getDraninigStatus())
		}

		/// Get ensemble ID
		func getEnsembleID() -> Encodable {
			EnsemblerService.logger.debug("Fetching ensemble ID")
			guard let ensembler = EnsemblerService.ensembler else {
				EnsemblerService.logger.error("Ensembler NOT configured! Initialization error?")
				return EnsemblerResponse(result: false, status: .uninitialized)
			}
			EnsemblerService.logger.debug("Found ensembler, getting ensemble ID...")
			return EnsemblerResponse(result: true, ensembleID: ensembler.getEnsembleID() ?? kDefaultEnsembleID)
		}
        
        /// Get rack ID
        func getRackID() -> Encodable {
            EnsemblerService.logger.debug("Fetching Rack ID")
            guard let ensembler = EnsemblerService.ensembler else {
                EnsemblerService.logger.error("Ensembler NOT configured! Initialization error?")
                return EnsemblerResponse(result: false, status: .uninitialized)
            }
            EnsemblerService.logger.debug("Found ensembler, getting rack ID...")
            return EnsemblerResponse(result: true, rackID: ensembler.getRackID() ?? kDefaultRackID)
        }

		// trigger distributing the key and return SingleUseKeyToken
		func distributeDataKey(key: Data, type: DistributionType) -> Encodable {
			EnsemblerService.logger.debug("Distributing the KVCache key")
			guard let ensembler = EnsemblerService.ensembler else {
				EnsemblerService.logger.error("Ensembler NOT configured! Initialization error?")
				return EnsemblerResponse(result: false, status: .uninitialized)
			}
			EnsemblerService.logger.debug("Found ensembler, distributing KVKey...")
			do {
				return try EnsemblerResponse(
					result: true,
					singleUseKeyToken: ensembler.distributeDataKey(key: key, type: type)
				)
			} catch {
				EnsemblerService.logger.error("Error distributing KVKey: \(error, privacy: .public)")
				return EnsemblerResponse(result: false)
			}
		}

		// get the KVCache key
		func getDataKey(token: SingleUseKeyToken) -> Encodable {
			EnsemblerService.logger.debug("Getting the KVCache key")
			guard let ensembler = EnsemblerService.ensembler else {
				EnsemblerService.logger.error("Ensembler NOT configured! Initialization error?")
				return EnsemblerResponse(result: false, status: .uninitialized)
			}
			EnsemblerService.logger.debug("Found ensembler, getting KVKey...")
			do {
				guard let keyData = try ensembler.getDataKey(token: token) else {
					EnsemblerService.logger
						.error("We got nil key data from ensembler, perhaps key was not found for token \(token, privacy: .public)")
					return EnsemblerResponse(result: false)
				}
				return EnsemblerResponse(result: true, kvKey: keyData)
			} catch {
				EnsemblerService.logger.error("Error getting KVKey: \(error, privacy: .public)")
				return EnsemblerResponse(result: false)
			}
		}

		/// Get maxBuffersPerKey
		func getMaxBuffersPerKey() -> Encodable {
			EnsemblerService.logger.debug("Fetching max buffers per key")
			guard let ensembler = EnsemblerService.ensembler else {
				EnsemblerService.logger.error("Ensembler NOT configured! Initialization error?")
				return EnsemblerResponse(result: false, status: .uninitialized)
			}

			EnsemblerService.logger.debug("Found ensembler, getting max buffers per key...")
			do {
				return try EnsemblerResponse(result: true, maxBuffersPerKey: ensembler.getMaxBuffersPerKey())
			} catch {
				EnsemblerService.logger.error("Error getting max buffers per key: \(error, privacy: .public)")
				return EnsemblerResponse(result: false)
			}
		}

		/// Get maxSecsPerKey
		func getMaxSecsPerKey() -> Encodable {
			EnsemblerService.logger.debug("Fetching max seconds per key")
			guard let ensembler = EnsemblerService.ensembler else {
				EnsemblerService.logger.error("Ensembler NOT configured! Initialization error?")
				return EnsemblerResponse(result: false, status: .uninitialized)
			}

			EnsemblerService.logger.debug("Found ensembler, getting max seconds per key...")
			do {
				return try EnsemblerResponse(result: true, maxSecsPerKey: ensembler.getMaxSecondsPerKey())
			} catch {
				EnsemblerService.logger.error("Error getting max buffers per key: \(error, privacy: .public)")
				return EnsemblerResponse(result: false)
			}
		}

		/// Encrypts plain text data
		func encrypt(data: Data) -> Encodable {
			EnsemblerService.logger.info("Encrypting the text")
			guard let ensembler = EnsemblerService.ensembler else {
				EnsemblerService.logger.error("Ensembler NOT configured! Initialization error?")
				return EnsemblerResponse(result: true, status: .uninitialized)
			}

			guard ensembler.getStatus() == .ready else {
				EnsemblerService.logger.warning(
					"Ensembler not ready yet. Cannot encrypt before status is ready"
				)
				return EnsemblerResponse(result: true, status: ensembler.getStatus())
			}

			do {
				let encrypted = try ensembler.encryptData(data: data)
				return EnsemblerResponse(result: true, encrypted: encrypted)
			} catch {
				EnsemblerService.logger.error("Error encrypting text")
				return EnsemblerResponse(result: false)
			}
		}

		/// Decrypts the data
		func decrypt(data: Data) -> Encodable {
			EnsemblerService.logger.info("Decrypting the text")
			guard let ensembler = EnsemblerService.ensembler else {
				EnsemblerService.logger.error("Ensembler NOT configured! Initialization error?")
				return EnsemblerResponse(result: true, status: .uninitialized)
			}

			guard ensembler.getStatus() == .ready else {
				EnsemblerService.logger
					.warning("Ensembler not ready yet. Cannot decrypt before status is ready")
				return EnsemblerResponse(result: true, status: ensembler.getStatus())
			}

			do {
				let decrypted = try ensembler.decryptData(data: data)
				return EnsemblerResponse(result: true, decrypted: decrypted)
			} catch {
				EnsemblerService.logger.error("Error decrypting text")
				return EnsemblerResponse(result: false)
			}
		}

		/// Get Authcode for the data
		func getAuthCode(data: Data) -> Encodable {
			EnsemblerService.logger.debug("Getting the auth code")
			guard let ensembler = EnsemblerService.ensembler else {
				EnsemblerService.logger.error("Ensembler NOT configured! Initialization error?")
				return EnsemblerResponse(result: false, status: .uninitialized)
			}

			guard ensembler.getStatus() == .ready else {
				EnsemblerService.logger
					.warning("Ensembler not ready yet. Cannot get auth code before status is ready")
				return EnsemblerResponse(result: false, status: ensembler.getStatus())
			}

			do {
				let authCode = try ensembler.getAuthCode(data: data)
				return EnsemblerResponse(result: true, authCode: authCode)
			} catch {
				EnsemblerService.logger.error("Error getting auth code : \(error, privacy: .public)")
				return EnsemblerResponse(result: false)
			}
		}

		/// Rotate the shared key
		func rotateSharedKey() -> Encodable {
			EnsemblerService.logger.info("Rotating shared Key")
			guard let ensembler = EnsemblerService.ensembler else {
				EnsemblerService.logger.error("Ensembler NOT configured! Initialization error?")
				return EnsemblerResponse(result: true, status: .uninitialized)
			}

			guard ensembler.getStatus() == .ready else {
				EnsemblerService.logger
					.warning(
						"Ensembler not ready yet. Cannot rotate the shared key before the status is ready"
					)
				return EnsemblerResponse(result: true, status: ensembler.getStatus())
			}

			do {
				try ensembler.rotateKey()
			} catch {
				EnsemblerService.logger.error("Error rotating shared key")
				return EnsemblerResponse(result: false)
			}

			return EnsemblerResponse(result: true)
		}

		func reloadConfiguration() -> Encodable {
			EnsemblerService.logger.info("Attempting to reload configuration")
			// We have no legal re-configuration model for a running ensemble at this time
			guard EnsemblerService.ensembler == nil else {
				EnsemblerService.logger.error("Ensembler already initialized, cannot reconfigure")
				// While not technically success, we are configured and should return true
				return EnsemblerResponse(result: true)
			}
			do {
				EnsemblerService.ensembler = try EnsemblerTLS()
			} catch {
				EnsemblerService.logger.error("Failed to reload configuration: \(error, privacy: .public)")
				return EnsemblerResponse(result: false)
			}
			EnsemblerService.logger.debug("Configuration loaded.")
			return EnsemblerResponse(result: true)
		}

		func activate() -> Encodable {
			EnsemblerService.logger.info("Attempting to activate backend")
			do {
				try EnsemblerService.ensembler?.activate()
				return EnsemblerResponse(result: true)
			} catch {
				EnsemblerService.logger.error("Ensembler activation failed: \(error, privacy: .public))")
				return EnsemblerResponse(result: false, error: String(describing: error))
			}
		}

		func getNodeMap() -> Encodable {
			EnsemblerService.logger.debug("Attempting to fetch nodeMap")
			return EnsemblerResponse(result: true, nodesInfo: EnsemblerService.ensembler?.getNodeMap())
		}

		func sendTestMessage(destination: Int) -> Encodable {
			EnsemblerService.logger.info("Attempting to send test message to \(destination, privacy: .public)")
			do {
				try EnsemblerService.ensembler?.sendTestMessage(destination: destination)
				return EnsemblerResponse(result: true)
			} catch {
				EnsemblerService.logger.error(
                    "Failed to send test message to \(destination, privacy: .public), error: \(error, privacy: .public)"
				)
				return EnsemblerResponse(result: false, error: String(describing: error))
			}
		}

		func getHealthState() -> Encodable {
			EnsemblerService.logger.debug("Attempting to get ensembler health state")
			let health = EnsemblerService.ensembler?.getHealth()
			return EnsemblerResponse(result: true, health: health)
		}

		func getCableDiagnostics() -> Encodable {
			EnsemblerService.logger.info("Attempting to get cable diagnostics")
			do {
				let diags = try EnsemblerService.ensembler?.checkConnectivity()
				return EnsemblerResponse(result: true, cableDiagnostics: diags)
			} catch {
				EnsemblerService.logger.error("Failed to get cable diagnostics, error: \(error, privacy: .public)")
				return EnsemblerResponse(result: false, error: String(describing: error))
			}
		}

		/// Register callback for receiving data messages
        func registerDataCallback(appID: String, callbackID: String) -> Encodable {
            EnsemblerService.logger.info("Registering data message handler for appID--: \(appID, privacy: .public)")
			guard let ensembler = EnsemblerService.ensembler else {
				EnsemblerService.logger.error("Ensembler NOT configured! Initialization error?")
				return EnsemblerResponse(result: false, status: .uninitialized)
			}

			// Register a default callback that handles the message processing
			ensembler.registerDataCallback(appID: appID) { [weak self] sender, data in
                guard let self = self else {
                    EnsemblerService.logger.error("Received data from other node, but error in referencing self for appID: \(appID, privacy: .public)")
                    throw DataMessageError.internalError(appID: appID, reason: "EnsemblerService instance was deallocated")
                }

                EnsemblerService.logger.debug("Received data from other node for appID: \(appID, privacy: .public)")
                let receivedData = EnsemblerRequest.recievedData(sender, callbackID, data)

                guard let session = self.session else {
                    EnsemblerService.logger.error("There is no session to send data to")
                    throw DataMessageError.internalError(appID: appID, reason: "XPC session is not available")
                }

                // Use async send so the Task suspends during the XPC round-trip to the client
                // app rather than blocking an ensembled GCD thread. This prevents thread-pool
                // exhaustion when slow or sync-callback clients (e.g. porter) share the pool.
                EnsemblerService.logger.debug("Sending the data to registered app with appID: \(appID, privacy: .public).")
                let reply = try await withCheckedThrowingContinuation { continuation in
                    do {
                        try session.send(receivedData, replyHandler: continuation.resume(with:))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                let response = try reply.decode(as: EnsemblerResponse.self)

                // result == false means the app explicitly reported failure (e.g. no registered callback).
                // This is distinct from a send throw (XPC/transport failure).
                guard response.result == true else {
                    let reason = response.error ?? "App callback returned result=false"
                    EnsemblerService.logger
                        .error(
                            "App callback reported failure for appID: \(appID, privacy: .public), error: \(String(describing: response.error), privacy: .public)"
                        )
                    throw DataMessageError.internalError(appID: appID, reason: reason)
                }
                guard let responseData = response.responseData else {
                    EnsemblerService.logger.error("App callback returned nil response data for appID: \(appID, privacy: .public)")
                    throw DataMessageError.internalError(appID: appID, reason: "App callback returned nil response data")
                }

                EnsemblerService.logger.debug("Got response back from the registered app handler for appID: \(appID, privacy: .public), sending it back to sender.")
                return responseData
			}

            registeredAppIDs.append(appID)
			return EnsemblerResponse(result: true)
		}
        
        /// unregister callback for receiving data messages
        func unregisterDataCallback(appID: String) -> Encodable {
            EnsemblerService.logger.info("unregistering data message handler for appID--: \(appID, privacy: .public)")
            guard let ensembler = EnsemblerService.ensembler else {
                EnsemblerService.logger.error("Ensembler NOT configured! Initialization error?")
                return EnsemblerResponse(result: false, status: .uninitialized)
            }

            // unregister a default callback that handles the message processing
            ensembler.unregisterDataCallback(appID: appID)
            
            return EnsemblerResponse(result: true)
        }


		/// Send data and get response from destination
		func sendDataAndGetResponse(appID: String, data: Data, destination: Int, timeout: TimeInterval) async -> Encodable {
            EnsemblerService.logger.debug("Sending data to destination: \(destination, privacy: .public), appID: \(appID, privacy: .public)")
			guard let ensembler = EnsemblerService.ensembler else {
				EnsemblerService.logger.error("Ensembler NOT configured! Initialization error?")
				return EnsemblerResponse(result: false, status: .uninitialized)
			}

            let status = ensembler.getStatus()
            guard  status == .ready else {
                EnsemblerService.logger.error("Ensembler NOT in ready state, current state is \(status). Cannot send data to \(destination, privacy: .public), appID: \(appID, privacy: .public)")
                let notReady = DataMessageError.notReady(appID: appID, currentStatus: String(describing: status))
                return EnsemblerResponse(result: false, status: status,
                                         error: notReady.description,
                                         dataMessageError: try? JSONEncoder().encode(notReady))
            }
            
            // Use proper async/await without blocking any threads
            let response = await withCheckedContinuation { continuation in
                ensembler.sendDataAndGetResponse(appID: appID, data: data, destination: destination, timeout: timeout) { result in
                    continuation.resume(returning: result)
                }
            }

            switch response {
            case .success(let responseData):
                EnsemblerService.logger.debug("Successfully sent the data to destination: \(destination, privacy: .public), appID: \(appID, privacy: .public) and got the response back")
                return EnsemblerResponse(result: true, responseData: responseData)
            case .failure(let error):
                EnsemblerService.logger.error("Failed to send data and get response for appID: \(appID, privacy: .public), destination: \(destination, privacy: .public), error: \(error, privacy: .public)")
                let dataError = error as? DataMessageError
                return EnsemblerResponse(result: false,
                                         error: String(describing: error),
                                         dataMessageError: dataError.flatMap { try? JSONEncoder().encode($0) })
            }
		}
		
		/// Send data to all followers and get responses
		func sendDataToAllFollowers(appID: String, data: Data, timeout: TimeInterval) async -> Encodable {
			EnsemblerService.logger.debug("Sending data to all followers, appID: \(appID, privacy: .public)")
			guard let ensembler = EnsemblerService.ensembler else {
				EnsemblerService.logger.error("Ensembler NOT configured! Initialization error?")
				return EnsemblerResponse(result: false, status: .uninitialized)
			}
            
            let status = ensembler.getStatus()
            guard  status == .ready else {
                EnsemblerService.logger.error("Ensembler NOT in ready state, current state is \(status)")
                let notReady = DataMessageError.notReady(appID: appID, currentStatus: String(describing: status))
                return EnsemblerResponse(result: false, status: status,
                                         error: notReady.description,
                                         dataMessageError: try? JSONEncoder().encode(notReady))
            }
            

            // Use proper async/await without blocking any threads
            let response = await withCheckedContinuation { continuation in
                ensembler.sendDataToAllFollowers(appID: appID, data: data, timeout: timeout) { result in
                    continuation.resume(returning: result)
                }
            }

            switch response {
            case .success(let responses):
                return EnsemblerResponse(result: true, allFollowersResponseData: responses)
            case .failure(let error):
                EnsemblerService.logger.error("Failed to send data to all followers: \(error, privacy: .public)")
                let dataError = error as? DataMessageError
                return EnsemblerResponse(result: false,
                                         error: String(describing: error),
                                         dataMessageError: dataError.flatMap { try? JSONEncoder().encode($0) })
            }
		}
        
		func handleIncomingRequest(_ message: XPCReceivedMessage) -> Encodable? {
			var audit = message.auditToken
            
			// We always check for a read entitlement
			guard let readEntitlement = xpc_copy_entitlement_for_token(
				kEnsemblerStatusEntitlement,
				&audit
			)
			else {
				let err = EnsemblerServiceError.unentitledCaller
				EnsemblerService.logger.error("Refused client: \(err, privacy: .public)")
				return EnsemblerResponse(result: false, error: String(describing: err))
			}

			guard xpc_bool_get_value(readEntitlement) == true else {
				let err = EnsemblerServiceError.unauthorizedOrUnknownOperation
				EnsemblerService.logger.error("Refused client: \(err, privacy: .public)")
				return EnsemblerResponse(result: false, error: String(describing: err))
			}

			var controlAllowed = false

			// A control entitlement is sometimes needed
			if let controlEntitlement = xpc_copy_entitlement_for_token(
				kEnsemblerControlEntitlement,
				&audit
			) {
				controlAllowed = xpc_bool_get_value(controlEntitlement)
			}

			var healthAllowed = controlAllowed
			if !healthAllowed,
			   let healthEntitlement = xpc_copy_entitlement_for_token(
			   	kEnsemblerHealthEntitlement,
			   	&audit
			   ) {
				healthAllowed = xpc_bool_get_value(healthEntitlement)
			}

			var coordinationServiceAllowed = false

			// A coordinationservice entitlement is  needed for getting tls options
			if let coordinationServiceEntitlement = xpc_copy_entitlement_for_token(
				kEnsemblerCoordinationServiceEntitlement,
				&audit
			) {
				coordinationServiceAllowed = xpc_bool_get_value(coordinationServiceEntitlement)
			}

			// Attempt to re-initialize if we failed before
			if EnsemblerService.ensembler == nil {
				_ = self.reloadConfiguration()
			}

			do {
				let request = try message.decode(as: EnsemblerRequest.self)

				// Some commands can be used with an uninitialized Ensembler
				switch (request, controlAllowed) {
				case (.getStatus, _):
					return self.getStatus()
				case (.getDraining, _):
					return self.getDraining()
				case (.reloadConfiguration, true):
					return self.reloadConfiguration()
				default:
					break
				}

				// Some cannot. Now we bail if we have no ensembler
				guard EnsemblerService.ensembler != nil else {
					let error = EnsemblerServiceError.ensemblerInitializationError
					return EnsemblerResponse(result: false, error: String(describing: error))
				}

				// For health state and cable diagnostics, check `healthAllowed`.
				// For getting auth code used for tls options, check `coordinationServiceAllowed`
				switch request {
				case .getHealth, .getCableDiagnostics:
					guard healthAllowed else {
						let err = EnsemblerServiceError.unauthorizedOrUnknownOperation
						EnsemblerService.logger.error(
							"""
							Missing entitlement: \
							.getCableDiagnostics needs at least one of the following: \
							[\(kEnsemblerHealthEntitlement, privacy: .public), \(kEnsemblerControlEntitlement, privacy: .public)]
							"""
						)
						return EnsemblerResponse(result: false, error: String(describing: err))
					}
				case .getAuthCode(let data):
					guard coordinationServiceAllowed else {
						let err = EnsemblerServiceError.unauthorizedOrUnknownOperation
						EnsemblerService.logger.error(
							"""
							Missing entitlement: \
							.getAuthCode needs following entitlement: \
							[\(kEnsemblerCoordinationServiceEntitlement, privacy: .public)]
							"""
						)
						return EnsemblerResponse(result: false, error: String(describing: err))
					}
					return self.getAuthCode(data: data)
				case .distributeDataKey(let key, let type):
					return self.distributeDataKey(key: key, type: type)
				case .getDataKey(let token):
					return self.getDataKey(token: token)
				case .registerDataCallback(let appID, let callbackID):
					return self.registerDataCallback(appID: appID, callbackID: callbackID)
                case .unregisterDataCallback(let appID):
                    return self.unregisterDataCallback(appID: appID)
				case .sendDataAndGetResponse(let appID, let data, let destination, let timeout):
					// Use handoffReply for async processing without blocking the XPC thread
                    return message.handoffReply(to: .global(qos: .userInitiated)) {
                        Task(priority: .userInitiated) {
                            let result = await self.sendDataAndGetResponse(
                                       appID: appID,
                                       data: data,
                                       destination: destination,
                                       timeout: timeout
                                   )
                                   message.reply(result)
                               }
                           }
				case .sendDataToAllFollowers(let appID, let data, let timeout):
					// Use handoffReply for async processing without blocking the XPC thread  
                    return message.handoffReply(to: .global(qos: .userInitiated)) {
                        Task(priority: .userInitiated) { 
                            let result = await self.sendDataToAllFollowers(
                                       appID: appID,
                                       data: data,
                                       timeout: timeout
                                   )
                                   message.reply(result)
                               }
                           }
				default:
					break
				}

				switch (request, controlAllowed) {
				// Read-only functionality
				case (.getNodeMap, _):
					return self.getNodeMap()
				case (.getEnsembleID, _):
					return self.getEnsembleID()
                case (.getRackID, _):
                    return self.getRackID()
				case (.getHealth, _):
					return self.getHealthState()
				case (.getCableDiagnostics, _):
					return self.getCableDiagnostics()
				default:
					break
				}

				// Just error out if we're in a failed state. It's unclear if it's safe to proceed
				guard EnsemblerService.ensembler?.getStatus() != .failed else {
					return EnsemblerResponse(
						result: false,
						error: """
						Ensembler is in unrecoverable state, must reboot to proceed: \
						\(String(describing: EnsemblerServiceError.ensemblerInFailedState))
						"""
					)
				}

				switch (request, controlAllowed) {
				// Read-only functionality
				case (.getMaxBuffersPerKey, _):
					return self.getMaxBuffersPerKey()
				case (.getMaxSecsPerKey, _):
					return self.getMaxSecsPerKey()
				// Control functionality
				case (.activate, true):
					return self.activate()
				case (.decryptData(let data), _):
					return self.decrypt(data: data)
				case (.encryptData(let data), _):
					return self.encrypt(data: data)
				case (.rotateSharedKey, _):
					return self.rotateSharedKey()
				case (.sendTestMessage(let destination), true):
					return self.sendTestMessage(destination: destination)
				case (_, false):
					// We don't differentiate an unentitled caller with an unknown message at
					// this point
					EnsemblerService.logger.error(
						"Potentially unentitled request: \(String(describing: request), privacy: .public)"
					)
					let error = EnsemblerServiceError.unauthorizedOrUnknownOperation
					return EnsemblerResponse(result: false, error: String(describing: error))
				case (_, true):
					// We have to assume that you're allowed to do this thing we don't handle
					return EnsemblerResponse(
						result: false,
						error: String(describing: EnsemblerServiceError.notImplemented)
					)
				}
			} catch {
				EnsemblerService.logger.error(
					"Failed to decode message: \(String(reflecting: message), privacy: .public)"
				)
				return EnsemblerResponse(result: false, error: String(describing: error))
			}
		}

		func handleCancellation(error: XPCRichError) {
			EnsemblerService.logger.debug("Received session cancellation: \(error, privacy: .public)")
            for appID in registeredAppIDs {
                EnsemblerService.logger.info("handleCancellation: unregistering callback for appID: \(appID, privacy: .public)")
                EnsemblerService.ensembler?.unregisterDataCallback(appID: appID)
            }
            registeredAppIDs.removeAll()
			// Nil out session to break any retain cycle between SessionHandler and XPCSession.
			// SessionHandler is the owner of the session (strong reference); when the XPC connection
			// ends this is the right time to release it, rather than using a weak reference which
			// risks the session being prematurely deallocated.
			self.session = nil
		}
	}

	static func listen() async throws {
		do {
			_ = try XPCListener(service: kEnsemblerServiceName) { request in
				request.accept { session in
                    SessionHandler(session: session)
				}
			}
			await EnsembleWatchdogService.activate()
			await Task.suspendIndefinitely()
		} catch {
			EnsemblerService.logger.error("Failed to create listener, error: \(error, privacy: .public)")
			throw EnsemblerServiceError.serviceInitializationFailure(error: error)
		}
	}
}
