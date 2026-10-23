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

#include "AppleCIOMeshLink.h"
#include "AppleCIOMeshChannel.h"
#include "AppleCIOMeshControlPath.h"
#include "AppleCIOMeshRxPath.h"
#include "AppleCIOMeshService.h"
#include "AppleCIOMeshSharedMemory.h"
#include "AppleCIOMeshThunderboltCommands.h"
#include "AppleCIOMeshTxPath.h"
#include "Signpost.h"

#define LOG_PREFIX "AppleCIOMeshLink"
#include "Util/Error.h"
#include "Util/Log.h"
#include "Util/ReturnCode.h"

#include <IOKit/IOPlatformExpert.h>

OSDefineMetaClassAndStructors(AppleCIOMeshLink, IOService);

#define kAppleCIOMeshConnectedNodeProperty "connectedNode"
#define kAppleCIOMeshChannelAssignedProperty "channel"
#define kAppleCIOMeshDataPathCredits "mesh_data_credits"

#define kRegistrationInitializationDelayMs (5000)
#define kRegistrationControlPathDelayMs (1000)
#define kRegistrationRetryDelayMs (5000)
#define kMeshMatchingWaitingTimeNs (30LL * 1000000000LL)

IOService *
AppleCIOMeshLink::probe(IOService * provider, __unused SInt32 * probe)
{
	LOG("probe\n");

	auto serviceMatch = IOService::serviceMatching("AppleCIOMeshService");
	auto service      = IOService::waitForMatchingService(serviceMatch, kMeshMatchingWaitingTimeNs);
	OSSafeReleaseNULL(serviceMatch);

	if (service == nullptr) {
		LOG("mesh service not available, not matching link\n")
		return nullptr;
	}

	auto meshService = OSRequiredCast(AppleCIOMeshService, service);
	auto xdService   = OSRequiredCast(IOThunderboltXDomainService, provider);
	auto acio        = xdService->getController()->getRID();

	if (meshService->acioDisabled(acio)) {
		LOG("acio%d has been disabled\n", acio)
		OSSafeReleaseNULL(service);
		return nullptr;
	}

	OSSafeReleaseNULL(service);
	return this;
}

bool
AppleCIOMeshLink::start(IOService * provider)
{
	auto xdService                   = OSRequiredCast(IOThunderboltXDomainService, provider);
	_tbtController                   = xdService->getController();
	OSNumber * connectedNodeId       = nullptr;
	uint32_t connectedNode           = 0;
	OSPtr<OSDictionary> serviceMatch = nullptr;

	IOServiceMatchingNotificationHandler handler =
	    OSMemberFunctionCast(IOServiceMatchingNotificationHandler, this, &AppleCIOMeshLink::_serviceRegistered);

	_registered                = false;
	_mismatchedHardwarePartner = false;
	_connectedHardwareNode     = kNonDCHardwarePlatform;

	LOG("[%p] start() %d\n", this, _tbtController->getRID());

	//
	// Do not match when the system is shutting down.
	//
	if (IOPMRootDomainGetWillShutdown()) {
		LOG("IOPMRootDomainGetWillShutdown() for AppleCIOMeshLink: (%p)\n", this);
		return false;
	}

	bool result = super::start(provider);
	if (!result) {
		return false;
	}

	auto registrationHandler = OSMemberFunctionCast(IOTimerEventSource::Action, this, &AppleCIOMeshLink::_registrationHandler);
	_registrationEventSource = IOTimerEventSource::timerEventSource(this, registrationHandler);
	if (!_registrationEventSource) {
		LOG("Failed to make registration event source");
	}
	getWorkLoop()->addEventSource(_registrationEventSource);
	_registrationState = RegistrationState::Initialized;

	_xdLink = OSRequiredCast(IOThunderboltXDomainLink, xdService->getProvider());
	_xdLink->retain();

	AppleCIOMeshPath::Configuration dataPathConfig = {
	    .tbtCredits  = 55,
	    .tbtPriority = 2,
	};

	if (!PE_parse_boot_argn(kAppleCIOMeshDataPathCredits, &dataPathConfig.tbtCredits, sizeof(dataPathConfig.tbtCredits))) {
		dataPathConfig.tbtCredits = 55;
	}

	for (int i = 0; i < kNumDataPaths; i++) {
		_txDataPaths[i] = AppleCIOMeshTxPath::withLink(this, dataPathConfig);
		GOTO_FAIL_IF_NULL(_txDataPaths[i], "could not allocate _txDataPaths[%d]", i);

		IOThunderboltHopID txSourceHop;
		IOThunderboltHopID txDestinationHop = _txDataPaths[i]->getDestinationHopID();
		_txDataPaths[i]->getSourceHopID(&txSourceHop);

		_rxDataPaths[i] = AppleCIOMeshRxPath::withLink(this, dataPathConfig, txSourceHop, txDestinationHop);
		GOTO_FAIL_IF_NULL(_rxDataPaths[i], "could not allocate _txDataPaths[%d]", i);

		_txDataPaths[i]->start();
		_rxDataPaths[i]->start();
	}
	LOG("Finished creating MeshLink on acio%d\n", _tbtController->getRID());

	serviceMatch         = IOService::serviceMatching("AppleCIOMeshService");
	_meshServiceNotifier = IOService::addMatchingNotification(gIOPublishNotification, serviceMatch, handler, this);
	OSSafeReleaseNULL(serviceMatch);
	GOTO_FAIL_IF_NULL(_meshServiceNotifier, "Failed to make mesh service notifier");

	atomic_store(&_rxDescriptorsAccess, false);
	atomic_store(&_txReserved, false);

	_rid = getController()->getRID();

	return true;

fail:
	OSSafeReleaseNULL(_controlPath);
	_controlPath = NULL;

	for (int i = 0; i < kNumDataPaths; i++) {
		OSSafeReleaseNULL(_rxDataPaths[i]);
		_rxDataPaths[i] = NULL;
		OSSafeReleaseNULL(_txDataPaths[i]);
		_txDataPaths[i] = NULL;
	}
	OSSafeReleaseNULL(_xdLink);
	_xdLink = NULL;
	return false;
}

void
AppleCIOMeshLink::stop(__unused IOService * provider)
{
	LOG("[%p] stop() %d %p %p %p %p\n", this, _tbtController->getRID(), _meshServiceNotifier, _registrationEventSource,
	    _controlPath, _meshService);
	if (_meshServiceNotifier) {
		// Remove also releases the object.
		_meshServiceNotifier->remove();
		_meshServiceNotifier = nullptr;
	}

	_registrationEventSource->cancelTimeout();
	if (_controlPath) {
		_controlPath->stop();
	}

	if (_meshService) {
		_meshService->unregisterLink(_tbtController->getRID());
	}

	for (int i = 0; i < kNumDataPaths; i++) {
		if (_rxDataPaths[i]) {
			_rxDataPaths[i]->stop();
		}
		if (_txDataPaths[i]) {
			_txDataPaths[i]->stop();
		}
	}
}

bool
AppleCIOMeshLink::_serviceRegistered(__unused void * refCon, IOService * newService, __unused IONotifier * notifier)
{
	if (!newService) {
		LOG("invalid service registered\n");
		return false;
	}

	auto meshService = OSDynamicCast(AppleCIOMeshService, newService);
	if (!meshService) {
		LOG("service does not match AppleCIOMeshService\n");
		return false;
	}

	RETURN_IF_FALSE(_setService(meshService), false, "Failed to register meshlink[%d] with meshService\n",
	                getController()->getRID());

	_registered = true;
	LOG("Successfully registered meshLink[%d] with meshService\n", getController()->getRID());
	return true;
}

bool
AppleCIOMeshLink::willTerminate(IOService * provider, IOOptionBits options)
{
	return super::willTerminate(provider, options);
}

bool
AppleCIOMeshLink::didTerminate(IOService * provider, IOOptionBits options, bool * defer)
{
	return super::didTerminate(provider, options, defer);
}

void
AppleCIOMeshLink::free()
{
	OSSafeReleaseNULL(_controlPath);
	_controlPath = nullptr;
	for (int i = 0; i < kNumDataPaths; i++) {
		OSSafeReleaseNULL(_rxDataPaths[i]);
		_rxDataPaths[i] = nullptr;
		OSSafeReleaseNULL(_txDataPaths[i]);
		_txDataPaths[i] = nullptr;
	}
	OSSafeReleaseNULL(_xdLink);
	_xdLink = nullptr;
	super::free();
}

void
AppleCIOMeshLink::restartDataPath()
{
	for (int i = 0; i < kNumDataPaths; i++) {
		_rxDataPaths[i]->stop();
		_txDataPaths[i]->stop();
	}

	for (int i = 0; i < kNumDataPaths; i++) {
		_txDataPaths[i]->start();
		_rxDataPaths[i]->start();
	}
}

void
AppleCIOMeshLink::startDataPath()
{
	for (int i = 0; i < kNumDataPaths; i++) {
		_txDataPaths[i]->start();
		_rxDataPaths[i]->start();
	}
}

void
AppleCIOMeshLink::stopDataPath()
{
	for (int i = 0; i < kNumDataPaths; i++) {
		_rxDataPaths[i]->stop();
		_txDataPaths[i]->stop();
	}
}

void
AppleCIOMeshLink::_startControlPath()
{
	if (_registrationState != RegistrationState::ControlPathStarting) {
		panic("Link[%d] registrationState is not ControlPathStarting but: %x\n", getController()->getRID(),
		      (int)_registrationState);
	}
	LOG("Starting control path on link[%d]\n", getController()->getRID());
	_controlPath->start();
}

void
AppleCIOMeshLink::_startRegistrationSequence()
{
	if (!_meshService->isActive()) {
		return;
	}

	if (_registrationState != RegistrationState::RegistrationStarting) {
		panic("Link[%d] registrationState is not RegistrationStarting but: %x\n", getController()->getRID(),
		      (int)_registrationState);
	}
	LOG("Starting registration sequence on link[%d]\n", getController()->getRID());

	MeshControlCommand nodeIdRequest;
	nodeIdRequest.commandType = MeshControlCommandType::NodeIdentificationRequest;
	_controlPath->submitControlCommand(&nodeIdRequest);
}

uint8_t
AppleCIOMeshLink::getRID()
{
	return _rid;
}

uint8_t
AppleCIOMeshLink::getLinkIdx()
{
	if (_channel->getLinkIndex(0) == getRID()) {
		return 0;
	}
	return 1;
}

IOThunderboltController *
AppleCIOMeshLink::getController()
{
	return _tbtController;
}

IOThunderboltXDomainLink *
AppleCIOMeshLink::getXDLink()
{
	return _xdLink;
}

AppleCIOMeshService *
AppleCIOMeshLink::getService()
{
	return _meshService;
}

IOWorkLoop *
AppleCIOMeshLink::getServiceWorkloop()
{
	return _meshService->getWorkLoop();
}

MCUCI::NodeId
AppleCIOMeshLink::getConnectedNodeId()
{
	return _connectedNode;
}

AppleCIOMeshChannel *
AppleCIOMeshLink::getChannel()
{
	return _channel;
}

void
AppleCIOMeshLink::getChassisId(MCUCI::ChassisId * chassis)
{
	memcpy(chassis, &_connectedChassis, sizeof(_connectedChassis));
}

bool
AppleCIOMeshLink::hasPendingLinkId()
{
	return _hasPendingLinkId;
}

bool
AppleCIOMeshLink::getPendingLinkId(LinkIdentificationCommand * cmd)
{
	if (!_hasPendingLinkId) {
		return false;
	}

	_hasPendingLinkId = false;
	cmd->linkIdx      = _pendingLinkId.linkIdx;
	cmd->nodeId       = _pendingLinkId.nodeId;
	return true;
}

void
AppleCIOMeshLink::setConnectedNodeId(MCUCI::NodeId node)
{
	getWorkLoop()->runActionBlock(^IOReturn {
	  setProperty(kAppleCIOMeshConnectedNodeProperty, (void *)&node, sizeof(node));

	  _connectedNode    = node;
	  _hasConnectedNode = true;

	  _registrationState = RegistrationState::PartnerIdentified;

	  return kIOReturnSuccess;
	});
}

// This does not need to be behind the workloop since it is a
// dumb set that doesn't trigger any state changes.
void
AppleCIOMeshLink::setConnectedChassisId(MCUCI::ChassisId chassis)
{
	memcpy(&_connectedChassis, &chassis, sizeof(chassis));
}

bool
AppleCIOMeshLink::isMismatchedHardwarePartner()
{
	return _mismatchedHardwarePartner;
}

void
AppleCIOMeshLink::setMismatchedHardwareParther(bool mismatch)
{
	_mismatchedHardwarePartner = mismatch;
}

HardwareNodeId
AppleCIOMeshLink::getConnectedHardwareNodeId()
{
	return _connectedHardwareNode;
}

void
AppleCIOMeshLink::setConnectedHardwareNodeId(HardwareNodeId node)
{
	_connectedHardwareNode = node;
}

bool
AppleCIOMeshLink::hasConnectedNodeId()
{
	return _hasConnectedNode;
}

void
AppleCIOMeshLink::setChannel(AppleCIOMeshChannel * channel)
{
	setProperty(kAppleCIOMeshChannelAssignedProperty, channel->getChannelIndex(), sizeof(MCUCI::MeshChannelIdx));

	_channel = channel;
}

void
AppleCIOMeshLink::setPendingLinkId(LinkIdentificationCommand * command)
{
	if (_hasPendingLinkId) {
		return;
	}

	_hasPendingLinkId      = true;
	_pendingLinkId.linkIdx = command->linkIdx;
	_pendingLinkId.nodeId  = command->nodeId;
}

bool
AppleCIOMeshLink::_setService(AppleCIOMeshService * service)
{
	if (this == nullptr) {
		panic("this is null\n");
	}
	_meshService = service;

	GOTO_FAIL_IF_FAIL(_meshService->registerLink(this, _tbtController->getRID()), "Failed to register link with meshService");

	_controlPath = AppleCIOMeshControlPath::withLink(this);
	GOTO_FAIL_IF_NULL(_controlPath, "failed to make control path");

	_registrationState = RegistrationState::WaitingForInitializationComplete;
	_registrationEventSource->setTimeoutMS(kRegistrationInitializationDelayMs);

	return true;

fail:
	return false;
}

uint32_t
AppleCIOMeshLink::assignRxNode(MCUCI::NodeId node)
{
	// check if previously assigned before assigning
	for (uint32_t i = 0; i < kNumDataPaths; i++) {
		if (_rxDataPaths[i]->getAssignedNode() == node) {
			return i;
		}
	}

	for (uint32_t i = 0; i < kNumDataPaths; i++) {
		if (_rxDataPaths[i]->getAssignedNode() == MCUCI::kUnassignedNode) {
			_rxDataPaths[i]->assignNode(node);
			return i;
		}
	}

	return MCUCI::kUnassignedNode;
}

uint32_t
AppleCIOMeshLink::assignTxNode(MCUCI::NodeId node)
{
	// check if previously assigned before assigning
	for (uint32_t i = 0; i < kNumDataPaths; i++) {
		if (_txDataPaths[i]->getAssignedNode() == node) {
			return i;
		}
	}

	for (uint32_t i = 0; i < kNumDataPaths; i++) {
		if (_txDataPaths[i]->getAssignedNode() == MCUCI::kUnassignedNode) {
			_txDataPaths[i]->assignNode(node);
			return i;
		}
	}

	return MCUCI::kUnassignedNode;
}

uint32_t
AppleCIOMeshLink::getTxPathAssignment(MCUCI::NodeId node)
{
	for (uint32_t i = 0; i < kNumDataPaths; i++) {
		if (_txDataPaths[i]->getAssignedNode() == node) {
			return i;
		}
	}

	return MCUCI::kUnassignedNode;
}

uint32_t
AppleCIOMeshLink::getRxPathAssignment(MCUCI::NodeId node)
{
	for (uint32_t i = 0; i < kNumDataPaths; i++) {
		if (_rxDataPaths[i]->getAssignedNode() == node) {
			return i;
		}
	}

	return MCUCI::kUnassignedNode;
}

IOThunderboltReceiveQueue *
AppleCIOMeshLink::getRXQueue(MCUCI::NodeId node)
{
	for (int i = 0; i < kNumDataPaths; i++) {
		if (_rxDataPaths[i]->getAssignedNode() == node) {
			return _rxDataPaths[i]->getQueue();
		}
	}
	FAIL("No data path assigned for %d\n", node);
	return nullptr;
}

IOThunderboltTransmitQueue *
AppleCIOMeshLink::getTXQueue(MCUCI::NodeId node)
{
	for (int i = 0; i < kNumDataPaths; i++) {
		if (_txDataPaths[i]->getAssignedNode() == node) {
			return _txDataPaths[i]->getQueue();
		}
	}
	FAIL("No data path assigned for %d\n", node);
	return nullptr;
}

IOReturn
AppleCIOMeshLink::sendData(MCUCI::NodeId node, int64_t offset, IOThunderboltTransmitCommand * transmitCommand)
{
	for (int i = 0; i < kNumDataPaths; i++) {
		if (_txDataPaths[i]->getAssignedNode() == node) {
			if (transmitCommand == nullptr) {
				_txDataPaths[i]->submitPrepared();
			} else {
				_txDataPaths[i]->submitPreparedPartial(transmitCommand, offset);
			}
			return kIOReturnSuccess;
		}
	}

	FAIL("No data path assigned for %d\n", node);
	return kIOReturnError;
}

void
AppleCIOMeshLink::prepareTXCommand(MCUCI::NodeId node, IOThunderboltTransmitCommand * command)
{
	for (int i = 0; i < kNumDataPaths; i++) {
		if (_txDataPaths[i]->getAssignedNode() == node) {
			_txDataPaths[i]->prepareCommand(command);
			return;
		}
	}
	panic("No data path assigned for node:%d link:%d\n", node, getRID());
}

void
AppleCIOMeshLink::sendPreparedRXCommand(MCUCI::NodeId node)
{
	for (int i = 0; i < kNumDataPaths; i++) {
		if (_rxDataPaths[i]->getAssignedNode() == node) {
			_rxDataPaths[i]->submitPrepared();
			return;
		}
	}
}

void
AppleCIOMeshLink::prepareRXCommand(MCUCI::NodeId node, IOThunderboltReceiveCommand * command)
{
	bool expected = false;
	while (!atomic_compare_exchange_strong(&_rxDescriptorsAccess, &expected, true)) {
		expected = false;
	}
	for (int i = 0; i < kNumDataPaths; i++) {
		if (_rxDataPaths[i]->getAssignedNode() == node) {
			_rxDataPaths[i]->prepareCommand(command); // used to do submission

			atomic_store(&_rxDescriptorsAccess, false);
			return;
		}
	}
	atomic_store(&_rxDescriptorsAccess, false);
	FAIL("No data path assigned for %d\n", node);
	return;
}

void
AppleCIOMeshLink::setupTXBuffer(MCUCI::NodeId node, AppleCIOMeshTransmitCommand * command, AppleCIOMeshSharedMemory * memory)
{
	// The SM will setup the TX buffer. Unlike RX, setup here is simply
	// queuing them up in an order to blast it out later.
	memory->setupTxCommand(this, node, command);
}

void
AppleCIOMeshLink::checkDataRXCompletion()
{
	for (int i = 0; i < kNumDataPaths; i++) {
		if (_rxDataPaths[i]->getAssignedNode() != MCUCI::kUnassignedNode) {
			_rxDataPaths[i]->checkCompletion();
		}
	}
}

void
AppleCIOMeshLink::checkDataRXCompletionForNode(MCUCI::NodeId node)
{
	for (int i = 0; i < kNumDataPaths; i++) {
		if (_rxDataPaths[i]->getAssignedNode() == node) {
			return _rxDataPaths[i]->checkCompletion();
		}
	}
}

void
AppleCIOMeshLink::checkDataTXCompletion()
{
	for (int i = 0; i < kNumDataPaths; i++) {
		if (_txDataPaths[i]->getAssignedNode() != MCUCI::kUnassignedNode) {
			_txDataPaths[i]->checkCompletion();
		}
	}
}

AppleCIOMeshControlPath *
AppleCIOMeshLink::getControlPath()
{
	return _controlPath;
}

void
AppleCIOMeshLink::_registrationHandler(IOTimerEventSource * sender)
{
	if (this->isInactive()) {
		return;
	}

	switch (_registrationState) {
	case RegistrationState::Initialized:
	case RegistrationState::ControlPathStarting:
	case RegistrationState::ControlPathStarted:
	case RegistrationState::RegistrationStarting:
	default:
		ERROR("Invalid state for registrationHandler: %x\n", _registrationState);
		break;
	case RegistrationState::WaitingForInitializationComplete:
		LOG("link[%d] WaitingForInitializationComplete\n", _tbtController->getRID());
		_registrationState = RegistrationState::ControlPathStarting;
		_startControlPath();
		_registrationState = RegistrationState::ControlPathStarted;
		_registrationState = RegistrationState::ControlPathQuiesce;
		_registrationEventSource->setTimeoutMS(kRegistrationControlPathDelayMs);
		break;
	case RegistrationState::ControlPathQuiesce:
		LOG("link[%d] ControlPathQuiesce\n", _tbtController->getRID());
		_registrationState = RegistrationState::RegistrationStarting;
		_startRegistrationSequence();
		_registrationState = RegistrationState::RegistrationStarted;
		_registrationEventSource->setTimeoutMS(kRegistrationRetryDelayMs);
		break;
	case RegistrationState::RegistrationStarted:
		LOG("link[%d] RegistrationStarted - retry\n", _tbtController->getRID());
		_registrationState = RegistrationState::RegistrationStarting;
		_startRegistrationSequence();
		_registrationState = RegistrationState::RegistrationStarted;
		_registrationEventSource->setTimeoutMS(kRegistrationRetryDelayMs);
		break;
	}
}
