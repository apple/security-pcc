// Copyright © 2025 Apple Inc. All Rights Reserved.

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

#include "AppleCIOMeshSharedMemory.h"
#include "AppleCIOMeshForwarder.h"
#include "AppleCIOMeshLink.h"
#include "AppleCIOMeshService.h"
#include "AppleCIOMeshSharedMemoryHelpers.h"
#include "AppleCIOMeshThunderboltCommands.h"
#include "AppleCIOMeshUserClient.h"

#define LOG_PREFIX "AppleCIOMeshSharedMemory"
#include "Common/Align.h"
#include "Common/Compiler.h"
#include "Util/Error.h"
#include "Util/Log.h"

#include "Signpost.h"

OSDefineMetaClassAndStructors(AppleCIOMeshSharedMemory, OSObject);

int64_t
AppleCIOMeshSharedMemory::_getOffsetIdx(int64_t offset)
{
	auto divisor = _sharedMemory.strideSkip == 0 ? _sharedMemory.chunkSize : _sharedMemory.strideWidth;
	return offset / divisor;
}

AppleCIOMeshSharedMemory *
AppleCIOMeshSharedMemory::allocate(AppleCIOMeshService * service,
                                   const MUCI::SharedMemory * config,
                                   OSBoundedArrayRef<AppleCIOMeshLink *> meshLinks,
                                   task_t owningTask,
                                   AppleCIOMeshUserClient * userClient)
{
	auto sharedMemory = OSTypeAlloc(AppleCIOMeshSharedMemory);
	if (sharedMemory != nullptr && !sharedMemory->initialize(service, config, meshLinks, owningTask, userClient)) {
		OSSafeReleaseNULL(sharedMemory);
	}
	return sharedMemory;
}

bool
AppleCIOMeshSharedMemory::initialize(AppleCIOMeshService * service,
                                     const MUCI::SharedMemory * config,
                                     OSBoundedArrayRef<AppleCIOMeshLink *> meshLinks,
                                     task_t owningTask,
                                     AppleCIOMeshUserClient * userClient)
{
	uint32_t count            = 0;
	uint32_t runningBreakdown = 0;

	_requiresRuntimePrepare = false;
	atomic_store(&_runtimePrepareDisabled, false);
	_owningUserClient = userClient;
	_sharedMemory     = *config;
	_service          = service;
	_meshLinks        = meshLinks;
	atomic_store(&_prepareCount, 0);

	for (uint8_t i = 0; i < _meshLinks.length(); i++) {
		if (_meshLinks[i]) {
			_meshLinks[i]->retain();
		}
	}

	for (uint8_t i = 0; i < _sizePerNode.length(); i++) {
		_sizePerNode[i] = 0;
	}

	// Verify memory is CIO aligned
	if (!is_aligned(_sharedMemory.address, kCIOPageAlignmentLeadingZeroBits)) {
		LOG("Address[0x%llx] for buffer[%lld] is not page aligned.\n", _sharedMemory.address, _sharedMemory.bufferId);
		goto fail;
	}

	// Also verify the chunk size is at least a multiple of 16 in size so we
	// don't have to deal with odd-sized chunks.
	if (!is_aligned(_sharedMemory.chunkSize, 4)) {
		LOG("ChunkSize[0x%llx] for buffer[%lld] is not a multiple of 16.\n", _sharedMemory.chunkSize, _sharedMemory.bufferId);
		goto fail;
	}

	// make the trailer be 1 frame
	_trailerSize          = kTrailerSize;
	_trailerAllocatedSize = kTrailerFrameSize;

	_preparedTxCommands = OSArray::withCapacity(10);
	if (_preparedTxCommands == nullptr) {
		LOG("Failed to allocate PreparedTXCommands\n");
		goto fail;
	}

	_assignments = OSArray::withCapacity(10);
	if (_assignments == nullptr) {
		LOG("Failed to allocate Assignment\n");
		goto fail;
	}

	for (int i = 0; i < kMaxTBTCommandCount; i++) {
		if (_sharedMemory.forwardBreakdown[i] != 0) {
			count++;
			runningBreakdown += _sharedMemory.forwardBreakdown[i];
		} else {
			break;
		}
	}
	// add in a breakdown for the pad/trailer
	_sharedMemory.forwardBreakdown[count++] = _trailerSize;
	_forwardBreakdownCount                  = (uint8_t)count;

	_commandGroups = AppleCIOMeshThunderboltCommandGroups::allocate(this, service, meshLinks, _sharedMemory, owningTask);
	if (_commandGroups == nullptr) {
		LOG("Failed to allocate AppleCIOMeshThunderboltCommandGroups\n");
		goto fail;
	}

	_receiveAssignments.direction       = MUCI::MeshDirection::In;
	_receiveAssignments.sharedMemory    = this;
	_receiveAssignments.startingIdx     = 0;
	_receiveAssignments.startingIdxSet  = false;
	_receiveAssignments.linksPerChannel = (uint8_t)_service->getLinksPerChannel();

	_outputAssignments.direction       = MUCI::MeshDirection::Out;
	_outputAssignments.sharedMemory    = this;
	_outputAssignments.linksPerChannel = (uint8_t)_service->getLinksPerChannel();

	for (int i = 0; i < kMaxCIOMeshNodes; i++) {
		for (int j = 0; j < kMaxMeshLinksPerChannel; j++) {
			atomic_store(&_receiveAssignments.nodeMap[i].linkCurrentIdx[j], 0);
			atomic_store(&_outputAssignments.nodeMap[i].linkCurrentIdx[j], 0);
		}
	}

	_forwardChains = OSArray::withCapacity(10);
	if (_forwardChains == nullptr) {
		LOG("Failed to allocate _forwardChains\n");
		goto fail;
	}

	if (_sharedMemory.strideSkip == 0) {
		uint32_t iter                = 0;
		uint64_t runningMemoryOffset = 0;

		for (int64_t offsetI = 0; offsetI < config->size; offsetI += config->chunkSize) {
			if (iter % _service->getLinksPerChannel() != 0) {
				// Use the running countdown as the offset
				runningMemoryOffset += runningBreakdown;
			} else {
				runningMemoryOffset = offsetI;
			}

			if (!_commandGroups->allocateCommands(offsetI, runningMemoryOffset)) {
				goto fail;
			}

			// create prepared commands now, it will cost us a bit of memory
			// but that's fine to make lookup faster.
			auto preparedCmd =
			    AppleCIOMeshPreparedCommand::allocate(this, _sharedMemory.bufferId, offsetI, _commandGroups->getCommands(offsetI));
			GOTO_FAIL_IF_NULL(preparedCmd, "Failed to make prepared command");

			_preparedTxCommands->setObject(preparedCmd);
			OSSafeReleaseNULL(preparedCmd); // because the array retains it

			_assignments->setObject(kOSBooleanFalse);

			iter++;
		}
	} else {
		for (int64_t offsetI = 0; offsetI < config->strideSkip; offsetI += config->strideWidth) {
			if (!_commandGroups->allocateCommands(offsetI, offsetI)) {
				goto fail;
			}

			// create prepared commands now, it will cost us a bit of memory
			// but that's fine to make lookup faster.
			auto preparedCmd =
			    AppleCIOMeshPreparedCommand::allocate(this, _sharedMemory.bufferId, offsetI, _commandGroups->getCommands(offsetI));
			GOTO_FAIL_IF_NULL(preparedCmd, "Failed to make prepared command");

			_preparedTxCommands->setObject(preparedCmd);
			OSSafeReleaseNULL(preparedCmd); // because the array retains it

			_assignments->setObject(kOSBooleanFalse);
		}
	}

	return true;

fail:
	OSSafeReleaseNULL(_forwardChains);
	_forwardChains = nullptr;
	OSSafeReleaseNULL(_commandGroups);
	_commandGroups = nullptr;
	if (_preparedTxCommands) {
		for (int i = (int)_preparedTxCommands->getCount() - 1; i >= 0; i--) {
			_preparedTxCommands->removeObject((unsigned int)i);
		}
	}
	OSSafeReleaseNULL(_preparedTxCommands);
	_preparedTxCommands = nullptr;
	OSSafeReleaseNULL(_assignments);
	_assignments = nullptr;
	for (uint8_t i = 0; i < _meshLinks.length(); i++) {
		if (_meshLinks[i]) {
			_meshLinks[i]->release();
			_meshLinks[i] = nullptr;
		}
	}
	return false;
}

void
AppleCIOMeshSharedMemory::free()
{
	if (_forwardChains) {
		for (int i = (int)_forwardChains->getCount() - 1; i >= 0; i--) {
			_forwardChains->removeObject((unsigned int)i);
		}
	}
	OSSafeReleaseNULL(_forwardChains);
	_forwardChains = nullptr;

	OSSafeReleaseNULL(_commandGroups);
	_commandGroups = nullptr;
	if (_preparedTxCommands) {
		for (int i = (int)_preparedTxCommands->getCount() - 1; i >= 0; i--) {
			_preparedTxCommands->removeObject((unsigned int)i);
		}
	}
	OSSafeReleaseNULL(_preparedTxCommands);
	_preparedTxCommands = nullptr;

	if (_assignments) {
		for (int i = (int)_assignments->getCount() - 1; i >= 0; i--) {
			_assignments->removeObject((unsigned int)i);
		}
	}
	OSSafeReleaseNULL(_assignments);
	_assignments = nullptr;

	for (uint8_t i = 0; i < _meshLinks.length(); i++) {
		if (_meshLinks[i]) {
			_meshLinks[i]->release();
		}
		// Note: we do not null out _meshLinks[i] because this
		// array isn't ours - it's part of AppleCIOMeshService
	}

	super::free();
}

bool
AppleCIOMeshSharedMemory::equal(AppleCIOMeshSharedMemory * otherMemory)
{
	return otherMemory->getId() == getId();
}

MUCI::BufferId
AppleCIOMeshSharedMemory::getId()
{
	return _sharedMemory.bufferId;
}

IOMemoryDescriptor *
AppleCIOMeshSharedMemory::getMD()
{
	return _commandGroups->getMD();
}

int64_t
AppleCIOMeshSharedMemory::getChunkSize()
{
	return _sharedMemory.chunkSize;
}

int64_t
AppleCIOMeshSharedMemory::getSize()
{
	return _sharedMemory.size;
}

int64_t
AppleCIOMeshSharedMemory::getBufferId()
{
	return _sharedMemory.bufferId;
}

bool
AppleCIOMeshSharedMemory::getForwardChainRequired()
{
	return _sharedMemory.forwardChainRequired;
}

AppleCIOMeshReceiveCommand *
AppleCIOMeshSharedMemory::getReceiveCommand(uint8_t linkIdx, int64_t offset)
{
	return _commandGroups->getReceiveCommand(linkIdx, offset);
}

AppleCIOMeshTransmitCommand *
AppleCIOMeshSharedMemory::getTransmitCommand(uint8_t linkIdx, int64_t offset)
{
	return _commandGroups->getTransmitCommand(linkIdx, offset);
}

AppleCIOMeshThunderboltCommands *
AppleCIOMeshSharedMemory::getThunderboltCommands(int64_t offset)
{
	return _commandGroups->getCommands(offset);
}

AppleCIOMeshUserClient *
AppleCIOMeshSharedMemory::getOwningUserClient()
{
	return _owningUserClient;
}

MUCI::AccessMode
AppleCIOMeshSharedMemory::getAccessMode(int64_t offset)
{
	return getThunderboltCommands(offset)->getAccessMode();
}

AppleCIOMeshService *
AppleCIOMeshSharedMemory::getProvider()
{
	return _service;
}

void
AppleCIOMeshSharedMemory::printState()
{
	IOLog("CIOMeshSharedMemory: Buffer: %lld chunkSize:%lld size:%lld strideSkip:%llu strideWidth:%llu chunkCount:%u \n",
	      _sharedMemory.bufferId, _sharedMemory.chunkSize, _sharedMemory.size, _sharedMemory.strideSkip, _sharedMemory.strideWidth,
	      _assignments->getCount());

	IOLog("CIOMeshSharedMemory: -----------------------------------\n");
	for (unsigned int i = 0; i < _assignments->getCount(); i++) {
		auto assignment = OSDynamicCast(AppleCIOMeshAssignment, _assignments->getObject(i));
		auto tmp        = _sharedMemory.strideSkip == 0 ? _sharedMemory.chunkSize : _sharedMemory.strideWidth;
		if (assignment == nullptr) {
			IOLog("CIOMeshSharedMemory: -> No assignment at offset: 0x%.8llx\n", tmp * i);
			continue;
		}
		IOLog("CIOMeshSharedMemory: -> Assignment at offset: 0x%.8llxn", tmp * i);
		assignment->printState();
	}
	IOLog("CIOMeshSharedMemory: -----------------------------------\n");
}

uint8_t
AppleCIOMeshSharedMemory::getCommandLength()
{
	return _forwardBreakdownCount;
}

uint32_t
AppleCIOMeshSharedMemory::getTrailerSize()
{
	return _trailerSize;
}

uint32_t
AppleCIOMeshSharedMemory::getTrailerAllocatedSize()
{
	return _trailerAllocatedSize;
}

int64_t
AppleCIOMeshSharedMemory::getCommandSize(uint8_t idx, bool receive)
{
	if (idx >= _forwardBreakdownCount) {
		return 0;
	}

	// We should pass the full allocated size for the last command, only for
	// receive. This way, NHI will not use a double buffer and the transmit side
	// will still only send a partial frame.
	if (receive && idx == (_forwardBreakdownCount - 1)) {
		return _trailerAllocatedSize;
	}

	// For receiving, we should always allocate a multiple of 4K to workaround
	// NHI double buffering. Transmit will allocate a smaller frame.
	if (receive) {
		return align(_sharedMemory.forwardBreakdown[idx], kCIOFrameAlignmentLeadingZeroBits);
	}

	return _sharedMemory.forwardBreakdown[idx];
}

int32_t
AppleCIOMeshSharedMemory::getPreparedCount()
{
	return atomic_load(&_prepareCount);
}

void
AppleCIOMeshSharedMemory::associateForwardChain(AppleCIOForwardChain * forwardChain)
{
	_forwardChains->setObject(forwardChain);
	// do not release it because the forwardChain is not already retained
}

void
AppleCIOMeshSharedMemory::disassociateAllForwardChain()
{
	AppleCIOMeshForwarder * forwarder = _service->getForwarder();
	for (int i = (int)_forwardChains->getCount() - 1; i >= 0; i--) {
		AppleCIOForwardChain * fChain = (AppleCIOForwardChain *)_forwardChains->getObject((unsigned int)i);

		forwarder->removeForwardChain(fChain);
		_forwardChains->removeObject((unsigned int)i);
	}
}

void
AppleCIOMeshSharedMemory::resetForwardingChains()
{
    for (int i = (int)_forwardChains->getCount() - 1; i >= 0; i--) {
        AppleCIOForwardChain * fChain = (AppleCIOForwardChain *)_forwardChains->getObject((unsigned int)i);
        fChain->reset();
    }
}

bool
AppleCIOMeshSharedMemory::createAssignment(int64_t offset, MUCI::MeshDirection direction, MCUCI::NodeId node, int64_t size)
{
	auto existingAssignment = _assignments->getObject((unsigned int)_getOffsetIdx(offset));
	if ((void *)existingAssignment != (void *)kOSBooleanFalse) {
		AppleCIOMeshAssignment * checkAssignment = (AppleCIOMeshAssignment *)existingAssignment;

		if (checkAssignment->getDirection() == MUCI::MeshDirection::In && direction == MUCI::MeshDirection::Out) {
			// This is a forward
			if (!_receiveAssignments.startingIdxSet) {
				_receiveAssignments.startingIdx    = _receiveAssignments.getIdxForOffset(offset);
				_receiveAssignments.startingIdxSet = true;
			}
		} else {
			panic("Creating a duplicate assignment at %lld. Existing assignment is Out.\n", offset);
		}

		return false;
	}

	// We need to check for boundaries before allocating
	// the new object and replacing the old one
	auto assignmentCount =
	    direction == MUCI::MeshDirection::In ? _receiveAssignments.assignmentCount : _outputAssignments.assignmentCount;
	if (assignmentCount >= kMaxAssignmentCount) {
		ERROR("Maximum number of %s assignments reached (%d)", direction == MUCI::MeshDirection::In ? "input" : "output",
		      assignmentCount);
		return false;
	}

	auto newAssignment = AppleCIOMeshAssignment::allocate(this, direction);
	if (newAssignment == nullptr) {
		return false;
	}

	if (direction == MUCI::MeshDirection::In) {
		newAssignment->setRXAssignedNode(node);

		_receiveAssignments.assignedNode[_receiveAssignments.assignmentCount]     = node;
		_receiveAssignments.assignmentOffset[_receiveAssignments.assignmentCount] = offset;
		_receiveAssignments.assignmentReady[_receiveAssignments.assignmentCount]  = false;
		_receiveAssignments.linkIdx[_receiveAssignments.assignmentCount]          = 0;
		_receiveAssignments.addAssignmentForNode(node, _receiveAssignments.assignmentCount);
		_receiveAssignments.addLinkAssignmentForNode(node, _receiveAssignments.assignmentCount, 0);
		_receiveAssignments.assignmentCount++;

		atomic_fetch_add(&_receiveAssignments.remainingAssignments, 1);

		if (_service->getLinksPerChannel() == 2) {
			// add the second link for receive
			_receiveAssignments.assignedNode[_receiveAssignments.assignmentCount]     = node;
			_receiveAssignments.assignmentOffset[_receiveAssignments.assignmentCount] = offset;
			_receiveAssignments.assignmentReady[_receiveAssignments.assignmentCount]  = false;
			_receiveAssignments.linkIdx[_receiveAssignments.assignmentCount]          = 1;
			_receiveAssignments.addAssignmentForNode(node, _receiveAssignments.assignmentCount);
			_receiveAssignments.addLinkAssignmentForNode(node, _receiveAssignments.assignmentCount, 1);
			_receiveAssignments.assignmentCount++;

			atomic_fetch_add(&_receiveAssignments.remainingAssignments, 1);
		}
	} else {
		_outputAssignments.assignedNode[_outputAssignments.assignmentCount]     = node;
		_outputAssignments.assignmentOffset[_outputAssignments.assignmentCount] = offset;
		_outputAssignments.addAssignmentForNode(node, _outputAssignments.assignmentCount);

		_outputAssignments.addLinkAssignmentForNode(node, _outputAssignments.assignmentCount, 0);
		if (_service->getLinksPerChannel() == 2) {
			_outputAssignments.addLinkAssignmentForNode(node, _outputAssignments.assignmentCount, 1);
		}

		_outputAssignments.assignmentCount++;

		atomic_fetch_add(&_outputAssignments.remainingAssignments, 1);
	}

	_assignments->replaceObject((unsigned int)_getOffsetIdx(offset), newAssignment);
	OSSafeReleaseNULL(newAssignment); // because the array retains it

	// Add this assignment for this node, if this node is now going to be
	// transferring more than the NHI queue size per link, the driver is going
	// to have to only prepare a partial transfer and then start managing
	// things a bit more.
	_sizePerNode[node] += (uint64_t)size;
	if ((_sizePerNode[node] / _service->getLinksPerChannel()) >= kMaxNHIQueueByteSize) {
		_requiresRuntimePrepare = true;
	}

	return true;
}

bool
AppleCIOMeshSharedMemory::isAssignmentInput(int64_t offset)
{
	auto existingAssignment = (AppleCIOMeshAssignment *)_assignments->getObject(_getOffsetIdx(offset));
	if (UNLIKELY((void *)existingAssignment == (void *)kOSBooleanFalse)) {
		panic("Assignment not created for offset: %lld\n", offset);
	}

	return existingAssignment->getDirection() == MUCI::MeshDirection::In;
}

void
AppleCIOMeshSharedMemory::addChunkOffsetToAssignment(int64_t assignmentOffset, int64_t chunkOffset)
{
	auto existingAssignment = (AppleCIOMeshAssignment *)_assignments->getObject(_getOffsetIdx(assignmentOffset));
	if ((void *)existingAssignment == (void *)kOSBooleanFalse) {
		ERROR("Assignment not created for offset: %lld\n", assignmentOffset);
		return;
	}

	AppleCIOMeshPreparedCommand * previouslySetup =
	    (AppleCIOMeshPreparedCommand *)(_preparedTxCommands->getObject(_getOffsetIdx(chunkOffset)));

	existingAssignment->addOffset(chunkOffset, previouslySetup);
}

void
AppleCIOMeshSharedMemory::setChannelLastOffsetForLink(int64_t assignmentOffset, int64_t chunkOffset, uint8_t linkIter)
{
	auto existingAssignment = (AppleCIOMeshAssignment *)_assignments->getObject(_getOffsetIdx(assignmentOffset));
	if ((void *)existingAssignment == (void *)kOSBooleanFalse) {
		ERROR("Assignment not created for offset: %lld\n", assignmentOffset);
		return;
	}
	AppleCIOMeshPreparedCommand * previouslySetup =
	    (AppleCIOMeshPreparedCommand *)(_preparedTxCommands->getObject(_getOffsetIdx(chunkOffset)));

	existingAssignment->addLastOffset(chunkOffset, linkIter, previouslySetup);
}

void
AppleCIOMeshSharedMemory::setChannelFirstOffsetForLink(int64_t assignmentOffset, int64_t chunkOffset, uint8_t linkIter)
{
	auto existingAssignment = (AppleCIOMeshAssignment *)_assignments->getObject(_getOffsetIdx(assignmentOffset));
	if ((void *)existingAssignment == (void *)kOSBooleanFalse) {
		ERROR("Assignment not created for offset: %lld\n", assignmentOffset);
		return;
	}
	AppleCIOMeshPreparedCommand * previouslySetup =
	    (AppleCIOMeshPreparedCommand *)(_preparedTxCommands->getObject(_getOffsetIdx(chunkOffset)));
	existingAssignment->addFirstOffset(chunkOffset, linkIter, previouslySetup);
}

void
AppleCIOMeshSharedMemory::dispatch(int64_t offset, uint8_t linkIterMask, char * tag, size_t tagSz)
{
	auto existingAssignment = (AppleCIOMeshAssignment *)_assignments->getObject(_getOffsetIdx(offset));
	if (UNLIKELY((void *)existingAssignment == (void *)kOSBooleanFalse)) {
		panic("Assignment not created for offset: %lld\n", offset);
		return;
	}
	if (atomic_load(&_hasBeenInterrupted)) {
		LOG("bad boy!  trying to dispatch *after* we've been interrupted is a no-no.  no cookie for you.\n");
		return;
	}
	existingAssignment->submit(linkIterMask, tag, tagSz);
}

bool
AppleCIOMeshSharedMemory::assignmentDispatched(int64_t offset, uint8_t linkIterMask)
{
	auto existingAssignment = (AppleCIOMeshAssignment *)_assignments->getObject(_getOffsetIdx(offset));
	if (UNLIKELY((void *)existingAssignment == (void *)kOSBooleanFalse)) {
		panic("Assignment not created for offset: %lld\n", offset);
		return false;
	}
	return existingAssignment->isDispatched(linkIterMask);
}

void
AppleCIOMeshSharedMemory::interruptIOThreads()
{
	atomic_store(&_hasBeenInterrupted, true);
}

void
AppleCIOMeshSharedMemory::clearInterruptState()
{
	atomic_store(&_hasBeenInterrupted, false);
}

void
AppleCIOMeshSharedMemory::prepareCommand(int64_t offset)
{
	auto existingAssignment = (AppleCIOMeshAssignment *)_assignments->getObject(_getOffsetIdx(offset));
	if ((void *)existingAssignment == (void *)kOSBooleanFalse) {
		panic("Assignment not created for offset: %lld\n", offset);
		return;
	}
	if (atomic_load(&_hasBeenInterrupted)) {
		LOG("bad boy!  trying to prepare *after* we've been interrupted is a no-no.  no cookie for you.\n");
		return;
	}
	existingAssignment->prepare(0x3);
}

void
AppleCIOMeshSharedMemory::markCommandForwardIncomplete(int64_t offset)
{
	auto existingAssignment = (AppleCIOMeshAssignment *)_assignments->getObject(_getOffsetIdx(offset));
	if ((void *)existingAssignment == (void *)kOSBooleanFalse) {
		panic("Assignment not created for offset: %lld\n", offset);
		return;
	}
	if (atomic_load(&_hasBeenInterrupted)) {
		LOG("bad boy!  trying to mark forward incomplete *after* we've been interrupted is a no-no.  no cookie for you.\n");
		return;
	}
	existingAssignment->markForwardIncomplete();
}

bool
AppleCIOMeshSharedMemory::dripPrepare(int64_t * assignmentIdx, int64_t * offsetIdx, int64_t * linkIdx)
{
	auto outgoingNode = _service->getLocalNodeId();
	auto existingAssignment =
	    (AppleCIOMeshAssignment *)_assignments->getObject(_getOffsetIdx(_outputAssignments.assignmentOffset[*assignmentIdx]));
	if ((void *)existingAssignment == (void *)kOSBooleanFalse) {
		panic("Assignment not created for offset: %lld\n", _outputAssignments.assignmentOffset[*assignmentIdx]);
	}

	if (requiresRuntimePrepare()) {
		if (_outputAssignments.nodeMap[outgoingNode].totalPrepared[0] + existingAssignment->getAssignmentSizePerLink() >=
		    kMaxNHIQueueByteSize) {
			// We are done early!
			return true;
		}
	}

	if (atomic_load(&_hasBeenInterrupted)) {
		LOG("bad boy!  trying to dripPrepare *after* we've been interrupted is a no-no.  no cookie for you.\n");
		return false;
	}

	if (existingAssignment->dripPrepare(offsetIdx, linkIdx)) {
		*assignmentIdx = (*assignmentIdx) + 1;

		// Increment total prepared for the assignment now.
		// we will check if we are done preparing all that we can in the next
		// dripPrepare.
		if (requiresRuntimePrepare()) {
			for (int i = 0; i < kMaxMeshLinksPerChannel; i++) {
				_outputAssignments.nodeMap[outgoingNode].totalPrepared[i] += existingAssignment->getAssignmentSizePerLink();
				atomic_fetch_add(&_outputAssignments.nodeMap[outgoingNode].linkCurrentIdx[i], 1);
			}
		}

		*offsetIdx = 0;
		*linkIdx   = 0;
	}

	if (*assignmentIdx == _outputAssignments.assignmentCount) {
		return true;
	}

	return false;
}

void
AppleCIOMeshSharedMemory::holdCommand(int64_t offset)
{
	auto existingAssignment = (AppleCIOMeshAssignment *)_assignments->getObject(_getOffsetIdx(offset));
	if ((void *)existingAssignment == (void *)kOSBooleanFalse) {
		panic("Assignment not created for offset: %lld\n", offset);
		return;
	}
	existingAssignment->hold();
}

void
AppleCIOMeshSharedMemory::holdOutput()
{
	for (int i = 0; i < _outputAssignments.assignmentCount; i++) {
		auto existingAssignment =
		    (AppleCIOMeshAssignment *)_assignments->getObject(_getOffsetIdx(_outputAssignments.assignmentOffset[i]));
		if ((void *)existingAssignment == (void *)kOSBooleanFalse) {
			panic("Assignment not created for offset: %lld\n", _outputAssignments.assignmentOffset[i]);
			return;
		}
		existingAssignment->hold();
	}
}

bool
AppleCIOMeshSharedMemory::checkAssignmentReady(int64_t offset, bool * interrupted)
{
	*interrupted = false;

	if (atomic_load(&_hasBeenInterrupted)) {
		LOG("Already interrupted for offset 0x%llx in bufferId %lld, returning Ready\n", offset, _sharedMemory.bufferId);
		*interrupted = true;
		return true;
	}

	int bits = 0;
	if ((bits = vfs_context_issignal(vfs_context_current(), (sigset_t)~0)) != 0) {
		LOG("offset 0x%llx interrupted w/bits 0x%x\n", offset, bits);
		atomic_store(&_hasBeenInterrupted, true);
		*interrupted = true;
		return true;
	}

	auto existingAssignment = (AppleCIOMeshAssignment *)_assignments->getObject(_getOffsetIdx(offset));
	if ((void *)existingAssignment == (void *)kOSBooleanFalse) {
		panic("Assignment not created for offset: %lld\n", offset);
		return false;
	}

	return existingAssignment->checkReady();
}

bool
AppleCIOMeshSharedMemory::forwardsCompleted(void)
{
	uint32_t forwardsCompleted;

	forwardsCompleted = 0;
	for (int i = 0; i < _assignments->getCount(); i++) {
		auto existingAssignment = (AppleCIOMeshAssignment *)_assignments->getObject(i);
		if ((void *)existingAssignment == (void *)kOSBooleanFalse) {
			forwardsCompleted++;
			continue;
		}

		if (existingAssignment->checkForwardComplete()) {
			forwardsCompleted++;
		}
	}

	return (forwardsCompleted == _assignments->getCount());
}

bool
AppleCIOMeshSharedMemory::checkAssignmentForwardComplete(int64_t offset, bool * interrupted)
{
	*interrupted = false;

	if (atomic_load(&_hasBeenInterrupted)) {
		LOG("Already interrupted for offset 0x%llx in bufferId %lld, returning Ready\n", offset, _sharedMemory.bufferId);
		*interrupted = true;
		return true;
	}

	int bits = 0;
	if ((bits = vfs_context_issignal(vfs_context_current(), (sigset_t)~0)) != 0) {
		LOG("offset 0x%llx interrupted w/bits 0x%x\n", offset, bits);
		atomic_store(&_hasBeenInterrupted, true);
		*interrupted = true;
		return true;
	}

	auto existingAssignment = (AppleCIOMeshAssignment *)_assignments->getObject(_getOffsetIdx(offset));
	if ((void *)existingAssignment == (void *)kOSBooleanFalse) {
		panic("Assignment not created for offset: %lld\n", offset);
		return false;
	}

	return existingAssignment->checkForwardComplete();
}

bool
AppleCIOMeshSharedMemory::checkTXAssignmentReady(int64_t offset, uint8_t linkIterMask, bool * interrupted)
{
	*interrupted = false;

	if (atomic_load(&_hasBeenInterrupted)) {
		LOG("Already interrupted for offset 0x%llx in bufferId %lld, returning Ready\n", offset, _sharedMemory.bufferId);
		*interrupted = true;
		return true;
	}

	auto existingAssignment = (AppleCIOMeshAssignment *)_assignments->getObject(_getOffsetIdx(offset));
	if ((void *)existingAssignment == (void *)kOSBooleanFalse) {
		panic("Assignment not created for offset: %lld\n", offset);
		return false;
	}
	return existingAssignment->checkTXReady(linkIterMask);
}

bool
AppleCIOMeshSharedMemory::checkAssignmentPrepared(int64_t offset)
{
	auto existingAssignment = (AppleCIOMeshAssignment *)_assignments->getObject(_getOffsetIdx(offset));
	if ((void *)existingAssignment == (void *)kOSBooleanFalse) {
		panic("Assignment not created for offset: %lld\n", offset);
	}
	return existingAssignment->checkPrepared();
}

bool
AppleCIOMeshSharedMemory::readAssignmentTagForLink(int64_t offset, uint8_t linkIter, char * tag, size_t tagSz)
{
	auto existingAssignment = (AppleCIOMeshAssignment *)_assignments->getObject(_getOffsetIdx(offset));
	if ((void *)existingAssignment == (void *)kOSBooleanFalse) {
		panic("Assignment not created for offset: %lld\n", offset);
	}
	return existingAssignment->getTrailer(linkIter, tag, tagSz);
}

AppleCIOMeshAssignmentMap *
AppleCIOMeshSharedMemory::getReceiveAssignmentMap()
{
	return &_receiveAssignments;
}

AppleCIOMeshAssignmentMap *
AppleCIOMeshSharedMemory::getOutputAssignmentMap()
{
	return &_outputAssignments;
}

void
AppleCIOMeshSharedMemory::overrideOutputAssignmentForWholeBuffer()
{
	for (int i = 0; i < _outputAssignments.assignmentCount; i++) {
		auto existingAssignment =
		    (AppleCIOMeshAssignment *)_assignments->getObject(_getOffsetIdx(_outputAssignments.assignmentOffset[i]));
		if ((void *)existingAssignment == (void *)kOSBooleanFalse) {
			panic("Assignment not created for offset: %lld\n", _outputAssignments.assignmentOffset[i]);
			return;
		}
		existingAssignment->setWholeBufferPrepared(true);
	}
}

AppleCIOMeshAssignment *
AppleCIOMeshSharedMemory::getAssignment(int64_t offset)
{
	auto existingAssignment = (AppleCIOMeshAssignment *)_assignments->getObject(_getOffsetIdx(offset));
	if ((void *)existingAssignment == (void *)kOSBooleanFalse) {
		panic("Assignment not created for offset: %lld\n", offset);
	}
	return existingAssignment;
}

AppleCIOMeshAssignment *
AppleCIOMeshSharedMemory::getAssignmentIn(int64_t offset, int8_t linkIdx)
{
	auto existingAssignment = (AppleCIOMeshAssignment *)_assignments->getObject(_getOffsetIdx(offset));
	if ((void *)existingAssignment == (void *)kOSBooleanFalse) {
		return nullptr;
	}
	return existingAssignment;
}

AppleCIOMeshAssignment *
AppleCIOMeshSharedMemory::getAssignmentOut(int64_t offset)
{
	auto existingAssignment = (AppleCIOMeshAssignment *)_assignments->getObject(_getOffsetIdx(offset));
	if ((void *)existingAssignment == (void *)kOSBooleanFalse) {
		panic("OUT Assignment not created for offset: %lld\n", offset);
	}
	return existingAssignment;
}

void
AppleCIOMeshSharedMemory::setupTxCommand(AppleCIOMeshLink * link, MCUCI::NodeId node, AppleCIOMeshTransmitCommand * command)
{
	int64_t offset = command->getDataChunk().offset;
	AppleCIOMeshPreparedCommand * previouslySetup =
	    (AppleCIOMeshPreparedCommand *)(_preparedTxCommands->getObject(_getOffsetIdx(offset)));

	if (!previouslySetup) {
		ERROR("Could not find previously setup TX command at offset: %lld\n", offset);
		return;
	}

	if (!previouslySetup->isSourceNodeSet()) {
		previouslySetup->setSourceNode(node);
	} else {
		if (previouslySetup->getSourceNode() != node) {
			LOG("Previously prepared TX command for offset: %lld is for node: %d, "
			    "cannot allocate same offset for multiple source nodes\n",
			    offset, node)
			return;
		}
	}

	previouslySetup->setupCommand(link, command);
}

void
AppleCIOMeshSharedMemory::_prepareRxCommand(int64_t offset)
{
	auto tbtCommands = getThunderboltCommands(offset);

	auto meshRxCommand = getReceiveCommand((uint8_t)tbtCommands->getAssignedInputLink(), offset);
	meshRxCommand->setPrepared(false);

	auto tbtRxCommands       = meshRxCommand->getCommands();
	auto tbtRxCommandsLength = meshRxCommand->getCommandsLength();

	for (int i = 0; i < tbtRxCommandsLength; i++) {
		meshRxCommand->getMeshLink()->prepareRXCommand(meshRxCommand->getAssignedChunk().sourceNode, tbtRxCommands[i]);
	}
	meshRxCommand->getMeshLink()->sendPreparedRXCommand(meshRxCommand->getAssignedChunk().sourceNode);

	RX_CHUNK_PREPARED_TR(meshRxCommand->getMeshLink()->getRID(), meshRxCommand->getDataChunk().bufferId, offset);

	meshRxCommand->setPrepared(true);

	addPrepared(1);
}

void
AppleCIOMeshSharedMemory::_holdRxCommand(int64_t offset)
{
	auto tbtCommands = getThunderboltCommands(offset);

	auto meshRxCommand = getReceiveCommand((uint8_t)tbtCommands->getAssignedInputLink(), offset);
	meshRxCommand->getProvider()->markRxUnready();
}

void
AppleCIOMeshSharedMemory::_correctThunderboltCallbacks()
{
	// First, let's group up all the assignment by node,
	// then start keeping track of how much that
}
