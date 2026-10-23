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
#include "AppleCIOMeshControlPath.h"
#include "AppleCIOMeshLink.h"
#include "AppleCIOMeshPath.h"
#include "AppleCIOMeshService.h"

#define LOG_PREFIX "AppleCIOMeshControlPath"
#include "Util/Error.h"
#include "Util/Log.h"
#include "Util/ReturnCode.h"

OSDefineMetaClassAndStructors(AppleCIOMeshControlPath, OSObject);

static const UInt32 kLaneRouting = IOThunderboltPath::kRoutingOptionUsePrimaryLane |
                                   IOThunderboltPath::kRoutingOptionUseSecondaryLane |
                                   IOThunderboltPath::kRoutingOptionUseInternalLinks;

AppleCIOMeshControlPath *
AppleCIOMeshControlPath::withLink(AppleCIOMeshLink * link)
{
	auto path = OSTypeAlloc(AppleCIOMeshControlPath);
	if (path != nullptr && !path->initWithLink(link)) {
		OSSafeReleaseNULL(path);
	}
	return path;
}

bool
AppleCIOMeshControlPath::initWithLink(AppleCIOMeshLink * link)
{
	_link = link;

	IOReturn status = initTx();
	bool retVal     = true;

	GOTO_FAIL_IF_FAIL(status, "failed to initialize tx control");

	status = initRx();
	if (status != kIOReturnSuccess) {
		ERROR("failed to initialize rx control");

		deinitTx();
		return status;
	}

	// Allocate all transmit/receive control commands
	retVal = initializeTransmitPool();
	GOTO_FAIL_IF_FALSE(retVal, "failed to initialize transmit pool");

	retVal = initializeReceivePool();
	GOTO_FAIL_IF_FALSE(retVal, "failed to initialize receive pool");

	return retVal;

fail:
	freeReceivePool();
	freeTransmitPool();
	deinitRx();
	deinitTx();

	return false;
}

void
AppleCIOMeshControlPath::free()
{
	freeReceivePool();
	freeTransmitPool();
	deinitRx();
	deinitTx();

	super::free();
}

void
AppleCIOMeshControlPath::start()
{
	_txQueue->start();
	_rxQueue->start();

	// Submit all receive commands to TBT to start receiving control messages
	int counter = 0;
	while (true) {
		auto command = _receivePool->getCommand(false);
		if (!command) {
			break;
		}

		auto meshCommand = OSRequiredCast(AppleCIOMeshReceiveControlCommand, command);
		if (_rxQueue->submit(meshCommand) != kIOReturnSuccess) {
			LOG("Failed to submit command into RX queue in init for counter: %d\n", counter);
			break;
		}
		counter++;
	}

	_started = true;
}

void
AppleCIOMeshControlPath::stop()
{
	_rxQueue->stop();
	_txQueue->stop();

	_started = false;
}

IOReturn
AppleCIOMeshControlPath::initTx()
{
	IOReturn status;

	auto controller = _link->getController();
	if (!controller) {
		LOG("_link->getController() failed with link: %p on %p\n", _link, this);
		return kIOReturnNoResources;
	}

	auto xdLink = _link->getXDLink();
	if (!xdLink) {
		LOG("_link->getXDLink() failed with link: %p on %p\n", _link, this);
		return kIOReturnNoResources;
	}

	// Create the queue
	_txQueue = IOThunderboltTransmitQueue::withController(controller);
	RETURN_IF_NULL(_txQueue, kIOReturnNoResources, "could not make transmit queue");

	_txQueue->enableRawMode(false);
	_txQueue->setQueueType(2);
	_txQueue->setRingSize(kNumControlCommands);
	_txQueue->setInterruptStride(kControlInterruptStride);
	_txQueue->setMaxFrameSize(kIOThunderboltMaxFrameSize);
	_txQueue->enableE2EFlowControl(kE2EFlowControlEnable);
	_txQueue->setFlags(0);
	status = _txQueue->allocate();
	RETURN_IF_FAIL(status, kIOReturnNoResources, "allocate tx queue");

	// Create the path
	_txPath = IOThunderboltPath::withController(controller);
	RETURN_IF_NULL(_txPath, kIOReturnNoResources, "create IOThunderboltPath");

	_txPath->setPriority(kControlPriority);
	_txPath->setWeight(1);
	_txPath->setCounterEnable(IOThunderboltPath::kMaskNoPorts);
	_txPath->setDropPacketEnable(IOThunderboltPath::kMaskNoPorts);

	_txPath->setIngressFlowControlEnable(IOThunderboltPath::kMaskAllPorts);
	_txPath->setEgressFlowControlEnable(IOThunderboltPath::kMaskAllPorts);

	_txPath->setIngressSharedBufferingEnable(IOThunderboltPath::kMaskNoPorts);
	_txPath->setEgressSharedBufferingEnable(IOThunderboltPath::kMaskNoPorts);
	_txPath->setNonFlowControlledCredits(0);
	_txPath->setFlags(0);
	_txPath->setRoutingOptions(kLaneRouting);

	IOThunderboltHopID srcHopId = 0;
	status                      = _txQueue->getHopID(&srcHopId);
	RETURN_IF_FAIL(status, status, "getHopId");

	IOThunderboltHopIDRange srcHopRange = {0};
	srcHopRange.start                   = srcHopId;
	srcHopRange.end                     = srcHopId;

	IOThunderboltHopIDRange dstHopRange = {0};
	dstHopRange.start                   = kIOThunderboltMinNonReservedHopID;
	dstHopRange.end                     = kIOThunderboltMaxHopID;

	IOThunderboltPort * srcPort = controller->getNHIPort();
	RETURN_IF_NULL(srcPort, kIOReturnError, "get src_port");

	IOThunderboltPort * dstPort = OSDynamicCast(IOThunderboltPort, xdLink->getProvider());
	RETURN_IF_NULL(dstPort, kIOReturnError, "get dest_port");

	auto maxCredits = MIN(srcPort->getMaxCredits(), dstPort->getMaxCredits());
	maxCredits      = MIN(maxCredits, kControlCredits);
	_txPath->setInitialCredits(maxCredits);
	_txPath->setSourceInitialCredits(maxCredits);

	_txPath->setSourceHopIDRange(srcHopRange);
	_txPath->setDestinationHopIDRange(dstHopRange);
	_txPath->setSourcePort(srcPort);
	_txPath->setDestinationPort(dstPort);
	status = _txPath->allocate();
	if (status != kIOReturnSuccess) {
		LOG("failed: (%x: %s) allocate tx path\n", status, ioReturnString(status));
		return status;
	}

	status = _txPath->activateSynchronous();
	if (status != kIOReturnSuccess) {
		LOG("failed: (%x: %s) activate tx path\n", status, ioReturnString(status));
		return status;
	}

	return kIOReturnSuccess;
}

void
AppleCIOMeshControlPath::deinitTx()
{
	if (_txQueue != nullptr) {
		if (_txQueue->isStarted()) {
			_txQueue->stop();
		}

		if (_txQueue->isAllocated()) {
			_txQueue->deallocate();
		}

		OSSafeReleaseNULL(_txQueue);
		_txQueue = nullptr;
	}

	if (_txPath != nullptr) {
		switch (_txPath->getState()) {
		case IOThunderboltPath::kStateActivated: {
			IOReturn status = _txPath->deactivateSynchronous();
			if (status != kIOReturnSuccess) {
				ERROR("_path->deactivateSynchronous failed: %s\n", ioReturnString(status));
			}
			break;
		}

		default:
			// Thunderbolt doesn't handle any other cases, and neither do we (for now).
			break;
		}

		_txPath->deallocate();
		OSSafeReleaseNULL(_txPath);
		_txPath = nullptr;
	}
}

IOReturn
AppleCIOMeshControlPath::initRx()
{
	IOReturn status = kIOReturnSuccess;

	auto controller = _link->getController();
	auto xdLink     = _link->getXDLink();
	IOThunderboltHopID txHopId;
	_txQueue->getHopID(&txHopId);

	_rxQueue = IOThunderboltReceiveQueue::withController(controller);
	RETURN_IF_NULL(_rxQueue, false, "create rx queue");

	_rxQueue->enableRawMode(false);
	_rxQueue->setFlags(0);
	_rxQueue->setSOFPDFBitmask(0x2);
	_rxQueue->setEOFPDFBitmask(0x4);
	_rxQueue->setQueueType(2);
	_rxQueue->setInterruptStride(kControlInterruptStride);
	_rxQueue->setRingSize(kNumControlCommands);
	_rxQueue->setMaxFrameSize(kIOThunderboltMaxFrameSize);
	_rxQueue->setTxE2EHopID(txHopId);
	_rxQueue->enableE2EFlowControl(kE2EFlowControlEnable);
	status = _rxQueue->allocate();
	RETURN_IF_FAIL(status, kIOReturnNoResources, "allocate rx queue");

	_rxPath = IOThunderboltPath::withController(controller);
	RETURN_IF_NULL(_rxPath, kIOReturnNoResources, "create IOThunderboltPath rx");

	_rxPath->setPriority(kControlPriority);
	_rxPath->setWeight(1);

	_rxPath->setCounterEnable(IOThunderboltPath::kMaskNoPorts);
	_rxPath->setDropPacketEnable(IOThunderboltPath::kMaskNoPorts);
	_rxPath->setIngressFlowControlEnable(IOThunderboltPath::kMaskAllPorts);
	_rxPath->setEgressFlowControlEnable(IOThunderboltPath::kMaskAllPorts);
	_rxPath->setIngressSharedBufferingEnable(IOThunderboltPath::kMaskNoPorts);
	_rxPath->setEgressSharedBufferingEnable(IOThunderboltPath::kMaskNoPorts);
	_rxPath->setNonFlowControlledCredits(0);
	_rxPath->setFlags(0);
	_rxPath->setRoutingOptions(kLaneRouting);

	IOThunderboltHopID destinationRxHopId = 0;
	status                                = _rxQueue->getHopID(&destinationRxHopId);
	RETURN_IF_FAIL(status, status, "get rx hopID");

	IOThunderboltHopIDRange srcHopRange = {0};
	IOThunderboltHopIDRange dstHopRange = {0};

	srcHopRange.start = _txPath->getAllocatedDestinationHopID();
	srcHopRange.end   = _txPath->getAllocatedDestinationHopID();

	dstHopRange.start = destinationRxHopId;
	dstHopRange.end   = destinationRxHopId;

	auto srcPort = OSDynamicCast(IOThunderboltPort, xdLink->getProvider());
	RETURN_IF_NULL(srcPort, kIOReturnError, "src port");

	auto destPort = controller->getNHIPort();
	if (!destPort) {
		LOG("controller->getNHIPort() failed for controller: %p on %p\n", controller, this);
		return kIOReturnNoResources;
	}

	auto maxCredits = MIN(srcPort->getMaxCredits(), destPort->getMaxCredits());
	maxCredits      = MIN(maxCredits, kControlCredits);
	_rxPath->setInitialCredits(maxCredits);
	_rxPath->setSourceInitialCredits(maxCredits);

	_rxPath->setSourceHopIDRange(srcHopRange);
	_rxPath->setDestinationHopIDRange(dstHopRange);
	_rxPath->setSourcePort(srcPort);
	_rxPath->setDestinationPort(destPort);
	status = _rxPath->allocate();
	if (status != kIOReturnSuccess) {
		LOG("failed: (%x: %s) allocate rx path\n", status, ioReturnString(status));
		return status;
	}

	status = _rxPath->activateSynchronous();
	if (status != kIOReturnSuccess) {
		LOG("failed: (%x: %s) activate rx path\n", status, ioReturnString(status));
		return status;
	}

	return status;
}

void
AppleCIOMeshControlPath::deinitRx()
{
	if (_rxQueue != nullptr) {
		if (_rxQueue->isStarted()) {
			LOG("_queue->stop() for _rxQueue:%p on %p\n", _rxQueue, this);
			_rxQueue->stop();
		}

		if (_rxQueue->isAllocated()) {
			_rxQueue->deallocate();
		}

		OSSafeReleaseNULL(_rxQueue);
		_rxQueue = nullptr;
	}

	if (_rxPath != nullptr) {
		switch (_rxPath->getState()) {
		case IOThunderboltPath::kStateActivated: {
			IOReturn status = _rxPath->deactivateSynchronous();
			if (status != kIOReturnSuccess) {
				ERROR("_rxPath->deactivateSynchronous failed: %s\n", ioReturnString(status));
			}
			break;
		}

		default:
			// AppleThunderboltIP and AppleThunderoltSAT don't handle any other cases,
			// and neither do we (for now).
			break;
		}

		_rxPath->deallocate();
		OSSafeReleaseNULL(_rxPath);
		_rxPath = nullptr;
	}
}

bool
AppleCIOMeshControlPath::initializeTransmitPool()
{
	_transmitPool = IOCommandPool::withWorkLoop(_link->getController()->getWorkLoop());
	if (!_transmitPool) {
		return false;
	}

	IOThunderboltTransmitCommand::Completion completion = {0};
	completion.target                                   = _link->getService();
	completion.action =
	    OSMemberFunctionCast(IOThunderboltTransmitCommand::Action, _link->getService(), &AppleCIOMeshService::controlSent);
	completion.parameter = this;

	for (UInt32 i = 0; i < kNumControlCommands; i++) {
		auto command = AppleCIOMeshTransmitControlCommand::allocate(this);
		command->setCompletion(completion);
		command->setLength(kCommandBufferSize);
		command->setSOF(kSOF);
		command->setEOF(kEOF);
		_transmitPool->returnCommand(command);
	}

	return true;
}

bool
AppleCIOMeshControlPath::initializeReceivePool()
{
	_receivePool = IOCommandPool::withWorkLoop(_link->getController()->getWorkLoop());
	if (!_receivePool) {
		return false;
	}

	IOThunderboltReceiveCommand::Completion completion = {0};
	completion.target                                  = _link->getService();
	completion.action =
	    OSMemberFunctionCast(IOThunderboltReceiveCommand::Action, _link->getService(), &AppleCIOMeshService::controlReceived);
	completion.parameter = this;

	for (UInt32 i = 0; i < kNumControlCommands; i++) {
		auto command = AppleCIOMeshReceiveControlCommand::allocate(this);
		command->setCompletion(completion);
		command->setLength(kCommandBufferSize);
		_receivePool->returnCommand(command);
	}

	return true;
}

void
AppleCIOMeshControlPath::freeTransmitPool()
{
	if (_transmitPool == nullptr) {
		LOG("ControlPath %p (link rid %d) has a null transmitPool\n", this, (int)_link->getRID());
	}

	while (_transmitPool) {
		auto command = OSRequiredCast(AppleCIOMeshTransmitControlCommand, _transmitPool->getCommand(false));
		if (command != nullptr) {
			command->setMemoryDescriptor(nullptr);
		} else {
			break;
		}
		OSSafeReleaseNULL(command);
	}
	OSSafeReleaseNULL(_transmitPool);
	_transmitPool = nullptr;
}

void
AppleCIOMeshControlPath::freeReceivePool()
{
	if (_receivePool == nullptr) {
		LOG("ControlPath %p (link rid %d) has a null receivePool\n", this, (int)_link->getRID());
	}

	while (_receivePool) {
		auto command = OSRequiredCast(AppleCIOMeshReceiveControlCommand, _receivePool->getCommand(false));
		if (command != nullptr) {
			command->setMemoryDescriptor(nullptr);
		} else {
			break;
		}
		OSSafeReleaseNULL(command);
	}
	OSSafeReleaseNULL(_receivePool);
	_receivePool = nullptr;
}

void
AppleCIOMeshControlPath::queueRxCommand(AppleCIOMeshReceiveControlCommand * command)
{
	if (_rxQueue && _rxQueue->submit(command) != kIOReturnSuccess) {
		LOG("Failed to submit command into RX queue\n");
	}
}

IOReturn
AppleCIOMeshControlPath::submitControlCommand(MeshControlCommand * controlCommand)
{
	if (_transmitPool == nullptr) {
		return kIOReturnNoResources;
	}
	auto command = OSRequiredCast(AppleCIOMeshTransmitControlCommand, _transmitPool->getCommand(false));
	if (command == nullptr) {
		return kIOReturnNoResources;
	}

	auto commandBuffer      = OSRequiredCast(IOBufferMemoryDescriptor, command->getMemoryDescriptor());
	auto commandBufferBytes = reinterpret_cast<UInt8 *>(commandBuffer->getBytesNoCopy());
	memcpy(commandBufferBytes, controlCommand, sizeof(*controlCommand));

	auto retVal = _txQueue->submit(command);
	if (retVal != kIOReturnSuccess) {
		LOG("Failed to send command: %d\n", controlCommand->commandType);
	}
	return retVal;
}

IOReturn
AppleCIOMeshControlPath::submitControlMessage(MeshControlMessage * controlMessage)
{
	if (_transmitPool == nullptr) {
		return kIOReturnNoResources;
	}
	auto command = OSRequiredCast(AppleCIOMeshTransmitControlCommand, _transmitPool->getCommand(false));
	if (command == nullptr) {
		return kIOReturnNoResources;
	}

	auto commandBuffer      = OSRequiredCast(IOBufferMemoryDescriptor, command->getMemoryDescriptor());
	auto commandBufferBytes = reinterpret_cast<UInt8 *>(commandBuffer->getBytesNoCopy());
	memcpy(commandBufferBytes, controlMessage, sizeof(*controlMessage));

	auto retVal = _txQueue->submit(command);
	if (retVal != kIOReturnSuccess) {
		LOG("Failed to send message to node %d\n", controlMessage->header.data.controlMessage.destinationNode);
	}
	return retVal;
}

void
AppleCIOMeshControlPath::returnControlCommand(AppleCIOMeshTransmitControlCommand * command)
{
	if (_transmitPool != nullptr) {
		_transmitPool->returnCommand(command);
	}
}

IOThunderboltController *
AppleCIOMeshControlPath::getController()
{
	return _link->getController();
}

AppleCIOMeshLink *
AppleCIOMeshControlPath::getLink()
{
	return _link;
}
