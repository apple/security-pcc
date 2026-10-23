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

#include "AppleCIOMeshForwarder.h"

#include "AppleCIOMeshLink.h"
#include "AppleCIOMeshService.h"
#include "AppleCIOMeshSharedMemory.h"
#include "AppleCIOMeshThunderboltCommands.h"

#define LOG_PREFIX "AppleCIOMeshForwarder"
#include "Signpost.h"
#include "Util/Error.h"
#include "Util/Log.h"
#include "Util/ReturnCode.h"

OSDefineMetaClassAndStructors(AppleCIOMeshForwarder, OSObject);
OSDefineMetaClassAndStructors(AppleCIOForwardChain, OSObject);

// MARK: - Forward Chain Group

#define MAX_LOOPS (1000000000ULL)

void
ForwardActionChainGroup::addChildElement(ForwardActionChainElement * element)
{
	// As we create the group, the group is ready to prepare
	// and is finished.
	elements[elementCount++] = element;
	atomic_store(&completeElementCount, elementCount);

	if (elementCount > kMaxForwardElementActions) {
		panic("Too many elemetns added to chain group: %d\n", elementCount);
	}
}

bool
ForwardActionChainGroup::isGroupFinished()
{
	return atomic_load(&completeElementCount) == elementCount;
}

// MARK: - Forward Chain

AppleCIOForwardChain *
AppleCIOForwardChain::allocate(MUCI::ForwardChainId chainId, uint8_t linksPerChannel)
{
	auto chain = OSTypeAlloc(AppleCIOForwardChain);
	if (chain != nullptr && !chain->initialize(chainId, linksPerChannel)) {
		OSSafeReleaseNULL(chain);
	}
	return chain;
}

bool
AppleCIOForwardChain::initialize(MUCI::ForwardChainId chainId, uint8_t linksPerChannel)
{
	_linksPerChannel   = linksPerChannel;
	_chainId           = chainId;
	_forwardChainCount = 0;
	_indefinite        = false;
	_partnerCount      = 0;
	_startIdx          = 0;

	return true;
}

void
AppleCIOForwardChain::free()
{
	super::free();
}

MUCI::ForwardChainId
AppleCIOForwardChain::getId()
{
	return _chainId;
}

uint32_t
AppleCIOForwardChain::getElementCount()
{
	return _forwardChainCount;
}

uint32_t
AppleCIOForwardChain::getStartIndex()
{
	return _startIdx;
}

void
AppleCIOForwardChain::addStartIndex(uint32_t count)
{
	// count is the total number of elements, which are grouped up by
	// the links * chunksPerBlock.

	auto elementsPerGroup = _groupPtrs[0]->elementCount;
	elementsPerGroup /= _linksPerChannel;

	_startIdx = (_startIdx + (count / elementsPerGroup)) % _forwardGroupCount;
}

ForwardActionChainElement *
AppleCIOForwardChain::getElement(uint32_t idx)
{
	return &(_forwardChain[idx]);
}

ForwardActionChainGroup *
AppleCIOForwardChain::getGroup(uint32_t idx)
{
	return _groupPtrs[idx];
}

OSBoundedArrayRef<AppleCIOForwardChain *>
AppleCIOForwardChain::getPartnerChains()
{
	return OSBoundedArrayRef<AppleCIOForwardChain *>(_partnerChains);
}

void
AppleCIOForwardChain::setChainGroup(uint32_t idx, ForwardActionChainGroup * group)
{
	_groupPtrs[idx]    = group;
	auto tmp           = idx + 1;
	_forwardGroupCount = tmp > _forwardGroupCount ? tmp : _forwardGroupCount;
}

ForwardActionChainElement *
AppleCIOForwardChain::addToChain(ForwardActionChainElement * tmpElement)
{
	auto idx = _forwardChainCount;
	if (idx + 1 == _forwardChain.length()) {
		panic("Too many elements in forward chain id:%d.", _chainId);
	}

	atomic_store(&_forwardChain[idx].completeActionCount, 0);
	_forwardChain[idx].idx        = _forwardChainCount;
	_forwardChain[idx].linkIdx    = tmpElement->linkIdx;
	_forwardChain[idx].provider   = this;
	_forwardChain[idx].chainGroup = nullptr;

	for (int i = 0; i < kForwardNodeCount; i++) {
		_forwardChain[idx].actions[i] = tmpElement->actions[i];
	}

	_forwardChainCount += 1;
	return &(_forwardChain[idx]);
}

void
AppleCIOForwardChain::startChain(int32_t elements)
{
	_indefinite = elements == 0;

	int32_t expected = 0;

	int32_t ctr = 0;
	while (!atomic_compare_exchange_strong(&_elementForwardCount, &expected, elements) && ctr++ < MAX_LOOPS) {
		expected = 0;
	}

	if (ctr >= MAX_LOOPS) {
		panic("Previous chain failed to stop in time");
	}
}

bool
AppleCIOForwardChain::continueForwarding()
{
	if (_indefinite) {
		return true;
	}

	// last forward will be when forwardCount == 1
	return atomic_fetch_sub(&_elementForwardCount, 1) > 1;
}

void
AppleCIOForwardChain::chainStop()
{
	if (atomic_load(&_elementForwardCount) == 0) {
		return;
	}

	atomic_store(&_elementForwardCount, 0);
	_indefinite = false;

	for (int i = 0; i < _partnerCount; i++) {
		_partnerChains[i]->chainStop();
	}
}

void
AppleCIOForwardChain::addPartnerChain(AppleCIOForwardChain * chain)
{
	_partnerChains[_partnerCount++] = chain;
}

ForwardActionChainGroup *
AppleCIOForwardChain::createChainGroup()
{
	auto idx = _forwardGroupCount;
	if (idx + 1 == _groups.length()) {
		panic("Too many groups in forward chain id:%d.", _chainId);
	}

	// Set the previous group's next to the new group.
	if (idx > 0) {
		_groups[idx - 1].nextGroup = &(_groups[idx]);
	}

	atomic_store(&_groups[idx].completeElementCount, 0);
	_groups[idx].elementCount = 0;

	// The next group is always [0], when a new chain group is added, this will
	// be changed to the new chain group.
	_groups[idx].nextGroup = &(_groups[0]);

	_forwardGroupCount += 1;

	// set the groups on all the partner chains
	_groupPtrs[idx] = &(_groups[idx]);
	for (int i = 0; i < _partnerCount; i++) {
		_partnerChains[i]->setChainGroup(idx, _groupPtrs[idx]);
	}

	return &(_groups[idx]);
}

// MARK: - Forwarder

AppleCIOMeshForwarder *
AppleCIOMeshForwarder::allocate(AppleCIOMeshService * service)
{
	auto forwarder = OSTypeAlloc(AppleCIOMeshForwarder);
	if (forwarder != nullptr && !forwarder->initialize(service)) {
		OSSafeReleaseNULL(forwarder);
	}
	return forwarder;
}

bool
AppleCIOMeshForwarder::initialize(AppleCIOMeshService * service)
{
	auto forwardingAction = OSMemberFunctionCast(IOInterruptEventAction, this, &AppleCIOMeshForwarder::_forwarderLoop);
	_forwardActionCount   = 0;

	_dummyDestroySharedMemoryAction.dummy = true;

	_service = service;
	atomic_store(&_active, false);
	atomic_store(&_stopped, true);
	atomic_store(&_chainActive, false);

	_workloop = IOWorkLoop::workLoop();
	GOTO_FAIL_IF_NULL(_workloop, "Failed to make forwarder workloop");

	_queue = AppleCIOMeshPtrQueue::allocate(kForwardQueueCount);
	GOTO_FAIL_IF_NULL(_queue, "Failed to make forwarder processing queue");

	_forwardEventSource = IOInterruptEventSource::interruptEventSource(this, forwardingAction);
	RETURN_IF_NULL(_forwardEventSource, false, "Failed to make forwarder event source\n");

	_workloop->addEventSource(_forwardEventSource);
	_forwardEventSource->enable();

	return true;

fail:
	if (_queue) {
		OSSafeReleaseNULL(_queue);
		_queue = nullptr;
	}

	if (_workloop) {
		OSSafeReleaseNULL(_workloop);
		_workloop = nullptr;
	}

	return false;
}

void
AppleCIOMeshForwarder::free()
{
	// make sure the forwarder has stopped before we start
	// free'ing things
	atomic_store(&_active, false);
	while (atomic_load(&_stopped) == false) {
		// spin
	}

	// Note: we will not free forward chains, they are freed automatically
	// when all shared memory in the forward chain is freed.

	for (int i = 0; i < kMaxForwardAction; i++) {
		if (atomic_load(&_forwardActions[i].initialized)) {
			OSSafeReleaseNULL(_forwardActions[i].txCommand);
			OSSafeReleaseNULL(_forwardActions[i].rxCommand);
			OSSafeReleaseNULL(_forwardActions[i].sharedMemory);
			atomic_store(&_forwardActions[i].initialized, false);
		}
	}

	if (_queue) {
		OSSafeReleaseNULL(_queue);
		_queue = nullptr;
	}

	if (_workloop) {
		OSSafeReleaseNULL(_workloop);
		_workloop = nullptr;
	}

	OSSafeReleaseNULL(_forwardEventSource);

	super::free();
}

bool
AppleCIOMeshForwarder::isStarted()
{
	return atomic_load(&_active);
}

void
AppleCIOMeshForwarder::start()
{
	atomic_store(&_safeToForward, true);
	atomic_store(&_active, true);
	_forwardEventSource->interruptOccurred(this, nullptr, 0);
}

void
AppleCIOMeshForwarder::stop()
{
	atomic_store(&_active, false);
}

bool
AppleCIOMeshForwarder::isStopped()
{
	return atomic_load(&_stopped);
}

ForwardAction *
AppleCIOMeshForwarder::getForwardAction(uint32_t idx)
{
	return &(_forwardActions[idx]);
}

void
AppleCIOMeshForwarder::addForwardingAction(AppleCIOMeshTransmitCommand * transmitCommand,
                                           AppleCIOMeshReceiveCommand * receiveCommand,
                                           MCUCI::NodeId source)
{
	int idx;
	for (idx = 0; idx < _forwardActions.length(); idx++) {
		if (_forwardActions[idx].sharedMemory == nullptr && _forwardActions[idx].txCommand == nullptr &&
		    _forwardActions[idx].initialized == false) {
			break;
		}
	}
	if (idx >= _forwardActions.length()) {
		panic("Too many forwards.");
	}

	_forwardActions[idx].dummy = false;
	atomic_store(&_forwardActions[idx].initialized, true);
	_forwardActions[idx].sourceNode = source;
	atomic_store(&_forwardActions[idx].rxReadyForForward, false);
	atomic_store(&_forwardActions[idx].prepared, false);
	atomic_store(&_forwardActions[idx].rxCommandsAvailable, 0);
	atomic_store(&_forwardActions[idx].txCommandsComplete, 0);
	atomic_store(&_forwardActions[idx].txCommandsSubmitted, 0);

	_forwardActions[idx].carryPartners[0] = nullptr;
	_forwardActions[idx].carryPartners[1] = nullptr;

	_forwardActions[idx].curTxCommand = 0;
	_forwardActions[idx].txCommand    = transmitCommand;
	_forwardActions[idx].rxCommand    = receiveCommand;
	_forwardActions[idx].state        = ForwardState::WaitingForRxStart;
	_forwardActions[idx].chainElement = nullptr;
	_forwardActions[idx].sharedMemory = transmitCommand->getProvider()->getProvider()->getProvider();

	_forwardActions[idx].txCommand->retain();
	_forwardActions[idx].rxCommand->retain();
	_forwardActions[idx].sharedMemory->retain();

	_forwardActions[idx].previousAction = nullptr;
	_forwardActions[idx].nextAction     = nullptr;
	atomic_store(&_forwardActions[idx].previousActionComplete, false);

	// Add a forward notify idx that has to be triggered by RX notify
	transmitCommand->getProvider()->addForwardNotifyIdx((int32_t)idx, this);
	// Set the transmit command's forward action
	transmitCommand->setForwardAction(&_forwardActions[idx]);

	if (idx >= _forwardActionCount) {
		_forwardActionCount = idx + 1;
	}
}

void
AppleCIOMeshForwarder::markActionRxComplete(uint32_t idx)
{
	ForwardAction * action = &_forwardActions[idx];
	atomic_store(&action->rxReadyForForward, true);
	atomic_fetch_add(&action->rxCommandsAvailable, 1);

	for (auto p = 0; p < kForwardNodeCount - 1; p++) {
		atomic_store(&action->carryPartners[p]->rxReadyForForward, true);
		atomic_fetch_add(&action->carryPartners[p]->rxCommandsAvailable, 1);
	}

	_queue->add((uintptr_t)action);
}

void
AppleCIOMeshForwarder::flowRxComplete(uint32_t idx)
{
	ForwardAction * action = &_forwardActions[idx];
	atomic_fetch_add(&action->rxCommandsAvailable, 1);

	for (auto p = 0; p < kForwardNodeCount - 1; p++) {
		atomic_fetch_add(&action->carryPartners[p]->rxCommandsAvailable, 1);
	}

	// That's it, the action is already in the queue and should be waiting for
	// RX completions to queue up their TX
}

AppleCIOForwardChain *
AppleCIOMeshForwarder::createForwardChain(MUCI::ForwardChainId * forwardChainId)
{
	int8_t assignedId = -1;

	// Find the first available one and use that id
	for (uint8_t i = 0; i < _forwardChains.length(); i++) {
		if (_forwardChains[i] == nullptr) {
			*forwardChainId = i;
			assignedId      = (int8_t)i;
			break;
		}
	}
	if (assignedId == -1) {
		for (uint8_t i = 0; i < _forwardChains.length(); i++) {
			if (_forwardChains[i] == nullptr) {
				continue;
			}
			LOG("forwardChain %d: chain %p\n", (int)i, _forwardChains[i]);
		}
	}

	if (assignedId == -1) {
		panic("Too many forward chains created");
	}

	auto newChain = AppleCIOForwardChain::allocate(*forwardChainId, _service->getLinksPerChannel());
	if (newChain == nullptr) {
		panic("Failed to allocate forward chain");
	}

	_forwardChains[assignedId] = newChain;

	if (*forwardChainId % 2 == 1) {
		auto oldChain = _forwardChains[assignedId - 1];
		oldChain->addPartnerChain(newChain);
		newChain->addPartnerChain(oldChain);
	}

	return newChain;
}

void
AppleCIOMeshForwarder::removeForwardChain(AppleCIOForwardChain * fChain)
{
	int8_t assignedId = -1;

	// Find the chain and release it
	for (uint8_t i = 0; i < _forwardChains.length(); i++) {
		if (_forwardChains[i] == fChain) {
			OSSafeReleaseNULL(_forwardChains[i]);
			_forwardChains[i] = nullptr;
			return;
		}
	}
}

void
AppleCIOMeshForwarder::addToForwardChain(MUCI::ForwardChainId forwardChain, MUCI::BufferId buffer, int64_t offset, uint8_t linkIdx)
{
	int remaining = kForwardNodeCount;
	int cur       = 0;

	ForwardActionChainElement tmpElement;
	ForwardActionChainElement * realElement = nullptr;

	tmpElement.linkIdx = linkIdx;

	for (int i = 0; i < _forwardActionCount && remaining > 0; i++) {
		if (atomic_load(&_forwardActions[i].initialized) == true &&
		    _forwardActions[i].txCommand->getDataChunk().bufferId == buffer &&
		    _forwardActions[i].txCommand->getDataChunk().offset == offset) {
			tmpElement.actions[cur] = &(_forwardActions[i]);

			remaining -= 1;
			cur += 1;
		}
	}

	if (remaining != 0) {
		panic("Could not find all forward actions for bufferId:%lld offset:%llx forwardActionCount %d remaining %d", buffer, offset,
		      _forwardActionCount, remaining);
	}

	if (_forwardChains[forwardChain] == nullptr) {
		panic("Adding to forward chain [%d] that does not exist", forwardChain);
	}

	realElement = _forwardChains[forwardChain]->addToChain(&tmpElement);
	if (realElement == nullptr) {
		panic("No element created in forward chain");
	}

	remaining = kForwardNodeCount;

	for (int i = 0; i < kForwardNodeCount; i++) {
		realElement->actions[i]->chainElement = realElement;
	}
}

static bool
isOffsetInRange(int64_t offset, MUCI::ForwardChain * forwardChain, uint64_t bufferSize)
{
	int64_t startOffset = forwardChain->startOffset;
	int64_t endOffset   = forwardChain->endOffset;

	for (int64_t i = 0; i < forwardChain->sectionCount; i++) {
		if (offset >= startOffset && offset <= endOffset) {
			return true;
		}

		startOffset += forwardChain->sectionOffset;
		endOffset += forwardChain->sectionOffset;

		startOffset = startOffset % bufferSize;
		endOffset   = endOffset % bufferSize;
	}

	return false;
}

void
AppleCIOMeshForwarder::groupChainElements(MUCI::ForwardChainId forwardChainId,
                                          MUCI::BufferId buffer,
                                          MUCI::ForwardChain * forwardChain,
                                          uint64_t bufferSize)
{
	uint32_t sortedIndices[kMaxForwardElementActions];
	uint8_t indexCount = 0;

	// First lets find our forwardChain and get all the partner chains
	AppleCIOForwardChain * chain = _forwardChains[forwardChainId];
	if (chain == nullptr) {
		panic("Could not find forward chain");
	}

	// Now get all the indices of elements that fit the buffer + offset range
	// Just for a single chain, the idea is the partner chains should have the
	// same indices because we divide data chunks evenly between all chains.
	for (int i = 0; i < chain->getElementCount(); i++) {
		auto tmp = chain->getElement((unsigned int)i)->actions[0]->txCommand;

		if (tmp->getDataChunk().bufferId == buffer) {
			// isOffsetInRange(tmp->getDataChunk().offset, forwardChain, bufferSize)) {
			sortedIndices[indexCount++] = (uint32_t)i;
		}
	}

	if (indexCount >= kMaxForwardElementActions) {
		panic("Too many chain elements grouped together: %d", indexCount);
	}

	// Let's make a new group on this chain. We don't have to make it on the
	// primary one because we eventually go through the ChainElement->chainGroup
	// direct connection.
	ForwardActionChainGroup * newGroup = chain->createChainGroup();

	// Now let's go get all the sorted indices and add them for each partner
	// chain to the group. Also set each element's chainGroup as the newly
	// created group.
	auto partners = chain->getPartnerChains();
	for (int partner_i = 0; partner_i < partners.length(); partner_i++) {
		if (partners[partner_i] == nullptr) {
			continue;
		}

		for (int index_i = 0; index_i < indexCount; index_i++) {
			auto cur  = partners[partner_i]->getElement(sortedIndices[index_i]);
			auto prev = index_i > 0 ? partners[partner_i]->getElement(sortedIndices[index_i - 1]) : nullptr;
			auto next = index_i < indexCount - 1 ? partners[partner_i]->getElement(sortedIndices[index_i + 1]) : nullptr;

			newGroup->addChildElement(cur);

			cur->chainGroup = newGroup;

			// set the previous/next actions for all the element's actions.
			for (int forward_i = 0; forward_i < kForwardNodeCount; forward_i++) {
				cur->actions[forward_i]->previousAction = prev ? prev->actions[forward_i] : nullptr;
				cur->actions[forward_i]->nextAction     = next ? next->actions[forward_i] : nullptr;
			}
		}
	}

	// Repeat the same thing for the current chain too
	for (int index_i = 0; index_i < indexCount; index_i++) {
		auto cur  = chain->getElement(sortedIndices[index_i]);
		auto prev = index_i > 0 ? chain->getElement(sortedIndices[index_i - 1]) : nullptr;
		auto next = index_i < indexCount - 1 ? chain->getElement(sortedIndices[index_i + 1]) : nullptr;

		newGroup->addChildElement(cur);

		cur->chainGroup = newGroup;

		// set the previous/next actions for all the element's actions.
		for (int forward_i = 0; forward_i < kForwardNodeCount; forward_i++) {
			cur->actions[forward_i]->previousAction = prev ? prev->actions[forward_i] : nullptr;
			cur->actions[forward_i]->nextAction     = next ? next->actions[forward_i] : nullptr;
		}
	}
}

void
AppleCIOMeshForwarder::startForwardChain(MUCI::ForwardChainId forwardChainId, uint32_t elements)
{
	atomic_store(&_chainActive, true);

	uint64_t ctr = 0;
	while (atomic_load(&_currentActiveChain) != (uintptr_t)nullptr && ctr++ < MAX_LOOPS) {}

	if (ctr >= MAX_LOOPS) {
		panic("Previous active chain did not stop in time when starting a new forward chain");
	}

	AppleCIOForwardChain * chain = _forwardChains[forwardChainId];
	atomic_store(&_currentActiveChain, (uintptr_t)chain);

	auto partners = chain->getPartnerChains();

	chain->startChain((int32_t)elements);
	for (int i = 0; i < partners.size(); i++) {
		if (partners[i] != nullptr) {
			partners[i]->startChain((int32_t)elements);
		}
	}

	auto idx = chain->getStartIndex();
	_prepareChainGroup(chain->getGroup(idx));

	chain->addStartIndex(elements);
}

void
AppleCIOMeshForwarder::stopAllForwardChains()
{
	atomic_store(&_chainActive, false);
}

void
AppleCIOMeshForwarder::disableActionsForSharedMemory(AppleCIOMeshSharedMemory * memory)
{
	_dummyDestroySharedMemoryAction.sharedMemory = memory;
	_queue->add((uintptr_t)&_dummyDestroySharedMemoryAction);
}

void
AppleCIOMeshForwarder::cleanupActionsForSharedMemory(AppleCIOMeshSharedMemory * memory)
{
	int numCleaned = 0, lastValid = -1, lastCleaned = 0;

	for (int i = 0; i < _forwardActions.length(); i++) {
		if (atomic_load(&_forwardActions[i].initialized) == false && _forwardActions[i].sharedMemory == memory &&
		    !_forwardActions[i].dummy) {
			_service->clearCommandeerForwardHelp(&_forwardActions[i]);
			OSSafeReleaseNULL(_forwardActions[i].txCommand);
			_forwardActions[i].txCommand = NULL;
			OSSafeReleaseNULL(_forwardActions[i].rxCommand);
			_forwardActions[i].rxCommand = NULL;
			OSSafeReleaseNULL(_forwardActions[i].sharedMemory);
			_forwardActions[i].sharedMemory = NULL;
			numCleaned++;
			lastCleaned = i;
		} else if (_forwardActions[i].sharedMemory != nullptr && _forwardActions[i].txCommand != nullptr &&
		           _forwardActions[i].initialized) {
			lastValid = i;
		}
	}

	LOG("forwardActionCount is %d (num cleaned %d, lastCleaned %d lastValid %d)\n", (int)_forwardActionCount, numCleaned,
	    lastCleaned, lastValid);
	_forwardActionCount = (uint32_t)lastValid + 1;
}

void
AppleCIOMeshForwarder::safeToForward()
{
	atomic_store(&_safeToForward, true);
}

IOReturn
AppleCIOMeshForwarder::forwardStateMachine(ForwardAction * action, bool dedicated, bool checkAhead)
{
	auto tbtCommands       = action->txCommand->getCommands();
	auto tbtCommandsLength = action->txCommand->getCommandsLength();
	auto controllerId      = action->txCommand->getMeshLink()->getController()->getRID();

	if (action->sharedMemory->hasBeenInterrupted()) {
		return kIOReturnNoMemory;
	}

	switch (action->state) {
	case ForwardState::WaitingForRxStart: {
		if (atomic_load(&action->rxReadyForForward) != true) {
			break;
		}

		// No longer ready for forward now that we start the forward procedure.
		atomic_store(&action->rxReadyForForward, false);
		for (auto p = 0; p < kForwardNodeCount - 1; p++) {
			atomic_store(&action->carryPartners[p]->rxReadyForForward, false);
		}
		atomic_store(&action->carryRequired, true);

		FORWARD_RX_RECEIVED_TR(controllerId, action->sourceNode, action->txCommand->getDataChunk().bufferId,
		                       action->txCommand->getDataChunk().offset);

		if (action->chainElement != nullptr) {
			action->state = ForwardState::ForwardWaitingPrepare;
			for (auto p = 0; p < kForwardNodeCount - 1; p++) {
				action->carryPartners[p]->state = ForwardState::ForwardWaitingPrepare;
			}

			goto waitingPrepare;
		}

		// Move the state to ForwardStartPrepare
		action->state = ForwardState::ForwardStartTxPrepare;
		for (auto p = 0; p < kForwardNodeCount - 1; p++) {
			action->carryPartners[p]->state = ForwardState::ForwardStartTxPrepare;
		}

		goto txPrepare;
	}
	case ForwardState::ForwardStartTxPrepare: {
	txPrepare:
		for (unsigned int j = 0; j < tbtCommandsLength; j++) {
			action->txCommand->getMeshLink()->prepareTXCommand(action->sourceNode, tbtCommands[j]);
		}

		for (auto p = 0; p < kForwardNodeCount - 1; p++) {
			auto partnerTBTCommands = action->carryPartners[p]->txCommand->getCommands();
			for (unsigned int j = 0; j < tbtCommandsLength; j++) {
				action->carryPartners[p]->txCommand->getMeshLink()->prepareTXCommand(action->sourceNode, partnerTBTCommands[j]);
			}
		}

		action->sharedMemory->addPrepared(kForwardNodeCount);

		FORWARD_PREPARED_TR(controllerId, false, action->txCommand->getDataChunk().bufferId,
		                    action->txCommand->getDataChunk().offset);

		action->state = ForwardState::WaitingPreviousTxComplete;
		for (auto p = 0; p < kForwardNodeCount - 1; p++) {
			action->carryPartners[p]->state = ForwardState::WaitingPreviousTxComplete;
		}

		goto waitingPreviousTxComplete;
	}
	case ForwardState::ForwardWaitingPrepare: {
	waitingPrepare:
		// If dedicated, we do not stick the action back into the queue.
		// The dedicated guy has to finish this.
		bool prepared = true;
		prepared &= atomic_load(&action->prepared);
		for (auto p = 0; p < kForwardNodeCount - 1; p++) {
			prepared &= atomic_load(&action->carryPartners[p]->prepared);
		}

		if (!prepared) {
			_queue->add((uintptr_t)action);
			break;
		}

		FORWARD_PREPARED_TR(controllerId, true, action->txCommand->getDataChunk().bufferId,
		                    action->txCommand->getDataChunk().offset);

		atomic_store(&action->prepared, false);
		for (auto p = 0; p < kForwardNodeCount - 1; p++) {
			atomic_store(&action->carryPartners[p]->prepared, false);
		}

		action->state = ForwardState::WaitingPreviousTxComplete;
		for (auto p = 0; p < kForwardNodeCount - 1; p++) {
			action->carryPartners[p]->state = ForwardState::WaitingPreviousTxComplete;
		}

		goto waitingPreviousTxComplete;
	}
	case ForwardState::WaitingPreviousTxComplete: {
	waitingPreviousTxComplete:
		// Time to add the 2 partner actions to the queue at this point, we
		// carried as much as possible.
		bool expected = true;
		if (action->carryPartners[0] != nullptr && atomic_compare_exchange_strong(&action->carryRequired, &expected, false)) {
			for (auto p = 0; p < kForwardNodeCount - 1; p++) {
				_queue->add((uintptr_t)action->carryPartners[p]);
			}
		}

		if (action->previousAction && atomic_load(&action->previousActionComplete) == false) {
			// Special: We will return success here, because the commandeer
			// doesn't need to do be dedicated to this check, the forward loop can
			// do this while managing the other forward actions.
			_queue->add((uintptr_t)action);
			return kIOReturnSuccess;
		}

		FORWARD_PREVIOUS_ACTION_COMPLETE_TR(controllerId, action->sourceNode, action->txCommand->getDataChunk().bufferId,
		                                    action->txCommand->getDataChunk().offset);

		atomic_store(&action->previousActionComplete, false);
		action->state = ForwardState::ForwardTxReadyToFlow;

		goto startTxTransfer;
	}
	// Flow loop start -----
	case ForwardState::ForwardTxReadyToFlow: {
	startTxTransfer:
		// Let's see how many descriptors we can submit
		// There has to be at least one
		if (atomic_load(&action->rxCommandsAvailable) < 1) {
			break;
		}

		// We are no longer ready for forwarding, after processing this.
		atomic_store(&action->rxReadyForForward, false);

		uint8_t submitCount = 0;
		while (int8_t tmp = atomic_fetch_sub(&action->rxCommandsAvailable, 1)) {
			submitCount++;
		}

		// The above loop will subtract 1 extra from the atomic than needed
		// because fetch_sub returns the previous value. The loop will not be
		// entered if the previous value was 0, so submitCount is safe, but
		// the atomic will be subbed to -1, we need to add 1 to make up for it.
		atomic_fetch_add(&action->rxCommandsAvailable, 1);

		// Set up txCommandsSubmitted so we know how how many commands need to
		// complete before we can complete forward or go back to waiting for RX
		atomic_store(&action->txCommandsSubmitted, submitCount);

		if (checkAhead) {
			ForwardAction * lookAhead = (ForwardAction *)_queue->remove();
			if (lookAhead == &_dummyDestroySharedMemoryAction) {
				_queue->add((uintptr_t)lookAhead);
			} else {
				if (lookAhead && !_service->commandeerForwardHelp(lookAhead)) {
					// Commandeer is already helping us, put this back in.
					_queue->add((uintptr_t)lookAhead);
				}
			}
		}

		action->curTxCommand += submitCount;
		auto tmp = action->txCommand->getCommands()[action->curTxCommand - 1];
		action->txCommand->getMeshLink()->sendData(action->sourceNode, action->txCommand->getDataChunk().offset, tmp);

		FORWARD_STARTED_TR(controllerId, action->txCommand->getDataChunk().bufferId, action->txCommand->getDataChunk().offset,
		                   submitCount);

		action->state = ForwardState::ForwardWaitingTxFlowComplete;
		_queue->add((uintptr_t)action);
		break;
	}
	case ForwardState::ForwardWaitingTxFlowComplete: {
		action->txCommand->getMeshLink()->checkDataTXCompletion();

		// We are waiting for all submitted tx commands to complete
		if (atomic_load(&action->txCommandsSubmitted) != 0) {
			_queue->add((uintptr_t)action);
			break;
		}

		FORWARD_TX_FLOW_COMPLETE_TR(controllerId, atomic_load(&action->txCommandsComplete),
		                            action->txCommand->getDataChunk().bufferId, action->txCommand->getDataChunk().offset);

		// Everything has been submitted, let's check if txCommandsComplete
		// is equal to the number of commands in the action
		if (atomic_load(&action->txCommandsComplete) == action->txCommand->getCommandsLength()) {
			// forward has been complete
			// We are not going to check forward complete, because this is
			// faster
			if (action->nextAction) {
				atomic_store(&action->nextAction->previousActionComplete, true);
			}

			action->state = ForwardState::ForwardPrepareOrComplete;
			goto forwardingComplete;
		} else {
			// We need to wait for more RX commands to drip into us
			action->state = ForwardState::WaitingForRxFlow;
			goto checkRxAvailable;
		}
	}
	case ForwardState::ForwardPrepareOrComplete: {
	forwardingComplete:
		if (dedicated) {
			_queue->add((uintptr_t)action);
			break;
		}

		action->state = ForwardState::WaitingForRxStart;

		// We should check continue forwarding first, so we can move the current
		// index forward. We only notify forward complete after incase this
		// completes broadcastAndGather and starts a new forward chain.
		ChainContinueState chainContinue = ChainContinueState::Unknown;

		if (action->chainElement != nullptr) {
			// Check if all actions for this chain element have finished
			//
			// Always reset complete action count back to 0 if we forward all the
			// expected actions with this chain element.
			if (atomic_fetch_add(&action->chainElement->completeActionCount, 1) == (kForwardNodeCount - 1)) {
				// Check if there are any pending elements for this action's link
				// If there are, we can queue up a prepare on this element
				// The commandeer will queue it up.
				auto linkIdx    = action->chainElement->linkIdx;
				auto chainGroup = action->chainElement->chainGroup;
				if (chainGroup->pendingPrepareElements[linkIdx] > 0) {
					// Find the element that's left. The chainElements in the
					// group are setup like so:
					// [link0][link0][link0] ... [link1][link1][link1]
					// So we can calculate the index to operate on next with
					// this formula:
					// ElementsPerLink = TotalCount / numLinksPerChannel
					// index = (ElementsPerLink * LinkIdx) + (elementsPerLink - pendingPrepare)
					// ie: if ElementsPerLink = 4, and pendingPrepare=1,
					// then the index is 4-1 = 3
					// if pendingPrepare=2, then 4-2 = 2.
					// for the second link, we can simply offset this by 3+4
					// or 2+4.

					int elementsPerLink = chainGroup->elementCount / _service->getLinksPerChannel();
					int prepareElementIdx =
					    (elementsPerLink * linkIdx) + (elementsPerLink - chainGroup->pendingPrepareElements[linkIdx]);
					chainGroup->pendingPrepareElements[linkIdx] -= 1;

					auto prepareElement = chainGroup->elements[prepareElementIdx];
					_service->commandeerPrepareForwardElement(prepareElement);
				}

				if (action->chainElement->provider->continueForwarding()) {
					chainContinue = ChainContinueState::ContinueChain;
				} else {
					chainContinue = ChainContinueState::StopChain;
				}
				atomic_store(&action->chainElement->completeActionCount, 0);
			}
		}

		FORWARD_COMPLETED_TR(((int)chainContinue << 12) | controllerId,
		                     action->chainElement == nullptr ? 0 : action->chainElement->provider->getForwardCount(),
		                     action->txCommand->getDataChunk().bufferId, action->txCommand->getDataChunk().offset);

		atomic_store(&action->rxCommandsAvailable, 0);
		atomic_store(&action->txCommandsComplete, 0);
		action->curTxCommand = 0;

		action->txCommand->getProvider()->notifyForwardComplete();

		// We already checked if we can continue with the next element in the chain.
		// We can continue if all the actions for the element have been completed
		// and if there is a chain element.
		if (chainContinue != ChainContinueState::ContinueChain) {
			if (chainContinue == ChainContinueState::StopChain) {
				// Check if we stopped and our partners stopped -- again just in case
				bool finished = action->chainElement->provider->isFinished();
				auto partners = action->chainElement->provider->getPartnerChains();
				for (int t = 0; t < partners.size() && finished; t++) {
					finished &= partners[t]->isFinished();
				}

				if (!finished) {
					break;
				}

				atomic_store(&_currentActiveChain, (uintptr_t)nullptr);
			}

			break;
		}

		auto group = action->chainElement->chainGroup;

		// Mark a complete element in the group.
		atomic_fetch_add(&group->completeElementCount, 1);

		// Check if it is safe to prepare the group
		if (!group->isGroupFinished()) {
			break; // break switch
		}

		// Let's prepare the next group.
		_prepareChainGroup(group->nextGroup);

		break; // break switch
	}
	case ForwardState::WaitingForRxFlow: {
	checkRxAvailable:
		// We are still waiting for RX flows to come in. Spin.
		if (atomic_load(&action->rxCommandsAvailable) == 0) {
			_queue->add((uintptr_t)action);
			break;
		}

		// we have a rx command available!
		action->state = ForwardState::ForwardTxReadyToFlow;
		goto startTxTransfer;
	}
		// Flow loop end -----
	}

	return kIOReturnSuccess;
}

IOReturn
AppleCIOMeshForwarder::_forwarderLoop(__unused IOInterruptEventSource * sender, __unused int count)
{
	LOG("======== forwarder starting ========\n");
	atomic_store(&_stopped, false);

	while (atomic_load(&_active)) {
		if (!atomic_load(&_safeToForward)) {
			continue;
		}

		ForwardAction * action = (ForwardAction *)_queue->remove();

		if (action == nullptr) {
			continue;
		}

		if (action == &_dummyDestroySharedMemoryAction) {
			// Destroy the associated forward chains
			action->sharedMemory->disassociateAllForwardChain();

			// Remove all forward actions associated with this shared memory
			for (int i = 0; i < _forwardActionCount; i++) {
				if (atomic_load(&_forwardActions[i].initialized) && _forwardActions[i].sharedMemory == action->sharedMemory) {
					atomic_store(&_forwardActions[i].initialized, false);
				}
			}

			// do not process anymore forwards until we have been given the go-ahead
			// by the service.
			atomic_store(&_safeToForward, false);

			// Let the service know we are done clearing memory. The service will
			// let us know when we can start forwarding again.
			_service->forwarderFinishedClearingMemory();

			continue;
		}

		if (!atomic_load(&action->initialized)) {
			continue;
		}

		forwardStateMachine(action, false, true);
	}

	atomic_store(&_safeToForward, false);
	LOG("======== forwarder stopping ========\n");

	//
	// Drain the queue in case anything is left in it
	// (which can happen when the user interrupts the program).
	// This occasionally finds some things in the queue and it
	// prevents us from trying to process them again when the
	// forwarder starts up again.
	//
	int ctr = 0;

	while (auto tmp = _queue->remove()) {
		ctr++;
	}
	if (ctr > 0) {
		LOG("*** Removed %d actions from the queue...\n", ctr);
	}
	atomic_store(&_stopped, true);

	return kIOReturnSuccess;
}

void
AppleCIOMeshForwarder::_prepareChainGroup(ForwardActionChainGroup * group)
{
	uint64_t preparedBytes[kMaxMeshLinksPerChannel] = {0};

	for (int i = 0; i < _service->getLinksPerChannel(); i++) {
		group->pendingPrepareElements[i] = group->elementCount / _service->getLinksPerChannel();
	}

	atomic_store(&group->completeElementCount, 0);

	// All Shared memories are the same for actions/elements, grab the first one.
	auto sm = group->elements[0]->actions[0]->sharedMemory;

	// We only need the asignment to get the size per link. We can grab the first
	// one and save the data we need.
	auto assignmentSizePerLink = sm->getAssignment(0)->getAssignmentSizePerLink();

	// Here we will be looping through each chunk
	for (int i = 0; i < group->elementCount; i++) {
		auto element = group->elements[i];
		auto linkIdx = element->linkIdx;

		if (assignmentSizePerLink + preparedBytes[linkIdx] >= kMaxNHIQueueByteSize) {
			continue;
		}

		prepareChainElement(element);

		preparedBytes[linkIdx] += assignmentSizePerLink;
		group->pendingPrepareElements[linkIdx] -= 1;
	}
}

void
AppleCIOMeshForwarder::prepareChainElement(ForwardActionChainElement * element)
{
	auto sm = element->actions[0]->sharedMemory;
	// Get the first RXCommand and mark it as forward incomplete
	element->actions[0]->rxCommand->getProvider()->markTxForwardIncomplete();

	for (int j = 0; j < kForwardNodeCount; j++) {
		auto action            = element->actions[j];
		auto tbtCommands       = action->txCommand->getCommands();
		auto tbtCommandsLength = action->txCommand->getCommandsLength();

		for (unsigned int k = 0; k < tbtCommandsLength; k++) {
			action->txCommand->getMeshLink()->prepareTXCommand(action->sourceNode, tbtCommands[k]);
		}

		atomic_store(&action->prepared, true);
		FORWARD_PREPARED_TR(action->txCommand->getMeshLink()->getController()->getRID(), false,
		                    action->txCommand->getDataChunk().bufferId, action->txCommand->getDataChunk().offset);
	}

	atomic_store(&element->prepared, true);

	sm->addPrepared(kForwardNodeCount);
}
