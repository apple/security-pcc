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

#include "Util/SymbolWorkaround.h"

#include <IOKit/IOMemoryDescriptor.h>
#include <IOKit/thunderbolt/IOThunderboltReceiveCommand.h>
#include <IOKit/thunderbolt/IOThunderboltTransmitCommand.h>
#include <libkern/c++/OSBoundedArray.h>
#include <libkern/c++/OSBoundedArrayRef.h>
#include <libkern/c++/OSObject.h>
#include <os/atomic.h>

#include "AppleCIOMeshUserClientInterface.h"
#include "Common/Config.h"

namespace MUCI  = AppleCIOMeshUserClientInterface;
namespace MCUCI = AppleCIOMeshConfigUserClientInterface;

class AppleCIOMeshForwarder;
class AppleCIOMeshLink;
class AppleCIOMeshService;
class AppleCIOMeshSharedMemory;
class AppleCIOMeshThunderboltCommands;
class AppleCIOMeshThunderboltCommandGroups;
struct ForwardAction;

// MARK: - Base Commands

class AppleCIOMeshReceiveCommand final : public OSObject
{
	OSDeclareDefaultStructors(AppleCIOMeshReceiveCommand);
	using super = OSObject;

  public:
	static AppleCIOMeshReceiveCommand * allocate(AppleCIOMeshThunderboltCommands * provider,
	                                             AppleCIOMeshLink * link,
	                                             AppleCIOMeshService * service,
	                                             IOMemoryDescriptor * iomd,
	                                             const MUCI::DataChunk & dataChunk);
	bool initialize(AppleCIOMeshThunderboltCommands * provider,
	                AppleCIOMeshLink * link,
	                AppleCIOMeshService * service,
	                IOMemoryDescriptor * iomd,
	                const MUCI::DataChunk & datachunk);
	virtual void free() APPLE_KEXT_OVERRIDE;

	IOReturn createTBTCommands();
	OSBoundedArrayRef<IOThunderboltReceiveCommand *> getCommands();
	uint32_t getCommandsLength();

	const MUCI::DataChunk & getDataChunk();
	AppleCIOMeshLink * getMeshLink();
	void setCompletion(uint32_t commandIdx, void * target, IOThunderboltReceiveCommand::Action action);
	void setAssignedChunk(const MUCI::AssignChunks * assignment);
	void setPrepared(bool prepared);
	bool getPrepared();
	void getTrailerData(void * data, uint32_t dataLen);

	const MUCI::AssignChunks & getAssignedChunk();
	AppleCIOMeshThunderboltCommands * getProvider();

	int updateFXReceivedIdx();
	int getFXReceivedIdx();

  private:
	AppleCIOMeshLink * _link;
	MUCI::DataChunk _dataChunk;
	AppleCIOMeshService * _service;
	OSBoundedArray<IOThunderboltReceiveCommand *, kMaxTBTCommandCount + 1> _commands;
	uint32_t _commandsLength;
	MUCI::AssignChunks _assignedChunk;
	AppleCIOMeshThunderboltCommands * _provider;
	IOMemoryDescriptor * _iomd;
	OSBoundedArray<IOMemoryDescriptor *, kMaxTBTCommandCount + 1> _commandsIOMD;
	_Atomic(bool) _prepared;

	_Atomic(int) _fxReceivedIdx;
};

class AppleCIOMeshTransmitCommand final : public OSObject
{
	OSDeclareDefaultStructors(AppleCIOMeshTransmitCommand);
	using super = OSObject;

  public:
	static AppleCIOMeshTransmitCommand * allocate(AppleCIOMeshThunderboltCommands * provider,
	                                              AppleCIOMeshLink * link,
	                                              AppleCIOMeshService * service,
	                                              IOMemoryDescriptor * iomd,
	                                              const MUCI::DataChunk & dataChunk);
	bool initialize(AppleCIOMeshThunderboltCommands * provider,
	                AppleCIOMeshLink * link,
	                AppleCIOMeshService * service,
	                IOMemoryDescriptor * iomd,
	                const MUCI::DataChunk & datachunk);
	virtual void free() APPLE_KEXT_OVERRIDE;

	IOReturn createTBTCommands();
	OSBoundedArrayRef<IOThunderboltTransmitCommand *> getCommands();
	uint32_t getCommandsLength();
	uint32_t getDescriptorsForCommand(uint8_t idx);

	const MUCI::DataChunk & getDataChunk();
	AppleCIOMeshLink * getMeshLink();
	void setCompletion(uint32_t commandIdx, void * target, IOThunderboltTransmitCommand::Action action);
	void setAssignedChunk(const MUCI::AssignChunks * assignment);
	const MUCI::AssignChunks & getAssignedChunk();
	AppleCIOMeshThunderboltCommands * getProvider();

	// Updates the index to the next one and returns the previous value.
	int updateFXCompletedIdx();
	int getFXCompletedIdx();

	// dataOut is useful to know when data has been sent out on this link to hold
	// preparing additional buffers until data has been sent out on on all links.
	void dataOut();
	// CompletionIn is used to indicate data has been sent from the transmitter's
	// view.
	void completionIn();
	// Waiting for completion is useful to know we do not have to continue
	// checking TX completion for this command's link while waiting for the data
	// to complete on all links before sending back send complete.
	bool waitingForCompletion();

	ForwardAction * getForwardAction();
	void setForwardAction(ForwardAction * forwardAction);
	void dripForwardComplete();

	void setTrailerData(const void * data, const uint32_t dataLen);

  private:
	AppleCIOMeshLink * _link;
	MUCI::DataChunk _dataChunk;
	AppleCIOMeshService * _service;
	OSBoundedArray<IOThunderboltTransmitCommand *, kMaxTBTCommandCount + 1> _commands;
	uint32_t _commandsLength;
	MUCI::AssignChunks _assignedChunk;
	AppleCIOMeshThunderboltCommands * _provider;
	IOMemoryDescriptor * _iomd;
	OSBoundedArray<IOMemoryDescriptor *, kMaxTBTCommandCount + 1> _commandsIOMD;

	ForwardAction * _forwardAction;
	uint32_t _descriptorsPerCommand[kMaxTBTCommandCount + 1];

	bool _sent;
	_Atomic(int) _fxCompletedIdx;
};

// MARK: - Commands+Groups

/// Thunderbolt commands associated with an offset.
class AppleCIOMeshThunderboltCommands final : public OSObject
{
	OSDeclareDefaultStructors(AppleCIOMeshThunderboltCommands);
	using super = OSObject;

  public:
	static AppleCIOMeshThunderboltCommands * allocate(AppleCIOMeshThunderboltCommandGroups * provider,
	                                                  AppleCIOMeshService * service,
	                                                  OSBoundedArrayRef<AppleCIOMeshLink *> meshLinks,
	                                                  IOMemoryDescriptor * iomd,
	                                                  const MUCI::DataChunk & dataChunk,
	                                                  char * trailerMem,
	                                                  uint32_t trailerSize,
	                                                  uint32_t trailerAllocatedSize);

	bool initialize(AppleCIOMeshThunderboltCommandGroups * provider,
	                AppleCIOMeshService * service,
	                OSBoundedArrayRef<AppleCIOMeshLink *> meshLinks,
	                IOMemoryDescriptor * iomd,
	                const MUCI::DataChunk & dataChunk,
	                char * trailerMem,
	                uint32_t trailerSize,
	                uint32_t trailerAllocatedSize);
	virtual void free() APPLE_KEXT_OVERRIDE;

	OSArray * getReceiveCommands();
	OSArray * getTransmitCommands();
	void setOutgoingCommandCountAndMask(int outgoing, uint32_t mask);
	void holdCommandForOutput();

	void setAssignedInputLink(int64_t assignedInputMeshLink);
	int64_t getAssignedInputLink();

	void setAssignedForOutput(bool assigned);
	bool getAssignedForOutput();

	void setAccessMode(MUCI::AccessMode mode);
	MUCI::AccessMode getAccessMode();

	// Decrements outgoing command and returns TRUE if it is time to notify
	bool decrementOutgoingCommandForMask(uint32_t linkMask);

	AppleCIOMeshThunderboltCommandGroups * getProvider();

	void notifyRxReady();
	bool checkRxReady();
	// This acts the same as checkRxReady but if you want to only check a specific
	// RX path/ring instead of all paths/rings.
	bool checkRxReadyForNode(MCUCI::NodeId node);
	bool isRxReady();
	void markRxUnready();

	void addForwardNotifyIdx(int32_t forwardIdx, AppleCIOMeshForwarder * forwarder);
	void notifyForwardComplete();

	void notifyTxReady();
	// Was TX dispatched/sent + also calls link->checkCompletion
	bool checkTxReady();
	// Was TX dispatched/sent
	bool isTxReady();
	void markTxUnready();

	bool inForwardChain();
	bool isTxForwarding();
	void markTxForwardIncomplete();
	bool isTxForwardComplete();

	bool finishedTxDispatch();
	void txDispatched();

	void notifyRXFlowControl(AppleCIOMeshReceiveCommand * command, AppleCIOMeshForwarder * forwarder);
	void notifyTXFlowControl(AppleCIOMeshTransmitCommand * command, AppleCIOMeshForwarder * forwarder);

	char * getTrailer(void);
	uint32_t getTrailerLen(void);

  private:
	OSArray * _receiveTBTCommands;
	OSArray * _transmitTBTCommands;

	MUCI::DataChunk _dataChunk;

	IOMemoryDescriptor * _iomd;
	char * _trailerMem;
	uint32_t _trailerSize;
	uint32_t _trailerAllocatedSize;
	AppleCIOMeshThunderboltCommandGroups * _provider;

	_Atomic(uint8_t) _pendingCompletions;
	_Atomic(uint32_t) _pendingCompletionsMask;
	_Atomic(uint8_t) _dispatchRemaining;
	_Atomic(bool) _rxReady;
	_Atomic(bool) _txReady;
	_Atomic(bool) _forwardComplete;

	int64_t _assignedInputMeshLink;
	bool _assignedForOutput;
	MUCI::AccessMode _accessMode;

	int32_t _forwardNotifyIdx[kForwardNodeCount];
	uint8_t _forwardCount;
	_Atomic(uint8_t) _forwardCompleteCount;
};

class AppleCIOMeshThunderboltCommandGroups final : public OSObject
{
	OSDeclareDefaultStructors(AppleCIOMeshThunderboltCommandGroups);
	using super = OSObject;

  public:
	static AppleCIOMeshThunderboltCommandGroups * allocate(AppleCIOMeshSharedMemory * provider,
	                                                       AppleCIOMeshService * service,
	                                                       OSBoundedArrayRef<AppleCIOMeshLink *> meshLinks,
	                                                       const MUCI::SharedMemory & sharedMemory,
	                                                       task_t owningTask);

	bool initialize(AppleCIOMeshSharedMemory * provider,
	                AppleCIOMeshService * service,
	                OSBoundedArrayRef<AppleCIOMeshLink *> meshLinks,
	                const MUCI::SharedMemory & sharedMemory,
	                task_t owningTask);
	bool allocateCommands(int64_t offset, uint64_t memoryOffset);
	virtual void free() APPLE_KEXT_OVERRIDE;

	AppleCIOMeshReceiveCommand * getReceiveCommand(uint8_t linkIdx, int64_t offset);
	AppleCIOMeshTransmitCommand * getTransmitCommand(uint8_t linkIdx, int64_t offset);
	AppleCIOMeshThunderboltCommands * getCommands(int64_t offset);
	IOMemoryDescriptor * getMD();
	AppleCIOMeshSharedMemory * getProvider();
	AppleCIOMeshLink * getMeshLink(uint8_t linkIndex);
	task_t getOwningTask();

  private:
	inline int64_t _getOffsetIdx(int64_t offset);
	AppleCIOMeshSharedMemory * _provider;
	MUCI::SharedMemory _sharedMemory;
	task_t _owningTask;
	AppleCIOMeshService * _service;

	IOMemoryDescriptor * _iomd;
	OSArray * _meshTBTCommands;
	OSBoundedArrayRef<AppleCIOMeshLink *> _meshLinks;
};
