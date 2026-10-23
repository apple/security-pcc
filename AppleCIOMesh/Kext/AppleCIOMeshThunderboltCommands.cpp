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

#include "AppleCIOMeshThunderboltCommands.h"
#include "AppleCIOMeshForwarder.h"
#include "AppleCIOMeshLink.h"
#include "AppleCIOMeshService.h"
#include "AppleCIOMeshSharedMemory.h"
#include <IOKit/IOMultiMemoryDescriptor.h>
#include <IOKit/IOSubMemoryDescriptor.h>
#include <IOKit/thunderbolt/IOThunderboltController.h>
#define BSD_KERNEL_PRIVATE 1
#include <sys/signalvar.h>
#include <sys/vnode.h>

#define LOG_PREFIX "AppleCIOMeshThunderboltCommands"
#include "Common/Compiler.h"
#include "Util/Error.h"
#include "Util/Log.h"

OSDefineMetaClassAndStructors(AppleCIOMeshReceiveCommand, OSObject);
OSDefineMetaClassAndStructors(AppleCIOMeshTransmitCommand, OSObject);
OSDefineMetaClassAndStructors(AppleCIOMeshThunderboltCommands, OSObject);
OSDefineMetaClassAndStructors(AppleCIOMeshThunderboltCommandGroups, OSObject);

#define kAppleCIOMeshForwardDelay "mesh_forward_delay"

// MARK: Thunderbolt Base Commands

// MARK: Receive Command
AppleCIOMeshReceiveCommand *
AppleCIOMeshReceiveCommand::allocate(AppleCIOMeshThunderboltCommands * provider,
                                     AppleCIOMeshLink * link,
                                     AppleCIOMeshService * service,
                                     IOMemoryDescriptor * iomd,
                                     const MUCI::DataChunk & dataChunk)
{
	auto receiveCmd = OSTypeAlloc(AppleCIOMeshReceiveCommand);
	if (receiveCmd != nullptr && !receiveCmd->initialize(provider, link, service, iomd, dataChunk)) {
		OSSafeReleaseNULL(receiveCmd);
	}
	return receiveCmd;
}

bool
AppleCIOMeshReceiveCommand::initialize(AppleCIOMeshThunderboltCommands * provider,
                                       AppleCIOMeshLink * link,
                                       AppleCIOMeshService * service,
                                       IOMemoryDescriptor * iomd,
                                       const MUCI::DataChunk & dataChunk)
{
	auto sharedMem = provider->getProvider()->getProvider();

	_provider           = provider;
	_link               = link;
	_service            = service;
	_dataChunk          = dataChunk;
	_assignedChunk.size = 0;
	_iomd               = iomd;

	_commandsLength = sharedMem->getCommandLength();

	atomic_store(&_prepared, false);
	atomic_store(&_fxReceivedIdx, 0);

	for (int i = 0; i < _commands.length(); i++) {
		_commands[i]     = nullptr;
		_commandsIOMD[i] = nullptr;
	}

	uint64_t offset = 0;
	for (int i = 0; i < _commandsLength; i++) {
		int64_t tmp = sharedMem->getCommandSize(i, true);

		_commandsIOMD[i] = IOSubMemoryDescriptor::withSubRange(_iomd, offset, tmp, kIODirectionIn);
		GOTO_FAIL_IF_NULL(
		    _commandsIOMD[i],
		    "Failed to create sub-sub memory descriptor at: %d offset %lld _commandsLen %d cmdSize %lld iomd len %lld\n", i, offset,
		    _commandsLength, tmp, _iomd->getLength());

		offset += tmp;
	}

	return true;

fail:
	for (int i = 0; i < _commandsLength; i++) {
		OSSafeReleaseNULL(_commands[i]);
		_commands[i] = nullptr;
		OSSafeReleaseNULL(_commandsIOMD[i]);
		_commandsIOMD[i] = nullptr;
	}

	return false;
}

void
AppleCIOMeshReceiveCommand::free()
{
	for (int i = 0; i < _commandsLength; i++) {
		OSSafeReleaseNULL(_commands[i]);
		OSSafeReleaseNULL(_commandsIOMD[i]);
	}
	super::free();
}

IOReturn
AppleCIOMeshReceiveCommand::createTBTCommands()
{
	for (int i = 0; i < _commandsLength; i++) {
		IOThunderboltReceiveCommand * receiveCmd = IOThunderboltReceiveCommand::withControllerAndQueue(
		    _link->getController(), _link->getRXQueue(_assignedChunk.sourceNode));
		GOTO_FAIL_IF_NULL(receiveCmd, "Failed to allocate receive command\n");

		receiveCmd->setMemoryDescriptor(_commandsIOMD[i]);
		receiveCmd->setLength(_commandsIOMD[i]->getLength());
		receiveCmd->setInterruptMode(IOThunderboltReceiveCommand::kInterruptModeNone);
		receiveCmd->setConsumerIndexUpdateMode(IOThunderboltReceiveCommand::kConsumerIndexUpdateModeNone);

		_commands[i] = receiveCmd;
	}

	return kIOReturnSuccess;

fail:
	for (int i = 0; i < _commandsLength; i++) {
		OSSafeReleaseNULL(_commands[i]);
		_commands[i] = nullptr;
	}
	return kIOReturnNoMemory;
}

OSBoundedArrayRef<IOThunderboltReceiveCommand *>
AppleCIOMeshReceiveCommand::getCommands()
{
	return OSBoundedArrayRef<IOThunderboltReceiveCommand *>(_commands);
}

uint32_t
AppleCIOMeshReceiveCommand::getCommandsLength()
{
	return _commandsLength;
}

const MUCI::DataChunk &
AppleCIOMeshReceiveCommand::getDataChunk()
{
	return _dataChunk;
}

AppleCIOMeshLink *
AppleCIOMeshReceiveCommand::getMeshLink()
{
	return _link;
}

void
AppleCIOMeshReceiveCommand::getTrailerData(void * data, uint32_t dataLen)
{
	void * ptr    = _provider->getTrailer();
	uint32_t tlen = _provider->getTrailerLen();
	memcpy(data, ptr, (tlen < dataLen) ? tlen : dataLen);
	if (tlen < dataLen) {
		memset((char *)data + tlen, 0, dataLen - tlen);
	}
}

void
AppleCIOMeshReceiveCommand::setCompletion(uint32_t commandIdx, void * target, IOThunderboltReceiveCommand::Action action)
{
	IOThunderboltReceiveCommand::Completion completion = {0};
	completion.target                                  = target;
	completion.action                                  = action;
	completion.parameter                               = this;
	_commands[commandIdx]->setCompletion(completion);
}

void
AppleCIOMeshReceiveCommand::setAssignedChunk(const MUCI::AssignChunks * assignment)
{
	_assignedChunk = *assignment;
}

void
AppleCIOMeshReceiveCommand::setPrepared(bool prepared)
{
	atomic_store(&_prepared, prepared);
}

bool
AppleCIOMeshReceiveCommand::getPrepared()
{
	return atomic_load(&_prepared);
}

const MUCI::AssignChunks &
AppleCIOMeshReceiveCommand::getAssignedChunk()
{
	return _assignedChunk;
}

AppleCIOMeshThunderboltCommands *
AppleCIOMeshReceiveCommand::getProvider()
{
	return _provider;
}

int
AppleCIOMeshReceiveCommand::updateFXReceivedIdx()
{
	int tmp = atomic_fetch_add(&_fxReceivedIdx, 1);
	if (tmp + 1 == getCommandsLength()) {
		atomic_store(&_fxReceivedIdx, 0);
	}

	return tmp;
}

int
AppleCIOMeshReceiveCommand::getFXReceivedIdx()
{
	return atomic_load(&_fxReceivedIdx);
}

// MARK: Transmit Command

AppleCIOMeshTransmitCommand *
AppleCIOMeshTransmitCommand::allocate(AppleCIOMeshThunderboltCommands * provider,
                                      AppleCIOMeshLink * link,
                                      AppleCIOMeshService * service,
                                      IOMemoryDescriptor * iomd,
                                      const MUCI::DataChunk & dataChunk)
{
	auto transmitCmd = OSTypeAlloc(AppleCIOMeshTransmitCommand);
	if (transmitCmd != nullptr && !transmitCmd->initialize(provider, link, service, iomd, dataChunk)) {
		OSSafeReleaseNULL(transmitCmd);
	}
	return transmitCmd;
}

bool
AppleCIOMeshTransmitCommand::initialize(AppleCIOMeshThunderboltCommands * provider,
                                        AppleCIOMeshLink * link,
                                        AppleCIOMeshService * service,
                                        IOMemoryDescriptor * iomd,
                                        const MUCI::DataChunk & dataChunk)
{
	auto sharedMem = provider->getProvider()->getProvider();

	_provider           = provider;
	_link               = link;
	_service            = service;
	_dataChunk          = dataChunk;
	_assignedChunk.size = 0;
	_iomd               = iomd;
	_commandsLength     = sharedMem->getCommandLength();

	for (int i = 0; i < _commands.length(); i++) {
		_commands[i]     = nullptr;
		_commandsIOMD[i] = nullptr;
	}

	uint64_t offset = 0;
	for (int i = 0; i < _commandsLength; i++) {
		// The value in tmp tracks the length we will Transmit and offset tracks
		// where in the buffer we are. The two values can be different if the
		// user's chunk size is not a multiple of 4k. In that case tmp will be
		// smaller than offset because of the padding added to ensure that NHI
		// does not do double buffering
		int64_t commandSize     = sharedMem->getCommandSize(i, false);
		int64_t offsetIncrement = sharedMem->getCommandSize(i, true);

		_descriptorsPerCommand[i] = commandSize / kIOThunderboltMaxFrameSize;

		_commandsIOMD[i] = IOSubMemoryDescriptor::withSubRange(_iomd, offset, commandSize, kIODirectionOut);
		GOTO_FAIL_IF_NULL(_commandsIOMD[i], "Failed to create sub-sub memory descriptor at: %d\n", i * kIOThunderboltMaxFrameSize);

		offset += offsetIncrement;
	}

	return true;

fail:
	for (int i = 0; i < _commandsLength; i++) {
		OSSafeReleaseNULL(_commands[i]);
		OSSafeReleaseNULL(_commandsIOMD[i]);
	}
	return false;
}

void
AppleCIOMeshTransmitCommand::free()
{
	for (int i = 0; i < _commandsLength; i++) {
		OSSafeReleaseNULL(_commands[i]);
		OSSafeReleaseNULL(_commandsIOMD[i]);
	}
	super::free();
}

uint32_t
AppleCIOMeshTransmitCommand::getDescriptorsForCommand(uint8_t idx)
{
	return _descriptorsPerCommand[idx];
}

IOReturn
AppleCIOMeshTransmitCommand::createTBTCommands()
{
	for (int i = 0; i < _commandsLength; i++) {
		IOThunderboltTransmitCommand * transmitCmd = IOThunderboltTransmitCommand::withControllerAndQueue(
		    _link->getController(), _link->getTXQueue(_assignedChunk.sourceNode));
		GOTO_FAIL_IF_NULL(transmitCmd, "Failed to allocate transmit command\n");

		transmitCmd->setMemoryDescriptor(_commandsIOMD[i]);
		transmitCmd->setLength(_commandsIOMD[i]->getLength());
		transmitCmd->setInterruptMode(IOThunderboltTransmitCommand::kInterruptModeNone);
		transmitCmd->setProducerIndexUpdateMode(IOThunderboltTransmitCommand::kProducerIndexUpdateModeNone);
		transmitCmd->setSOF(kSOF);
		transmitCmd->setEOF(kEOF);

		_commands[i] = transmitCmd;
	}

	return kIOReturnSuccess;
fail:
	for (int i = 0; i < _commandsLength; i++) {
		OSSafeReleaseNULL(_commands[i]);
		_commands[i] = nullptr;
	}
	return kIOReturnNoMemory;
}

OSBoundedArrayRef<IOThunderboltTransmitCommand *>
AppleCIOMeshTransmitCommand::getCommands()
{
	return OSBoundedArrayRef<IOThunderboltTransmitCommand *>(_commands);
}

uint32_t
AppleCIOMeshTransmitCommand::getCommandsLength()
{
	return _commandsLength;
}

const MUCI::DataChunk &
AppleCIOMeshTransmitCommand::getDataChunk()
{
	return _dataChunk;
}

AppleCIOMeshLink *
AppleCIOMeshTransmitCommand::getMeshLink()
{
	return _link;
}

void
AppleCIOMeshTransmitCommand::setTrailerData(const void * data, const uint32_t dataLen)
{
	void * ptr    = _provider->getTrailer();
	uint32_t tlen = _provider->getTrailerLen();

	memcpy(ptr, data, (dataLen < tlen) ? dataLen : tlen);
	if (dataLen < tlen) {
		memset((char *)ptr + dataLen, 0xe9, tlen - dataLen);
	}
}

void
AppleCIOMeshTransmitCommand::setCompletion(uint32_t commandIdx, void * target, IOThunderboltTransmitCommand::Action action)
{
	IOThunderboltTransmitCommand::Completion completion = {0};
	completion.target                                   = target;
	completion.action                                   = action;
	completion.parameter                                = this;
	_commands[commandIdx]->setCompletion(completion);
}

void
AppleCIOMeshTransmitCommand::setAssignedChunk(const MUCI::AssignChunks * assignment)
{
	_assignedChunk = *assignment;
}

const MUCI::AssignChunks &
AppleCIOMeshTransmitCommand::getAssignedChunk()
{
	return _assignedChunk;
}

AppleCIOMeshThunderboltCommands *
AppleCIOMeshTransmitCommand::getProvider()
{
	return _provider;
}

void
AppleCIOMeshTransmitCommand::dataOut()
{
	_sent = true;
}

void
AppleCIOMeshTransmitCommand::completionIn()
{
	_sent = false;
}

bool
AppleCIOMeshTransmitCommand::waitingForCompletion()
{
	return _sent;
}

ForwardAction *
AppleCIOMeshTransmitCommand::getForwardAction()
{
	return _forwardAction;
}

void
AppleCIOMeshTransmitCommand::setForwardAction(ForwardAction * forwardAction)
{
	_forwardAction = forwardAction;
}

void
AppleCIOMeshTransmitCommand::dripForwardComplete()
{
	atomic_fetch_add(&_forwardAction->txCommandsComplete, 1);
	atomic_fetch_sub(&_forwardAction->txCommandsSubmitted, 1);
}

int
AppleCIOMeshTransmitCommand::updateFXCompletedIdx()
{
	int tmp = atomic_fetch_add(&_fxCompletedIdx, 1);
	if (tmp == getCommandsLength() - 1) {
		atomic_store(&_fxCompletedIdx, 0);
	}

	return tmp;
}

int
AppleCIOMeshTransmitCommand::getFXCompletedIdx()
{
	return atomic_load(&_fxCompletedIdx);
}

// MARK: Thunderbolt Commands

AppleCIOMeshThunderboltCommands *
AppleCIOMeshThunderboltCommands::allocate(AppleCIOMeshThunderboltCommandGroups * provider,
                                          AppleCIOMeshService * service,
                                          OSBoundedArrayRef<AppleCIOMeshLink *> meshLinks,
                                          IOMemoryDescriptor * iomd,
                                          const MUCI::DataChunk & dataChunk,
                                          char * trailerMem,
                                          uint32_t trailerSize,
                                          uint32_t trailerAllocatedSize)
{
	auto tbtCommands = OSTypeAlloc(AppleCIOMeshThunderboltCommands);
	if (tbtCommands != nullptr &&
	    !tbtCommands->initialize(provider, service, meshLinks, iomd, dataChunk, trailerMem, trailerSize, trailerAllocatedSize)) {
		OSSafeReleaseNULL(tbtCommands);
	}
	return tbtCommands;
}

bool
AppleCIOMeshThunderboltCommands::initialize(AppleCIOMeshThunderboltCommandGroups * provider,
                                            AppleCIOMeshService * service,
                                            OSBoundedArrayRef<AppleCIOMeshLink *> meshLinks,
                                            IOMemoryDescriptor * iomd,
                                            const MUCI::DataChunk & dataChunk,
                                            char * trailerMem,
                                            uint32_t trailerSize,
                                            uint32_t trailerAllocatedSize)
{
	_dataChunk = dataChunk;

	_provider = provider;
	atomic_store(&_pendingCompletions, 0);
	atomic_store(&_dispatchRemaining, 0);
	atomic_store(&_rxReady, false);
	atomic_store(&_txReady, false);

	_forwardCount = 0;
	atomic_store(&_forwardCompleteCount, 0);
	atomic_store(&_forwardComplete, true);

	_assignedInputMeshLink = -1;
	_iomd                  = iomd;
	_iomd->retain();

	_trailerMem           = trailerMem;
	_trailerSize          = trailerSize;
	_trailerAllocatedSize = trailerAllocatedSize;

	_receiveTBTCommands = OSArray::withCapacity((unsigned int)meshLinks.length());
	GOTO_FAIL_IF_NULL(_receiveTBTCommands, "failed to make receive tbt local array");
	_transmitTBTCommands = OSArray::withCapacity((unsigned int)meshLinks.length());
	GOTO_FAIL_IF_NULL(_transmitTBTCommands, "failed to make transmit tbt local array");

	_accessMode = MUCI::AccessMode::Block;

	for (unsigned i = 0; i < meshLinks.length(); i++) {
		if (meshLinks[i] == nullptr) {
			_receiveTBTCommands->setObject(i, kOSBooleanFalse);
			_transmitTBTCommands->setObject(i, kOSBooleanFalse);
			continue;
		}

		auto receiveCmd = AppleCIOMeshReceiveCommand::allocate(this, meshLinks[i], service, iomd, dataChunk);
		GOTO_FAIL_IF_NULL(receiveCmd, "failed to make receiveCmd[%d]", i);
		_receiveTBTCommands->setObject(i, receiveCmd);
		OSSafeReleaseNULL(receiveCmd); // because the array retains it

		auto transmitCmd = AppleCIOMeshTransmitCommand::allocate(this, meshLinks[i], service, iomd, dataChunk);
		GOTO_FAIL_IF_NULL(transmitCmd, "failed to make transmitCmd[%d]", i);
		_transmitTBTCommands->setObject(i, transmitCmd);
		OSSafeReleaseNULL(transmitCmd); // because the array retains it
	}

	return true;

fail:
	if (_receiveTBTCommands) {
		for (int i = (int)_receiveTBTCommands->getCount() - 1; i >= 0; i--) {
			_receiveTBTCommands->removeObject((unsigned int)i);
		}
		OSSafeReleaseNULL(_receiveTBTCommands);
		_receiveTBTCommands = nullptr;
	}

	if (_transmitTBTCommands) {
		for (int i = (int)_transmitTBTCommands->getCount() - 1; i >= 0; i--) {
			_transmitTBTCommands->removeObject((unsigned int)i);
		}
		OSSafeReleaseNULL(_transmitTBTCommands);
		_transmitTBTCommands = nullptr;
	}

	OSSafeReleaseNULL(_iomd);
	_iomd = nullptr;

	IOSafeDeleteNULL(_trailerMem, char, _trailerAllocatedSize);
	_trailerMem = nullptr;

	return false;
}

void
AppleCIOMeshThunderboltCommands::free()
{
	if (_receiveTBTCommands) {
		for (int i = (int)_receiveTBTCommands->getCount() - 1; i >= 0; i--) {
			_receiveTBTCommands->removeObject((unsigned int)i);
		}
		OSSafeReleaseNULL(_receiveTBTCommands);
	}

	if (_transmitTBTCommands) {
		for (int i = (int)_transmitTBTCommands->getCount() - 1; i >= 0; i--) {
			_transmitTBTCommands->removeObject((unsigned int)i);
		}
		OSSafeReleaseNULL(_transmitTBTCommands);
	}

	OSSafeReleaseNULL(_iomd);

	IOSafeDeleteNULL(_trailerMem, char, _trailerAllocatedSize);

	super::free();
}

OSArray *
AppleCIOMeshThunderboltCommands::getReceiveCommands()
{
	return _receiveTBTCommands;
}

OSArray *
AppleCIOMeshThunderboltCommands::getTransmitCommands()
{
	return _transmitTBTCommands;
}

void
AppleCIOMeshThunderboltCommands::setOutgoingCommandCountAndMask(int outgoing, uint32_t mask)
{
	if (UNLIKELY(_pendingCompletions != 0)) {
		panic("setOutgoingCommandCount cannot be set twice. Duplicate prepare.");
	}

	atomic_store(&_pendingCompletions, (uint8_t)outgoing);

	atomic_store(&_dispatchRemaining, (uint8_t)outgoing);
	atomic_store(&_pendingCompletionsMask, mask);
}

void
AppleCIOMeshThunderboltCommands::holdCommandForOutput()
{
	atomic_store(&_dispatchRemaining, (uint8_t)0xFF);
}

void
AppleCIOMeshThunderboltCommands::setAssignedInputLink(int64_t assignedInputMeshLink)
{
	_assignedInputMeshLink = assignedInputMeshLink;
}

int64_t
AppleCIOMeshThunderboltCommands::getAssignedInputLink()
{
	return _assignedInputMeshLink;
}

void
AppleCIOMeshThunderboltCommands::setAssignedForOutput(bool assigned)
{
	_assignedForOutput = assigned;
}

bool
AppleCIOMeshThunderboltCommands::getAssignedForOutput()
{
	return _assignedForOutput;
}

void
AppleCIOMeshThunderboltCommands::setAccessMode(MUCI::AccessMode mode)
{
	_accessMode = mode;
}

MUCI::AccessMode
AppleCIOMeshThunderboltCommands::getAccessMode()
{
	return _accessMode;
}

bool
AppleCIOMeshThunderboltCommands::decrementOutgoingCommandForMask(uint32_t linkMask)
{
	atomic_fetch_xor(&_pendingCompletionsMask, linkMask);
	return atomic_fetch_sub(&_pendingCompletions, 1) == 1;
}

AppleCIOMeshThunderboltCommandGroups *
AppleCIOMeshThunderboltCommands::getProvider()
{
	return _provider;
}

void
AppleCIOMeshThunderboltCommands::notifyRxReady()
{
	if (atomic_load(&_rxReady)) {
		panic("_rxReady already true\n");
	}

	atomic_store(&_rxReady, true);
}

bool
AppleCIOMeshThunderboltCommands::checkRxReady()
{
	if (isRxReady()) {
		return true;
	}
	AppleCIOMeshLink * link = getProvider()->getMeshLink((uint8_t)getAssignedInputLink());
	if (link) {
		link->checkDataRXCompletion();
	}
	return isRxReady();
}

bool
AppleCIOMeshThunderboltCommands::checkRxReadyForNode(MCUCI::NodeId node)
{
	if (isRxReady()) {
		return true;
	}
	AppleCIOMeshLink * link = getProvider()->getMeshLink((uint8_t)getAssignedInputLink());
	if (link) {
		link->checkDataRXCompletionForNode(node);
	}
	return isRxReady();
}

bool
AppleCIOMeshThunderboltCommands::isRxReady()
{
	return atomic_load(&_rxReady);
	//	bool retVal = atomic_load(&_rxReady);
	//	if (retVal) {
	//		atomic_store(&_rxReady, false);
	//	}
	//	return retVal;
}

void
AppleCIOMeshThunderboltCommands::markRxUnready()
{
	atomic_store(&_rxReady, false);
}

void
AppleCIOMeshThunderboltCommands::notifyTxReady()
{
	if (atomic_load(&_txReady)) {
		panic("_txReady already true\n");
	}
	atomic_store(&_txReady, true);
}

bool
AppleCIOMeshThunderboltCommands::checkTxReady()
{
	if (isTxReady()) {
		return true;
	}

	for (unsigned int i = 0; i < getTransmitCommands()->getCount(); i++) {
		auto cmd = (AppleCIOMeshTransmitCommand *)getTransmitCommands()->getObject(i);
		if ((void *)cmd != (void *)kOSBooleanFalse && (atomic_load(&_pendingCompletionsMask) & (0x1 << i))) {
			auto link = cmd->getMeshLink();
			if (link) {
				link->checkDataTXCompletion();
			}
		}
	}

	return isTxReady();
}

bool
AppleCIOMeshThunderboltCommands::isTxReady()
{
	return atomic_load(&_txReady);
	//	bool retVal = atomic_load(&_txReady);
	//	if (retVal) {
	//		atomic_store(&_txReady, false);
	//	}
	//	return retVal;
}

void
AppleCIOMeshThunderboltCommands::markTxUnready()
{
	atomic_store(&_txReady, false);
}
bool
AppleCIOMeshThunderboltCommands::inForwardChain()
{
	bool inChain = false;

	for (unsigned int i = 0; i < getTransmitCommands()->getCount(); i++) {
		auto cmd = (AppleCIOMeshTransmitCommand *)getTransmitCommands()->getObject(i);

		if ((void *)cmd != (void *)kOSBooleanFalse) {
			auto forwardAction = cmd->getForwardAction();
			if (forwardAction && forwardAction->chainElement != nullptr) {
				return true;
			}
		}
	}

	return false;
}

bool
AppleCIOMeshThunderboltCommands::isTxForwarding()
{
	return (_assignedInputMeshLink != -1) && (_forwardCount > 0);
}

void
AppleCIOMeshThunderboltCommands::markTxForwardIncomplete()
{
	bool expected = true;
	if (!atomic_compare_exchange_strong(&_forwardComplete, &expected, false)) {
		LOG("!!!!!! Attempted to mark forwardsComplete FALSE failed for buffer:%lld\n", _provider->getProvider()->getBufferId());
	}
}

bool
AppleCIOMeshThunderboltCommands::isTxForwardComplete()
{
	return atomic_load(&_forwardComplete);
}

void
AppleCIOMeshThunderboltCommands::addForwardNotifyIdx(int32_t forwardIdx, AppleCIOMeshForwarder * forwarder)
{
	ForwardAction * original  = nullptr;
	ForwardAction * newAction = nullptr;

	if (_forwardCount > 0) {
		original  = forwarder->getForwardAction((uint32_t)_forwardNotifyIdx[0]);
		newAction = forwarder->getForwardAction((uint32_t)forwardIdx);
	}

	if (_forwardCount >= sizeof(_forwardNotifyIdx) / sizeof(_forwardNotifyIdx[0])) {
		panic("Too many forward notifies... _forwardIdx %d _forwardCount %d (max %d)\n", forwardIdx, _forwardCount,
		      sizeof(_forwardNotifyIdx) / sizeof(_forwardNotifyIdx[0]));
	}

	_forwardNotifyIdx[_forwardCount] = forwardIdx;

	// Set the partner in the original
	if (original) {
		original->carryPartners[_forwardCount - 1] = newAction;
	}

	_forwardCount += 1;
}

void
AppleCIOMeshThunderboltCommands::notifyForwardComplete()
{
	if (atomic_fetch_add(&_forwardCompleteCount, 1) == _forwardCount - 1) {
		bool expected = false;
		if (!atomic_compare_exchange_strong(&_forwardComplete, &expected, true)) {
			LOG("!!!!!! Attempted to mark forwardsComplete TRUE failed for buffer:%lld\n", _provider->getProvider()->getBufferId());
		}
		atomic_store(&_forwardCompleteCount, 0);
	}
}

bool
AppleCIOMeshThunderboltCommands::finishedTxDispatch()
{
	return atomic_load(&_dispatchRemaining) == 0;
}

void
AppleCIOMeshThunderboltCommands::txDispatched()
{
	atomic_fetch_sub(&_dispatchRemaining, 1);
}

void
AppleCIOMeshThunderboltCommands::notifyRXFlowControl(AppleCIOMeshReceiveCommand * command, AppleCIOMeshForwarder * forwarder)
{
	if (!isTxForwarding()) {
		return;
	}

	// update the completed index of the receiving command
	int completedCommandIdx = command->updateFXReceivedIdx();

	// First one - this means the RX
	// Every other one is a flow RX complete
	if (completedCommandIdx == 0) {
		//		for (int i = 0; i < kForwardNodeCount; i++) {
		forwarder->markActionRxComplete(_forwardNotifyIdx[0]);
		//		}
	} else {
		//		for (int i = 0; i < kForwardNodeCount; i++) {
		forwarder->flowRxComplete(_forwardNotifyIdx[0]);
		//		}
	}
}
void
AppleCIOMeshThunderboltCommands::notifyTXFlowControl(AppleCIOMeshTransmitCommand * command, AppleCIOMeshForwarder * forwarder)
{
	if (!isTxForwarding()) {
		return;
	}

	// update the completed index of the transmitting command
	command->updateFXCompletedIdx();

	// drip into forwarder the TX has completed
	command->dripForwardComplete();
}

char *
AppleCIOMeshThunderboltCommands::getTrailer()
{
	return _trailerMem;
}

uint32_t
AppleCIOMeshThunderboltCommands::getTrailerLen()
{
	return _trailerSize;
}

// MARK: Thunderbolt Command Groups

AppleCIOMeshThunderboltCommandGroups *
AppleCIOMeshThunderboltCommandGroups::allocate(AppleCIOMeshSharedMemory * provider,
                                               AppleCIOMeshService * service,
                                               OSBoundedArrayRef<AppleCIOMeshLink *> meshLinks,
                                               const MUCI::SharedMemory & sharedMemory,
                                               task_t owningTask)
{
	auto tbtCommandGroup = OSTypeAlloc(AppleCIOMeshThunderboltCommandGroups);
	if (tbtCommandGroup != nullptr && !tbtCommandGroup->initialize(provider, service, meshLinks, sharedMemory, owningTask)) {
		OSSafeReleaseNULL(tbtCommandGroup);
	}
	return tbtCommandGroup;
}

bool
AppleCIOMeshThunderboltCommandGroups::initialize(AppleCIOMeshSharedMemory * provider,
                                                 AppleCIOMeshService * service,
                                                 OSBoundedArrayRef<AppleCIOMeshLink *> meshLinks,
                                                 const MUCI::SharedMemory & sharedMemory,
                                                 task_t owningTask)
{
	_provider     = provider;
	_service      = service;
	_sharedMemory = sharedMemory;
	_owningTask   = owningTask;
	_meshLinks    = meshLinks;

	IOOptionBits mdOptions = kIODirectionOutIn | kIOMemoryKernelUserShared | kIOMemoryPhysicallyContiguous | kIOMapAnywhere;
	_iomd = IOMemoryDescriptor::withAddressRange(sharedMemory.address, (mach_vm_size_t)sharedMemory.size, mdOptions, owningTask);
	if (_iomd == nullptr) {
		LOG("Failed to allocate MemoryDescriptor\n");
		return false;
	}
	_iomd->prepare(kIODirectionInOut);

	_meshTBTCommands = OSArray::withCapacity(((unsigned int)_sharedMemory.size / (unsigned int)_sharedMemory.chunkSize) + 1);
	if (_meshTBTCommands == nullptr) {
		LOG("Failed to allocate meshTBTCommands OSArray\n");
		OSSafeReleaseNULL(_iomd);
		return false;
	}

	return true;
}

void
AppleCIOMeshThunderboltCommandGroups::free()
{
	if (!_meshTBTCommands) {
		return;
	}
	for (int i = (int)_meshTBTCommands->getCount() - 1; i >= 0; i--) {
		_meshTBTCommands->removeObject((unsigned int)i);
	}
	OSSafeReleaseNULL(_meshTBTCommands);
	OSSafeReleaseNULL(_iomd);
	super::free();
}

bool
AppleCIOMeshThunderboltCommandGroups::allocateCommands(int64_t offset, uint64_t memoryOffset)
{
	IOMemoryDescriptor * subMD = nullptr;
	OSBoundedArray<IOMemoryDescriptor *, 64> subMDs;
	uint32_t idx                   = 0;
	uint32_t trailerSize           = _provider->getTrailerSize();
	uint32_t trailerAllocSize      = _provider->getTrailerAllocatedSize();
	char * trailerMem              = IONewZero(char, trailerAllocSize);
	IOMemoryDescriptor * trailerMD = nullptr;

	if (_sharedMemory.strideSkip == 0) {
		IOMemoryDescriptor * chunkMD;
		chunkMD = IOSubMemoryDescriptor::withSubRange(_iomd, (IOByteCount)memoryOffset, (mach_vm_size_t)_sharedMemory.chunkSize,
		                                              kIODirectionInOut);
		RETURN_IF_NULL(chunkMD, false, "Could not allocate chunkMD at offset: %lld\n", offset);

		subMDs[idx++] = chunkMD;

	} else {
		int64_t strideOffset = offset;
		int64_t remaining    = _sharedMemory.chunkSize;

		while (remaining > 0) {
			subMDs[idx] = IOSubMemoryDescriptor::withSubRange(_iomd, strideOffset, _sharedMemory.strideWidth, kIODirectionInOut);
			strideOffset += _sharedMemory.strideSkip;
			remaining -= _sharedMemory.strideWidth;
			idx++;
		}
	}

	if (trailerMem) {
		IOOptionBits trailerOptions = kIODirectionOutIn | kIOMapAnywhere;
		trailerMD = IOMemoryDescriptor::withAddressRange((mach_vm_address_t)trailerMem, (mach_vm_size_t)trailerAllocSize,
		                                                 trailerOptions, kernel_task);
	}

	if (trailerMD) {
		trailerMD->prepare(kIODirectionInOut);
		subMDs[idx++] = trailerMD;
	}

	subMD = IOMultiMemoryDescriptor::withDescriptors(subMDs.data(), idx, kIODirectionInOut);

	// release references that are now held by the subMD
	for (int i = 0; i < idx; i++) {
		OSSafeReleaseNULL(subMDs[i]);
	}

	RETURN_IF_NULL(subMD, false, "Could not allocate subdescriptor at offset: %lld\n", offset);

	MUCI::DataChunk chunk = {
	    .bufferId = _sharedMemory.bufferId, .offset = offset,
	    //	    .size     = subMD->getLength()
	};
	chunk.size = subMD->getLength();

	// note: this takes over ownership of trailerMem and will handle free'ing it
	AppleCIOMeshThunderboltCommands * commands = AppleCIOMeshThunderboltCommands::allocate(
	    this, _service, _meshLinks, subMD, chunk, trailerMem, trailerSize, trailerAllocSize);
	if (commands == nullptr) {
		LOG("Failed to allocate MeshThunderboltCommands\n");
		return false;
	}
	OSSafeReleaseNULL(subMD); // because the commands have a reference on it

	auto divisor = _sharedMemory.strideSkip == 0 ? (unsigned int)_sharedMemory.chunkSize : (unsigned int)_sharedMemory.strideWidth;

	_meshTBTCommands->setObject((unsigned int)offset / divisor, commands);
	OSSafeReleaseNULL(commands); // because the array retains it
	return true;
}

AppleCIOMeshReceiveCommand *
AppleCIOMeshThunderboltCommandGroups::getReceiveCommand(uint8_t linkIdx, int64_t offset)
{
	auto commands = (AppleCIOMeshThunderboltCommands *)_meshTBTCommands->getObject(_getOffsetIdx(offset));
	return (AppleCIOMeshReceiveCommand *)commands->getReceiveCommands()->getObject(linkIdx);
}

AppleCIOMeshTransmitCommand *
AppleCIOMeshThunderboltCommandGroups::getTransmitCommand(uint8_t linkIdx, int64_t offset)
{
	auto commands = (AppleCIOMeshThunderboltCommands *)_meshTBTCommands->getObject(_getOffsetIdx(offset));
	return (AppleCIOMeshTransmitCommand *)commands->getTransmitCommands()->getObject(linkIdx);
}

AppleCIOMeshThunderboltCommands *
AppleCIOMeshThunderboltCommandGroups::getCommands(int64_t offset)
{
	return (AppleCIOMeshThunderboltCommands *)_meshTBTCommands->getObject(_getOffsetIdx(offset));
}

IOMemoryDescriptor *
AppleCIOMeshThunderboltCommandGroups::getMD()
{
	return _iomd;
}

AppleCIOMeshSharedMemory *
AppleCIOMeshThunderboltCommandGroups::getProvider()
{
	return _provider;
}

AppleCIOMeshLink *
AppleCIOMeshThunderboltCommandGroups::getMeshLink(uint8_t linkIndex)
{
	return _meshLinks[linkIndex];
}

task_t
AppleCIOMeshThunderboltCommandGroups::getOwningTask()
{
	return _owningTask;
}

int64_t
AppleCIOMeshThunderboltCommandGroups::_getOffsetIdx(int64_t offset)
{
	auto divisor = _sharedMemory.strideSkip == 0 ? _sharedMemory.chunkSize : _sharedMemory.strideWidth;
	return offset / divisor;
}
