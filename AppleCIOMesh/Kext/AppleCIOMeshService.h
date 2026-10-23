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

// Copyright 2021, Apple Inc. All rights reserved.

#pragma once

#include "AppleCIOMeshControlCommand.h"
#include <IOKit/IOCommandPool.h>
#include <IOKit/IOLocks.h>
#include <IOKit/IOService.h>
#include <IOKit/IOWorkLoop.h>
#include <IOKit/platform/AppleARMIODevice.h>
#include <IOKit/thunderbolt/AppleThunderboltGenericHAL.h>
#include <IOKit/thunderbolt/IOThunderboltController.h>
#include <IOKit/thunderbolt/IOThunderboltPath.h>
#include <IOKit/thunderbolt/IOThunderboltProtocolListener.h>
#include <libkern/c++/OSBoundedArray.h>
#include <os/atomic.h>

#include "AppleCIOMeshHardwarePlatform.h"
#include "AppleCIOMeshPtrQueue.h"
#include "AppleCIOMeshUserClientInterface.h"
#include "Common/Config.h"

namespace MUCI  = AppleCIOMeshUserClientInterface;
namespace MCUCI = AppleCIOMeshConfigUserClientInterface;

class AppleCIOMeshAssignment;
class AppleCIOMeshChannel;
class AppleCIOMeshCommandRouter;
class AppleCIOMeshConfigUserClient;
class AppleCIOMeshForwarder;
class AppleCIOMeshLink;
class AppleCIOMeshSharedMemory;
class AppleCIOMeshReceiveCommand;
class AppleCIOMeshReceiveControlCommand;
class AppleCIOMeshTransmitCommand;
class AppleCIOMeshTransmitControlCommand;
class AppleCIOMeshThunderboltCommands;
class AppleCIOMeshUserClient;
struct ForwardAction;
struct ForwardActionChainElement;
struct NodeAssignmentMap;

typedef struct {
	uint64_t key[4];
} __attribute__((packed)) AppleCIOMeshCryptoKey;

const uint64_t kNsPerSecond      = 1000000000;
const uint64_t kNsPerMillisecond = 1000000;
const uint64_t kNsPerMicrosecond = 1000;
const size_t kUserKeySize        = sizeof(AppleCIOMeshCryptoKey);

class AppleCIOMeshService : public IOService
{
	OSDeclareDefaultStructors(AppleCIOMeshService);
	using super = IOService;

  public:
	IOService * probe(IOService *, SInt32 * score) APPLE_KEXT_OVERRIDE final;
	bool start(IOService *) APPLE_KEXT_OVERRIDE final;
	void stop(IOService *) APPLE_KEXT_OVERRIDE final;
	void free() APPLE_KEXT_OVERRIDE final;

	IOWorkLoop * getWorkLoop() const APPLE_KEXT_OVERRIDE final;
	IOReturn newUserClient(task_t owningTask,
	                       void * securityID,
	                       UInt32 type,
	                       OSDictionary * properties,
	                       LIBKERN_RETURNS_RETAINED IOUserClient ** handler) APPLE_KEXT_OVERRIDE final;

	IOReturn registerLink(AppleCIOMeshLink * link, unsigned acioIdx);
	IOReturn unregisterLink(unsigned acioIdx);
	bool registerUserClient(AppleCIOMeshUserClient * uc);
	void unregisterUserClient(AppleCIOMeshUserClient * uc);
	AppleCIOMeshSharedMemory * getSharedMemory(MUCI::BufferId bufferId);
	AppleCIOMeshSharedMemory * getRetainSharedMemory(MUCI::BufferId bufferId);
	bool registerConfigUserClient(AppleCIOMeshConfigUserClient * uc);
	void unregisterConfigUserClient(AppleCIOMeshConfigUserClient * uc);
	uint32_t getLinksPerChannel();
	uint32_t getSignpostSequenceNumber();
	MCUCI::NodeId getExtendedNodeId();
	MCUCI::NodeId getLocalNodeId();
	MCUCI::EnsembleSize getEnsembleSize();
	MCUCI::PartitionIdx getPartitionIndex();
	AppleCIOMeshForwarder * getForwarder();
	uint8_t getConnectedLinkCount();
	uint8_t getConnectedChannelCount();
	bool isActive();

	bool acioDisabled(uint8_t acio);
	void populateHardwareConfig();
	void populatePartnerMap();
	void dumpCommandeerState();

	// TBT Workloop Context Methods - TBT Actions
  public:
	void controlSent(void * param, IOReturn status, IOThunderboltTransmitCommand * command);
	void controlReceived(void * param, IOReturn status, IOThunderboltReceiveCommand * command);
	void dataSent(void * param, IOReturn status, IOThunderboltTransmitCommand * command);
	void dataReceived(void * param, IOReturn status, IOThunderboltReceiveCommand * command);

	// Completion commands -- these are use for flow control when forwarding
	void commandSentFlowControl(void * param, IOReturn status, IOThunderboltTransmitCommand * command);
	void commandReceivedFlowControl(void * param, IOReturn status, IOThunderboltReceiveCommand * command);

	// UserClient notification methods
  public:
	void notifySendComplete(MUCI::DataChunk & dataChunk);
	void notifyDataAvailable(MUCI::DataChunk & dataChunk);

	void notifyMeshChannelChange(AppleCIOMeshChannel * channel);
	void notifyConnectionChange(const MCUCI::NodeConnectionInfo & connection, bool connected, bool TX);

	// UserClient Methods
  public:
	IOReturn allocateSharedMemory(const MUCI::SharedMemory * memory, task_t owningTask, AppleCIOMeshUserClient * uc);
	IOReturn deallocateSharedMemory(const MUCI::SharedMemoryRef * memory, task_t owningTask, AppleCIOMeshUserClient * uc);
	IOReturn assignMemoryChunk(const MUCI::AssignChunks * assignment);
	IOReturn printBufferState(const MUCI::BufferId * bufferId);
	IOReturn setForwardChain(const MUCI::ForwardChain * forwardChain, MUCI::ForwardChainId * chainId);
	IOReturn overrideRuntimePrepare(const MUCI::BufferId * bufferId);
	IOReturn startNewGeneration();

	// These methods do not have a gated equivalent, multiple clients should
	// not access them simultaneously.
	IOReturn sendAssignedData(
	    AppleCIOMeshSharedMemory * sharedMem, const int64_t offset, const uint8_t linkIterMask, char * tag, size_t tagSz);
	IOReturn prepareCommand(AppleCIOMeshSharedMemory * sharedMem, const int64_t offset);
	void markForwardIncomplete(AppleCIOMeshSharedMemory * sharedMem, const int64_t offset);

	// This does not have a gated equivalent, but it is safe to call multiple times.
	// This is a generic wait that waits for the full assignment at the offset.
	IOReturn waitData(AppleCIOMeshSharedMemory * sharedMem, const int64_t offset, bool * interrupted, char * tag, size_t tagSz);

	IOReturn startForwardChain(const MUCI::ForwardChainId forwardChainId, const uint32_t elements);
	IOReturn stopForwardChain();
	void forwarderFinishedClearingMemory();

	IOReturn setMaxWaitTime(uint64_t maxWaitTime); // in mach_absolute_time() units

	void commandeerSend(AppleCIOMeshSharedMemory * sm, int64_t offset, AppleCIOMeshUserClient * uc, char * tag, size_t tagSz);
	void commandeerDripPrepare(AppleCIOMeshSharedMemory * sm, int64_t offset, AppleCIOMeshSharedMemory * sendingSM);
	void commandeerBulkPrepare(AppleCIOMeshAssignment * assignment, uint8_t linkIdx);
	void commandeerPendingPrepare(NodeAssignmentMap * nodeMap, uint8_t linkIdx);
	void commandeerPrepareForwardElement(ForwardActionChainElement * chainElement);
	// Returns if the commandeer is able to do this or not.
	bool commandeerForwardHelp(ForwardAction * action);
	void clearCommandeerForwardHelp(ForwardAction * action);

	// ConfigUserClient Methods
  public:
	IOReturn setExtendedNodeId(const MCUCI::NodeId * nodeId);
	IOReturn setEnsembleSize(const MCUCI::EnsembleSize * ensembleSize);
	IOReturn setChassisId(const MCUCI::ChassisId * chassisId);
	IOReturn addPeerHostname(const MCUCI::PeerNode * peerNode);
	IOReturn getPeerHostnames(MCUCI::PeerHostnames * outPeerHostnames);
	IOReturn activateMesh();
	IOReturn deactivateMesh();
	IOReturn lockCIO();
	bool isCIOLocked();
	IOReturn disconnectChannel(const MCUCI::MeshChannelIdx * channelIdx);
	IOReturn establishTXConnection(const MCUCI::NodeConnectionInfo * connection);
	IOReturn sendControlMessage(const MCUCI::MeshMessage * message);
	IOReturn getConnectedNodes(MCUCI::ConnectedNodes * connectedNodes);
	IOReturn getCIOConnectionState(MCUCI::CIOConnections * cioConnections);
	bool isShuttingDown(void);
	IOReturn cryptoKeyReset();
	IOReturn cryptoKeyMarkUsed();
	bool cryptoKeyCheckUsed();
	IOReturn getUserKey(AppleCIOMeshCryptoKey * key);
	void setUserKey(AppleCIOMeshCryptoKey * key);
	void getCryptoFlags(MCUCI::CryptoFlags * flags);
	void setCryptoFlags(MCUCI::CryptoFlags flags);
	IOReturn getBuffersAllocatedCounter(uint64_t * buffersAllocated);
	bool canActivate(const MCUCI::MeshNodeCount * nodeCount);

  private:
	IOReturn _allocateSharedMemoryUCGated(void * sharedMemoryArg, void * taskArg, void * ucArg);
	IOReturn _deallocateSharedMemoryUCGated(void * sharedMemoryRefArg, void * taskArg, void * ucArg);
	IOReturn _assignMemoryChunkUCGated(void * assignmentArg);
	IOReturn _printBufferStateUCGated(void * bufferIdArg);
	IOReturn _overrideRuntimePrepareUCGated(void * bufferIdArg);
	IOReturn _setForwardChainUCGated(void * forwardChainArg, void * forwardChainIdArg);
	IOReturn _setMaxWaitTimeUCGated(void * maxWaitTimeArg);
	IOReturn _startNewGenerationUCGated();
	void _checkGenerationReady();

	IOReturn _setNodeIdUCGated(void * nodeIdArg);
	IOReturn _setEnsembleSizeUCGated(void * ensembleSizeArg);
	IOReturn _setChassisIdUCGated(void * chassisIdArg);
	IOReturn _addPeerHostnameUCGated(void * hostnamesArg);
	IOReturn _getPeerHostnamesUCGated(void * hostnamesArg);
	IOReturn _activateMeshUCGated();
	IOReturn _deactivateMeshUCGated();
	IOReturn _lockCIOUCGated();
	IOReturn _disconnectChannelUCGated(void * channelIdxArg);
	IOReturn _establishTXConnectionUCGated(void * connectionArg);
	IOReturn _sendControlMessageUCGated(void * messageArg);
	IOReturn _getConnectedNodesUCGated(void * connectedNodesArg);
	IOReturn _getCIOConnectionStateUCGated(void * cioConnectionsArg);
	IOReturn _cryptoKeyResetUCGated();
	IOReturn _cryptoKeyMarkUsedUCGated();
	IOReturn _getUserKeyGated(AppleCIOMeshCryptoKey * key);
	IOReturn _setUserKeyGated(AppleCIOMeshCryptoKey * key);
	IOReturn _getCryptoFlagsGated(MCUCI::CryptoFlags * flags);
	IOReturn _setCryptoFlagsGated(MCUCI::CryptoFlags * flags);
	IOReturn _getBuffersAllocatedCounterUCGated(uint64_t * buffersAllocated);
	IOReturn _assignInputMemory(const MUCI::AssignChunks * assignment);
	IOReturn _assignOutputMemory(const MUCI::AssignChunks * assignment);

	// Prepares 1 offset at at time to allow more work to go if possible.
	// Returns kIOReturnSuccess when the buffer has been fully prepared.
	// Returns kIOReturnStillOpen when more commands have to be prepared.
	// AssignmentIdx, OffsetIdx, LinkIdx are in/out variables.
	IOReturn _dripPrepareBuffer(AppleCIOMeshSharedMemory * sm, int64_t * assignmentIdx, int64_t * offsetIdx, int64_t * linkIdx);

	static IOReturn meshPowerStateChangeCallback(
	    void * target, void * refCon, UInt32 messageType, IOService * service, void * messageArgument, vm_size_t argSize);

	// Other
  private:
	IOThunderboltLocalNode * _getThunderboltLocalNode(OSString * acioName);
	void _requestNodeIdentification(IOTimerEventSource * timer);
	IOReturn _assignLinkToPartnerNodeGated(AppleCIOMeshLink * link);
	IOReturn _meshControlCommandHandler(IOInterruptEventSource * sender, int count);
	void _addForwardingCommand(AppleCIOMeshTransmitCommand * transmitCommand,
	                           AppleCIOMeshReceiveCommand * receiveCommand,
	                           MCUCI::NodeId sourceNode);
	IOService * _resolvePHandle(const char * key, const char * className);

	int _freeSharedMemoryUCGated(int64_t bufferId);
	IOReturn _startThreadsUCGated();
	IOReturn _stopThreadsUCGated();
	bool _meshLinksHealthy() const;

	// Control Command Handlers
	void nodeIdRequestHandlerGated(AppleCIOMeshControlPath * path);
	void nodeIdResponseHandlerGated(AppleCIOMeshControlPath * path, NodeIdentificationResponseCommand * nodeIdResponse);
	void linkIdHandlerGated(AppleCIOMeshControlPath * path, LinkIdentificationCommand * linkId);
	void channelLinkSwapHandlerGated(AppleCIOMeshControlPath * path);
	void channelReadyHandlerGated(AppleCIOMeshControlPath * path, ChannelReadyCommand * ready);
	void pingHandlerGated(AppleCIOMeshControlPath * path);
	void pongHandlerGated(AppleCIOMeshControlPath * path);
	void txAssignmentHandlerGated(AppleCIOMeshControlPath * controlPath, TxAssignmentNotificationCommand * txAssignment);
	void txForwardNotificationHandlerGated(AppleCIOMeshControlPath * controlPath, TxForwardNotificationCommand * txForward);
	void controlMessageHandlerGated(AppleCIOMeshControlPath * path, MeshControlMessage * message);
	void newGenerationHandlerGated(AppleCIOMeshControlPath * path, StartGenerationCommand * generation);

	// Helper functions
	bool getCurrentSlot(uint8_t & slot);

  private:
	bool _active;
	bool _hasBeenDeactivated;
	bool _shuttingDown;

	OSArray * _tbtControllers;
	OSArray * _meshProtocolListeners;
	OSArray * _acioNames;
	uint8_t _acioCount;

	OSBoundedArray<bool, kMaxMeshLinkCount> _meshLinksLocked;
	OSBoundedArray<AppleCIOMeshLink *, kMaxMeshLinkCount> _meshLinks;
	OSBoundedArray<AppleCIOMeshChannel *, kMaxMeshChannelCount> _meshChannels;
	uint8_t _channelCount;

	uint64_t _maxWaitTime; // in mach_absolute_time() units
	OSArray * _userClients;
	OSArray * _configUserClients;
	IOLock * _ucLock;
	IOLock * _linkLock;
	bool _acioLock;

	IOWorkLoop * _workloop;

	OSArray * _sharedMemoryRegions;

	MCUCI::NodeId _nodeId;
	MCUCI::PartitionIdx _partitionIdx;
	MCUCI::EnsembleSize _ensembleSize;
	MCUCI::ChassisId _chassisId;
	MCUCI::PeerHostnames _peerHostnames;
	uint32_t _linksPerChannel;
	uint32_t _signpostSequenceNumber;

	AppleCIOMeshPtrQueue * _commandQueue;
	IOInterruptEventSource * _controlCommandEventSource;

	AppleCIOMeshCommandRouter * _commandRouter;
	MeshControlMessage _dummyTxControlMessage;
	MCUCI::MeshMessage _dummyRxMeshMessage;

	AppleCIOMeshForwarder * _forwarder;
	IOLock * _forwarderLock; // taken when a UserClient registers and released when it unregisters
	_Atomic(bool) _forwarderFinishedRelease;

	void _commandeerLoopPendingCheck(NodeAssignmentMap * nodeMap, uint8_t linkIdx);
	IOReturn _commandeerLoop(IOInterruptEventSource * sender, int count);
	IOWorkLoop * _commandeerWorkloop;
	IOInterruptEventSource * _commandeerEventSource;
	_Atomic(bool) _commandeerActivated;
	_Atomic(bool) _commandeerActive;
	_Atomic(bool) _commandeerSendData;
	_Atomic(bool) _commandeerPrepareData;

	// Commandeer User client for notification on Sends
	AppleCIOMeshUserClient * _commandeerSendUserClient;
	// Commandeer Send
	AppleCIOMeshSharedMemory * _commandeerSMSend;
	int64_t _commandeerSMSendOffset;
	uint64_t _commanderSMSendStart;
	char _commandeerSendTag[kTagSize];
	size_t _commandeerSendTagSz;
	uint64_t _commanderSMSendCounter;
	// Commandeer Drip Prepare
	AppleCIOMeshSharedMemory * _commandeerSMPrepare;
	AppleCIOMeshSharedMemory * _commandeerPreparePreviousSM;
	bool _commandeerPreparePreviousComplete;
	int64_t _commandeerSMPrepareOffset;
	int64_t _commandeerPrepareDripAssignmentIdx;
	int64_t _commandeerPrepareDripOffsetIdx;
	int64_t _commandeerPrepareDripLinkIdx;
	// Commandeer Forward
	_Atomic(uintptr_t) _commandeerForwardAction;
	// Commandeer bulk prepare queue -- this should really be 1 queue
	// but assignment groups up both link unfortunately.
	AppleCIOMeshPtrQueue * _commandeerPrepareAssignmentQueue0;
	AppleCIOMeshPtrQueue * _commandeerPendingPrepareQueue0;
	AppleCIOMeshPtrQueue * _commandeerPrepareAssignmentQueue1;
	AppleCIOMeshPtrQueue * _commandeerPendingPrepareQueue1;
	AppleCIOMeshPtrQueue * _commandeerForwardPrepareQueue;

	AppleCIOMeshHardwareConfig _hardwareConfig;
	uint8_t _meshConfig;
	AppleCIOMeshPartnerMap _partnerMap;

	int32_t _numNodesMesh;
	int32_t _receivedGeneration[kMaxCIOMeshNodes];
	bool _newClient[kMaxCIOMeshNodes];
	uint32_t _expectedGeneration;
	bool _dataPathRestartRequired;

	uint64_t _maxBuffersPerKey;
	uint64_t _buffersAllocated;

	uint64_t _maxTimePerKey;
	uint64_t _cryptoKeyTimeLimit; // in mach_absolute_time() units
	atomic_bool _cryptoKeyUsed;
	AppleCIOMeshCryptoKey _userKey;
	MCUCI::CryptoFlags _userCryptoFlags;

	bool _checkForXDomainLinkService(IORegistryEntry * reg);
	bool _canActivate2(OSCollectionIterator * devices);
	bool _canActivate4(OSCollectionIterator * devices);
	bool _canActivate8(OSCollectionIterator * devices);
};
