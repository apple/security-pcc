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
//  EnsemblerTLS.swift
//  AppleComputeEnsembler
//
//  Created by Dhanasekar Thangavel on 11/12/24.
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

private let kDefaultDataKeyDeleteTimeout = 20.0
// Default retry interval in seconds
public let kDefaultRetryInterval = 2
public let kEnsemblerTimeout =
	1200 // we will wait for 20 minutes for followers to check in and nodes to activate their CIOMesh.
public let kMessageProcessTimeout = 2
public let kEnsemblerRecyclingTimeout =
    120 // we will wait for 2 minutes for key rotation to be successful. Currently it takes 1.5 seconds.

public class EnsemblerTLS: EnsemblerInterface, DenaliFileMonitorDelegate {
    
    public func getMaxBuffersPerKey() throws -> UInt64? {
        throw "Not implemented"
    }
    
    public func getMaxSecondsPerKey() throws -> UInt64? {
        throw "Not implemented"
    }
    
    public func getAuthCode(data: Data) throws -> Data {
        throw "Not implemented"
    }
    
    /// Triggers the workflow to rotate the keys.
    /// Common implementation shared by all subclasses (CIO, CIOFusion, etc.).
    /// Subclasses with different behaviour can override this method.
    public func rotateKey() throws {
        // Barrier on dataRequestQueue provides mutual exclusion with data sends:
        // - Waits for all currently dispatched send-initiation blocks to complete.
        // - Blocks new sendDataAndGetResponse / sendDataToAllFollowers calls from
        //   dispatching until rotateKeyInternal() returns and the barrier is released.
        // Concurrent rotateKey() callers are also serialized here since barriers on the
        // same queue are ordered with respect to each other.
        // rotateKeyInternal() additionally calls activeDataRequests.wait() to drain
        // any in-flight round-trips whose completions run outside dataRequestQueue.
        try dataRequestQueue.sync(flags: .barrier) {
            try rotateKeyInternal()
        }
    }
    
    internal func rotateKeyInternal() throws {
        guard self.status == .ready else {
            EnsemblerTLS.logger.error(
            """
            Oops: Attempting to rotate key from an illegal state: Expected .ready, \
            found \(self.status, privacy: .public)
            """
            )
            throw InitializationError.invalidOperation
        }

        guard self.isLeader == true else {
            EnsemblerTLS.logger.error("Oops: Rotate key can be called only on leader")
            throw InitializationError.invalidOperation
        }

        if self.nodeMap.count == 1 {
            EnsemblerTLS.logger.info(
            """
            EnsemblerTLS.rotateKey(): Returning in the .ready state because single-node ensembles \
            don't have a shared key to rotate.
            """
            )
            return
        }

        self.resetEnsembleKeyDistributionStatus()
        self.resetNodeReadyStatus()

        if !self.setStatus(.redistributingKey) {
            throw EnsembleError.illegalStateTransition
        }
        
        // Wait for any inflight active data requests to complete with a maximum timeout of 1 second.
        // Any new data requests would fail because we had already set the state to redistributingKey.
        let result = activeDataRequests.wait(timeout: .now() + 1)

        switch result {
        case .success:
            EnsemblerTLS.logger.info("All active data requests completed before key rotation")
        case .timedOut:
            EnsemblerTLS.logger.warning("Some data requests are still active after 1 second timeout, proceeding with key rotation")
        }

        // Timeout and move to failed state, if we get stuck in redistributingKey.
        // Store the work item so it can be cancelled when rotation succeeds and we return to .ready.
        let timeoutItem = DispatchWorkItem { [weak self] in
              guard let self = self else {
                  EnsemblerTLS.logger.error("EnsemblerTLS.rotateKey(): self deallocated")
                  return
              }

              guard self.status == .ready else {
                  EnsemblerTLS.logger.error("EnsemblerTLS.rotateKey(): Timeout when redistributing key during key recycling")
                  EnsemblerTLS.fromBackendQ.async {
                      self.ensembleFailed(failMsg: "EnsemblerTLS.rotateKey(): Timeout when redistributing key during key recycling")
                  }
                  return
              }
            EnsemblerTLS.logger.info("EnsemblerTLS.rotateKey(): Redistributing key was successful, and moved to ready state.")
        }
        keyRotationTimeoutItem = timeoutItem
        DispatchQueue.global(qos: .userInitiated)
          .asyncAfter(deadline: .now() + .seconds(kEnsemblerRecyclingTimeout), execute: timeoutItem)
        
        try self.resetFollowerConnections()
        self.sharedKey = SecureSymmetricKey()

        self.distributeKey()
    }
    
    public func sendTestMessage(destination: Int) throws {
        throw "Not implemented"
    }
    
    public func checkConnectivity() throws -> [String] {
        throw "Not implemented"
    }
    
	let ensembleConfig: EnsembleConfiguration
	public let ensembleID: String?
    public let rackID: String?
	let currentNodeConfig: NodeConfiguration
	let UDID: String
	let isLeader: Bool
	var slots = [Slot]()
	let transaction: os_transaction_t
	let autoRestart: Bool
	let doDarwinInitCheck: Bool
	let darwinInitTimeout: Int
	let dataKeyDeleteTimeout: Double
	var everyoneFound = false
	var doneInitializing = false
	var ensemblerTimeout: Int
	/// Public view of the ensemble configuration
	public var nodeMap: [String: EnsembleNodeInfo] = [:]

	public var keyMap: [SingleUseKeyToken: Data] = [:]

	// `toBackendQ` is dedicated to the backend. It should NOT be used by the EnsemblerTLS.
	static let toBackendQ = DispatchSerialQueue(label: "\(kEnsemblerPrefix).to.backend.queue")

	// `fromBackendQ` serves two purposes
	//   1. Serialize operations from the backend. For example, two `incomingMessage()` requests
	//   arriving at the ensembler concurrently are coordinated through `fromBackendQ`.
	//   2. Offload delegate handlers onto a new thread of execution. Specifically, a thread
	//   handling a backend delegate operation is NOT allowed to call back into the backend.
	//   Otherwise, ensembled can deadlock. And this can happen on the failure code path, which
	//   calls into the backend to deactivate the mesh. Thus, backend delegate operations should
	//   always be async enqueued.
	static let fromBackendQ = DispatchSerialQueue(
		label: "\(kEnsemblerPrefix).from.backend.queue",
		qos: .userInteractive
	)

	// `dataCallbackQ` is dedicated to executing external data message callbacks (e.g.
	// EnsemblePorter). It is serial to preserve message ordering for appIDs with sequential
	// dependencies. Keeping it separate from `fromBackendQ` ensures that a slow or hung
	// application callback cannot block control message processing (key rotation, ensemble
	// state transitions, etc.) on `fromBackendQ`.
	static let dataCallbackQ = DispatchSerialQueue(
		label: "\(kEnsemblerPrefix).data.callback.queue",
		qos: .userInteractive
	)

	// `drainingQ` serializes all reads/writes to `_draining`.
	let drainingQ = DispatchSerialQueue(label: "\(kEnsemblerPrefix).draining.queue")

	let dataKeyQ = DispatchSerialQueue(label: "\(kEnsemblerPrefix).datakey.queue")
	
	// Concurrent queue for data sends. Multiple sendDataAndGetResponse / sendDataToAllFollowers
    // calls dispatch here with .async and run in parallel. Key rotation dispatches with
    // .sync(flags: .barrier) as the exclusive writer, waiting for all in-flight send-initiation
    // blocks and blocking new ones until rotation completes.
    private let dataRequestQueue = DispatchQueue(label: "\(kEnsemblerPrefix).datarequest.queue", qos: .userInitiated, attributes: .concurrent)
    
    
    // active data request group
    internal let activeDataRequests = DispatchGroup()

    // Cancellable timeout work item for key rotation; cancelled on successful transition to .ready
    private var keyRotationTimeoutItem: DispatchWorkItem?

    // Cancellable timeout work item for ensemble formation; cancelled when ensemble first reaches .ready,
    // preventing a false failure if rotateSharedKey moves state to .redistributingKey before the timer fires.
    private var formationTimeoutItem: DispatchWorkItem?

    // Timestamp (nanoseconds) captured when key rotation begins (.redistributingKey); cleared after
    // duration is emitted on the subsequent .ready transition.
    private let keyRotationStartNanos = OSAllocatedUnfairLock<Int64?>(initialState: nil)
    
	private let attestationAsyncQueue = AsyncQueue()
	private var plainTextUUID = UUID().uuidString
	static let logger = Logger(subsystem: kEnsemblerPrefix, category: "EnsemblerTLS")
	internal var backend: Backend?
	// Lock-protected: onClientConnectionChange (NW delegate queue), reset functions (key-rotation
	// paths), and isAllFollowerConnectionsReady (timeout/global queues) all race on this dict.
	internal let clientConnectionsLock = OSAllocatedUnfairLock(initialState: [Int: NWConnection.State]())
	private let leaderConnectionReadySemaphore = DispatchSemaphore(value: 0)
	let allFollowersReadySemaphore = DispatchSemaphore(value: 0)
	private var announceRetryTimer: DispatchSourceTimer?
	private var serverStatus: NWListener.State = .cancelled
	private var denaliMonitor: DenaliFileMonitor? = nil
	private let skipWaitingForDenali: Bool
	private let useStubAttestation: Bool
	public var status: EnsemblerStatus {
        return self.stateMachine?.state ?? EnsemblerStatus.unknown
	}

    internal var stateMachine: (any StateMachine)? = nil

	private var _draining = false
	public var draining: Bool {
		get {
			return self.drainingQ.sync {
				return self._draining
			}
		}
		set {
			self.drainingQ.sync {
				self._draining = newValue
			}
		}
	}

	internal var sharedKey: SecureSymmetricKey?
	internal var initialSharedkey: SecureSymmetricKey?
	public var tlsChannel: TLSChannel?
	internal let jobQuiescenceMonitor = JobQuiescenceMonitor()
	internal let dataKeyDistributedDisapatchGroup = DispatchGroup()
	internal var debugMsg: DebugMessage
    internal var convergenceSummary: EnsembleFormationConvergenceSummary
    internal var traceID: String?
    internal var linkSpanID: String?
    internal var linkTraceID: String?
    internal var spanID: String?
    // Lock-protected registry: multiple data callbacks can be dispatched concurrently onto
    // DispatchQueue.global, so register/unregister must be thread-safe with respect to reads.
    private let dataMessageCallbackRegistry = OSAllocatedUnfairLock(initialState: [String: EnsembleDataMessageReceivedInternal]())
    internal var gpuCount: Int = 1

    internal func updateTraceCheckpoint(state: EnsemblerStatus,error: Error? = nil) {
        
        // we need to send convergence checkpoint only till first time ensemble move to ready
        // i.e during initial convergence
        if doneInitializing == false {
            let checkpoint = EnsembleFormationConvergenceCheckpoint(operationName: state.description,
                                                                    error: error,traceID: self.traceID,
                                                                    spanID: generateSpanId(),
                                                                    linkTraceID: linkTraceID,
                                                                    linkSpanID: linkSpanID)
            checkpoint.log(to: EnsemblerTLS.logger)
        }
    }
    
    internal func updateTraceCheckpoint(operationName: String, error: Error? = nil) {
        // we need to send convergence checkpoint only till first time ensemble move to ready
        // i.e during initial convergence
        if doneInitializing == false {
            let checkpoint = EnsembleFormationConvergenceCheckpoint(operationName: operationName,
                                                                    error: error, traceID: self.traceID,
                                                                    spanID: generateSpanId(),
                                                                    linkTraceID: linkTraceID,
                                                                    linkSpanID: linkSpanID)
            checkpoint.log(to: EnsemblerTLS.logger)
        }
    }
    
	internal func setStatus(_ state: EnsemblerStatus) -> Bool {
		do {
			try self.stateMachine?.goto(targetState: state)
		} catch {
			Self.logger.error(
				"EnsemblerTLS.setStatus(): Failed on state transition \(self.status, privacy: .public) -> \(state, privacy: .public): \(error, privacy: .public)"
			)
			self.ensembleFailed(failMsg: "EnsemblerTLS.setStatus(): Failed on state transition \(self.status) -> \(state): \(error)")
			return false
		}

		// update the metrics about the state
		handleStateTransition(
			to: self.status,
			isLeader: self.isLeader,
			rank: self.currentNodeConfig.rank,
			chassisID: self.currentNodeConfig.chassisID,
			nodeCnt: self.nodeMap.count
		)

        // capture start time for key rotation duration metric
        if state == .redistributingKey {
            keyRotationStartNanos.withLock { $0 = getNanoSec() }
        }

        // update tracecheckpoints
        updateTraceCheckpoint(state: state)
        
		// post a notification for entering to ready and failed state
		if state == .ready {
			EnsemblerTLS.logger.info(
				"Posting notifiication: \(kEnsembleStatusReadyEventName, privacy: .public)"
			)
			notify_post(kEnsembleStatusReadyEventName)
		}
		if state.inFailedState() {
			EnsemblerTLS.logger.info(
				"Posting notifiication: \(kEnsembleStatusFailedEventName, privacy: .public)"
			)
			notify_post(kEnsembleStatusFailedEventName)
		}

		return true
	}

	func validateEnsembleConfigForChassisID() -> Bool {
		// for 2 node config, we will have 1 chassis, so make the minimum as 1.
		let chassisCount = min(1, self.ensembleConfig.nodes.count / 4)
		for i in 0 ... chassisCount {
			// rank0-3 should have same chassisID, likewise rank4-7, rank8-11, and so on.
			let groupNodes = self.ensembleConfig.nodes.values.filter { $0.rank / 4 == i }
			let chassisID = groupNodes.first?.chassisID

			for node in groupNodes {
				if node.chassisID != chassisID {
					return false
				}
			}
		}

		return true
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
        spanID: String? = nil,
        gpuCount: Int = 1
	) throws {
		self.ensembleConfig = ensembleConfig
		self.ensembleID = ensembleConfig.ensembleID
        
        EnsemblerTLS.logger.info(
            """
            Initalizing ensembler: ensembleID: 
            \(self.ensembleID, privacy: .public)
            """
        )
        self.rackID = ensembleConfig.rackID
        
        EnsemblerTLS.logger.info(
            """
            Initalizing ensembler: rackID: 
            \(self.rackID, privacy: .public)
            """
        )
        
		self.skipWaitingForDenali = skipWaitingForDenali
		self.useStubAttestation = useStubAttestation
		self.debugMsg = DebugMessage()
        
        // Initialize the convergence summary for tracing
        EnsemblerTLS.logger.info(
            """
            Initalizing ensembler: traceID: 
            \(traceID, privacy: .public)
            """
        )
        
        EnsemblerTLS.logger.info(
            """
            Initalizing ensembler: spanID : 
            \(spanID, privacy: .public)
            """
        )
        
        self.traceID = generateTraceID()
        self.spanID = generateSpanId()
        self.linkSpanID = spanID
        self.linkTraceID = traceID
        self.convergenceSummary = EnsembleFormationConvergenceSummary( traceID: self.traceID, spanID: self.spanID, linkTraceID: self.linkTraceID, linkSpanID: self.linkSpanID)
        self.convergenceSummary.startTimeNanos = getNanoSec()

		// In case of running unit tests on same machine simulating running multiple instances of
		// EnsembleConfiguration, the getNodeUDID will return the same UDID and result in duplicate key
		// in the nodeMap. Because of this, EnsembleConfiguration provides way to pass in the UDID which
		// will be used only in the unit testing.
		if currentUDID == nil {
			self.UDID = try getNodeUDID()
		} else {
			self.UDID = currentUDID!
		}

		// This is OK to log publically because the private fields are obfuscated.
		EnsemblerTLS.logger.info(
			"""
			Initalizing ensembler: ensembleConfig : \
			\(String(reportableDescription: self.ensembleConfig), privacy: .public)
			"""
		)

		self.autoRestart = autoRestart
		EnsemblerTLS.logger.info(
			"Initalizing ensembler: autoRestart: \(self.autoRestart, privacy: .public)"
		)
		self.doDarwinInitCheck = !skipDarwinInitCheck
		EnsemblerTLS.logger.info(
			"Initalizing ensembler: doDarwinInitCheck: \(self.doDarwinInitCheck, privacy: .public)"
		)
		self.darwinInitTimeout = darwinInitTimeout ?? kDarwinInitDefaultTimeout
		EnsemblerTLS.logger.info(
			"""
			Initalizing ensembler: darwinInitTimeout: \
			\(self.darwinInitTimeout, privacy: .public)
			"""
		)

		self.ensemblerTimeout = ensemblerTimeout ?? kEnsemblerTimeout
		EnsemblerTLS.logger.info(
            """
            Initalizing ensembler: ensemblerTimeout: \
            \(self.ensemblerTimeout, privacy: .public)
            """
		)

		self.dataKeyDeleteTimeout = dataKeyDeleteTimeout ?? kDefaultDataKeyDeleteTimeout
		EnsemblerTLS.logger.info(
			"""
			Initalizing ensembler: dataKeyDeleteTimeout: \
			\(self.dataKeyDeleteTimeout, privacy: .public)
			"""
		)

		guard let nodeConfig = self.ensembleConfig.nodes[self.UDID] else {
			EnsemblerTLS.logger.error(
				"Failed to find configuration for UDID: \(self.UDID, privacy: .public)"
			)
			throw InitializationError.cannotFindSelfInConfiguration
		}
		EnsemblerTLS.logger.info(
			"Initalizing ensembler: UDID: \(self.UDID, privacy: .public)"
		)

		self.currentNodeConfig = nodeConfig
		// This is OK to log publically because the private fields are obfuscated.
		EnsemblerTLS.logger.info(
			"""
			Initalizing ensembler: currentNodeConfig [.public]: \
			\(String(reportableDescription: self.currentNodeConfig), privacy: .public)
			"""
		)
		EnsemblerTLS.logger.info(
			"""
			Initalizing ensembler: currentNodeConfig : \
			\(self.currentNodeConfig, privacy: .public)
			"""
		)
		self.isLeader = (self.currentNodeConfig.rank == 0 ? true : false)
		EnsemblerTLS.logger.info(
			"Initalizing ensembler: isLeader: \(self.isLeader, privacy: .public)"
		)

		for rank in 0 ..< self.ensembleConfig.nodes.count {
			if rank == self.currentNodeConfig.rank {
				self.slots.append(Util.slot())
			} else {
				self.slots.append(.notInitialized)
			}
		}

		// send metrics with initializing status
		// calling this explicitly, since calling setStatus is not allowed before initializing all
		// members.
		handleStateTransition(
			to: .initializing,
			isLeader: self.isLeader,
			rank: self.currentNodeConfig.rank,
			chassisID: self.currentNodeConfig.chassisID,
			nodeCnt: self.ensembleConfig.nodes.count
		)

		for node in self.ensembleConfig.nodes {
			self.nodeMap[node.key] = EnsembleNodeInfo(
				leader: node.value.rank == 0,
				UDID: node.key,
				rank: node.value.rank,
				hostName: node.value.hostName,
				chassisID: node.value.chassisID,
                gpuCount: gpuCount
			)
		}
		EnsemblerTLS.logger.info(
			"Initalizing ensembler: nodeMap.count: \(self.nodeMap.count, privacy: .public)"
		)

        // The ensembler has an in-memory state machine and is thus always dirty.
        self.transaction = os_transaction_create(kEnsemblerPrefix)
        
		if skipJobQuiescence == false {
			try self.jobQuiescenceMonitor.start(ensembler: self)
		}
	}

	private func startTLSChannel() throws {
		
        let dispatchGroup = DispatchGroup()
        dispatchGroup.enter()
        Task {
            defer {
                dispatchGroup.leave()
            }
            self.tlsChannel = try await TLSChannel(
                nodeInfo: self.currentNodeConfig,
                ensembleConfig: self.ensembleConfig,
                serverDelegate: self,
                clientDelegate: self,
                useNoAttestation: self.useStubAttestation
            )
            
            guard self.tlsChannel != nil else {
                EnsemblerTLS.logger.error(
                    "EnsemblerTLS.startTLSChannel() on rank \(self.currentNodeConfig.rank, privacy: .public): TLSChannel is nil"
                )
                ensembleFailed(failMsg: "EnsemblerTLS.startTLSChannel() on rank \(self.currentNodeConfig.rank): TLSChannel is nil")
                return
            }
            
            EnsemblerTLS.logger.info(
                "EnsemblerTLS.startTLSChannel() on rank \(self.currentNodeConfig.rank): Started TLSChannel Successfully"
            )
        }

        dispatchGroup.wait()

		EnsemblerTLS.logger.info(
			"The Ensembler has been setup and is ready to assemble ensembles."
		)
	}

	public func DenaliProvisioningStatus(status: Bool) {
		guard status else {
			EnsemblerTLS.logger
				.error("Denali provisioning is not complete. Moving ensembled to failed state")
            
            updateTraceCheckpoint(operationName: "Denali provisioning", error: EnsembleError.internalError(error: "Denali provisioning is not complete."))
			ensembleFailed(failMsg: "EnsemblerTLS.DenaliProvisioningStatus: Denali provisioning is not complete.")
			return
		}

        updateTraceCheckpoint(operationName: "Denali provisioning")
		EnsemblerTLS.logger.info("Denali provisioning complete.")
		do {
			try self.startTLSChannel()
			// Now that we have setup the tlschannel, we are ready to coordinate between leader and followers
			self.coordinateEnsemble()
		} catch {
			EnsemblerTLS.logger.error("EnsemblerTLS.DenaliProvisioningStatus: Error in starting TLSChannel, moving to failed state")
			ensembleFailed(failMsg: "EnsemblerTLS.DenaliProvisioningStatus: Error in starting TLSChannel, error = \(error)")
		}
	}

	deinit {
		self.tlsChannel?.stopServer()
	}

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
			skipWaitingForDenali: skipWaitingForDenali,
			ensemblerTimeout: ensemblerTimeout,
            traceID: traceID,
            spanID: spanID
		)
	}

	internal func dumpEnsembleDebugMap() {
		EnsemblerTLS.logger.info(
			"\(Util.ensembleDebugMap(ensembleConfig: self.ensembleConfig, slots: self.slots))"
		)
	}

	private func checkDarwinInit() -> Bool {
		EnsemblerTLS.logger.info(
			"""
			Running pre-activation check: darwin-init applied matches the BMC's expected darwin-init
			"""
		)
		let ok: Bool
		do {
			ok = try DarwinInitChecker(darwinInitTimeout: self.darwinInitTimeout).run()
		} catch {
			EnsemblerTLS.logger.error(
				"""
				DarwinInitChecker failed: \
				\(String(reportableError: error), privacy: .public))
				"""
			)
			return false
		}
		return ok
	}

    public func activateMesh() throws {
        EnsemblerTLS.logger.info("EnsemblerTLS: activateMesh not implemented")
    }
    
    internal func singleNodeActivation() throws -> Bool {
        return false
    }
    
	public func activate() throws {
		// Bail if we're not initializing; no need for this to be fatal
		guard self.status == .initializing else {
			EnsemblerTLS.logger.error(
				"Oops: Attempted to start coordinating from an illegal state: \(self.status, privacy: .public)"
			)
			throw InitializationError.invalidActivationState
		}

		do {
			if self.doDarwinInitCheck {
				if !self.setStatus(.initializingDarwinInitCheckInProgress) {
					throw EnsembleError.illegalStateTransition
				}
				let darwinInitOK = self.checkDarwinInit()
				if darwinInitOK {
					if !self.setStatus(.initializingActivationChecksOK) {
						throw EnsembleError.illegalStateTransition
					}
				} else {
					// Note: When a preactivation check fails, there is no way to notify others because
					// the ensemble is not activated. So just mark ourselves as failed and return.
					if !self.setStatus(.failedActivationChecks) {
						throw EnsembleError.illegalStateTransition
					}
					return
				}
			}

			if self.isLeader {
				self.sharedKey = SecureSymmetricKey()
			}

			// if there is only one node, its a single node ensemble which is valid configuration
			// we transition to ready state
			if try singleNodeActivation() == false {
				if self.skipWaitingForDenali == false {
					EnsemblerTLS.logger.info(
						"Waiting for Denali provisioning to be complete."
					)
					// we will now check if the denali has provisioned the policies, if not we will wait
					// until it is complete to before we start the servers.
					self.denaliMonitor = try DenaliFileMonitor(delegate: self)
					self.denaliMonitor?.startMonitoring()
				} else {
					EnsemblerTLS.logger.info(
						"Skipping waiting for Denali provisioning to be complete."
					)
					try self.startTLSChannel()
					self.coordinateEnsemble()
				}
			}
		} catch {
			self.ensembleFailed(failMsg: "EnsemblerTLS.activate(): Error when activating the EnsemblerTLS, error = \(error)")
			throw error
		}
	}

	public func drain() {
		// Serialize the update to `draining` through `fromBackendQ`, that way any subsequent
		// actions read the new value.
		EnsemblerTLS.fromBackendQ.sync {
			self.draining = true
		}
		do {
			try self.broadcastMessage(msg: EnsembleControlMessage.ensembleDraining)
		} catch {
			Self.logger.error("Oops, failed to broadcast .ensembleDraining msg: \(error, privacy: .public)")
		}
	}

	public func stopServer() {
		self.tlsChannel?.cancelClientRetries()
		self.tlsChannel?.stopServer()
	}
    
    internal func forwardMessage(forward: EnsembleControlMessage.Forward) {
        Self.logger.error("Not implemented")
    }
    
    func addPeer(hostName: String, nodeRank: Int) {
        Self.logger.error("Not implemented")
    }
    
    public func setCryptoKey() {
        setCryptoKeyInternal()
    }
    
    internal func setCryptoKeyInternal(outputSize: Int = 32) {
        do {
            EnsemblerTLS.logger.info(
                """
                EnsemblerTLS.setCryptoKey(): \
                Getting the derived key to set
                """
            )
            
            // use the HKDF-SHA384 derived key, default is 128bits/32 bytes, required by CIOMesh
            guard let derivedKey = try sharedKey?.getDerivedKey(type: .MeshEncryption, outputSize: outputSize) else {
                EnsemblerTLS.logger.error(
                    """
                    Oops: setCryptoKey() Getting derivedKey failed. Error getting shared key.
                    """
                )
                throw InitializationError.unexpectedBehavior(
                    """
                    Oops: setCryptoKey() Getting derivedKey failed. Error getting shared key.
                    """
                )
            }

            // store the key in initialSharedkey for use in TLS PSK Options.
            // this initialSharedkey will not be updated on rotation.
            if self.initialSharedkey == nil {
                self.initialSharedkey = try self.sharedKey?.getDerivedKey(type: .TlsPsk)
            }

            defer {
                derivedKey.zeroKey()

                EnsemblerTLS.logger.info(
                    """
                    EnsemblerTLS.setCryptoKey(): \
                    Succcessfully cleared the keydata
                    """
                )

                sharedKey?.zeroKey()
                self.sharedKey = nil
            }

            EnsemblerTLS.logger.info("EnsemblerTLS.setCryptoKey(): Call backend.setCryptoKey()")
            try self.backend?.setCryptoKey(key: derivedKey.getKeyDataWrapper().data, flags: 0)
            EnsemblerTLS.logger.info(
                "EnsemblerTLS.setCryptoKey(): Successfully set crypto key"
            )
        } catch {
            // This is technically harmless as only our status matters
            EnsemblerTLS.logger.error(
                """
                Failed to set crypto key: \
                \(String(reportableError: error), privacy: .public) (\(error, privacy: .public))
                """
            )
            ensembleFailed(failMsg: "Failed to set crypto key: \(error)")
        }
    }
    
}

// MARK: - Delegates -

// Assume we are queue protected in these delegates

extension EnsemblerTLS: ServerConnectionDelegate, ClientConnectionDelegate {

    public func incomingMessage(node: Int, message: Data, completion:@escaping (Data?) -> Void) {
        let controlMsg: EnsembleControlMessage
        do {
            controlMsg = try EnsembleControlMessage.decode(from: message)
        } catch {
            Self.logger.warning(
                "EnsemblerTLS.incomingMessage() on rank \(self.currentNodeConfig.rank, privacy: .public): Control message decoding failed: \(error, privacy: .public)"
            )
            completion(nil)
            return
        }

        // Data messages bypass fromBackendQ to reduce latency; control messages need
        // serialisation through fromBackendQ to prevent concurrent state mutations.
        if case .dataMessageRequest(let appID, let data, let requestID, let callbackTimeout) = controlMsg {
            incomingDataMessageInternal(
                node: node,
                appID: appID,
                data: data,
                requestID: requestID,
                callbackTimeout: callbackTimeout,
                completion: completion
            )
        } else {
            let dispatchGroup = DispatchGroup()
            dispatchGroup.enter()
            EnsemblerTLS.fromBackendQ.async {
                defer {
                   dispatchGroup.leave()
                }
                self.incomingControlMessageInternal(node: node, controlMsg: controlMsg, completion: completion)
            }
            if dispatchGroup.wait(timeout: .now() + 2) == .timedOut {
                Self.logger.error("EnsemblerTLS.incomingMessage(): control message processing timed out — fromBackendQ may be blocked")
                completion(nil)
            }
        }
    }
    
	public func sendCallback(node: Int, message: Data, error: Error?) {
		let controlMsg: EnsembleControlMessage
		do {
			controlMsg = try EnsembleControlMessage.decode(from: message)
		} catch {
			Self.logger.warning(
				"EnsemblerTLS.sendCallback() on rank \(self.currentNodeConfig.rank, privacy: .public): Control message decoding failed: \(error, privacy: .public)"
			)
			return
		}

		guard error == nil else {
			EnsemblerTLS.logger.error(
				"""
				EnsemblerTLS.sendCallback() on rank \(
					self.currentNodeConfig
						.rank, privacy: .public
				): sending message \(controlMsg, privacy: .public) to \(node, privacy: .public) failed with error: \(error, privacy: .public)
				"""
			)

			// transition to failed state
            ensembleFailed(failMsg: "EnsemblerTLS.sendCallback(): sending message \(controlMsg) to \(node) failed with error: \(String(describing: error)) ")
			return
		}
	}

	public func onClientConnectionFailure(node: Int) {
		EnsemblerTLS.logger.error(
			"""
			EnsemblerTLS.onClientConnectionFailure() on rank \(
				self.currentNodeConfig
					.rank, privacy: .public
			): connection to rank \(node, privacy: .public) could not be started after maximum retries.
			marking ensemble as failed
			"""
		)
		if self.isLeader == true {
			let helpMsg = """
			Possible reasons are 
			1. Network issues: Check if ensemble have network connectivity
			2. Denali ACL issues: Check if the Denali ACLs are updated for the environment. If you have moved ensembles between environment.,update the SG.
			3. Attestation: Check if all nodes are having same HW/SW configurations.Also make sure BMC are running same OS.
			"""
            ensembleFailed(failMsg: "EnsemblerTLS.onClientConnectionFailure: Leader is not able to connect to node \(node) after maximum retries.", helpMsg: helpMsg)
            return
		}
		ensembleFailed(failMsg: "EnsemblerTLS.onClientConnectionFailure: Follower node is not able to connect to leader after maximum retries.")
	}

	public func onClientConnectionChange(node: Int, state: NWConnection.State) {
		let prevState = clientConnectionsLock.withLock { connections -> NWConnection.State? in
			let prev = connections[node]
			connections[node] = state
			return prev
		}

		if prevState != .ready, state == .ready {
			EnsemblerTLS.logger.info(
				"""
				EnsemblerTLS.onClientConnectionChange() on rank \(
					self.currentNodeConfig
						.rank, privacy: .public
				): connection to rank \(node, privacy: .public) is ready now
				"""
			)
		}

		if prevState == .ready, state != .ready {
			EnsemblerTLS.logger.info(
				"""
				EnsemblerTLS.onClientConnectionChange() on rank \(
					self.currentNodeConfig
						.rank, privacy: .public
				): connection to rank \(node, privacy: .public) is disconnected
				"""
			)
		}

		if node == 0, state == .ready {
			self.leaderConnectionReadySemaphore.signal()
		}
		if self.isAllFollowerConnectionsReady() {
			self.allFollowersReadySemaphore.signal()
		}
	}

	public func onServerStatusChange(state: NWListener.State) {
		if self.serverStatus != .ready, state == .ready {
			EnsemblerTLS.logger.info(
				"""
				EnsemblerTLS.onServerStatusChange() on rank \(
					self.currentNodeConfig
						.rank, privacy: .public
				): server is ready now
				"""
			)
		}

		if self.serverStatus == .ready, state != .ready {
			EnsemblerTLS.logger.info(
				"""
				EnsemblerTLS.onServerStatusChange() on rank \(
					self.currentNodeConfig
						.rank, privacy: .public
				): server is disconnected
				"""
			)
		}

		self.serverStatus = state
	}
}

// Incoming message handlers
extension EnsemblerTLS {
	private func incomingMessageForLeader(
		node _: Int,
		controlMsg: EnsembleControlMessage,
		sender: [String: NodeConfiguration].Element
	) throws {
		switch controlMsg {
		case .followerAnnounceNode(let slot):
			self.slots[sender.value.rank] = slot
			self.handleAnnounceNode(udid: sender.key)
		case .followerKeyAccepted:
			try self.handleKeyAccepted(udid: sender.key)
		case .followerActivationComplete:
			try self.handleActivationComplete(udid: sender.key)
		case .followerNodeReady:
			try self.handleNodeReady(udid: sender.key)
		case .followerDataKeyObtained:
			try self.handleDataKeyObtained(udid: sender.key)
		case .ensembleFailed:
            
            // if leader was rebooted and its in new session's coordinating,
            // the followers will fail because of disconnection event
            // from CIOMesh due to leaders reboot and will try to send ensembleFailed
            // notification from their old session, in such case we should just ignore it.
            guard status != .coordinating else {
                EnsemblerTLS.logger.info(
                    """
                    EnsemblerTLS.ensembleFailed(): \
                    Handling extraneous message.
                    """
                )
                return
            }
            
            ensembleFailed(failMsg: "EnsemblerTLS.incomingMessageForLeader():  Received ensembleFailed from \(sender.value.rank)")
		default:
			Self.logger.error(
				"""
				EnsemblerTLS.incomingMessageForLeader(): \
				Received unexpected command message \(String(describing: controlMsg), privacy: .public)
				"""
			)
			ensembleFailed(failMsg: "EnsemblerTLS.incomingMessageForLeader():  Received unexpected command message \(controlMsg)")
		}
	}

	private func resetLeaderConnection() throws {
		// reset the connection status of all nodes
		resetLeaderConnectionStatus()
		// reconnect with clients to pick up the refreshed attestation.
		try self.tlsChannel?.reConnectWithClients()
	}

	private func incomingMessageForFollower(
		node _: Int,
		controlMsg: EnsembleControlMessage,
		sender: [String: NodeConfiguration].Element
	) throws {
		guard sender.value.rank == 0 else {
			Self.logger.error(
				"""
				EnsemblerTLS.incomingMessageForFollower(): \
				Rejecting \(String(describing: controlMsg), privacy: .public) \
				from non-leader rank \(sender.value.rank, privacy: .public)
				"""
			)
			return
		}
		switch controlMsg {
		case .ensembleAcceptAndshareCIOKey(let cioKey):
			if self.status == .keyAccepted {
				return
			}

			if self.status == .ready {
				// we got the rotated key. we should reset the connection and start using refreshed attestation
				// and tlsoptions.
				try self.resetLeaderConnection()
			}

            EnsemblerTLS.logger.info("Key obtained is of size \(cioKey.count)")
			// get the key and store it
			self.sharedKey = SecureSymmetricKey(data: cioKey)
			if !self.setStatus(.keyAccepted) {
				throw EnsembleError.illegalStateTransition
			}

			self.sendKeyAcceptedToLeader()
		case .ensembleCIOKeyShared:
			if self.status == .activating || self.status == .activated {
				return
			}
			try handleEnsembleCIOKeyShared()
		case .ensembleActivationComplete:
			try handleEnsembleActivationComplete()
		case .ensembleReady:
			if self.status == .ready {
				return
			}
			goToReady()
		case .ensembleShareDataKey(let keyData, let singleUseToken):
			setDataKey(singleUseKeyToken: singleUseToken, key: keyData)
			self.sendDataKeyObtainedToLeader()
		case .ensembleFailed:
            // if follower was rebooted and its in new session's coordinating,
            // the other nodes and leader will fail because of disconnection event
            // from CIOMesh due to the follower reboot
            // The leader will still keep sending ensembleFailed, so ignore it.
            guard status != .coordinating else {
                EnsemblerTLS.logger.info(
                    """
                    EnsemblerTLS.ensembleFailed(): \
                    Handling extraneous message.
                    """
                )
                return
            }
            
			// If we get a failure message as a follower, then leader is already broadcasting the
			// failure to the rest of the ensemble.
			self.goToFailed(failMsg: "Follower node got ensembleFailed from Leader node")
		default:
			Self.logger.error(
				"""
				EnsemblerTLS.incomingMessageForFollower(): \
				Received unexpected command message \(String(describing: controlMsg), privacy: .public)
				"""
			)
			ensembleFailed(failMsg: "EnsemblerTLS.incomingMessageForFollower():  Received unexpected command message \(controlMsg)")
		}
	}

    private func controlMessageToData(message: EnsembleControlMessage) -> Data {
        do {
            let responseMessageData = try JSONEncoder().encode(message)
            return responseMessageData
    
        } catch {
            EnsemblerTLS.logger.error(
                """
                EnsemblerTLS.controlMessageToData(): Failed to encode response to data message: \(error, privacy: .public)
                Sending default acknowledge
                """
            )
            return controlMessageToData(message: EnsembleControlMessage.acknowledge)
        }
    }

    private func invokeRegisteredCallback(callback: @escaping EnsembleDataMessageReceivedInternal,
                                          appID: String,
                                          node: Int,
                                          data: Data,
                                          requestID: UUID,
                                          callbackTimeout: TimeInterval,
                                          completion: @escaping (Data?) -> Void) {
        // Apply a callback timeout so a hung app callback doesn't block the leader
        // for the full round-trip timeout. The flag ensures only one branch fires.
        let responseSent = OSAllocatedUnfairLock(initialState: false)

        // Branch 1: app callback returns in time.
        // Use a Swift Task so the cooperative thread suspends during the async XPC round-trip
        // to the client app — no GCD thread is held while waiting, preventing thread-pool
        // exhaustion when slow or sync-callback clients (e.g. porter) share the same pool.
        let capturedAppID = appID
        let capturedRequestID = requestID
        Task(priority: .userInitiated) { [weak self] in
            guard let self else {
                EnsemblerTLS.logger.error(
                    "EnsemblerTLS.invokeRegisteredCallback: EnsemblerTLS deallocated while callback was in flight for appID: \(capturedAppID, privacy: .public) requestID: \(capturedRequestID, privacy: .public)"
                )
                return
            }
            let callbackResult: Result<Data, Error>
            do {
                callbackResult = .success(try await callback(node, data))
            } catch {
                callbackResult = .failure(error)
            }

            let alreadySent = responseSent.withLock { state -> Bool in
                if state { return true }
                state = true
                return false
            }
            guard !alreadySent else {
                EnsemblerTLS.logger.warning(
                    "EnsemblerTLS.invokeRegisteredCallback: callback returned after timeout already fired for appID: \(appID, privacy: .public) requestID: \(requestID, privacy: .public) — discarding late response"
                )
                return
            }

            switch callbackResult {
            case .success(let responseData):
                let responseMessage = EnsembleControlMessage.dataMessageResponse(
                    appID: appID,
                    data: responseData,
                    requestID: requestID
                )
                completion(self.controlMessageToData(message: responseMessage))
            case .failure(let error):
                EnsemblerTLS.logger.error(
                    """
                    EnsemblerTLS.invokeRegisteredCallback(): data message callback failed for appID:\(appID, privacy: .public) requestID: \(requestID, privacy: .public) with error: \(error, privacy: .public)
                    """
                )
                let dataError = (error as? DataMessageError) ?? DataMessageError.internalError(appID: appID, reason: error.localizedDescription)
                let errorMessage = EnsembleControlMessage.dataMessageError(
                    error: dataError,
                    requestID: requestID
                )
                completion(self.controlMessageToData(message: errorMessage))
            }
        }

        // Branch 2: callback timeout fires first
        DispatchQueue.global().asyncAfter(deadline: .now() + callbackTimeout) { [weak self] in
            guard let self else {
                EnsemblerTLS.logger.error(
                    "EnsemblerTLS.invokeRegisteredCallback: EnsemblerTLS deallocated while timeout was in flight for appID: \(capturedAppID, privacy: .public) requestID: \(capturedRequestID, privacy: .public)"
                )
                return
            }
            let alreadySent = responseSent.withLock { state -> Bool in
                if state { return true }
                state = true
                return false
            }
            guard !alreadySent else { return }
            
            EnsemblerTLS.logger.error(
                """
                EnsemblerTLS.invokeRegisteredCallback(): data message callback timedout for appID:\(appID, privacy: .public) requestID: \(requestID, privacy: .public)
                """
            )
            
            let errorMessage = EnsembleControlMessage.dataMessageError(
                error: DataMessageError.timeoutOnPeerHandler(appID: appID),
                requestID: requestID
            )
            completion(self.controlMessageToData(message: errorMessage))
        }
    }
    
	// Handles an incoming dataMessageRequest from a peer node.
	// Called directly from incomingMessage — bypasses fromBackendQ for lower latency.
	internal func incomingDataMessageInternal(
		node: Int,
		appID: String,
		data: Data,
		requestID: UUID,
		callbackTimeout: TimeInterval,
		completion: @escaping (Data?) -> Void
	) {
		EnsemblerTLS.logger.debug(
			"EnsemblerTLS.incomingDataMessageInternal(): Received data message from rank \(node, privacy: .public), appID: \(appID, privacy: .public)"
		)

        guard let callback = self.dataMessageCallbackRegistry.withLock({ $0[appID] }) else {
            // Fast-fail: no registered handler — reply immediately so the leader
            // gets a typed error rather than waiting for the full timeout.
            EnsemblerTLS.logger.warning(
                "EnsemblerTLS.incomingDataMessageInternal(): No callback registered for appID: \(appID, privacy: .public), requestID: \(requestID)"
            )
            let errorMessage = EnsembleControlMessage.dataMessageError(
                error: DataMessageError.noRegisteredHandler(appID: appID),
                requestID: requestID
            )
            completion(self.controlMessageToData(message: errorMessage))
            return
        }
        
        self.invokeRegisteredCallback(
            callback: callback,
            appID: appID,
            node: node,
            data: data,
            requestID: requestID,
            callbackTimeout: callbackTimeout,
            completion: completion
        )
	}

	// Handles all non-data control messages. Always called on fromBackendQ for serialisation.
	internal func incomingControlMessageInternal(node: Int, controlMsg: EnsembleControlMessage, completion:@escaping (Data?) -> Void) {

		guard let sender = self.ensembleConfig.nodes.first(where: { $0.value.rank == node }) else {
			Self.logger.error(
				"EnsemblerTLS.incomingControlMessageInternal() on rank \(self.currentNodeConfig.rank, privacy: .public): Cannot find node \(node, privacy: .public) in configuration"
			)
            completion(nil)
            return
		}

		Self.logger.info(
			"""
			EnsemblerTLS.incomingControlMessageInternal() on rank \(self.currentNodeConfig.rank, privacy: .public): Received \(
				controlMsg,
				privacy: .public
			) message \
			from rank \(node, privacy: .public)
			"""
		)

		switch controlMsg {
		// Generic operations
		case .ForwardMessage(let forward):
            forwardMessage(forward: forward)
		case .testMessage:
			EnsemblerTLS.logger.info(
				"""
				EnsemblerTLS.incomingControlMessageInternal(): Received test message \
				from node \(sender.key, privacy: .public) with rank \(node, privacy: .public)
				"""
			)
		case .ensembleDraining:
			self.draining = true
		default:
			// Non-generic operations
			do {
				if self.isLeader {
					try self.incomingMessageForLeader(node: node, controlMsg: controlMsg, sender: sender)
				} else {
					try self.incomingMessageForFollower(
						node: node,
						controlMsg: controlMsg,
						sender: sender
					)
				}
			} catch {
				Self.logger.warning(
					"""
					EnsemblerTLS.incomingControlMessageInternal() on rank \(self.currentNodeConfig.rank, privacy: .public):: \
					Failed to handle command message \(String(describing: controlMsg), privacy: .public): \(error, privacy: .public)
					"""
				)
			}
		}

		Self.logger.info(
			"""
			EnsemblerTLS.incomingControlMessageInternal(): \
			Finished handling message \(controlMsg, privacy: .public) \
			from node \(sender.key, privacy: .public) with rank \(node, privacy: .public)
			"""
		)

        completion(nil)
	}
    
    
}

// basic methods to send out communication mewssages
extension EnsemblerTLS {
	private func broadcastOurFailure() {
		EnsemblerTLS.logger.info(
			"EnsemblerTLS.broadcastOurFailure(): rank \(self.currentNodeConfig.rank, privacy: .public)"
		)
		let msg = EnsembleControlMessage.ensembleFailed
		do {
			if self.isLeader {
				try self.broadcastMessage(msg: msg)
			} else {
				try self.tlsChannel?.sendMessageTo(msg: msg, destination: 0)
			}
		} catch {
			EnsemblerTLS.logger.warning("Failed to broadcast failure: \(error, privacy: .public)")
		}
	}
}

// Follower specific message handlers
extension EnsemblerTLS {
	private func handleEnsembleCIOKeyShared() throws {
		// Now that we know the key is present in all nodes, we can set it in CIOMesh driver.
		self.setCryptoKey()
        
		if self.backend?.isLocked() == true {
			// backend is already activated as part of initial bootstrapping, so we can go to ready state,
			// now that we got the new rotated key
			goToNodeReady()
		} else if self.autoRestart == true {
			EnsemblerTLS.logger.error(
				"""
				The ensemble has already been activated. Attempting to auto-restart it. \
				This should never happen in production!
				"""
			)
			self.backend?.setActivatedFlag()
			goToNodeReady()
		} else {
			// Now that the key is obtained, activate the backend and then if everything looks good, go to
			// ready state.
			try self.activateMesh()
		}
	}

	private func handleEnsembleActivationComplete() throws {
		// Now that we know the all nodes are activated, we can to ready state
		goToNodeReady()
	}

}

// methods used in leader/follower to perform operations
extension EnsemblerTLS {
	internal func goToNodeReady() {
		if self.status == .ready {
			return
		}

		self.goToReady()

		sendNodeReadyToLeader()
	}

	internal func goToReady() {
		if !self.setStatus(.ready) {
			return
		}
        
        dataRequestQueue.sync {
           keyRotationTimeoutItem?.cancel()
           keyRotationTimeoutItem = nil
           formationTimeoutItem?.cancel()
           formationTimeoutItem = nil
        }
        
        if doneInitializing == false {
            convergenceSummary.endTimeNanos = getNanoSec()
            convergenceSummary.log(to: EnsemblerTLS.logger)
            if let startNanos = convergenceSummary.startTimeNanos, let endNanos = convergenceSummary.endTimeNanos {
                let durationSeconds = Double(endNanos - startNanos) / 1_000_000_000.0
                trackEnsembleFormationDuration(durationSeconds: durationSeconds, isLeader: self.isLeader, rank: self.currentNodeConfig.rank, chassisID: self.currentNodeConfig.chassisID)
            }
        } else if let startNanos = keyRotationStartNanos.withLock({ nanos -> Int64? in
            let s = nanos; nanos = nil; return s
        }) {
            let durationSeconds = Double(getNanoSec() - startNanos) / 1_000_000_000.0
            trackKeyRotationDuration(durationSeconds: durationSeconds, isLeader: self.isLeader, rank: self.currentNodeConfig.rank, chassisID: self.currentNodeConfig.chassisID)
        }
        
        self.doneInitializing = true
	}

    private func goToFailed(failMsg: String? = nil, helpMsg: String? = nil) {
        let failureMsg = failMsg ?? ""
        let helpMsg = helpMsg ?? ""
        convergenceSummary.endTimeNanos = getNanoSec()

        self.debugMsg.updatePrimaryMessage(message: failureMsg)
        self.debugMsg.updateSecondaryMessage(message: helpMsg)
        
        EnsemblerTLS.logger.error("EnsemblerTLS.goToFailed(): Marking ensemble as failed with failMsg: \(failMsg, privacy: .public), helpMsg: \(helpMsg, privacy: .public) ")
        
        let error = EnsembleError.internalError(error: failureMsg)
        
        convergenceSummary.populate(error: error)
        convergenceSummary.log(to: EnsemblerTLS.logger)
        
		if !self.draining {
			if !self.setStatus(.failed) {
				return
			}
		} else {
			if !self.setStatus(.failedWhileDraining) {
				return
			}
		}
	}

    // Check for any failures that prevents ensemble from going to ready state
    private func handleEnsemblerTimeoutFollower() {
        EnsemblerTLS.logger.warning(
            "EnsemblerTLS.handleEnsemblerTimeout(): Timeout occured while forming ensemble."
        )
        if self.status != .ready {
            ensembleFailed(failMsg: "Timeout occured on follower while forming ensemble.")
        }
    }
    
	// Check for any failures that prevents ensemble from going to ready state
	// update the debugMsg which will be propogated to AirDarwin
	private func handleEnsemblerTimeoutLeader() {
        EnsemblerTLS.logger.warning(
            "EnsemblerTLS.handleEnsemblerTimeout(): Timeout occured while forming ensemble."
        )
        
		if self.status == .coordinating, self.checkAllNodesFoundStatus() == false {
			EnsemblerTLS.logger.error(
				"EnsemblerTLS.handleEnsemblerTimeout(): Atleast one follower did not check in with leader."
			)
			let nodesNotFound = self.checkAllNodeRanksNotFound()
			let formattedNodesNotFound = nodesNotFound.map { String($0) }.joined(separator: ", ")

            let helpMsg = """
			Possible reasons are 
			1. Network issues: Check if ensemble have network connectivity
			2. Denali ACL issues: Check if the Denali ACLs are updated for the environment. If you have moved ensembles between environment.,update the SG.
			3. Attestation: Check if all nodes are having same HW/SW configurations.Also make sure BMC are running same OS.
			"""
			self.ensembleFailed(failMsg: "Ensembler Timeout: Atleast one follower did not check in with leader. Following nodes did not yet checkin:\(formattedNodesNotFound)", helpMsg: helpMsg)
			return
		}

		if self.status == .coordinating, self.isAllFollowerConnectionsReady() == false {
			EnsemblerTLS.logger.error(
				"EnsemblerTLS.handleEnsemblerTimeout(): Leader is not able to create connection to atleast one follower."
			)
			let nodesNotConnected = self.checkFollowerConnectionsNotReady()
			let formattedNodesNotConnected = nodesNotConnected.map { String($0) }.joined(separator: ", ")

            let helpMsg =  """
			Possible reasons are 
			1. Network issues: Check if ensemble have network connectivity or other network issues
			2. Denali ACL issues: Check if the Denali ACLs are updated for the environment. If you have moved ensembles between environment.,update the SG.
			3. Attestation: Check if all nodes are having same HW/SW configurations.Also make sure BMC are running same OS.
			"""
			self.ensembleFailed(failMsg: "Ensembler Timeout: Leader is not able to connect to following followers:\(formattedNodesNotConnected)", helpMsg: helpMsg)
			return
		}

		if self.status == .distributingKey, self.checkEnsembleForKeyDistribution() == false {
			EnsemblerTLS.logger.error(
				"EnsemblerTLS.handleEnsemblerTimeout(): Atleast one follower is not distributed with the CIOKey."
			)
			let nodesNotDistributedCIOKey = self.checkNodesNotDistributionCIOKey()
			let formattedNodesNotDistributedCIOKey = nodesNotDistributedCIOKey.map { String($0) }
				.joined(separator: ", ")
        
			self.ensembleFailed(failMsg: "Ensembler Timeout: Atleast one follower is not distributed the CIOKey. Following nodes did not get CIOMesh Key:\(formattedNodesNotDistributedCIOKey)")
			return
		}

		if self.status == .activating, self.checkEnsembleForActivationCompletion() == false {
			EnsemblerTLS.logger.error(
				"EnsemblerTLS.handleEnsemblerTimeout(): Atleast one follower is not able to activate the CIOMesh."
			)
			let nodesNotActivated = self.checkNodesNotActivated()
			let formattedNodesNotActivated = nodesNotActivated.map { String($0) }.joined(separator: ", ")
			
			var connectivityCheck: [String] = []
			do {
				connectivityCheck = try self.checkConnectivity()
			} catch {
				EnsemblerTLS.logger.warning(
					"EnsemblerTLS.handleEnsemblerTimeout(): Error getting information from checkConnectivity."
				)
			}
			let helpMsg = """
			Possible reasons are 
			1. Misconfiguration of the ensemble. Make sure the darwininit ensemble configuration adheres to the specification.
			2. Cable connection issues.
			3. Following is the result from cableconnectivity check:
			    \(connectivityCheck)
			"""
			self.ensembleFailed(failMsg: "Ensembler Timeout: Atleast one follower is not able to activate the CIOMesh.. Following nodes did not get CIOMesh activated:\(formattedNodesNotActivated)",
                helpMsg: helpMsg)
			return
		}

		if self.status == .activated, self.checkEnsembleForEnsembleReady() == false {
			EnsemblerTLS.logger.error(
				"EnsemblerTLS.handleEnsemblerTimeout(): Atleast one follower is not able to go to ready state."
			)
			self.ensembleFailed(failMsg: "Ensembler Timeout: Atleast one follower is not able to go to ready state.")
			return
		}

		if self.status != .ready {
			EnsemblerTLS.logger.error(
				"EnsemblerTLS.handleEnsemblerTimeout(): Leader is not able to go to ready state, while all followers checked in, activated the mesh, and ready."
			)
			self.ensembleFailed(failMsg: "Ensembler Timeout: Leader is not able to go to ready state, while all followers checked in, activated the mesh, and ready.")
			return
		}
	}

	private func coordinateEnsemble() {
		// It is time to talk to our friends
		EnsemblerTLS.logger.info(
			"EnsemblerTLS.coordinateEnsemble(): The node is now coordinating."
		)
		if !self.setStatus(.coordinating) {
			EnsemblerTLS.logger.warning(
				"EnsemblerTLS.coordinateEnsemble(): Error setting state to .coordinating ."
			)
			return
		}
		guard self.isLeader == false else {
			// We handle ourselves like any other node in the group
			self.handleAnnounceNode(udid: self.UDID)

			// Trigger handleEnsmblerTimout, and check for any failures that prevents the
			// ensemble to goto ready state.
			let leaderTimeoutItem = DispatchWorkItem { [weak self] in
				guard let self else {
					EnsemblerTLS.logger.warning("EnsemblerTLS.coordinateEnsemble(): self deallocated before leader formation timeout fired.")
					return
				}
				self.handleEnsemblerTimeoutLeader()
			}
			self.formationTimeoutItem = leaderTimeoutItem
			DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(self.ensemblerTimeout), execute: leaderTimeoutItem)
			return
		}

        // Trigger handleEnsmblerTimout, and check for any failures that prevents the
        // ensemble to goto ready state.
        let followerTimeoutItem = DispatchWorkItem { [weak self] in
            guard let self else {
                EnsemblerTLS.logger.warning("EnsemblerTLS.coordinateEnsemble(): self deallocated before follower formation timeout fired.")
                return
            }
            self.handleEnsemblerTimeoutFollower()
        }
        self.formationTimeoutItem = followerTimeoutItem
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(self.ensemblerTimeout), execute: followerTimeoutItem)
        
		DispatchQueue.global().async {
			// Wait for leader connection to become ready instead of polling every second.
			_ = self.leaderConnectionReadySemaphore.wait(timeout: .now() + .seconds(self.ensemblerTimeout))
			let leaderState = self.clientConnectionsLock.withLock { $0[0] }
			guard leaderState == .ready else {
				EnsemblerTLS.logger.error(
					"""
					EnsemblerTLS.coordinateEnsemble(): Timed out waiting for leader connection \
					after \(self.ensemblerTimeout)s. Leader connection state: \
					\(String(describing: leaderState), privacy: .public). \
					Leader may not have started yet or network connectivity issue.
					"""
				)
				return
			}

            self.updateTraceCheckpoint(operationName: "Leader arrived")
			EnsemblerTLS.logger.info(
				"EnsemblerTLS.coordinateEnsemble(): Leader came up, lets checkin with leader."
			)

            // we need to keep retrying because, in case of follower node rebooted with new config
            // the connection to leader will succeed and start sending announce message
            // but the leader will ignore it because it already found this UDID checked in.
            // when the leader node is also rebooted, then leader will respond to announce message
            // and proceed.
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now(), repeating: .seconds(30))
            timer.setEventHandler { [weak self] in
                guard let self, self.status == .coordinating else {
                    self?.announceRetryTimer?.cancel()
                    return
                }
                if self.clientConnectionsLock.withLock({ $0[0] }) == .ready {
                    self.sendAnnounceToLeader()
                }
            }
            self.announceRetryTimer = timer
            timer.resume()
		}
	}

	
}

// functions exposed to framework
extension EnsemblerTLS {
	public func getHealth() -> EnsembleHealth {
		let status = self.status
		switch status {
		// `.failed` states. These clearly indicate that the ensemble is unhealthy.
		case .failed, .failedActivationChecks, .failedWhileDraining:
			return EnsembleHealth(
				healthState: HealthState.unhealthy,
				internalState: status,
				message1: self.debugMsg.primaryMessage,
				message2: self.debugMsg.secondaryMessage
			)

		// `.healthy` states. These clearly indicate that the ensemble is healthy.
		case .ready:
			return EnsembleHealth(healthState: HealthState.healthy, internalState: status)

		// These states can be entered in two cases:
		//   1. Installing the initial key. Here, the ensemble is still starting, and we should
		//   return .initializing.
		//   2. During a key rotation. Here, the ensemble has already been established as healthy.
		//   Thus, we should return .healthy.
		default:
			if !self.doneInitializing {
				return EnsembleHealth(healthState: HealthState.initializing, internalState: status)
			} else {
				return EnsembleHealth(healthState: HealthState.healthy, internalState: status)
			}
		}
	}

	public func encryptData(data: Data) throws -> Data {
		guard let cioBackend = self.backend as? (any CIOBackendProtocol) else {
			EnsemblerTLS.logger.error("encryptData: backend does not support getCryptoKey")
			throw InitializationError.unexpectedBehavior("Oops: Error getting crypt key!")
		}
		var keyData = try cioBackend.getCryptoKey()
		defer {
			let keySize = keyData.count
			keyData.withUnsafeMutableBytes { ptr in
				if let base = ptr.baseAddress, keySize > 0 {
					memset_s(base, keySize, 0, keySize)
				}
			}
		}
		// The key we get from CIOMesh is already a derived key,
		// we are deriving a new key from the derived key here.
		let encryptKey = SecureSymmetricKey(data: keyData)
		defer { encryptKey.zeroKey() }
		let derivedKey = try encryptKey.getDerivedKey(type: .TestEncryptDecrypt)
		defer { derivedKey.zeroKey() }
		return try derivedKey.encrypt(data: data)
	}

	public func decryptData(data: Data) throws -> Data {
		guard let cioBackend = self.backend as? (any CIOBackendProtocol) else {
			EnsemblerTLS.logger.error("decryptData: backend does not support getCryptoKey")
			throw InitializationError.unexpectedBehavior("Oops: Error getting crypt key!")
		}
		var keyData = try cioBackend.getCryptoKey()
		defer {
			let keySize = keyData.count
			keyData.withUnsafeMutableBytes { ptr in
				if let base = ptr.baseAddress, keySize > 0 {
					memset_s(base, keySize, 0, keySize)
				}
			}
		}
		// The key we get from CIOMesh is already a derived key,
		// we are deriving a new key from the derived key here.
		let decryptKey = SecureSymmetricKey(data: keyData)
		defer { decryptKey.zeroKey() }
		let derivedKey = try decryptKey.getDerivedKey(type: .TestEncryptDecrypt)
		defer { derivedKey.zeroKey() }
		return try derivedKey.decrypt(data: data)
	}

	internal func resetFollowerConnections() throws {
		resetFollowerConnectionStatus()
		// reconnect with clients to pick up the refreshed attestation.
		try self.tlsChannel?.reConnectWithClients()
		self.tlsChannel?.startClientsToFollowers()

		// wait for all follower connections to come to ready state, before we
		// start broadcasting messages.
		if self.waitForAllFollowerConnectionsReady() == false {
			EnsemblerTLS.logger.error(
				"EnsemblerTLS.resetFollowerConnections() on rank \(self.currentNodeConfig.rank, privacy: .public): Could not create client connection to all followers"
			)
			ensembleFailed(failMsg: "EnsemblerTLS.resetFollowerConnections(): Leader could not create client connections to all followers")
		}
	}

	public func getStatus() -> EnsemblerStatus {
		return self.status
	}

	public func getDraninigStatus() -> Bool {
		return self.draining
	}

	public func getEnsembleID() -> String? {
        EnsemblerTLS.logger.info("EnsemblerTLS: getEnsembleID, ensemble_id = \(self.ensembleID, privacy: .public)")
		return self.ensembleID
	}
    
    public func getRackID() -> String? {
        EnsemblerTLS.logger.info("EnsemblerTLS: getRackID, rack_id = \(self.rackID, privacy: .public)")
        return self.rackID
    }

	public func getNodeMap() -> [String: EnsembleNodeInfo] {
		return self.nodeMap
	}

	private func setDataKey(singleUseKeyToken: SingleUseKeyToken, key: Data) {
		func zeroOutKey(inputKey: Data) {
			let keyDataPointer = inputKey.withUnsafeBytes { UnsafeRawPointer($0.baseAddress!) }
			let keySize = inputKey.count
			memset_s(UnsafeMutableRawPointer(mutating: keyDataPointer), keySize, 0, keySize)
		}

		EnsemblerTLS.logger.info("Setting data key for singleUseKeyToken: \(singleUseKeyToken, privacy: .public)")
		self.dataKeyQ.sync {
			// store the key in the memory map
			self.keyMap[singleUseKeyToken] = key
		}

		// start the timer to delete it.
		DispatchQueue.global().asyncAfter(deadline: .now() + self.dataKeyDeleteTimeout) { [weak self] in
			guard let self = self else {
				// bail out, but wipe out the key before we go
				EnsemblerTLS.logger.info("EnsemblerTLS deallocated during key deletion delay - key cleanup abandoned for singleUseKeyToken: \(singleUseKeyToken, privacy: .public)")
				zeroOutKey(inputKey: key)
				return
			}
			EnsemblerTLS.logger
				.info("Deleting the key from memory for singleUseKeyToken: \(singleUseKeyToken, privacy: .public)")
			self.dataKeyQ.sync {
				// secure memset the data key to 0 before we remove from the map
				zeroOutKey(inputKey: key)
				self.keyMap.removeValue(forKey: singleUseKeyToken)
			}
		}
	}

	public func distributeDataKey(key: Data, type: DistributionType) throws -> SingleUseKeyToken {
		guard self.isLeader == true else {
			EnsemblerTLS.logger.error("Oops: distributeDataKey can be called only on leader.")
			throw InitializationError.invalidOperation
		}

		let singleUseKeyToken = UUID()
		self.setDataKey(singleUseKeyToken: singleUseKeyToken, key: key)

		// distribute it, if the type is .distributed
		if type == .distributed {
			self.dataKeyDistributedDisapatchGroup.enter()
			self.distributeDataKey(singleUseKeyToken: singleUseKeyToken, key: key)

			EnsemblerTLS.logger
				.info(
					"we have broadcasted the data key to followers. waiting to get acknowledgement from followers."
				)

			// wait for confirmation that key is distributed successfully.
			let timeoutDelay: DispatchTimeInterval = .milliseconds(30)
			let result = self.dataKeyDistributedDisapatchGroup.wait(timeout: .now() + timeoutDelay)

			switch result {
			case .success:
				EnsemblerTLS.logger.info("Successfully distributed the key.")
			case .timedOut:
				EnsemblerTLS.logger.error("Error distributing the data key")
			}

			resetEnsembleDataKeyDistributionStatus()
		}

		return singleUseKeyToken
	}

	public func getDataKey(token: SingleUseKeyToken) throws -> Data? {
		self.dataKeyQ.sync {
			guard let key = keyMap[token] else {
				EnsemblerTLS.logger.warning("Oops: There was no key found for token \(token, privacy: .public).")
				return nil
			}
			// secure memset the data key to 0 before we remove from the map
			let keyData = key.withUnsafeBytes { Data(Array($0)) }

			// remove the key from memory
			self.keyMap.removeValue(forKey: token)
			let keyDataPointer = key.withUnsafeBytes { UnsafeRawPointer($0.baseAddress!) }
			let keySize = key.count
			memset_s(UnsafeMutableRawPointer(mutating: keyDataPointer), keySize, 0, keySize)
			return keyData
		}
	}
	
    public func registerDataCallback(appID: String, callback: @escaping EnsembleDataMessageReceivedInternal) {
		dataMessageCallbackRegistry.withLock { $0[appID] = callback }
	}
    
    public func unregisterDataCallback(appID: String) {
        let removed = dataMessageCallbackRegistry.withLock { $0.removeValue(forKey: appID) != nil }
        guard removed else {
            EnsemblerTLS.logger.error("No callback registered for appID: \(appID, privacy: .public)")
            return
        }
        EnsemblerTLS.logger.info("Successfully unregistered callback for appID: \(appID, privacy: .public)")
    }
	
	/// Send data to a specific node and wait for a response
	/// - Parameters:
	///   - data: The data to send
	///   - destination: The rank of the destination node
	///   - timeout: Timeout for waiting for a response (default: 2.0 seconds)
	///   - completion: Completion handler that receives the result
	public func sendDataAndGetResponse(
        appID: String,
		data: Data,
		destination: Int,
		timeout: TimeInterval = 2.0,
		completion: @escaping (Result<Data, Error>) -> Void
	) {
        
		dataRequestQueue.async {
            guard self.status == .ready else {
                EnsemblerTLS.logger.error("sendDataAndGetResponse: dropping send for appID: \(appID, privacy: .public), destination: \(destination, privacy: .public) — not ready, current status: \(self.status, privacy: .public)")
                let notReadyError = DataMessageError.notReady(appID: appID, currentStatus: String(describing: self.status))
                trackSendDataAndGetResponse(success: false, error: notReadyError, durationMs: 0, isLeader: self.isLeader, rank: self.currentNodeConfig.rank, chassisID: self.currentNodeConfig.chassisID)
                completion(.failure(notReadyError))
                return
            }

            guard let channel = self.tlsChannel else {
                EnsemblerTLS.logger.error("sendDataAndGetResponse: tlsChannel is nil for appID: \(appID, privacy: .public), destination: \(destination, privacy: .public)")
                let channelNilError = ClientError.ClientError(message: "sendDataAndGetResponse Error: tlsChannel is nil for appID: \(appID), destination: \(destination)")
                trackSendDataAndGetResponse(success: false, error: channelNilError, durationMs: 0, isLeader: self.isLeader, rank: self.currentNodeConfig.rank, chassisID: self.currentNodeConfig.chassisID)
                completion(.failure(channelNilError))
                return
            }
            let activeRequests = self.activeDataRequests
            activeRequests.enter()
            let sendStartNanos = getNanoSec()
            channel.sendDataAndGetResponse(
                appID: appID,
                data: data,
                rank: destination,
                timeout: timeout,
                completion: { result in
                    activeRequests.leave()
                    let durationMs = Double(getNanoSec() - sendStartNanos) / 1_000_000.0
                    switch result {
                    case .success:
                        trackSendDataAndGetResponse(success: true, error: nil, durationMs: durationMs, isLeader: self.isLeader, rank: self.currentNodeConfig.rank, chassisID: self.currentNodeConfig.chassisID)
                    case .failure(let error):
                        trackSendDataAndGetResponse(success: false, error: error, durationMs: durationMs, isLeader: self.isLeader, rank: self.currentNodeConfig.rank, chassisID: self.currentNodeConfig.chassisID)
                    }
                    completion(result)
                }
            )
		}
	}
    
    public func sendDataToAllFollowers(
        appID: String,
        data: Data,
        timeout: TimeInterval = 2.0,
        completion: @escaping (Result<[NodeResponse], Error>) -> Void
    ) {
		dataRequestQueue.async {
            guard self.status == .ready else {
                EnsemblerTLS.logger.error("sendDataToAllFollowers: Error sending data to all followers for appID: \(appID, privacy: .public)")
                completion(.failure(DataMessageError.notReady(appID: appID, currentStatus: String(describing: self.status))))
                return
            }
            
            guard let channel = self.tlsChannel else {
                EnsemblerTLS.logger.error("sendDataToAllFollowers: tlsChannel is nil for appID: \(appID, privacy: .public)")
                completion(.failure(ClientError.ClientError(message: "sendDataToAllFollowers Error: tlsChannel is nil for appID: \(appID)")))
                return
            }
            let activeRequests = self.activeDataRequests
            activeRequests.enter()
            channel.sendDataToAllFollowers(
                appID: appID,
                data: data,
                timeout: timeout,
                completion: { result in
                    activeRequests.leave()
                    completion(result)
                }
            )
		}
    }
}

// Router delegates
extension EnsemblerTLS: RouterDelegate {
    
    func ensembleFailed(failMsg: String) {
        self.ensembleFailed(failMsg: failMsg, helpMsg: nil)
    }
    
	func ensembleReady() {
		do {
			EnsemblerTLS.logger.info(
				"""
				EnsemblerTLS.ensembleReady(): \
				Locking the mesh.
				"""
			)

			try self.backend?.lock()

			if self.isLeader == true {
				// We handle ourselves like any other node in the group
				try self.handleActivationComplete(udid: self.UDID)
				return
			}

			self.setStatus(.activated)
			sendfollowerActivationCompleteToLeader()
		} catch {
            EnsemblerTLS.logger.error("Failed to lock ensemble, failing, error = \(error, privacy: .public).")
            self.ensembleFailed(failMsg: "Failed to lock ensemble, failing, error = \(error).")
			return
		}
	}

	// called when there is any failure during activation and readying process.
    func ensembleFailed(failMsg: String, helpMsg: String? = nil) {
		let status = self.status
        
		guard !status.inFailedState() else {
			EnsemblerTLS.logger.info(
				"""
				EnsemblerTLS.ensembleFailed(): \
				We already acknowledged failure so no need to do it again.
				"""
			)
			return
		}
		
		self.goToFailed(failMsg: failMsg, helpMsg: helpMsg)
		self.broadcastOurFailure()
		do {
			// Attempt a deactivation
			try self.backend?.deactivate()
		} catch {
			EnsemblerTLS.logger.warning(
				"""
				EnsemblerTLS.ensembleFailed(): \
				We somehow failed at failure itself and failed to deactivate backend \
				\(String(reportableError: error), privacy: .public) (\(error, privacy: .public))
				"""
			)
		}
		self.dumpEnsembleDebugMap()
	}
}
