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

#include <IOKit/IOBufferMemoryDescriptor.h>
#include <IOKit/thunderbolt/IOThunderboltReceiveCommand.h>
#include <IOKit/thunderbolt/IOThunderboltTransmitCommand.h>
#include <libkern/c++/OSBoundedArray.h>
#include <libkern/c++/OSBoundedArrayRef.h>
#include <libkern/c++/OSObject.h>

#include "AppleCIOMeshSharedMemoryHelpers.h"
#include "AppleCIOMeshUserClientInterface.h"
#include "Common/Config.h"
#include "Signpost.h"

namespace MUCI  = AppleCIOMeshUserClientInterface;
namespace MCUCI = AppleCIOMeshConfigUserClientInterface;

class AppleCIOForwardChain;
class AppleCIOMeshForwarder;
class AppleCIOMeshLink;
class AppleCIOMeshLinkDispatcher;
class AppleCIOMeshReceiveCommand;
class AppleCIOMeshService;
class AppleCIOMeshSharedMemory;
class AppleCIOMeshTransmitCommand;
class AppleCIOMeshThunderboltCommands;
class AppleCIOMeshThunderboltCommandGroups;
class AppleCIOMeshUserClient;

class AppleCIOMeshSharedMemory final : public OSObject
{
	OSDeclareDefaultStructors(AppleCIOMeshSharedMemory);
	using super = OSObject;

	friend class AppleCIOMeshPreparedCommand;
	friend class AppleCIOMeshAssignment;

  public:
	static AppleCIOMeshSharedMemory * allocate(AppleCIOMeshService * service,
	                                           const MUCI::SharedMemory * config,
	                                           OSBoundedArrayRef<AppleCIOMeshLink *> meshLinks,
	                                           task_t owningTask,
	                                           AppleCIOMeshUserClient * userClient);

	bool initialize(AppleCIOMeshService * service,
	                const MUCI::SharedMemory * config,
	                OSBoundedArrayRef<AppleCIOMeshLink *> meshLinks,
	                task_t owningTask,
	                AppleCIOMeshUserClient * userClient);
	bool equal(AppleCIOMeshSharedMemory * otherMemory);
	virtual void free() APPLE_KEXT_OVERRIDE;

	MUCI::BufferId getId();
	IOMemoryDescriptor * getMD();
	int64_t getChunkSize();
	int64_t getSize();
	int64_t getBufferId();
	bool getForwardChainRequired();
	AppleCIOMeshReceiveCommand * getReceiveCommand(uint8_t linkIdx, int64_t offset);
	AppleCIOMeshTransmitCommand * getTransmitCommand(uint8_t linkIdx, int64_t offset);
	AppleCIOMeshThunderboltCommands * getThunderboltCommands(int64_t offset);
	AppleCIOMeshUserClient * getOwningUserClient();
	MUCI::AccessMode getAccessMode(int64_t offset);
	AppleCIOMeshService * getProvider();
	void printState();
	uint8_t getCommandLength();
	int64_t getCommandSize(uint8_t idx, bool receive);
	int32_t getPreparedCount();
	uint32_t getTrailerSize();
	uint32_t getTrailerAllocatedSize();

	// Assigned Buffer related
	bool createAssignment(int64_t offset, MUCI::MeshDirection direction, MCUCI::NodeId node, int64_t size);
	bool isAssignmentInput(int64_t offset);
	void addChunkOffsetToAssignment(int64_t assignmentOffset, int64_t chunkOffset);
	void setChannelLastOffsetForLink(int64_t assignmentOffset, int64_t chunkOffset, uint8_t linkIter);
	void setChannelFirstOffsetForLink(int64_t assignmentOffset, int64_t chunkOffset, uint8_t linkIter);
	void dispatch(int64_t offset, uint8_t linkIterMask, char * tag, size_t tagSz);
	bool assignmentDispatched(int64_t offset, uint8_t linkIterMask);
	void prepareCommand(int64_t offset);
	void markCommandForwardIncomplete(int64_t offset);
	// Returns true if all assignments are prepared.
	bool dripPrepare(int64_t * assignmentIdx, int64_t * offsetIdx, int64_t * linkIdx);
	void holdCommand(int64_t offset);
	void holdOutput();
	bool checkAssignmentReady(int64_t offset, bool * interrupted);
	bool checkAssignmentForwardComplete(int64_t offset, bool * interrupted);
	bool forwardsCompleted();
	bool checkTXAssignmentReady(int64_t offset, uint8_t linkIterMask, bool * interrupted);
	bool checkAssignmentPrepared(int64_t offset);
	bool readAssignmentTagForLink(int64_t offset, uint8_t linkIter, char * tag, size_t tagSz);
	AppleCIOMeshAssignmentMap * getReceiveAssignmentMap();
	AppleCIOMeshAssignmentMap * getOutputAssignmentMap();
	void overrideOutputAssignmentForWholeBuffer();
	AppleCIOMeshAssignment * getAssignment(int64_t offset);
	AppleCIOMeshAssignment * getAssignmentIn(int64_t offset, int8_t linkIdx);
	AppleCIOMeshAssignment * getAssignmentOut(int64_t offset);

	void setupTxCommand(AppleCIOMeshLink * link, MCUCI::NodeId node, AppleCIOMeshTransmitCommand * command);
	void interruptIOThreads();
	void clearInterruptState();
	inline bool
	hasBeenInterrupted(void)
	{
		return atomic_load(&_hasBeenInterrupted);
	}

	inline void
	addPrepared(uint32_t count)
	{
		atomic_fetch_add(&_prepareCount, count);
	}
	inline void
	removePrepared(uint32_t count)
	{
		atomic_fetch_sub(&_prepareCount, count);
	}

	void associateForwardChain(AppleCIOForwardChain * forwardChain);
	void disassociateAllForwardChain();
    void resetForwardingChains();
	bool
	requiresRuntimePrepare()
	{
		return _requiresRuntimePrepare;
	}

	void
	setRequiresRuntimePrepare(bool requiresRuntimePrepare)
	{
		_requiresRuntimePrepare = requiresRuntimePrepare;
	}

	bool
	runtimePrepareDisabled()
	{
		return atomic_load(&_runtimePrepareDisabled);
	}

	void
	setRuntimePrepareDisabled(bool disabled)
	{
		atomic_store(&_runtimePrepareDisabled, disabled);
	}

  protected:
	void _prepareRxCommand(int64_t offset);
	inline int64_t _getOffsetIdx(int64_t offset);
	void _holdRxCommand(int64_t offset);

  private:
	_Atomic(int32_t) _prepareCount;

	AppleCIOMeshService * _service;
	MUCI::SharedMemory _sharedMemory;
	uint8_t _forwardBreakdownCount;

	AppleCIOMeshThunderboltCommandGroups * _commandGroups;

	OSBoundedArrayRef<AppleCIOMeshLink *> _meshLinks;
	AppleCIOMeshUserClient * _owningUserClient;
	// Pending will be reset once all the commands are received.
	AppleCIOMeshAssignmentMap _receiveAssignments;
	// Only the offsets in the output assignment are used as fast access.
	AppleCIOMeshAssignmentMap _outputAssignments;

	OSArray * _preparedTxCommands;
	OSArray * _assignments;

	uint32_t _trailerSize;
	uint32_t _trailerAllocatedSize;

	_Atomic(bool) _hasBeenInterrupted;

	// Forward Chains this shared memory is part of.
	OSArray * _forwardChains;

	OSBoundedArray<size_t, kMaxCIOMeshNodes> _sizePerNode;
	bool _requiresRuntimePrepare;
	_Atomic(bool) _runtimePrepareDisabled;

	void _correctThunderboltCallbacks();
};
