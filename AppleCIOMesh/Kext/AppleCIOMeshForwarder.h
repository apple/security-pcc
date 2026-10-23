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

#include "Common/Config.h"
#include "Util/SymbolWorkaround.h"

#include <IOKit/IOBufferMemoryDescriptor.h>
#include <IOKit/IOInterruptEventSource.h>
#include <libkern/c++/OSBoundedArray.h>
#include <libkern/c++/OSBoundedArrayRef.h>
#include <libkern/c++/OSObject.h>

#include "AppleCIOMeshPtrQueue.h"
#include "AppleCIOMeshUserClientInterface.h"
#include "Common/Config.h"

namespace MUCI  = AppleCIOMeshUserClientInterface;
namespace MCUCI = AppleCIOMeshConfigUserClientInterface;

class AppleCIOForwardChain;
class AppleCIOMeshService;
class AppleCIOMeshSharedMemory;
class AppleCIOMeshReceiveCommand;
class AppleCIOMeshTransmitCommand;

struct ForwardAction;
struct ForwardActionChainElement;
struct ForwardActionChainGroup;

/// Note: flow here means an intermediate TBT command within the full
/// forwarding chunk.
enum class ForwardState : uint32_t {
	// First state that begins the forwarding procedure
	WaitingForRxStart = 0x1,
	// Prepare Tx buffers for transfer
	ForwardStartTxPrepare,
	// Waiting for Tx to be prepared, only used in chains
	// when the chain hasn't prepared yet for whatever reason.
	ForwardWaitingPrepare,
	// Waiting for the previous TX chunk to be complete.
	WaitingPreviousTxComplete,
	// Waiting for TX link to be free
	WaitingForTxFree,
	// Forwarder can send 1 flow out of the full block/chunk
	ForwardTxReadyToFlow,
	// Forwarder is waiting for a TX flow to complete.
	ForwardWaitingTxFlowComplete,
	// Forwarder is waiting for an intermediate RX flow before sending
	// the next TBT command. This will not be entered the first time,
	// because the first flow completing kicked off the forwarding.
	WaitingForRxFlow,
	// Forwarder is going to prepare or complete the forward action.
	ForwardPrepareOrComplete,
};

// The chain continue state when going through the forward state machine.
enum class ChainContinueState : uint8_t {
	// We do not know if the chain should continue and don't check because
	// we are not the last action to complete.
	Unknown = 0x1,
	// The chain should stop after this action has completed.
	StopChain = 0x2,
	// The chain should continue to the next element after this action has
	// completed.
	ContinueChain = 0x3,
};

// This is 1 chunk's forward (there are 3 forwards per chunk)
typedef struct ForwardAction {
	bool dummy;
	_Atomic(bool) initialized;

	MCUCI::NodeId sourceNode;
	_Atomic(bool) rxReadyForForward;
	_Atomic(bool) prepared;

	_Atomic(int8_t) rxCommandsAvailable;
	_Atomic(int8_t) txCommandsComplete;
	_Atomic(uint8_t) txCommandsSubmitted;

	uint8_t curTxCommand;

	// Retained and managed by Forwarder
	AppleCIOMeshTransmitCommand * txCommand;
	AppleCIOMeshReceiveCommand * rxCommand;

	ForwardState state;
	ForwardActionChainElement * chainElement;
	AppleCIOMeshSharedMemory * sharedMemory;

	// Forward actions that will be carried through the forward state machine.
	ForwardAction * carryPartners[kForwardNodeCount - 1];
	// If a carry is still required or has the partner been carried far enough
	// to do the rest themselves.
	_Atomic(bool) carryRequired;

	// The previous forward action before this action. This will not be
	// set for non-chain actions and for the first forward action in a
	// buffer.
	ForwardAction * previousAction;
	// The next forward action after this action. This will not be set for
	// non-chain actions and for the last forward action in a buffer.
	ForwardAction * nextAction;
	// If the previous action has been complete. This is only applicable if
	// previousAction was set.
	_Atomic(bool) previousActionComplete;
} ForwardAction;

// One element within the chain of forward actions. This collects
// multiple ForwardActions together.
// This is 1 chunk in SM terms and all the forwards for that chunk.
typedef struct ForwardActionChainElement {
	// The current element idx
	uint32_t idx;

	// The link index the forward actions belong to.
	uint8_t linkIdx;

	// If this chain element has been prepared.
	_Atomic(bool) prepared;

	// All the forward actions associated with this chain
	// This will be the same buffer/offset but different links
	ForwardAction * actions[kForwardNodeCount];

	// The number of completed forwards so far.
	_Atomic(uint8_t) completeActionCount;

	// The chain this element belongs to.
	AppleCIOForwardChain * provider;

	// The chain group this element belongs to.
	ForwardActionChainGroup * chainGroup;
} ForwardActionChainElement;

// A collection of forward action chain elements.
// This is 1 block in SM terms.
typedef struct ForwardActionChainGroup {
	// The number of elements that have been completed. This should be
	// reset to 0 when this group has been prepared.
	_Atomic(uint32_t) completeElementCount;

	// The number of elements each link needs to prepare.
	uint32_t pendingPrepareElements[kMaxMeshLinksPerChannel];

	// Elements that need to be prepared together.
	ForwardActionChainElement * elements[kMaxForwardElementActions];

	// Number of elements;
	uint8_t elementCount;

	// The next group. This group will be prepared after the current group
	// has been completed;
	ForwardActionChainGroup * nextGroup;

	// Adds a child element to thie chain group.
	void addChildElement(ForwardActionChainElement * element);

	// If it is safe to move on from this group. This is after all the elements
	// have been completed.
	bool isGroupFinished();
} ForwardActionChainGroup;

class AppleCIOForwardChain : public OSObject
{
	OSDeclareDefaultStructors(AppleCIOForwardChain);
	using super = OSObject;

  public:
	static AppleCIOForwardChain * allocate(MUCI::ForwardChainId chainId, uint8_t linksPerChannel);

	bool initialize(MUCI::ForwardChainId chainId, uint8_t linksPerChannel);
	void free() APPLE_KEXT_OVERRIDE;

	MUCI::ForwardChainId getId();
	uint32_t getElementCount();
	uint32_t getStartIndex();
	void addStartIndex(uint32_t count);
	ForwardActionChainElement * getElement(uint32_t idx);
	ForwardActionChainGroup * getGroup(uint32_t idx);
	OSBoundedArrayRef<AppleCIOForwardChain *> getPartnerChains();
	void setChainGroup(uint32_t idx, ForwardActionChainGroup * group);
	bool
	isFinished()
	{
		return atomic_load(&_elementForwardCount) == 0;
	}

	// Returns the real chain element that the actions shoud use
	ForwardActionChainElement * addToChain(ForwardActionChainElement * tmpElement);

	// "Starts" the chain by setting element count
	void startChain(int32_t elements);

	// Returns whether the chain should still continue.
	// True for continue, false for stop.
	bool continueForwarding();

	// Immediately stops the chain.
	void chainStop();

	// A partner chain is a collection of forward chains that will start and
	// stop together.
	void addPartnerChain(AppleCIOForwardChain * chain);

	// Creates and returns a chain group.
	ForwardActionChainGroup * createChainGroup();

	inline int
	getForwardCount()
	{
		return _elementForwardCount;
	}

    inline void
    reset() {
        _startIdx = 0;
    }

  private:
	MUCI::ForwardChainId _chainId;
	OSBoundedArray<ForwardActionChainElement, kMaxForwardChainElement> _forwardChain;
	uint32_t _forwardChainCount;

	OSBoundedArray<ForwardActionChainGroup, kMaxForwardChainGroup> _groups;
	OSBoundedArray<ForwardActionChainGroup *, kMaxForwardChainGroup> _groupPtrs;
	uint32_t _forwardGroupCount;

	// The nubmer of forward chain elements we have to get through
	// for this forward chain. This is NOT ChainGroup count.
	_Atomic(int32_t) _elementForwardCount;
	bool _indefinite;

	OSBoundedArray<AppleCIOForwardChain *, kMaxMeshLinksPerChannel - 1> _partnerChains;
	uint32_t _partnerCount;

	uint32_t _startIdx;
	uint8_t _linksPerChannel;
};

class AppleCIOMeshForwarder : public OSObject
{
	OSDeclareDefaultStructors(AppleCIOMeshForwarder);
	using super = OSObject;

  public:
	static AppleCIOMeshForwarder * allocate(AppleCIOMeshService * service);
	bool initialize(AppleCIOMeshService * service);
	void free() APPLE_KEXT_OVERRIDE;

	bool isStarted();
	void start();
	void stop();
	bool isStopped();

	ForwardAction * getForwardAction(uint32_t idx);

	void startForwardChain(MUCI::ForwardChainId forwardChainId, uint32_t iterations);
	void stopAllForwardChains();
	// Marks actions as disabled for shared memory. They have to be cleaned up
	// eventually with cleanupActionsForSharedMemory. Forwarding will be halted
	// after this is called until safeToForward is called. This is because paths
	// may need to be reset.
	void disableActionsForSharedMemory(AppleCIOMeshSharedMemory * memory);
	// This should be called after all the paths have restarted and the forwarder
	// can once again submit thunderbolt commands.
	void safeToForward();
	// Cleans up all disabled actions for shared memory.
	void cleanupActionsForSharedMemory(AppleCIOMeshSharedMemory * memory);

	// Creates a forwarding action from receive -> transmit for the particular
	// source.
	void addForwardingAction(AppleCIOMeshTransmitCommand * transmitCommand,
	                         AppleCIOMeshReceiveCommand * receiveCommand,
	                         MCUCI::NodeId source);

	// Marks an action as rx completed and ready to start processing
	void markActionRxComplete(uint32_t idx);

	// Marks an action as a single flow control RX has completed and
	// it is safe to send the next TX command.
	void flowRxComplete(uint32_t idx);

	// Creates a new forward chain. Returns the chain ID associated
	// with this forward chain.
	AppleCIOForwardChain * createForwardChain(MUCI::ForwardChainId * forwardChainId);

	// removes a forward chain (used when cleaning up a SharedMemory object)
	void removeForwardChain(AppleCIOForwardChain * fChain);

	// Adds a forward action to an existing forward chain
	void addToForwardChain(MUCI::ForwardChainId forwardChain, MUCI::BufferId buffer, int64_t offset, uint8_t linkIdx);

	// Groups all forward chain elements together from start offset to
	// end offset. This is so they are all prepared together in 1 shot.
	// This will go through all
	void groupChainElements(MUCI::ForwardChainId forwardChainId,
	                        MUCI::BufferId buffer,
	                        MUCI::ForwardChain * forwardChain,
	                        uint64_t bufferSize);

	// Runs through the forward state machine for a forwarding action
	// Dedicated can be used to indicate if the action must absolutely
	// be completed or if it is safe to stick the action back in the
	// waiting queue if it is blocked for whatever reason.
	// CheckAhead can be used to check if there are any pending actions
	// that can be dispatched while doing slow work.
	IOReturn forwardStateMachine(ForwardAction * action, bool dedicated = true, bool checkAhead = false);

	void prepareChainElement(ForwardActionChainElement * element);

  private:
	IOReturn _forwarderLoop(IOInterruptEventSource * sender, int count);
	void _prepareChainGroup(ForwardActionChainGroup * group);

	IOInterruptEventSource * _forwardEventSource;
	IOWorkLoop * _workloop;

	OSBoundedArray<ForwardAction, kMaxForwardAction> _forwardActions;
	uint32_t _forwardActionCount;

	AppleCIOMeshPtrQueue * _queue;
	AppleCIOMeshService * _service;

	_Atomic(bool) _active;
	_Atomic(bool) _stopped;

	OSBoundedArray<AppleCIOForwardChain *, kMaxForwardChains> _forwardChains;

	_Atomic(bool) _chainActive;
	_Atomic(bool) _safeToForward;

	ForwardAction _dummyDestroySharedMemoryAction;

	_Atomic(uintptr_t) _currentActiveChain;
};
