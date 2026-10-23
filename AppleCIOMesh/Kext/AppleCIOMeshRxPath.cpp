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

#include "AppleCIOMeshRxPath.h"
#include "AppleCIOMeshLink.h"
#include "AppleCIOMeshService.h"

#define LOG_PREFIX "AppleCIOMeshRxPath"
#include "Signpost.h"
#include "Util/Error.h"
#include "Util/Log.h"
#include "Util/ReturnCode.h"

OSDefineMetaClassAndStructors(AppleCIOMeshRxPath, AppleCIOMeshPath);

#define kAppleCIOMeshRxRingSize "mesh_rx_ring_size"
#define kAppleCIOMeshRxInterruptStride "mesh_rx_interrupt_stride"
#define kAppleCIOMeshE2EFlowControl "mesh_e2e_flow"

static const UInt32 kLaneRouting = IOThunderboltPath::kRoutingOptionUsePrimaryLane |
                                   IOThunderboltPath::kRoutingOptionUseSecondaryLane |
                                   IOThunderboltPath::kRoutingOptionUseInternalLinks;

AppleCIOMeshRxPath *
AppleCIOMeshRxPath::withLink(AppleCIOMeshLink * link,
                             Configuration & configuration,
                             IOThunderboltHopID sourceTxHopID,
                             IOThunderboltHopID destinationTxHopID)
{
	auto rxPath = OSTypeAlloc(AppleCIOMeshRxPath);
	if (rxPath != nullptr && !rxPath->initWithLink(link, configuration, sourceTxHopID, destinationTxHopID)) {
		OSSafeReleaseNULL(rxPath);
	}
	return rxPath;
}

bool
AppleCIOMeshRxPath::initWithLink(AppleCIOMeshLink * link,
                                 Configuration & configuration,
                                 IOThunderboltHopID sourceTxHopID,
                                 IOThunderboltHopID destinationTxHopID)
{
	if (!super::initWithLink(link, configuration)) {
		return false;
	}

	if (!PE_parse_boot_argn(kAppleCIOMeshRxRingSize, &_rxRingSize, sizeof(_rxRingSize))) {
		_rxRingSize = kRxRingSize;
	}
	if (!PE_parse_boot_argn(kAppleCIOMeshRxInterruptStride, &_rxInterruptStride, sizeof(_rxInterruptStride))) {
		_rxInterruptStride = kRxInterruptStride;
	}
	if (!PE_parse_boot_argn(kAppleCIOMeshE2EFlowControl, &_e2eFlowControlEnable, sizeof(_e2eFlowControlEnable))) {
		_e2eFlowControlEnable = kE2EFlowControlEnable;
	}

	IOReturn status = initPath(sourceTxHopID, destinationTxHopID);
	if (status != kIOReturnSuccess) {
		LOG("initRxPath() failed with status -> 0x%0x\n", status);
		deinitPath();
		return false;
	}

	return true;
}

void
AppleCIOMeshRxPath::free()
{
	deinitPath();
	super::free();
}

IOReturn
AppleCIOMeshRxPath::initPath(IOThunderboltHopID sourceTxHopID, IOThunderboltHopID destinationTxHopID)
{
	IOReturn status = kIOReturnSuccess;

	auto controller = _link->getController();
	auto xdLink     = _link->getXDLink();

	_queue = IOThunderboltReceiveQueue::withControllerAndWorkLoop(controller, _processingWorkloop);
	RETURN_IF_NULL(_queue, false, "create rx queue");

	_queue->enableRawMode(false);
	_queue->setFlags(0);
	_queue->setSOFPDFBitmask(0x2);
	_queue->setEOFPDFBitmask(0x4);
	_queue->setQueueType(2);
	_queue->setInterruptStride(_rxInterruptStride);
	_queue->setRingSize(_rxRingSize);
	_queue->setMaxFrameSize(kIOThunderboltMaxFrameSize);
	_queue->setTxE2EHopID(sourceTxHopID);
	_queue->enableE2EFlowControl(_e2eFlowControlEnable);
	status = _queue->allocate();
	RETURN_IF_FAIL(status, kIOReturnNoResources, "allocate rx queue");

	_path = IOThunderboltPath::withController(controller);
	RETURN_IF_NULL(_path, kIOReturnNoResources, "create IOThunderboltPath rx");

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

	IOThunderboltHopID destinationRxHopId = 0;
	status                                = _queue->getHopID(&destinationRxHopId);
	RETURN_IF_FAIL(status, status, "get rx hopID");

	IOThunderboltHopIDRange srcHopRange = {0};
	IOThunderboltHopIDRange dstHopRange = {0};

	srcHopRange.start = destinationTxHopID;
	srcHopRange.end   = destinationTxHopID;

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
	maxCredits      = MIN(maxCredits, _config.tbtCredits);
	_path->setInitialCredits(maxCredits);
	_path->setSourceInitialCredits(maxCredits);

	_path->setSourceHopIDRange(srcHopRange);
	_path->setDestinationHopIDRange(dstHopRange);
	_path->setSourcePort(srcPort);
	_path->setDestinationPort(destPort);
	status = _path->allocate();
	if (status != kIOReturnSuccess) {
		LOG("failed: (%x: %s) allocate rx path\n", status, ioReturnString(status));
		return status;
	}

	status = _path->activateSynchronous();
	if (status != kIOReturnSuccess) {
		LOG("failed: (%x: %s) activate rx path\n", status, ioReturnString(status));
		return status;
	}

	return status;
}

void
AppleCIOMeshRxPath::deinitPath()
{
	if (_queue != nullptr) {
		if (_queue->isStarted()) {
			LOG("_queue->stop() for _rxQueue:%p on %p\n", _queue, this);
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
				ERROR("_rxPath->deactivateSynchronous failed: %s\n", ioReturnString(status));
			}
			break;
		}

		default:
			// AppleThunderboltIP and AppleThunderoltSAT don't handle any other cases,
			// and neither do we (for now).
			break;
		}

		_path->deallocate();
		OSSafeReleaseNULL(_path);
	}
}

bool
AppleCIOMeshRxPath::start()
{
	IOReturn status = _queue->start();
	RETURN_IF_FAIL(status, false, "start RX queue");

	return true;
}

void
AppleCIOMeshRxPath::stop()
{
	_queue->stop();
}

void
AppleCIOMeshRxPath::submitPrepared()
{
	_queue->updateConsumerIndex();
}

void
AppleCIOMeshRxPath::submitPreparedPartial(__unused IOThunderboltCommand * command, __unused int64_t offset)
{
	panic("submitPreparedPartial is not supported on RX Path");
}

void
AppleCIOMeshRxPath::prepareCommand(IOThunderboltCommand * command)
{
	auto status = _queue->submit((IOThunderboltReceiveCommand *)command);
}

void
AppleCIOMeshRxPath::checkCompletion()
{
	_queue->checkNHIForData();
}

IOThunderboltReceiveQueue *
AppleCIOMeshRxPath::getQueue()
{
	return _queue;
}
