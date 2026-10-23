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

#include "AppleCIOMeshConfigUserClient.h"
#include "AppleCIOMeshService.h"
#include "UserClientHelpers.h"
#include <IOKit/IOKitKeys.h>
#include <string.h>
#include <sys/proc.h>

#include <AssertMacros.h>
#define LOG_PREFIX "AppleCIOMeshConfigUserClient"
#include "Util/Log.h"

OSDefineMetaClassAndStructors(AppleCIOMeshConfigUserClient, AppleCIOMeshConfigUserClient::super);

extern int gDisableSingleKeyUse;

const IOExternalMethodDispatch2022 AppleCIOMeshConfigUserClient::_methods[MCUCI::Method::NumMethods] =
    {[MCUCI::Method::NotificationRegister] =
         {
             &AppleCIOMeshConfigUserClient::notificationRegister, 0, 0, 0, 0, true,
             /* no special entitlement */
         },
     [MCUCI::Method::NotificationUnregister] =
         {
             &AppleCIOMeshConfigUserClient::notificationUnregister, 0, 0, 0, 0, false,
             /* no special entitlement */
         },
     [MCUCI::Method::GetHardwareState] =
         {
             &AppleCIOMeshConfigUserClient::getHardwareState, 0, 0, 0, sizeof(MCUCI::HardwareState), false,
             /* no special entitlement */
         },
     [MCUCI::Method::SetExtendedNodeId] = {&AppleCIOMeshConfigUserClient::setExtendedNodeId, 0, sizeof(MCUCI::NodeId), 0, 0, false,
                                           kAppleCIOMeshConfigUserModifyEntitlement},
     [MCUCI::Method::GetExtendedNodeId] =
         {
             &AppleCIOMeshConfigUserClient::getExtendedNodeId, 0, 0, 0, sizeof(MCUCI::NodeId), false,
             /* no special entitlement */
         },

     [MCUCI::Method::SetEnsembleSize] = {&AppleCIOMeshConfigUserClient::setEnsembleSize, 0, sizeof(MCUCI::EnsembleSize), 0, 0,
                                         false, kAppleCIOMeshConfigUserModifyEntitlement},
     [MCUCI::Method::GetEnsembleSize] =
         {
             &AppleCIOMeshConfigUserClient::getEnsembleSize, 0, 0, 0, sizeof(MCUCI::EnsembleSize), false,
             /* no special entitlement */
         },
     [MCUCI::Method::GetLocalNodeId] =
         {
             &AppleCIOMeshConfigUserClient::getLocalNodeId, 0, 0, 0, sizeof(MCUCI::NodeId), false,
             /* no special entitlement */
         },
     [MCUCI::Method::SetChassisId]     = {&AppleCIOMeshConfigUserClient::setChassisId, 0, sizeof(MCUCI::ChassisId), 0, 0, false,
                                          kAppleCIOMeshConfigUserModifyEntitlement},
     [MCUCI::Method::AddPeerHostname]  = {&AppleCIOMeshConfigUserClient::addPeerHostname, 0, sizeof(MCUCI::PeerNode), 0, 0, false,
                                          kAppleCIOMeshConfigUserModifyEntitlement},
     [MCUCI::Method::GetPeerHostnames] = {&AppleCIOMeshConfigUserClient::getPeerHostnames, 0, 0, 0, sizeof(MCUCI::PeerHostnames),
                                          false,
                                          /* no special entitlement */},
     [MCUCI::Method::Activate]         = {&AppleCIOMeshConfigUserClient::activate, 0, 0, 0, 0, false,
                                          kAppleCIOMeshConfigUserModifyEntitlement},
     [MCUCI::Method::Deactivate]       = {&AppleCIOMeshConfigUserClient::deactivate, 0, 0, 0, 0, false,
                                          kAppleCIOMeshConfigUserModifyEntitlement},
     [MCUCI::Method::Lock] = {&AppleCIOMeshConfigUserClient::lock, 0, 0, 0, 0, false, kAppleCIOMeshConfigUserModifyEntitlement},
     [MCUCI::Method::IsLocked] =
         {
             &AppleCIOMeshConfigUserClient::isLocked, 0, 0, 0, 0, false,
             /* no special entitlement */
         },
     [MCUCI::Method::DisconnectCIOChannel] = {&AppleCIOMeshConfigUserClient::disconnectCIOChannel, 0, sizeof(MCUCI::MeshChannelIdx),
                                              0, 0, false, kAppleCIOMeshConfigUserModifyEntitlement},
     [MCUCI::Method::EstablishTxConnection] = {&AppleCIOMeshConfigUserClient::establishTXConnection, 0,
                                               sizeof(MCUCI::NodeConnectionInfo), 0, 0, false,
                                               kAppleCIOMeshConfigUserModifyEntitlement},
     [MCUCI::Method::SendControlMessage] =
         {
             &AppleCIOMeshConfigUserClient::sendControlMessage, 0, sizeof(MCUCI::MeshMessage), 0, 0, false,
             /* no special entitlement */
         },
     [MCUCI::Method::GetConnectedNodes] =
         {
             &AppleCIOMeshConfigUserClient::getConnectedNodes, 0, 0, 0, sizeof(MCUCI::ConnectedNodes), false,
             /* no special entitlement */
         },
     [MCUCI::Method::GetCIOConnectionState] =
         {
             &AppleCIOMeshConfigUserClient::getCIOConnectionState, 0, 0, 0, sizeof(MCUCI::CIOConnections), false,
             /* no special entitlement */
         },
     [MCUCI::Method::SetCryptoKey] = {&AppleCIOMeshConfigUserClient::setCryptoState, 0, sizeof(MCUCI::CryptoInfo), 0, 0, false,
                                      kAppleCIOMeshConfigUserModifyEntitlement},
     [MCUCI::Method::GetCryptoKey] =
         {
             &AppleCIOMeshConfigUserClient::getCryptoState, 0, sizeof(MCUCI::CryptoInfo), 0, sizeof(MCUCI::CryptoInfo), false,
             /* no special entitlement */
         },

     [MCUCI::Method::GetBuffersUsedByKey] =
         {
             &AppleCIOMeshConfigUserClient::getBuffersAllocatedByCrypto, 0, 0, 0, sizeof(uint64_t), false,
             /* no special entitlement */
         },
     [MCUCI::Method::canActivate] = {
         &AppleCIOMeshConfigUserClient::canActivate, 0, sizeof(MCUCI::MeshNodeCount), 0, 0, false,
         /* no special entitlement */

     }};

bool
AppleCIOMeshConfigUserClient::initWithTask(task_t owning_task, void * security_token, UInt32 type, OSDictionary * properties)
{
	require(super::initWithTask(owning_task, security_token, type, properties), fail);

	_notify_lock = IOLockAlloc();
	require(_notify_lock != nullptr, fail);
	_owningTask = owning_task;

	return true;

fail:
	return false;
}

bool
AppleCIOMeshConfigUserClient::start(IOService * provider)
{
	require(super::start(provider), fail);

	setProperty(kIOUserClientDefaultLockingKey, kOSBooleanTrue);
	setProperty(kIOUserClientDefaultLockingSetPropertiesKey, kOSBooleanTrue);
	setProperty(kIOUserClientDefaultLockingSingleThreadExternalMethodKey, kOSBooleanTrue);
	setProperty(kIOUserClientEntitlementsKey, kAppleCIOMeshConfigUserAccessEntitlement);

	_provider = OSDynamicCast(AppleCIOMeshService, provider);
	require(_provider != nullptr, fail);

	_dataQueue = IOSharedDataQueue::withEntries(kMaxMessageCount, sizeof(MCUCI::MeshMessage));
	require(_dataQueue != nullptr, fail);

	_provider->retain();

	require(_provider->registerConfigUserClient(this), fail);

	return true;

fail:
	return false;
}

void
AppleCIOMeshConfigUserClient::stop(IOService * provider)
{
	_provider->unregisterConfigUserClient(this);

	IOLockLock(_notify_lock);

	if (_notify_ref_valid) {
		_notify_ref_valid = false;
		releaseAsyncReference64(_notify_ref);
	}

	IOLockUnlock(_notify_lock);

	super::stop(provider);
}

void
AppleCIOMeshConfigUserClient::free()
{
	OSSafeReleaseNULL(_provider);
	OSSafeReleaseNULL(_dataQueue);

	if (_notify_lock) {
		IOLockFree(_notify_lock);
		_notify_lock = nullptr;
	}

	super::free();
}

task_t
AppleCIOMeshConfigUserClient::getOwningTask()
{
	return _owningTask;
}

IOReturn
AppleCIOMeshConfigUserClient::clientClose()
{
	terminate();
	return kIOReturnSuccess;
}

IOReturn
AppleCIOMeshConfigUserClient::externalMethod(uint32_t selector, IOExternalMethodArgumentsOpaque * args)
{
	return dispatchExternalMethod(selector, args, _methods, sizeof(_methods) / sizeof(_methods[0]), this, NULL);
}

IOReturn
AppleCIOMeshConfigUserClient::clientMemoryForType(__unused UInt32 type,
                                                  __unused IOOptionBits * options,
                                                  IOMemoryDescriptor ** memory)
{
	*memory = _dataQueue->getMemoryDescriptor();
	(*memory)->retain();

	return kIOReturnSuccess;
}

IOReturn
AppleCIOMeshConfigUserClient::registerNotificationPort(mach_port_t port, UInt32, UInt32)
{
	_dataQueue->setNotificationPort(port);
	return kIOReturnSuccess;
}

// MARK: - Notifications

void
AppleCIOMeshConfigUserClient::notifyChannelChange(const MCUCI::MeshChannelInfo & channelInfo, bool available)
{
	static constexpr uint64_t kChannelChangeNotificationSize =
	    roundup(sizeof(io_user_reference_t) + sizeof(MCUCI::MeshChannelInfo) + sizeof(bool), sizeof(io_user_reference_t));

	uint8_t tmp[kChannelChangeNotificationSize];
	uint32_t offset                      = 0;
	io_user_reference_t notificationType = (io_user_reference_t)MCUCI::Notification::MeshChannelChange;

	memcpy(tmp + offset, &notificationType, sizeof(notificationType));
	offset += sizeof(notificationType);

	memcpy(tmp + offset, &channelInfo, sizeof(channelInfo));
	offset += sizeof(channelInfo);

	memcpy(tmp + offset, &available, sizeof(available));

	sendNotification((io_user_reference_t *)tmp, kChannelChangeNotificationSize / sizeof(io_user_reference_t));
}

void
AppleCIOMeshConfigUserClient::notifyConnectionChange(const MCUCI::NodeConnectionInfo & connectionInfo, bool connected, bool TX)
{
	static constexpr uint64_t kConnectionChangeNotificationSize =
	    roundup(sizeof(io_user_reference_t) + sizeof(MCUCI::NodeConnectionInfo) + sizeof(uint8_t), sizeof(io_user_reference_t));

	uint8_t tmp[kConnectionChangeNotificationSize];
	uint32_t offset                      = 0;
	io_user_reference_t notificationType = TX ? (io_user_reference_t)MCUCI::Notification::TXNodeConnectionChange
	                                          : (io_user_reference_t)MCUCI::Notification::RXNodeConnectionChange;

	memcpy(tmp + offset, &notificationType, sizeof(notificationType));
	offset += sizeof(notificationType);

	memcpy(tmp + offset, &connectionInfo, sizeof(connectionInfo));
	offset += sizeof(connectionInfo);

	memcpy(tmp + offset, (uint8_t *)&connected, sizeof(uint8_t));

	sendNotification((io_user_reference_t *)tmp, kConnectionChangeNotificationSize / sizeof(io_user_reference_t));
}

void
AppleCIOMeshConfigUserClient::notifyControlMessage(const MCUCI::MeshMessage * message)
{
	_dataQueue->enqueue((void *)message, sizeof(MCUCI::MeshMessage));
}

void
AppleCIOMeshConfigUserClient::sendNotification(io_user_reference_t * args, uint32_t count)
{
	if (_notify_ref_valid) {
		sendAsyncResult64(_notify_ref, kIOReturnSuccess, args, count);
	}
}

IOReturn
AppleCIOMeshConfigUserClient::notificationRegister(OSObject * target,
                                                   __unused void * reference,
                                                   IOExternalMethodArguments * arguments)
{
	auto me = OSRequiredCast(AppleCIOMeshConfigUserClient, target);

	if (arguments->asyncWakePort == MACH_PORT_NULL) {
		return kIOReturnBadArgument;
	}

	IOLockLock(me->_notify_lock);

	if (me->_notify_ref_valid) {
		releaseAsyncReference64(me->_notify_ref);
	}
	memcpy(me->_notify_ref, arguments->asyncReference, sizeof(me->_notify_ref));
	me->_notify_ref_valid = true;

	IOLockUnlock(me->_notify_lock);

	return kIOReturnSuccess;
}

IOReturn
AppleCIOMeshConfigUserClient::notificationUnregister(OSObject * target,
                                                     __unused void * reference,
                                                     __unused IOExternalMethodArguments * arguments)
{
	auto me = OSRequiredCast(AppleCIOMeshConfigUserClient, target);

	IOLockLock(me->_notify_lock);

	if (me->_notify_ref_valid) {
		me->_notify_ref_valid = false;
		releaseAsyncReference64(me->_notify_ref);
	}

	IOLockUnlock(me->_notify_lock);

	return kIOReturnSuccess;
}

IOReturn
AppleCIOMeshConfigUserClient::getHardwareState(OSObject * target, __unused void * reference, IOExternalMethodArguments * arguments)
{
	auto me = OSRequiredCast(AppleCIOMeshConfigUserClient, target);
	EMAOutputExtractor<MCUCI::HardwareState> outputArg(arguments);

	MCUCI::HardwareState * hardware = (MCUCI::HardwareState *)outputArg.get();

	hardware->meshLinksPerChannel = me->_provider->getLinksPerChannel();
	hardware->maxMeshChannelCount = kMaxMeshChannelCount;
	hardware->maxMeshLinkCount    = kMaxMeshLinkCount;
	hardware->meshChannelCount    = me->_provider->getConnectedChannelCount();
	hardware->meshLinkCount       = me->_provider->getConnectedLinkCount();

	return kIOReturnSuccess;
}

IOReturn
AppleCIOMeshConfigUserClient::setExtendedNodeId(OSObject * target, __unused void * reference, IOExternalMethodArguments * arguments)
{
	auto me = OSRequiredCast(AppleCIOMeshConfigUserClient, target);
	EMAInputExtractor<MCUCI::NodeId> nodeId(arguments);

	if (me->_provider->isCIOLocked()) {
		return kIOReturnBusy;
	}

	const MCUCI::NodeId * realNodeId = (const MCUCI::NodeId *)nodeId.get();
	LOG("Setting node id to %d\n", *realNodeId);

	return me->_provider->setExtendedNodeId(nodeId.get());
}

IOReturn
AppleCIOMeshConfigUserClient::getExtendedNodeId(OSObject * target, __unused void * reference, IOExternalMethodArguments * arguments)
{
	auto me = OSRequiredCast(AppleCIOMeshConfigUserClient, target);
	EMAOutputExtractor<MCUCI::NodeId> nodeId(arguments);

	if (!me->_provider->isCIOLocked()) {
		return kIOReturnNotReady;
	}

	LOG("Getting extended node id (%d)\n", me->_provider->getExtendedNodeId());
	MCUCI::NodeId * userNodeId = (MCUCI::NodeId *)nodeId.get();
	*userNodeId                = me->_provider->getExtendedNodeId();
	return kIOReturnSuccess;
}

IOReturn
AppleCIOMeshConfigUserClient::getEnsembleSize(OSObject * target, __unused void * reference, IOExternalMethodArguments * arguments)
{
	auto me = OSRequiredCast(AppleCIOMeshConfigUserClient, target);
	EMAOutputExtractor<MCUCI::EnsembleSize> ensembleSize(arguments);

	if (!me->_provider->isCIOLocked()) {
		return kIOReturnNotReady;
	}

	LOG("Getting ensemble size(%d)\n", me->_provider->getEnsembleSize());
	MCUCI::EnsembleSize * userEnsembleSize = (MCUCI::EnsembleSize *)ensembleSize.get();
	*userEnsembleSize                      = me->_provider->getEnsembleSize();
	return kIOReturnSuccess;
}

IOReturn
AppleCIOMeshConfigUserClient::setEnsembleSize(OSObject * target, __unused void * reference, IOExternalMethodArguments * arguments)
{
	auto me = OSRequiredCast(AppleCIOMeshConfigUserClient, target);
	EMAInputExtractor<MCUCI::EnsembleSize> ensembleSize(arguments);

	if (me->_provider->isCIOLocked()) {
		return kIOReturnNotReady;
	}

	MCUCI::EnsembleSize * userEnsembleSize = (MCUCI::EnsembleSize *)ensembleSize.get();
	LOG("Setting ensemble size to (%d)\n", *userEnsembleSize);
	return me->_provider->setEnsembleSize(userEnsembleSize);
}

IOReturn
AppleCIOMeshConfigUserClient::getLocalNodeId(OSObject * target, __unused void * reference, IOExternalMethodArguments * arguments)
{
	auto me = OSRequiredCast(AppleCIOMeshConfigUserClient, target);
	EMAOutputExtractor<MCUCI::NodeId> nodeId(arguments);

	if (!me->_provider->isCIOLocked()) {
		return kIOReturnNotReady;
	}

	LOG("Getting relative node id (%d)\n", me->_provider->getLocalNodeId());
	MCUCI::NodeId * userNodeId = (MCUCI::NodeId *)nodeId.get();
	*userNodeId                = me->_provider->getLocalNodeId();
	return kIOReturnSuccess;
}

IOReturn
AppleCIOMeshConfigUserClient::setChassisId(OSObject * target, __unused void * reference, IOExternalMethodArguments * arguments)
{
	auto me = OSRequiredCast(AppleCIOMeshConfigUserClient, target);
	EMAInputExtractor<MCUCI::ChassisId> chassisId(arguments);

	if (me->_provider->isCIOLocked()) {
		return kIOReturnBusy;
	}

	LOG("Setting chassis id to %s\n", (char *)chassisId.get());
	return me->_provider->setChassisId(chassisId.get());
}

IOReturn
AppleCIOMeshConfigUserClient::addPeerHostname(OSObject * target, __unused void * reference, IOExternalMethodArguments * arguments)
{
	auto me = OSRequiredCast(AppleCIOMeshConfigUserClient, target);
	EMAInputExtractor<MCUCI::PeerNode> peerNode(arguments);

	if (me->_provider->isCIOLocked()) {
		ERROR("CIO is locked, cannot add peer hostname\n");
		return kIOReturnBusy;
	}

	LOG("Setting peer hostnames\n");
	return me->_provider->addPeerHostname(peerNode.get());
}

IOReturn
AppleCIOMeshConfigUserClient::getPeerHostnames(OSObject * target, __unused void * reference, IOExternalMethodArguments * arguments)
{
	auto me = OSRequiredCast(AppleCIOMeshConfigUserClient, target);
	EMAOutputExtractor<MCUCI::PeerHostnames> hostnamesArg(arguments);

	if (!me->_provider->isCIOLocked()) {
		return kIOReturnNotReady;
	}

	MCUCI::PeerHostnames * hostnames = hostnamesArg.get();

	me->_provider->getPeerHostnames(hostnames);
	return kIOReturnSuccess;
}

IOReturn
AppleCIOMeshConfigUserClient::activate(OSObject * target, __unused void * reference, __unused IOExternalMethodArguments * arguments)
{
	auto me = OSRequiredCast(AppleCIOMeshConfigUserClient, target);

	if (me->_provider->isCIOLocked()) {
		return kIOReturnBusy;
	}

	LOG("ACTIVATING!!!!\n");
	return me->_provider->activateMesh();
}

IOReturn
AppleCIOMeshConfigUserClient::deactivate(OSObject * target,
                                         __unused void * reference,
                                         __unused IOExternalMethodArguments * arguments)
{
	auto me = OSRequiredCast(AppleCIOMeshConfigUserClient, target);

	LOG("DE-ACTIVATING!!!!\n");
	return me->_provider->deactivateMesh();
}

IOReturn
AppleCIOMeshConfigUserClient::lock(OSObject * target, __unused void * reference, __unused IOExternalMethodArguments * arguments)
{
	auto me = OSRequiredCast(AppleCIOMeshConfigUserClient, target);

	if (me->_provider->isCIOLocked()) {
		return kIOReturnBusy;
	}

	return me->_provider->lockCIO();
}

IOReturn
AppleCIOMeshConfigUserClient::isLocked(OSObject * target, __unused void * reference, __unused IOExternalMethodArguments * arguments)
{
	auto me = OSRequiredCast(AppleCIOMeshConfigUserClient, target);

	if (me->_provider->isCIOLocked()) {
		return kIOReturnSuccess;
	}

	return kIOReturnNotReady;
}

IOReturn
AppleCIOMeshConfigUserClient::disconnectCIOChannel(OSObject * target,
                                                   __unused void * reference,
                                                   IOExternalMethodArguments * arguments)
{
	auto me = OSRequiredCast(AppleCIOMeshConfigUserClient, target);
	EMAInputExtractor<MCUCI::MeshChannelIdx> channelIdx(arguments);

	if (me->_provider->isCIOLocked()) {
		return kIOReturnBusy;
	}

	return me->_provider->disconnectChannel(channelIdx.get());
}

IOReturn
AppleCIOMeshConfigUserClient::establishTXConnection(OSObject * target,
                                                    __unused void * reference,
                                                    IOExternalMethodArguments * arguments)
{
	auto me = OSRequiredCast(AppleCIOMeshConfigUserClient, target);
	EMAInputExtractor<MCUCI::NodeConnectionInfo> connection(arguments);

	if (me->_provider->isCIOLocked()) {
		return kIOReturnBusy;
	}

	return me->_provider->establishTXConnection(connection.get());
}

IOReturn
AppleCIOMeshConfigUserClient::sendControlMessage(OSObject * target,
                                                 __unused void * reference,
                                                 IOExternalMethodArguments * arguments)
{
	auto me = OSRequiredCast(AppleCIOMeshConfigUserClient, target);
	EMAInputExtractor<MCUCI::MeshMessage> message(arguments);

	return me->_provider->sendControlMessage(message.get());
}

IOReturn
AppleCIOMeshConfigUserClient::getConnectedNodes(OSObject * target, __unused void * reference, IOExternalMethodArguments * arguments)
{
	auto me = OSRequiredCast(AppleCIOMeshConfigUserClient, target);
	EMAOutputExtractor<MCUCI::ConnectedNodes> connectedNodes(arguments);

	if (!me->_provider->isCIOLocked()) {
		return kIOReturnNotReady;
	}

	return me->_provider->getConnectedNodes((MCUCI::ConnectedNodes *)connectedNodes.get());
}

IOReturn
AppleCIOMeshConfigUserClient::getCIOConnectionState(OSObject * target,
                                                    __unused void * reference,
                                                    IOExternalMethodArguments * arguments)
{
	auto me = OSRequiredCast(AppleCIOMeshConfigUserClient, target);
	EMAOutputExtractor<MCUCI::CIOConnections> cioConnections(arguments);

	return me->_provider->getCIOConnectionState((MCUCI::CIOConnections *)cioConnections.get());
}

bool
AppleCIOMeshConfigUserClient::is_task_entitled_to(task_t task, const char * entitlement)
{
	boolean_t rv = false;
	if (task && entitlement) {
		OSObject * obj = IOUserClient::copyClientEntitlement(task, entitlement);
		if (obj) {
			rv = (obj == kOSBooleanTrue);
			obj->release();
		}
	}
	return rv;
}

IOReturn
AppleCIOMeshConfigUserClient::setCryptoState(OSObject * target, __unused void * reference, IOExternalMethodArguments * arguments)
{
	auto me = OSRequiredCast(AppleCIOMeshConfigUserClient, target);
	EMAInputExtractor<MCUCI::CryptoInfo> cryptoInfoArg(arguments);
	MCUCI::CryptoInfo * cryptoInfo = (MCUCI::CryptoInfo *)cryptoInfoArg.get();

	if (cryptoInfo->keyDataLen == 0 && !me->is_task_entitled_to(me->_owningTask, kAppleCIOMeshConfigClearCryptoKey)) {
		LOG("fail: task is not entitled to clear the crypto key.\n");
		return kIOReturnError;
	} else if (cryptoInfo->keyDataLen >= 0 && !me->is_task_entitled_to(me->_owningTask, kAppleCIOMeshConfigSetCryptoKey)) {
		LOG("fail: task is not entitled to set the crypto key.\n");
		return kIOReturnError;
	}

	if (cryptoInfo->keyDataLen != kUserKeySize) {
		LOG("fail: key length must be exactly %lu.\n", kUserKeySize);
		return kIOReturnBadArgument;
	}

	AppleCIOMeshCryptoKey userKey;
	if (copyin((const user_addr_t)cryptoInfo->keyData, (void *)&userKey.key[0], kUserKeySize) != 0) {
		LOG("could not copyin the user key of size %zd into buffer of size %zd\n", cryptoInfo->keyDataLen, kUserKeySize);
		return kIOReturnBadArgument;
	}

	me->_provider->setUserKey(&userKey);
	memset_s(&userKey, sizeof(AppleCIOMeshCryptoKey), 0, sizeof(AppleCIOMeshCryptoKey));

	me->_provider->setCryptoFlags(cryptoInfo->flags);
	me->_provider->cryptoKeyReset();

	LOG("crypto key was set w/len %zd and flags 0x%x\n", cryptoInfo->keyDataLen, cryptoInfo->flags);

	return kIOReturnSuccess;
}

IOReturn
AppleCIOMeshConfigUserClient::getCryptoState(__unused OSObject * target,
                                             __unused void * reference,
                                             IOExternalMethodArguments * arguments)
{
	auto me = OSRequiredCast(AppleCIOMeshConfigUserClient, target);
	EMAInputExtractor<MCUCI::CryptoInfo> cryptoInfoInputArg(arguments);
	MCUCI::CryptoInfo * cryptoInputInfo = (MCUCI::CryptoInfo *)cryptoInfoInputArg.get();
	EMAOutputExtractor<MCUCI::CryptoInfo> cryptoInfoOutputArg(arguments);
	MCUCI::CryptoInfo * cryptoOutputInfo = (MCUCI::CryptoInfo *)cryptoInfoOutputArg.get();

	if (!gDisableSingleKeyUse && me->_provider->cryptoKeyCheckUsed()) {
		LOG("Crypto key needs to be reset\n");
		return kIOReturnError;
	}

	AppleCIOMeshCryptoKey userKey;
	auto ret = me->_provider->getUserKey(&userKey);
	if (ret != kIOReturnSuccess) {
		return ret;
	}
	if (copyout((void *)&userKey.key, (user_addr_t)cryptoInputInfo->keyData, kUserKeySize) != 0) {
		LOG("failed to copy out the key to user space (userKeyLen %zd, keyDataLen %zd)\n", kUserKeySize,
		    cryptoInputInfo->keyDataLen);
		return kIOReturnBadArgument;
	}
	memset_s(&userKey, sizeof(AppleCIOMeshCryptoKey), 0, sizeof(AppleCIOMeshCryptoKey));
	cryptoOutputInfo->keyDataLen = kUserKeySize;
	MCUCI::CryptoFlags flags;
	me->_provider->getCryptoFlags(&flags);
	cryptoOutputInfo->flags = flags;
	me->_provider->cryptoKeyMarkUsed();
	return kIOReturnSuccess;
}

IOReturn
AppleCIOMeshConfigUserClient::getBuffersAllocatedByCrypto(OSObject * target,
                                                          __unused void * reference,
                                                          IOExternalMethodArguments * arguments)
{
	auto me = OSRequiredCast(AppleCIOMeshConfigUserClient, target);
	EMAOutputExtractor<uint64_t> buffersUsed(arguments);

	return me->_provider->getBuffersAllocatedCounter((uint64_t *)buffersUsed.get());
}

IOReturn
AppleCIOMeshConfigUserClient::canActivate(OSObject * target,
                                          __unused void * reference,
                                          __unused IOExternalMethodArguments * arguments)
{
	auto me = OSRequiredCast(AppleCIOMeshConfigUserClient, target);
	EMAInputExtractor<MCUCI::MeshNodeCount> nodeCount(arguments);

	if (me->_provider->canActivate(nodeCount.get())) {
		return kIOReturnSuccess;
	} else {
		return kIOReturnNotReady;
	}
}
