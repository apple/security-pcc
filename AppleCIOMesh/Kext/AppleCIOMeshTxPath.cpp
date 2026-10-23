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

#include "AppleCIOMeshTxPath.h"
#include "AppleCIOMeshChannel.h"
#include "AppleCIOMeshLink.h"
#include "AppleCIOMeshService.h"

#define LOG_PREFIX "AppleCIOMeshTxPath"
#include "Signpost.h"
#include "Util/Error.h"
#include "Util/Log.h"
#include "Util/ReturnCode.h"

OSDefineMetaClassAndStructors(AppleCIOMeshTxPath, AppleCIOMeshPath);

#define kAppleCIOMeshTxRingSize "mesh_tx_ring_size"
#define kAppleCIOMeshTxInterruptStride "mesh_tx_interrupt_stride"
#define kAppleCIOMeshE2EFlowControl "mesh_e2e_flow"

static const UInt32 kLaneRouting = IOThunderboltPath::kRoutingOptionUsePrimaryLane |
                                   IOThunderboltPath::kRoutingOptionUseSecondaryLane |
                                   IOThunderboltPath::kRoutingOptionUseInternalLinks;

AppleCIOMeshTxPath *
AppleCIOMeshTxPath::withLink(AppleCIOMeshLink * link, Configuration & configuration)
{
	auto path = OSTypeAlloc(AppleCIOMeshTxPath);
	if (path != nullptr && !path->initWithLink(link, configuration)) {
		OSSafeReleaseNULL(path);
	}
	return path;
}

bool
AppleCIOMeshTxPath::initWithLink(AppleCIOMeshLink * link, Configuration & configuration)
{
	if (!super::initWithLink(link, configuration)) {
		return false;
	}

	if (!PE_parse_boot_argn(kAppleCIOMeshTxRingSize, &_txRingSize, sizeof(_txRingSize))) {
		_txRingSize = kTxRingSize;
	}
	if (!PE_parse_boot_argn(kAppleCIOMeshTxInterruptStride, &_txInterruptStride, sizeof(_txInterruptStride))) {
		_txInterruptStride = kTxInterruptStride;
	}
	if (!PE_parse_boot_argn(kAppleCIOMeshE2EFlowControl, &_e2eFlowControlEnable, sizeof(_e2eFlowControlEnable))) {
		_e2eFlowControlEnable = kE2EFlowControlEnable;
	}

	atomic_store(&_txPathProducerIndexAccess, false);

	IOReturn status = initPath();
	if (status != kIOReturnSuccess) {
		LOG("initPath() failed with status -> 0x%0x\n", status);
		deinitPath();

		return false;
	}

	return true;
}

void
AppleCIOMeshTxPath::free()
{
	deinitPath();
	super::free();
}

void
AppleCIOMeshTxPath::getSourceHopID(IOThunderboltHopID * hopID)
{
	_queue->getHopID(hopID);
}

IOThunderboltHopID
AppleCIOMeshTxPath::getDestinationHopID()
{
	return _path->getAllocatedDestinationHopID();
}

IOReturn
AppleCIOMeshTxPath::initPath()
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
	_queue = IOThunderboltTransmitQueue::withControllerAndWorkLoop(controller, _processingWorkloop);
	RETURN_IF_NULL(_queue, kIOReturnNoResources, "could not make transmit queue");

	_queue->enableRawMode(false);
	_queue->setQueueType(2);
	_queue->setRingSize(_txRingSize);
	_queue->setInterruptStride(_txInterruptStride);
	_queue->setMaxFrameSize(kIOThunderboltMaxFrameSize);
	_queue->enableE2EFlowControl(_e2eFlowControlEnable);
	_queue->setFlags(0);
	status = _queue->allocate();
	RETURN_IF_FAIL(status, kIOReturnNoResources, "allocate tx queue");

	// Create the path
	_path = IOThunderboltPath::withController(controller);
	RETURN_IF_NULL(_path, kIOReturnNoResources, "create IOThunderboltPath");

	_path->setPriority(_config.tbtPriority);
	_path->setWeight(1);
	_path->setCounterEnable(IOThunderboltPath::kMaskNoPorts);
	_path->setDropPacketEnable(IOThunderboltPath::kMaskNoPorts);

	_path->setIngressFlowControlEnable(IOThunderboltPath::kMaskAllPorts);
	_path->setEgressFlowControlEnable(IOThunderboltPath::kMaskAllPorts);

	_path->setIngressSharedBufferingEnable(IOThunderboltPath::kMaskNoPorts);
	_path->setEgressSharedBufferingEnable(IOThunderboltPath::kMaskNoPorts);
	_path->setNonFlowControlledCredits(0);
	_path->setFlags(0);
	_path->setRoutingOptions(kLaneRouting);

	IOThunderboltHopID srcHopId = 0;
	status                      = _queue->getHopID(&srcHopId);
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
	maxCredits      = MIN(maxCredits, _config.tbtCredits);
	_path->setInitialCredits(maxCredits);
	_path->setSourceInitialCredits(maxCredits);

	_path->setSourceHopIDRange(srcHopRange);
	_path->setDestinationHopIDRange(dstHopRange);
	_path->setSourcePort(srcPort);
	_path->setDestinationPort(dstPort);
	status = _path->allocate();
	if (status != kIOReturnSuccess) {
		LOG("failed: (%x: %s) allocate tx path\n", status, ioReturnString(status));
		return status;
	}

	status = _path->activateSynchronous();
	if (status != kIOReturnSuccess) {
		LOG("failed: (%x: %s) activate tx path\n", status, ioReturnString(status));
		return status;
	}

	return kIOReturnSuccess;
}

void
AppleCIOMeshTxPath::deinitPath()
{
	if (_queue != nullptr) {
		if (_queue->isStarted()) {
			_queue->stop();
		}

		if (_queue->isAllocated()) {
			_queue->deallocate();
		}

		OSSafeReleaseNULL(_queue);
	}

	if (_path != nullptr) {
		switch (_path->getState()) {
		case IOThunderboltPath::kStateActivated: {
			IOReturn status = _path->deactivateSynchronous();
			if (status != kIOReturnSuccess) {
				ERROR("_path->deactivateSynchronous failed: %s\n", ioReturnString(status));
			}
			break;
		}

		default:
			// Thunderbolt doesn't handle any other cases, and neither do we (for now).
			break;
		}

		_path->deallocate();
		OSSafeReleaseNULL(_path);
	}
}

bool
AppleCIOMeshTxPath::start()
{
	IOReturn status = _queue->start();
	RETURN_IF_FAIL(status, false, "start TX queue");

	return true;
}

void
AppleCIOMeshTxPath::stop()
{
	_queue->stop();
}

void
AppleCIOMeshTxPath::submitPrepared()
{
	GOTO_FAIL_IF_FALSE(_queue->isStarted(), "Queue has not started");

	TRANSMIT_QUEUE_TR(_link->getRID(), 0, TRANSMIT_QUEUE_META_PRE_PIO_WRITE_ALL);
	_queue->updateProducerIndex();
	TRANSMIT_QUEUE_TR(_link->getRID(), 0, TRANSMIT_QUEUE_META_POST_PIO_WRITE_ALL);
	return;

fail:
	return;
}

void
AppleCIOMeshTxPath::submitPreparedPartial(IOThunderboltCommand * command, int64_t offset)
{
	IOThunderboltTransmitCommand * tmp = (IOThunderboltTransmitCommand *)command;

	TRANSMIT_QUEUE_TR(_link->getRID(), offset, TRANSMIT_QUEUE_META_PRE_PIO_WRITE_PARTIAL);
	_queue->updateProducerIndexForCommand(tmp);
	TRANSMIT_QUEUE_TR(_link->getRID(), offset, TRANSMIT_QUEUE_META_POST_PIO_WRITE_PARTIAL);

	return;
}

void
AppleCIOMeshTxPath::prepareCommand(IOThunderboltCommand * command)
{
	GOTO_FAIL_IF_FALSE(_queue->isStarted(), "Queue has not started");

	TRANSMIT_QUEUE_TR(_link->getRID(), 0, TRANSMIT_QUEUE_META_PRE_SUBMIT);
	_queue->submit((IOThunderboltTransmitCommand *)command);
	TRANSMIT_QUEUE_TR(_link->getRID(), 0, TRANSMIT_QUEUE_META_POST_SUBMIT);

fail:
	return;
}

void
AppleCIOMeshTxPath::checkCompletion()
{
	if (_startCompletionCheck()) {
		_queue->checkNHIForData();
		_endCompletionCheck();
	}
}

IOThunderboltTransmitQueue *
AppleCIOMeshTxPath::getQueue()
{
	return _queue;
}
