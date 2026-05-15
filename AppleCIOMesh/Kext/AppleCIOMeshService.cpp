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

#include "AppleCIOMeshService.h"
#include "AppleCIOMeshChannel.h"
#include "AppleCIOMeshCommandRouter.h"
#include "AppleCIOMeshConfigUserClient.h"
#include "AppleCIOMeshControlPath.h"
#include "AppleCIOMeshForwarder.h"
#include "AppleCIOMeshLink.h"
#include "AppleCIOMeshProtocolListener.h"
#include "AppleCIOMeshPtrQueue.h"
#include "AppleCIOMeshSharedMemory.h"
#include "AppleCIOMeshThunderboltCommands.h"
#include "AppleCIOMeshUserClient.h"
#include "Signpost.h"

#define LOG_PREFIX "AppleCIOMeshService"
#include "Common/Compiler.h"
#include "Util/Error.h"
#include "Util/Log.h"

#include <IOKit/IODeviceTreeSupport.h>
#include <IOKit/thunderbolt/IOThunderboltLocalNode.h>
#include <kern/thread.h>
#include <libkern/c++/OSData.h>
#include <os/atomic.h>
#include <sys/sysctl.h>

OSDefineMetaClassAndStructors(AppleCIOMeshService, IOService);

#define kACIODeviceName "acio"
#define kACIOCompatibleValue "acio"
#define kAppleCIOMeshNodeId "meshNodeId"
#define kAppleCIOMeshLinksPerChannelBootArg "meshLinksPerChannel"
#define kAppleCIOMeshDisableSignposts "meshDisableSignposts"
#define kMeshConfigHypercube "j236hypercube"
#define kMeshDisableMaxBuffersPerKey "meshDisableBuffersPerKey"
#define kMeshDisableTimePerKey "meshDisableTimePerKey"
#define kComputeMCUMatchingWaitingTimeNs (30LL * kNsPerSecond)
#define kThreadStartStopTimeNs (30LL * kNsPerSecond)
#define kForwardStopTimeNs (5LL * kNsPerMillisecond)

bool gSignpostsEnabled;

int gDisableSingleKeyUse = 0;
SYSCTL_DECL(_security_mac);
SYSCTL_NODE(_security_mac, OID_AUTO, ciomesh, CTLFLAG_RD, 0, "AppleCIOMeshService");
SYSCTL_INT(_security_mac_ciomesh, OID_AUTO, disable_singlekey_use, CTLFLAG_RW, &gDisableSingleKeyUse, 0, "Disable single key use");

IOService *
AppleCIOMeshService::probe(IOService * provider, __unused SInt32 * probe)
{
	LOG("probe\n");

	if (provider->getProperty(OSSymbol::OSString::withCString("disable-mesh"))) {
		LOG("unavailable\n");
		return nullptr;
	}

	return this;
}

bool
AppleCIOMeshService::start(__unused IOService * provider)
{
	auto interruptAction  = OSMemberFunctionCast(IOInterruptEventAction, this, &AppleCIOMeshService::_meshControlCommandHandler);
	auto armIODeviceEntry = IORegistryEntry::fromPath("IODeviceTree:/arm-io");
	OSCollectionIterator * devices = nullptr;
	OSString * acioCompatible      = OSString::withCString(kACIOCompatibleValue);
	auto commandeerAction          = OSMemberFunctionCast(IOInterruptEventAction, this, &AppleCIOMeshService::_commandeerLoop);
	uint32_t tmp;

	LOG("start\n");

	sysctl_register_oid(&sysctl__security_mac_ciomesh);
	sysctl_register_oid(&sysctl__security_mac_ciomesh_disable_singlekey_use);

	//	_maxBuffersPerKey = kMaxBuffersPerCryptoKey;
	//	_maxTimePerKey    = kMaxSecondsPerCryptoKey;
	_maxBuffersPerKey    = 0;
	_maxTimePerKey       = 0;
	_peerHostnames.count = 0;

	if (PE_parse_boot_argn(kMeshDisableMaxBuffersPerKey, &tmp, sizeof(tmp))) {
		_maxBuffersPerKey = 0;
	}

	if (PE_parse_boot_argn(kMeshDisableTimePerKey, &tmp, sizeof(tmp))) {
		_maxTimePerKey = 0;
	}

	_buffersAllocated   = 0;
	_cryptoKeyTimeLimit = 0;
	gSignpostsEnabled   = true;

	// Mark the initial default key as used/unusable
	// Clients are required to set a new key before start sending/receiving messages.
	atomic_store(&_cryptoKeyUsed, true);

	// Populate the hardware configuration for mesh.
	populateHardwareConfig();

	// Populate the partner map for the current node.
	populatePartnerMap();

	if (!PE_parse_boot_argn(kAppleCIOMeshNodeId, &_nodeId, sizeof(_nodeId))) {
		_nodeId = MCUCI::kUnassignedNode;
	}

	if (!PE_parse_boot_argn(kAppleCIOMeshLinksPerChannelBootArg, &_linksPerChannel, sizeof(_linksPerChannel))) {
		_linksPerChannel = kMaxMeshLinksPerChannel;
	}

	if (PE_parse_boot_argn(kAppleCIOMeshDisableSignposts, &tmp, sizeof(tmp))) {
		gSignpostsEnabled = false;
	}

	setProperty(kAppleCIOMeshNodeId, &_nodeId, sizeof(_nodeId));

	_workloop = IOWorkLoop::workLoop();
	GOTO_FAIL_IF_NULL(_workloop, "Failed to make mesh service workloop\n");

	_commandeerWorkloop = IOWorkLoop::workLoop();
	GOTO_FAIL_IF_NULL(_commandeerWorkloop, "Failed to make mesh service commandeerWorkloop\n");

	_commandeerEventSource = IOInterruptEventSource::interruptEventSource(this, commandeerAction);
	GOTO_FAIL_IF_NULL(_commandeerEventSource, "Failed to make mesh service commanderEventSource\n");

	_commandeerPrepareAssignmentQueue0 = AppleCIOMeshPtrQueue::allocate(kNumBulkPrepare);
	GOTO_FAIL_IF_NULL(_commandeerPrepareAssignmentQueue0, "Failed to make commandeer prepare assignment queue 0\n");
	_commandeerPrepareAssignmentQueue1 = AppleCIOMeshPtrQueue::allocate(kNumBulkPrepare);
	GOTO_FAIL_IF_NULL(_commandeerPrepareAssignmentQueue1, "Failed to make commandeer prepare assignment queue 0\n");
	_commandeerPendingPrepareQueue0 = AppleCIOMeshPtrQueue::allocate(kNumBulkPrepare);
	GOTO_FAIL_IF_NULL(_commandeerPendingPrepareQueue0, "Failed to make commandeer pending prepare queue 0\n");
	_commandeerPendingPrepareQueue1 = AppleCIOMeshPtrQueue::allocate(kNumBulkPrepare);
	GOTO_FAIL_IF_NULL(_commandeerPendingPrepareQueue1, "Failed to make commandeer pending prepare queue 1\n");
	_commandeerForwardPrepareQueue = AppleCIOMeshPtrQueue::allocate(kNumBulkPrepare);
	GOTO_FAIL_IF_NULL(_commandeerForwardPrepareQueue, "Failed to make commandeer forward prepare queue\n");

	_commandeerWorkloop->addEventSource(_commandeerEventSource);
	atomic_store(&_commandeerActive, false);

	// the commandeer thread will get started when a user client starts threads.

	_acioNames = OSArray::withCapacity(10);
	GOTO_FAIL_IF_NULL(_acioNames, "Could not create ACIO name array");

	// count number of ACIO, wait for all ThunderboltNodes to initialize
	GOTO_FAIL_IF_NULL(armIODeviceEntry, "No arm-io device entry");

	devices = IODTFindMatchingEntries(armIODeviceEntry, kIODTExclusive, 0);
	OSSafeReleaseNULL(armIODeviceEntry);
	GOTO_FAIL_IF_NULL(devices, "No arm-io child devices");

	devices->reset();
	while (auto device = (IORegistryEntry *)devices->getNextObject()) {
		if (!strncmp(device->getName(), kACIODeviceName, 4) && device->propertyHasValue("compatible", acioCompatible)) {
			_acioCount++;
			_acioNames->setObject(device->copyName());
		}
	}
	OSSafeReleaseNULL(acioCompatible);
	OSSafeReleaseNULL(devices);

	LOG("Found %d acio entries\n", _acioCount);

	_tbtControllers = OSArray::withCapacity(_acioCount);
	GOTO_FAIL_IF_NULL(_tbtControllers, "failed to make tbt controllers local array");

	_meshProtocolListeners = OSArray::withCapacity(_acioCount);
	GOTO_FAIL_IF_NULL(_meshProtocolListeners, "failed to make tbt protocol listeners local array");

	_sharedMemoryRegions = OSArray::withCapacity(1);
	GOTO_FAIL_IF_NULL(_sharedMemoryRegions, "failed to make shared memory regions local array");

	_userClients = OSArray::withCapacity(1);
	GOTO_FAIL_IF_NULL(_userClients, "failed to make user clients local array");

	_configUserClients = OSArray::withCapacity(1);
	GOTO_FAIL_IF_NULL(_configUserClients, "failed to make config user clients local array");

	_ucLock = IOLockAlloc();
	GOTO_FAIL_IF_NULL(_ucLock, "failed to make user clients lock");

	_forwarderLock = IOLockAlloc();
	GOTO_FAIL_IF_NULL(_forwarderLock, "failed to make forwarder lock");

	_linkLock = IOLockAlloc();
	GOTO_FAIL_IF_NULL(_linkLock, "failed to make link lock");

	PMinit();
	provider->joinPMtree(this);
	registerPrioritySleepWakeInterest(&AppleCIOMeshService::meshPowerStateChangeCallback, this);

	_controlCommandEventSource = IOInterruptEventSource::interruptEventSource(this, interruptAction);
	RETURN_IF_NULL(_controlCommandEventSource, false, "Failed to make control command event source\n");

	_commandQueue = AppleCIOMeshPtrQueue::allocate(kNumControlCommands);
	RETURN_IF_NULL(_commandQueue, false, "Failed to make control command queue\n");

	for (uint8_t i = 0; i < _meshLinksLocked.length(); i++) {
		_meshLinksLocked[i] = false;
	}

	_workloop->addEventSource(_controlCommandEventSource);
	_controlCommandEventSource->enable();

	_commandRouter = AppleCIOMeshCommandRouter::withService(this);
	GOTO_FAIL_IF_NULL(_commandRouter, "failed to allocate command router");

	_acioLock = false;

	nanoseconds_to_absolutetime(kMaxWaitTimeInSeconds * kNsPerSecond, &_maxWaitTime);
	registerService();

	_numNodesMesh = -1;
	for (auto i = 0; i < kMaxCIOMeshNodes; i++) {
		_receivedGeneration[i] = -1;
	}
	_expectedGeneration = 1;

	return true;

fail:
	if (_linkLock) {
		IOLockFree(_linkLock);
	}

	if (_forwarderLock) {
		IOLockFree(_forwarderLock);
	}

	if (_ucLock) {
		IOLockFree(_ucLock);
	}

	if (_controlCommandEventSource) {
		_controlCommandEventSource->disable();
		OSSafeReleaseNULL(_controlCommandEventSource);
	}

	OSSafeReleaseNULL(_commandRouter);
	OSSafeReleaseNULL(_commandQueue);
	OSSafeReleaseNULL(_userClients);
	OSSafeReleaseNULL(_configUserClients);
	OSSafeReleaseNULL(_sharedMemoryRegions);

	if (_meshProtocolListeners) {
		for (int i = (int)_meshProtocolListeners->getCount() - 1; i >= 0; i--) {
			_meshProtocolListeners->removeObject((unsigned int)i);
		}
		OSSafeReleaseNULL(_meshProtocolListeners);
	}

	if (_tbtControllers) {
		for (int i = (int)_tbtControllers->getCount() - 1; i >= 0; i--) {
			_tbtControllers->removeObject((unsigned int)i);
		}
		OSSafeReleaseNULL(_tbtControllers);
	}

	if (_acioNames) {
		for (int i = (int)_acioNames->getCount() - 1; i >= 0; i--) {
			_acioNames->removeObject((unsigned int)i);
		}
		OSSafeReleaseNULL(_acioNames);
	}

	OSSafeReleaseNULL(_commandeerEventSource);
	OSSafeReleaseNULL(_commandeerWorkloop);
	OSSafeReleaseNULL(_workloop);

	return false;
}

void
AppleCIOMeshService::stop(__unused IOService * provider)
{
	// XXXdbg - should kick all uc's out here

	atomic_store(&_commandeerActivated, false);

	_controlCommandEventSource->disable();

	if (_forwarder) {
		_forwarder->stopAllForwardChains();
		_forwarder->stop();
	}
	OSSafeReleaseNULL(_forwarder);
	_forwarder = nullptr;

	// Teardown all shared memory buffers
	for (int i = (int)_sharedMemoryRegions->getCount() - 1; i >= 0; i--) {
		_sharedMemoryRegions->removeObject((unsigned int)i);
	}

	// Teardown all channels.
	for (int i = 0; i < _meshChannels.length(); i++) {
		OSSafeReleaseNULL(_meshChannels[i]);
		_meshChannels[i] = nullptr;
	}

	// Teardown all links.
	for (int i = 0; i < _meshLinks.length(); i++) {
		if (_meshLinks[i] == nullptr) {
			continue;
		}

		_meshLinks[i]->stop(this);
		OSSafeReleaseNULL(_meshLinks[i]);

		_meshLinks[i] = nullptr;
	}
}

void
AppleCIOMeshService::free()
{
	if (_linkLock) {
		IOLockFree(_linkLock);
	}

	if (_forwarderLock) {
		IOLockFree(_forwarderLock);
	}

	if (_ucLock) {
		IOLockFree(_ucLock);
	}

	if (_controlCommandEventSource) {
		_controlCommandEventSource->disable();
		OSSafeReleaseNULL(_controlCommandEventSource);
	}

	OSSafeReleaseNULL(_commandRouter);
	OSSafeReleaseNULL(_commandQueue);
	OSSafeReleaseNULL(_userClients);
	OSSafeReleaseNULL(_configUserClients);
	OSSafeReleaseNULL(_sharedMemoryRegions);

	if (_meshProtocolListeners) {
		for (int i = (int)_meshProtocolListeners->getCount() - 1; i >= 0; i--) {
			_meshProtocolListeners->removeObject((unsigned int)i);
		}
		OSSafeReleaseNULL(_meshProtocolListeners);
	}

	if (_tbtControllers) {
		for (int i = (int)_tbtControllers->getCount() - 1; i >= 0; i--) {
			_tbtControllers->removeObject((unsigned int)i);
		}
		OSSafeReleaseNULL(_tbtControllers);
	}

	if (_acioNames) {
		for (int i = (int)_acioNames->getCount() - 1; i >= 0; i--) {
			_acioNames->removeObject((unsigned int)i);
		}
		OSSafeReleaseNULL(_acioNames);
	}

	OSSafeReleaseNULL(_commandeerWorkloop);
	OSSafeReleaseNULL(_workloop);

	super::free();
}

IOReturn
AppleCIOMeshService::meshPowerStateChangeCallback(
    void * target, void * refCon, UInt32 messageType, IOService * service, void * messageArgument, vm_size_t argSize)
{
	AppleCIOMeshService * currentInstance;

	currentInstance = OSDynamicCast(AppleCIOMeshService, (AppleCIOMeshService *)target);
	if (!currentInstance) {
		LOG("ERROR getting currentInstance\n");
		return kIOReturnError;
	}

	//
	// The message PagingOff is the earliest notifcation we'll
	// receive that a restart or halt is in progress.  Once
	// this happens we set _shuttingDown to true which disallows
	// any new operations and interrupts any current receives
	// or sends.
	//
	if (messageType == kIOMessageSystemPagingOff) {
		LOG("shut down has begun!\n");
		currentInstance->_shuttingDown = true;
	} else if (messageType == kIOMessageSystemWillSleep) {
		LOG("system will sleep!\n");
		currentInstance->_shuttingDown = true;
	} else if (messageType == kIOMessageSystemWillRestart) {
		LOG("system restart imminent!\n");
		currentInstance->_shuttingDown = true;
	} else if (messageType == kIOMessageSystemWillPowerOff) {
		LOG("system power off!\n");
		currentInstance->_shuttingDown = true;
	}
	return kIOReturnSuccess;
}

bool
AppleCIOMeshService::isShuttingDown(void)
{
	return _shuttingDown;
}

IOWorkLoop *
AppleCIOMeshService::getWorkLoop() const
{
	return _workloop;
}

IOReturn
AppleCIOMeshService::registerLink(AppleCIOMeshLink * link, unsigned acioIdx)
{
	IOLockLock(_linkLock);

	if (_meshLinks[acioIdx] != nullptr) {
		panic("meshLink previously registered for acioIdx:%d", acioIdx);
	}

	_meshLinks[acioIdx] = link;
	link->retain();

	IOLockUnlock(_linkLock);

	return kIOReturnSuccess;
}

IOReturn
AppleCIOMeshService::unregisterLink(unsigned acioIdx)
{
	LOG("Unregistering link %d\n", acioIdx);
	if (_meshLinks[acioIdx] == nullptr) {
		return kIOReturnSuccess;
	}

	AppleCIOMeshChannel * channel = nullptr;

	IOLockLock(_linkLock);

	// Remove the link from the channel. We will keep
	// the channel because a channel is permanent unless
	// someone unplugs, which we do not want to support.
	for (int i = 0; i < _meshChannels.length(); i++) {
		if (_meshChannels[i] != nullptr && _meshChannels[i]->getPartnerNodeId() == _meshLinks[acioIdx]->getConnectedNodeId()) {
			_meshChannels[i]->removeLink(_meshLinks[acioIdx]);
			channel = _meshChannels[i];
			break;
		}
	}

	OSSafeReleaseNULL(_meshLinks[acioIdx]);
	_meshLinks[acioIdx] = nullptr;

	IOLockUnlock(_linkLock);

	if (channel) {
		notifyMeshChannelChange(channel);
	} else {
		LOG("no channel found while unregistering link %d\n", acioIdx);
	}

	// Deactivate the entire mesh when a link drops.
	if (_active) {
		_hasBeenDeactivated = true;
	}

	return kIOReturnSuccess;
}

IOReturn
AppleCIOMeshService::_assignLinkToPartnerNodeGated(AppleCIOMeshLink * link)
{
	if (_meshLinks[link->getController()->getRID()] == nullptr) {
		panic("meshLink %p not registered", link);
	}

	auto linkPartnerHardwareId = link->getConnectedHardwareNodeId();
	auto linkPartnerNodeId     = link->getConnectedNodeId();
	MCUCI::ChassisId chassisId;
	link->getChassisId(&chassisId);

	IOLockLock(_linkLock);

	int channelIdx = -1;
	for (int i = 0; i < _meshChannels.length(); i++) {
		if (linkPartnerHardwareId == kNonDCHardwarePlatform) {
			if (_meshChannels[i] != nullptr && _meshChannels[i]->getPartnerNodeId() == linkPartnerNodeId) {
				channelIdx = i;
				break;
			}
		} else {
			if (_meshChannels[i] != nullptr && _meshChannels[i]->getPartnerHardwareId() == linkPartnerHardwareId &&
			    _meshChannels[i]->getPartnerNodeId() == linkPartnerNodeId) {
				channelIdx = i;
				break;
			}
		}
	}

	if (channelIdx == -1) {
		AppleCIOMeshChannel * channel =
		    AppleCIOMeshChannel::allocate(this, _nodeId, _partitionIdx, linkPartnerNodeId, linkPartnerHardwareId, _channelCount);
		RETURN_IF_NULL(channel, kIOReturnNoMemory, "Could not allocate channel for partner:%d\n", linkPartnerNodeId);

		_meshChannels[_channelCount] = channel;
		channelIdx                   = _channelCount++;
		LOG("Created new channel id %d for partner node-id %d\n", channelIdx, linkPartnerNodeId);

		// Add the channel to the command router, when a TX connection gets made
		// we will set the channel for that destination.
		_commandRouter->addChannel((MCUCI::MeshChannelIdx)channelIdx, linkPartnerNodeId);
	}

	link->setChannel(_meshChannels[channelIdx]);

	int linkIdx = -1;
	for (int i = 0; i < _meshLinks.length(); i++) {
		if (_meshLinks[i] == link) {
			linkIdx = i;
			break;
		}
	}

	assertf(linkIdx >= 0, "Could not find link when assigning link to partner node\n");

	_meshChannels[channelIdx]->addLink(link, (uint8_t)linkIdx);

	IOLockUnlock(_linkLock);

	_meshChannels[channelIdx]->sendPendingNodeRegisters();
	_meshChannels[channelIdx]->sendNodeIdentification();

	return kIOReturnSuccess;
}

bool
AppleCIOMeshService::registerUserClient(AppleCIOMeshUserClient * uc)
{
	uint32_t tries           = 0;
	const uint32_t maxTries  = 60;
	const int timeoutSeconds = 5;

	char p_name[32];
	pid_t mypid = proc_selfpid();
	proc_selfname(&p_name[0], sizeof(p_name));

	LOG("*** AppleCIOMesh new client: %s (pid %d)\n", p_name, mypid);

	AbsoluteTime deadline;

	for (tries = 0; tries < maxTries; tries++) {
		int res;

		IOLockLock(_forwarderLock);
		if (_forwarder == nullptr) {
			break;
		}

		// someone else is already using the driver.  go to sleep until we either
		// get woken up or time out.
		clock_interval_to_deadline(timeoutSeconds, kSecondScale, &deadline);
		res = IOLockSleepDeadline(_forwarderLock, &_forwarder, deadline, THREAD_ABORTSAFE);

		if (res == 0 && _forwarder == nullptr) {
			// yay! we got the lock and the forwarder is still null.
			// break out of the loop while still holding the _forwarderLock
			break;
		} else if (_forwarder == nullptr) {
			LOG("*** how odd - we got an error on the forwarder lock but _forwarder is NULL?! (res %d)\n", res);
			break;
		}

		IOLockUnlock(_forwarderLock);
		if (res == THREAD_TIMED_OUT) {
			LOG("pid %d still waiting for the forwarder lock (tries %d of %d; _forwarder %p)\n", mypid, tries + 1, maxTries,
			    _forwarder);
		} else if (res == THREAD_INTERRUPTED) {
			LOG("pid %d interrupted while waiting for the forwarder lock (tries %d of %d)\n", mypid, tries, maxTries);
			return false;
		} else {
			LOG("pid %d got unexpected error %d while waiting for the forwarder lock\n", mypid, res);
			return false;
		}
	}

	if (tries >= maxTries) {
		LOG("no bueno - exceeded maxTries (_forwarder %p)\n", _forwarder);
		return false;
	}

	IOLockLock(_ucLock);

	_userClients->setObject(uc);

	_forwarder = AppleCIOMeshForwarder::allocate(this);
	assertf(_forwarder, "failed to create forwarder");

	IOLockUnlock(_forwarderLock);

	IOLockUnlock(_ucLock);

	// Do not start forwarder or commandeer. They will be started/stopped
	// by userspace.

	return true;
}

void
AppleCIOMeshService::unregisterUserClient(AppleCIOMeshUserClient * uc)
{
	IOLockLock(_ucLock);

	int ucIdx = -1;
	for (unsigned int i = 0; i < _userClients->getCount(); i++) {
		auto ucIter = _userClients->getObject(i);
		if (uc == ucIter) {
			ucIdx = (int)i;
			break;
		}
	}

	if (ucIdx == -1) {
		LOG("Could not find user client to unregister\n");
		goto exit;
	}

	// Let's stop the commandeer here.
	{
		atomic_store(&_commandeerActivated, false);
		_commandeerEventSource->disable();

		uint64_t start = mach_absolute_time();
		uint64_t now, limit;
		nanoseconds_to_absolutetime(kThreadStartStopTimeNs, &limit);
		uint64_t ctr = 0;

		while (atomic_load(&_commandeerActive)) {
			ctr++;
			if ((ctr % 10000) == 0) {
				now = mach_absolute_time();

				if ((now - start) > limit) {
					LOG("Commandeer did not stop within timeout. Will attempt to keep going.\n")
					break;
				}
			}
		}
	}

	// Destroy shared memory associated with this userclient.
	for (int i = (int)_sharedMemoryRegions->getCount() - 1; i >= 0; i--) {
		auto sm = OSRequiredCast(AppleCIOMeshSharedMemory, _sharedMemoryRegions->getObject((unsigned int)i));
		if (sm->getOwningUserClient() == uc) {
			_freeSharedMemoryUCGated(sm->getId());
		}
	}

	_userClients->removeObject((unsigned int)ucIdx);

	LOG("Restarting data paths always\n");
	for (int j = 0; j < _meshLinks.length(); j++) {
		if (_meshLinks[j] != nullptr) {
			_meshLinks[j]->stopDataPath();
		}
	}
	_dataPathRestartRequired = true;

	if (_forwarder) {
		IOLockLock(_forwarderLock);
		OSSafeReleaseNULL(_forwarder);
		_forwarder = nullptr;
		IOLockUnlock(_forwarderLock);                    // this acts as a memory barrier
		IOLockWakeup(_forwarderLock, &_forwarder, true); // now wakeup a single thread if one is waiting
	}

exit:
	IOLockUnlock(_ucLock);
}

bool
AppleCIOMeshService::registerConfigUserClient(AppleCIOMeshConfigUserClient * uc)
{
	IOLockLock(_ucLock);
	_configUserClients->setObject(uc);
	IOLockUnlock(_ucLock);

	return true;
}

void
AppleCIOMeshService::unregisterConfigUserClient(AppleCIOMeshConfigUserClient * uc)
{
	IOLockLock(_ucLock);

	int ucIdx = -1;
	for (unsigned int i = 0; i < _configUserClients->getCount(); i++) {
		auto ucIter = _configUserClients->getObject(i);
		if (uc == ucIter) {
			ucIdx = (int)i;
			break;
		}
	}

	if (ucIdx == -1) {
		LOG("Could not find config user client to unregister\n");
		goto exit;
	}

	_configUserClients->removeObject((unsigned int)ucIdx);

exit:
	IOLockUnlock(_ucLock);
}

AppleCIOMeshSharedMemory *
AppleCIOMeshService::getSharedMemory(MUCI::BufferId bufferId)
{
	for (unsigned int i = 0; i < _sharedMemoryRegions->getCount(); i++) {
		auto sm = OSRequiredCast(AppleCIOMeshSharedMemory, _sharedMemoryRegions->getObject(i));

		if (sm->getId() == bufferId) {
			return sm;
		}
	}
	return nullptr;
}

AppleCIOMeshSharedMemory *
AppleCIOMeshService::getRetainSharedMemory(MUCI::BufferId bufferId)
{
	for (unsigned int i = 0; i < _sharedMemoryRegions->getCount(); i++) {
		auto sm = OSRequiredCast(AppleCIOMeshSharedMemory, _sharedMemoryRegions->getObject(i));

		if (sm->getId() == bufferId) {
			sm->retain();
			return sm;
		}
	}
	return nullptr;
}

uint32_t
AppleCIOMeshService::getLinksPerChannel()
{
	return _linksPerChannel;
}

uint32_t
AppleCIOMeshService::getSignpostSequenceNumber()
{
	return _signpostSequenceNumber;
}

MCUCI::NodeId
AppleCIOMeshService::getLocalNodeId()
{
	return _nodeId;
}

MCUCI::EnsembleSize
AppleCIOMeshService::getEnsembleSize()
{
	return _ensembleSize;
}

MCUCI::NodeId
AppleCIOMeshService::getExtendedNodeId()
{
	return _partitionIdx * 8 + _nodeId;
}

MCUCI::PartitionIdx
AppleCIOMeshService::getPartitionIndex()
{
	return _partitionIdx;
}

AppleCIOMeshForwarder *
AppleCIOMeshService::getForwarder()
{
	return _forwarder;
}

uint8_t
AppleCIOMeshService::getConnectedLinkCount()
{
	uint8_t connected = 0;
	for (int i = 0; i < _meshLinks.length(); i++) {
		if (_meshLinks[i] != nullptr && _meshLinks[i]->getChannel() != nullptr) {
			connected++;
		}
	}

	return connected;
}

uint8_t
AppleCIOMeshService::getConnectedChannelCount()
{
	uint8_t connected = 0;
	for (int i = 0; i < _meshChannels.length(); i++) {
		if (_meshChannels[i] != nullptr && _meshChannels[i]->isReady()) {
			connected++;
		}
	}

	return connected;
}

bool
AppleCIOMeshService::isActive()
{
	return _active;
}

bool
AppleCIOMeshService::acioDisabled(uint8_t acio)
{
	// Even if CIO has not activated, we will allow connections in
	// because connections will not be remade from the other side, which
	// we cannot control.

	// Until we go active, we will not be able to register so that's fine.
	// Links will remain in an unregistered/un-usable state.
	// A channel will never be created and we have a dangling link.

	// It will get fixed when we eventually lock and close down all dangling
	// links.

	bool retval = _meshLinksLocked[acio];

	retval &= _acioLock;

	return retval;
}

void
AppleCIOMeshService::populateHardwareConfig()
{
	IORegistryEntry * product = IORegistryEntry::fromPath("/product", gIODTPlane);
	_meshConfig               = kNoConfig;

	if (!product) {
		panic("/product not found in DeviceTreePlane\n");
	}

	auto meshConfigProp = product->getProperty("mesh-config");
	OSSafeReleaseNULL(product);

	// TODO: do not assume hypercube once property is added to EDT
	if (!meshConfigProp) {
		LOG("mesh-config not found, assuming J236Hypercube\n");
		_meshConfig = kJ236Hypercube;
		_hardwareConfig.populate(_meshConfig);
		return;

		panic("mesh-config not found in /product registryEntry\n");
	}

	auto meshConfigData = OSDynamicCast(OSData, meshConfigProp);
	if (!meshConfigData) {
		panic("mesh-config not osdata\n");
	}

	if (strncmp(kMeshConfigHypercube, (const char *)meshConfigData->getBytesNoCopy(), meshConfigData->getLength()) == 0) {
		_meshConfig = kJ236Hypercube;
	}

	_hardwareConfig.populate(_meshConfig);
}

void
AppleCIOMeshService::dumpCommandeerState()
{
	LOG("commandeerActivated %s SendData %s PrepareData %s ForwardHelp 0x%llx\n", _commandeerActivated ? "YES" : "NO",
	    _commandeerSendData ? "YES" : "NO", _commandeerPrepareData ? "YES" : "NO", (uint64_t)_commandeerForwardAction);
	LOG("commandeer SMSend %p (id %lld) SendOffset 0x%llx SMPrepare %p (id %lld) PrepareOffset 0x%llx DripAssignmentIdx %lld "
	    "DripOffsetIdx %lld LinkIdx %lld\n",
	    _commandeerSMSend, _commandeerSMSend ? _commandeerSMSend->getId() : (int64_t)0, _commandeerSMSendOffset,
	    _commandeerSMPrepare, _commandeerSMPrepare ? _commandeerSMPrepare->getId() : (int64_t)0, _commandeerSMPrepareOffset,
	    _commandeerPrepareDripAssignmentIdx, _commandeerPrepareDripOffsetIdx, _commandeerPrepareDripLinkIdx);
}

bool
AppleCIOMeshService::getCurrentSlot(uint8_t & slot)
{
	IOService * computeMCUService = _resolvePHandle("computeMCU", "AppleOceanComputeMCU");

	// TODO: do not search again once the property is in J236 EDT
	if (computeMCUService == nullptr) {
		LOG("Couldn't find compute MCU, searching again directly\n");

		auto serviceMatch = IOService::serviceMatching("AppleOceanComputeMCU");
		computeMCUService = IOService::waitForMatchingService(serviceMatch, kComputeMCUMatchingWaitingTimeNs);
		OSSafeReleaseNULL(serviceMatch);
	}

	if (computeMCUService == nullptr) {
		LOG("!!!!!! Could not find AppleOceanComputeMCU service. Assuming nonDC hardware platform.\n");
		_partnerMap.initialized         = false;
		_partnerMap.currentHardwareNode = kNonDCHardwarePlatform;
		return false;
	}

	auto slotProperty = computeMCUService->getProperty("Carrier Slot");
	if (!slotProperty) {
		panic("AppleOceanComputeMCU does not have Carrier Slot property");
	}

	auto slotObj = OSDynamicCast(OSNumber, slotProperty);
	if (!slotObj) {
		panic("AppleOceanComputeMCU Carrier Slot is not a OSNumber");
	}

	slot = slotObj->unsigned8BitValue();
	return true;
}

void
AppleCIOMeshService::populatePartnerMap()
{
	uint8_t slot = 0;
	if (!getCurrentSlot(slot)) {
		return;
	}
	_partnerMap.populate(&_hardwareConfig, slot);
}

IOReturn
AppleCIOMeshService::newUserClient(
    task_t owningTask, void * securityID, UInt32 type, OSDictionary * properties, LIBKERN_RETURNS_RETAINED IOUserClient ** handler)
{
	IOUserClient * client = nullptr;

	switch (type) {
	case MUCI::AppleCIOMeshUserClientType:
		client = OSTypeAlloc(AppleCIOMeshUserClient);
		break;
	case MCUCI::AppleCIOMeshConfigUserClientType:
		client = OSTypeAlloc(AppleCIOMeshConfigUserClient);
		break;
	default:
		return kIOReturnUnsupported;
	}

	if (!client->initWithTask(owningTask, securityID, type, properties)) {
		client->release();
		return kIOReturnBadArgument;
	}

	if (!client->attach(this)) {
		client->release();
		return kIOReturnUnsupported;
	}

	if (!client->start(this)) {
		LOG("starting user client failed...\n");
		*handler = NULL;
		client->detach(this);
		client->release();
		return kIOReturnUnsupported;
	}

	*handler = client;
	return kIOReturnSuccess;
}

void
AppleCIOMeshService::_commandeerLoopPendingCheck(NodeAssignmentMap * nodeMap, uint8_t linkIdx)
{
	auto node   = nodeMap->node;
	auto map    = nodeMap->provider;
	auto sm     = map->sharedMemory;
	bool output = false;

	if (atomic_load(&nodeMap->linkCurrentIdx[linkIdx]) != nodeMap->linkAssignCount[linkIdx]) {
		if (sm->runtimePrepareDisabled()) {
			// Do not allow runtime preparing while the SM is being prepared, the 2
			// chunks will overlap and cause a lot of issues, so just prepare
			// 1 chunk at a time to avoid this issue.
			// We need to store this in a pending queue to eventually process
			// the commandeerloop will eventually prepare this.
			commandeerPendingPrepare(nodeMap, linkIdx);
		} else {
			auto idxIdx = atomic_fetch_add(&nodeMap->linkCurrentIdx[linkIdx], 1);

			// TODO: Fix the subtraction here, we subtract because 1 assignment
			// has both links' chunks. So if we are in the second link,
			// we need to go back to the previous index.

			if (node == _nodeId) {
				output = true;
			}

			auto assignmentIdx = nodeMap->linkAssignedIdx[linkIdx][idxIdx];
			if (!output) {
				assignmentIdx -= linkIdx;
			}

			auto assignment = sm->getAssignmentIn(map->getAssignmentOffset(assignmentIdx), assignmentIdx);
			commandeerBulkPrepare(assignment, linkIdx);
		}
	}
}

IOReturn
AppleCIOMeshService::_commandeerLoop(__unused IOInterruptEventSource * sender, __unused int count)
{
	atomic_store(&_commandeerActive, true);
	// This thread can deadlock because it is forwarding and sending data. Sending includes
	// checking the send has completed, but we do not check for forwarding complete, unless it
	// helps out the forwarder thread. Be careful with all infinite loops in here.

	// When exiting from error, the order has to be:
	// release the buffer, clear the working atomic, goto after.
	LOG("_commandeerLoop is alive\n");

	IOReturn retVal = kIOReturnSuccess;
	while (atomic_load(&_commandeerActivated)) {
		// Send Data -- Few infinite loops:
		// 1) Instead of waiting indefinitely for assignment to be dispatched, we need to
		// check, send if not fully dispatched, and then if not fully dispatched again
		// do a quick checkTXAssignmentReady to trigger command completions, which will
		// free up any TX links, which is the only reason the assignment was not dispatched.
		// 2) We can always wait indefinitely for TX data to complete, because
		// we have the link for sending out data.
		if (atomic_load(&_commandeerSendData)) {
			_commanderSMSendCounter++;
			if ((_commanderSMSendCounter % 10000000) == 0) {
				if (mach_absolute_time() - _commanderSMSendStart >= _maxWaitTime) {
					LOG("commandeer send timedOut... offset 0x%llx\n", _commandeerSMSendOffset);

					OSSafeReleaseNULL(_commandeerSMSend);
					OSSafeReleaseNULL(_commandeerSendUserClient);
					atomic_store(&_commandeerSendData, false);
					goto afterSend;
				}
			}

			if (_commandeerSMSend->hasBeenInterrupted()) {
				LOG("commandeer send interrupted... offset 0x%llx\n", _commandeerSMSendOffset);

				OSSafeReleaseNULL(_commandeerSMSend);
				OSSafeReleaseNULL(_commandeerSendUserClient);
				atomic_store(&_commandeerSendData, false);
				goto afterSend;
			}

			if (!_commandeerSMSend->assignmentDispatched(_commandeerSMSendOffset, 0x2)) {
				COMMANDEER_SEND_TR(_commandeerSMSend->getId(), _commandeerSMSendOffset, COMMANDEER_SEND_META_NOT_DISPATCHED);
				sendAssignedData(_commandeerSMSend, (int64_t)_commandeerSMSendOffset, 0x2, _commandeerSendTag,
				                 _commandeerSendTagSz);
			}

			bool interrupted = false;
			COMMANDEER_SEND_TR(_commandeerSMSend->getId(), _commandeerSMSendOffset, COMMANDEER_SEND_META_CHECK_READY);
			bool assignmentReady = _commandeerSMSend->checkTXAssignmentReady(_commandeerSMSendOffset, 0x2, &interrupted);
			if (assignmentReady) {
				COMMANDEER_SEND_TR(_commandeerSMSend->getId(), _commandeerSMSendOffset, COMMANDEER_SEND_META_COMPLETE);
				_commandeerSendUserClient->commandeerSendComplete();

				OSSafeReleaseNULL(_commandeerSMSend);
				OSSafeReleaseNULL(_commandeerSendUserClient);
				atomic_store(&_commandeerSendData, false);
				goto afterSend;
			}

			if (interrupted) {
				LOG("commandeer send interrupted... offset 0x%llx\n", _commandeerSMSendOffset);

				OSSafeReleaseNULL(_commandeerSMSend);
				OSSafeReleaseNULL(_commandeerSendUserClient);
				atomic_store(&_commandeerSendData, false);
				goto afterSend;
			}
		}

	afterSend:

		// Drip prepare data -- No infinite loops here.
		// But preparing takes a long time, so we will only prepare 1 thing
		// at a time, and then check if there is other work we have to do.
		// that has to be higher priority.
		if (atomic_load(&_commandeerPrepareData)) {
			if (_commandeerSMPrepare->hasBeenInterrupted()) {
				LOG("bufferId %lld was interrupted.\n", _commandeerSMPrepare->getId());

				OSSafeReleaseNULL(_commandeerPreparePreviousSM);
				OSSafeReleaseNULL(_commandeerSMPrepare);
				atomic_store(&_commandeerPrepareData, false);
				goto afterDripPrepare;
			}

			if (!_commandeerPreparePreviousComplete) {
				auto previousSMReceiveAssignments = _commandeerPreparePreviousSM->getReceiveAssignmentMap();
				bool expected                     = true;
				if (!atomic_compare_exchange_strong(&previousSMReceiveAssignments->allReceiveFinished, &expected, false)) {
					goto afterDripPrepare;
				}
				_commandeerPreparePreviousComplete = true;
			}

			if (_commandeerSMPrepareOffset == MUCI::PrepareFullBuffer) {
				retVal = _dripPrepareBuffer(_commandeerSMPrepare, &_commandeerPrepareDripAssignmentIdx,
				                            &_commandeerPrepareDripOffsetIdx, &_commandeerPrepareDripLinkIdx);
			} else {
				panic("commmandeer should not prepare a single buffer");
			}

			if (retVal == kIOReturnSuccess) {
				OSSafeReleaseNULL(_commandeerPreparePreviousSM);
				OSSafeReleaseNULL(_commandeerSMPrepare);
				atomic_store(&_commandeerPrepareData, false);
				goto afterDripPrepare;
			} else if (retVal == kIOReturnStillOpen) {
				if (_commandeerSMPrepare->hasBeenInterrupted()) {
					LOG("bufferId %lld was interrupted.\n", _commandeerSMPrepare->getId());

					OSSafeReleaseNULL(_commandeerPreparePreviousSM);
					OSSafeReleaseNULL(_commandeerSMPrepare);
					atomic_store(&_commandeerPrepareData, false);
					goto afterDripPrepare;
				}

				// Still have more prepare to do, we will come back to working on this.
				goto afterDripPrepare;
			} else {
				panic("Failed to prepare %s: 0x%x\n", _commandeerSMPrepareOffset == MUCI::PrepareFullBuffer ? "buffer" : "command",
				      retVal);
			}
		}

	afterDripPrepare:

		// Forward helper -- can be any action from checking completion to submit
		// to whatever. We will only finish our forward action once it does not
		// return kIOReturnBusy -- this is either after a submit, check TX completion,
		// forward completion, etc. kIOReturnBusy will be returned to indicate
		// we should retry and help the forwarder.
		uintptr_t expected, curval;
		curval = atomic_load(&_commandeerForwardAction);
		if (curval) {
			expected            = curval;
			ForwardAction * cfa = (ForwardAction *)_commandeerForwardAction;
			COMMANDEER_FORWARD_TR(cfa->txCommand->getMeshLink()->getRID(), cfa->txCommand->getDataChunk().bufferId,
			                      cfa->txCommand->getDataChunk().offset, 0x1000 | (uint32_t)cfa->state);
			retVal = _forwarder->forwardStateMachine(cfa, true, false);
			COMMANDEER_FORWARD_TR(cfa->txCommand->getMeshLink()->getRID(), cfa->txCommand->getDataChunk().bufferId,
			                      cfa->txCommand->getDataChunk().offset, 0x2000 | (uint32_t)cfa->state);
			if (retVal != kIOReturnBusy) {
				// this action is done, clear out our state
				if (!atomic_compare_exchange_strong(&_commandeerForwardAction, &expected, 0)) {
					LOG("how can this be? I had curval 0x%llx but expected is 0x%llx (0x%llx)\n", (uint64_t)curval,
					    (uint64_t)expected, (uint64_t)_commandeerForwardAction);
					goto afterForward;
				}

				goto afterForward;
			}
		}

	afterForward:

		// Bulk Prepare helper for queue 0 -- No infinite loop, just prepare
		// 1 assignment at a time.
		AppleCIOMeshAssignment * toPrepareAssignment0 = (AppleCIOMeshAssignment *)_commandeerPrepareAssignmentQueue0->remove();
		if (toPrepareAssignment0 == nullptr) {
			goto afterBulkPrepare0;
		}
		toPrepareAssignment0->prepare(0x1);

	afterBulkPrepare0:

		// Bulk Prepare helper for queue 0 -- No infinite loop, just prepare
		// 1 assignment at a time.
		AppleCIOMeshAssignment * toPrepareAssignment1 = (AppleCIOMeshAssignment *)_commandeerPrepareAssignmentQueue1->remove();
		if (toPrepareAssignment1 == nullptr) {
			goto afterBulkPrepare1;
		}
		toPrepareAssignment1->prepare(0x2);

	afterBulkPrepare1:
		// Pending prepare helper for queue 0 -- no infinite loop
		NodeAssignmentMap * nodeMap0 = (NodeAssignmentMap *)_commandeerPendingPrepareQueue0->remove();
		if (nodeMap0) {
			_commandeerLoopPendingCheck(nodeMap0, 0);
		}

	afterPendingPrepare0:
		// Pending prepare helper for queue 1 -- no infinite loop
		NodeAssignmentMap * nodeMap1 = (NodeAssignmentMap *)_commandeerPendingPrepareQueue1->remove();
		if (nodeMap1) {
			_commandeerLoopPendingCheck(nodeMap1, 1);
		}

	afterPendingPrepare1:
		ForwardActionChainElement * chainElement = (ForwardActionChainElement *)_commandeerForwardPrepareQueue->remove();
		if (chainElement == nullptr) {
			goto afterForwardPrepare;
		}
		_forwarder->prepareChainElement(chainElement);

	afterForwardPrepare:
		continue;
	}

	LOG("*** _commandeerLoop going away\n");
	atomic_store(&_commandeerActive, false);
	return kIOReturnSuccess;
}

// MARK: - Thunderbolt Workloop Context Methods

void
AppleCIOMeshService::commandSentFlowControl(void * param, IOReturn status, __unused IOThunderboltTransmitCommand * command)
{
	auto transmitCommand = static_cast<AppleCIOMeshTransmitCommand *>(param);

	switch (status) {
	case kIOReturnSuccess:
		break;
	case kIOReturnAborted:
		return;
	case kIOReturnIOError: {
		uint8_t slot;
		if (getCurrentSlot(slot)) {
			auto * label = _hardwareConfig.getLinkLabel(slot, transmitCommand->getMeshLink()->getRID());
			panic("crc error on cable %d%s", slot, label);
		}
		panic("CRC error. Unable to determine cable.");
	}
	default:
		panic("commandSentFlowControl status: %x\n", status);
	}

	TX_COMMAND_SENT_TR(transmitCommand->getMeshLink()->getController()->getRID(), transmitCommand->getDataChunk().bufferId,
	                   transmitCommand->getDataChunk().offset, transmitCommand->getFXCompletedIdx());

	transmitCommand->getProvider()->notifyTXFlowControl(transmitCommand, _forwarder);
}

void
AppleCIOMeshService::commandReceivedFlowControl(void * param, IOReturn status, __unused IOThunderboltReceiveCommand * command)
{
	auto receiveCommand = static_cast<AppleCIOMeshReceiveCommand *>(param);

	switch (status) {
	case kIOReturnSuccess:
		break;
	case kIOReturnAborted:
		return;
	case kIOReturnIOError: {
		uint8_t slot;
		if (getCurrentSlot(slot)) {
			auto * label = _hardwareConfig.getLinkLabel(slot, receiveCommand->getMeshLink()->getRID());
			panic("crc error on cable %d%s", slot, label);
		}
		panic("CRC error. Unable to determine cable.");
	}
	default:
		panic("commandReceivedFlowControl status: %x\n", status);
	}

	if (receiveCommand->getMeshLink()->isInactive() || receiveCommand->getMeshLink()->getXDLink()->isTerminated()) {
		return;
	}

	RX_COMMAND_RECEIVED_TR(receiveCommand->getMeshLink()->getController()->getRID(), receiveCommand->getDataChunk().bufferId,
	                       receiveCommand->getDataChunk().offset, receiveCommand->getFXReceivedIdx());

	receiveCommand->getProvider()->notifyRXFlowControl(receiveCommand, _forwarder);
}

void
AppleCIOMeshService::dataSent(void * param, IOReturn status, __unused IOThunderboltTransmitCommand * command)
{
	auto transmitCommand = static_cast<AppleCIOMeshTransmitCommand *>(param);

	switch (status) {
	case kIOReturnSuccess:
		break;
	case kIOReturnAborted:
		return;
	case kIOReturnIOError: {
		uint8_t slot;
		if (getCurrentSlot(slot)) {
			auto * label = _hardwareConfig.getLinkLabel(slot, transmitCommand->getMeshLink()->getRID());
			panic("crc error on cable %d%s", slot, label);
		}
		panic("CRC error. Unable to determine cable.");
	}
	default:
		panic("dataSent status: %x\n", status);
	}

	if (transmitCommand->getMeshLink()->isInactive() || transmitCommand->getMeshLink()->getXDLink()->isTerminated()) {
		return;
	}

	TX_COMMAND_SENT_TR(transmitCommand->getMeshLink()->getController()->getRID(), transmitCommand->getDataChunk().bufferId,
	                   transmitCommand->getDataChunk().offset, transmitCommand->getFXCompletedIdx());
	LINK_DATA_SENT_CALLBACK_TR(transmitCommand->getMeshLink()->getController()->getRID(), transmitCommand->getDataChunk().bufferId,
	                           transmitCommand->getDataChunk().offset);

	transmitCommand->getProvider()->getProvider()->getProvider()->removePrepared(1);
	if (_forwarder) {
		transmitCommand->getProvider()->notifyTXFlowControl(transmitCommand, _forwarder);
	}

	transmitCommand->completionIn();

	uint32_t mask = 0x1 << transmitCommand->getMeshLink()->getController()->getRID();

	if (transmitCommand->getProvider()->isTxForwarding()) {
		return;
	} else if (transmitCommand->getProvider()->decrementOutgoingCommandForMask(mask)) {
		ALL_LINKS_DATA_SENT_TR(transmitCommand->getDataChunk().bufferId, transmitCommand->getDataChunk().offset);

		auto sm = transmitCommand->getProvider()->getProvider()->getProvider();
		if (sm->requiresRuntimePrepare()) {
			auto linkIdx     = transmitCommand->getMeshLink()->getLinkIdx();
			auto node        = transmitCommand->getAssignedChunk().sourceNode;
			auto outgoingMap = sm->getOutputAssignmentMap();
			auto nodeMap     = &(outgoingMap->nodeMap[node]);

			_commandeerLoopPendingCheck(nodeMap, linkIdx);
		}

		transmitCommand->getProvider()->notifyTxReady();
	}
}

void
AppleCIOMeshService::dataReceived(void * param, IOReturn status, __unused IOThunderboltReceiveCommand * command)
{
	auto receiveCommand = static_cast<AppleCIOMeshReceiveCommand *>(param);
	switch (status) {
	case kIOReturnSuccess:
		break;
	case kIOReturnAborted:
		return;
	case kIOReturnIOError: {
		uint8_t slot;
		if (getCurrentSlot(slot)) {
			auto * label = _hardwareConfig.getLinkLabel(slot, receiveCommand->getMeshLink()->getRID());
			panic("crc error on cable %d%s", slot, label);
		}
		panic("CRC error. Unable to determine cable.");
	}
	default:
		panic("dataReceivedNotify status: %x\n", status);
	}

	LINK_DATA_RECEIVED_CALLBACK_TR(receiveCommand->getMeshLink()->getController()->getRID(),
	                               receiveCommand->getDataChunk().bufferId, receiveCommand->getDataChunk().offset);

	RX_COMMAND_RECEIVED_TR(receiveCommand->getMeshLink()->getController()->getRID(), receiveCommand->getDataChunk().bufferId,
	                       receiveCommand->getDataChunk().offset, receiveCommand->getFXReceivedIdx());

	if (receiveCommand->getMeshLink()->isInactive() || receiveCommand->getMeshLink()->getXDLink()->isTerminated()) {
		return;
	}

	receiveCommand->getProvider()->getProvider()->getProvider()->removePrepared(1);

	if (_forwarder) {
		receiveCommand->getProvider()->notifyRXFlowControl(receiveCommand, _forwarder);
	}

	auto sm = receiveCommand->getProvider()->getProvider()->getProvider();
	if (sm->requiresRuntimePrepare()) {
		auto linkIdx    = receiveCommand->getMeshLink()->getLinkIdx();
		auto node       = receiveCommand->getAssignedChunk().sourceNode;
		auto receiveMap = sm->getReceiveAssignmentMap();
		auto nodeMap    = &(receiveMap->nodeMap[node]);

		_commandeerLoopPendingCheck(nodeMap, linkIdx);
	}

	receiveCommand->getProvider()->notifyRxReady();
}

// MARK: - Control Command Methods
void
AppleCIOMeshService::controlSent(void * param, IOReturn status, IOThunderboltTransmitCommand * command)
{
	AppleCIOMeshControlPath * controlPath               = (AppleCIOMeshControlPath *)param;
	AppleCIOMeshTransmitControlCommand * controlCommand = OSDynamicCast(AppleCIOMeshTransmitControlCommand, command);

	if (controlCommand == nullptr) {
		ERROR("Unable to return control command: %p that was not a AppleCIOMeshTransmitControlCommand\n", command);
		return;
	}

	if (status != kIOReturnSuccess) {
		LOG("Failed to send control command: %x. Status:%x\n", controlCommand->getCommand()->commandType, status);
		return;
	}

	controlPath->returnControlCommand(controlCommand);
	return;
}

void
AppleCIOMeshService::controlReceived(__unused void * param, IOReturn status, IOThunderboltReceiveCommand * command)
{
	if (status != kIOReturnSuccess) {
		return;
	}

	// Will be freed by command handler
	command->retain();

	_commandQueue->add((uintptr_t)command);
	_controlCommandEventSource->interruptOccurred(this, nullptr, 0);
}

IOReturn
AppleCIOMeshService::_meshControlCommandHandler(__unused IOInterruptEventSource * sender, __unused int count)
{
	while (true) {
		AppleCIOMeshReceiveControlCommand * rxControlCommand = (AppleCIOMeshReceiveControlCommand *)_commandQueue->remove();

		if (rxControlCommand == nullptr) {
			break;
		}

		AppleCIOMeshControlPath * controlPath = rxControlCommand->getControlPath();
		MeshControlCommand * controlCommand   = rxControlCommand->getCommand();
		MeshControlMessage * controlMessage   = rxControlCommand->getControlMessage();

		switch (controlCommand->commandType) {
		case MeshControlCommandType::NodeIdentificationRequest:
			nodeIdRequestHandlerGated(controlPath);
			break;
		case MeshControlCommandType::NodeIdentificationResponse:
			nodeIdResponseHandlerGated(controlPath, &controlCommand->data.nodeIdResponse);
			break;
		case MeshControlCommandType::LinkIdentification:
			linkIdHandlerGated(controlPath, &controlCommand->data.linkId);
			break;
		case MeshControlCommandType::ChannelLinkSwap:
			channelLinkSwapHandlerGated(controlPath);
			break;
		case MeshControlCommandType::ChannelReady:
			channelReadyHandlerGated(controlPath, &controlCommand->data.channelReady);
			break;
		case MeshControlCommandType::PrimaryLinkPing:
			pingHandlerGated(controlPath);
			break;
		case MeshControlCommandType::SecondaryLinkPong:
			pongHandlerGated(controlPath);
			break;
		case MeshControlCommandType::TxAssignmentNotification:
			txAssignmentHandlerGated(controlPath, &controlCommand->data.txAssignment);
			break;
		case MeshControlCommandType::TxForwardNotificationCommand:
			txForwardNotificationHandlerGated(controlPath, &controlCommand->data.txForward);
			break;
		case MeshControlCommandType::RawMessage:
			controlMessageHandlerGated(controlPath, controlMessage);
			break;
		case MeshControlCommandType::NewGeneration:
			newGenerationHandlerGated(controlPath, &controlCommand->data.startGeneration);
			break;
		default:
			ERROR("Unknown command: %d\n", controlCommand->commandType);
			break;
		}

		controlPath->queueRxCommand(rxControlCommand);
		rxControlCommand->release();
	}
	return kIOReturnSuccess;
}

void
AppleCIOMeshService::nodeIdRequestHandlerGated(AppleCIOMeshControlPath * path)
{
	MeshControlCommand nodeIdResponse;
	nodeIdResponse.commandType                        = MeshControlCommandType::NodeIdentificationResponse;
	nodeIdResponse.data.nodeIdResponse.configNodeId   = _nodeId;
	nodeIdResponse.data.nodeIdResponse.hardwareNodeId = _partnerMap.currentHardwareNode;

	LOG("nodeIdRequestHandler path %p link[%d] in chassis <%s> for node %d\n", path, path->getLink()->getController()->getRID(),
	    &_chassisId.id[0], _nodeId);

	memcpy(&nodeIdResponse.data.nodeIdResponse.chassisId, &_chassisId, sizeof(_chassisId));

	IOReturn status = path->submitControlCommand(&nodeIdResponse);
	if (status != kIOReturnSuccess) {
		ERROR("Failed to send NodeIdentificationResponse on path: %p. acio: %d\n", path,
		      path->getLink()->getController()->getRID());
	}
}

void
AppleCIOMeshService::nodeIdResponseHandlerGated(AppleCIOMeshControlPath * path, NodeIdentificationResponseCommand * nodeIdResponse)
{
	LOG("nodeIdResponseHandler path %p link[%d] is connected to: %d in chassis <%s>\n", path,
	    path->getLink()->getController()->getRID(), nodeIdResponse->configNodeId, nodeIdResponse->chassisId);

	if (path->getLink()->hasConnectedNodeId()) {
		if (nodeIdResponse->configNodeId != path->getLink()->getConnectedNodeId() ||
		    nodeIdResponse->hardwareNodeId != path->getLink()->getConnectedNodeId()) {
			LOG("!!!!!! Link was previously assigned to NodeId:[%d] with hardware partner [%d]. Got NodeId:[%d] and hardware "
			    "partner [%d]\n",
			    path->getLink()->getConnectedNodeId(), path->getLink()->getConnectedNodeId(), nodeIdResponse->configNodeId,
			    nodeIdResponse->hardwareNodeId);
		}

		return;
	}

	path->getLink()->setConnectedChassisId(nodeIdResponse->chassisId);
	path->getLink()->setConnectedNodeId(nodeIdResponse->configNodeId);
	path->getLink()->setConnectedHardwareNodeId(nodeIdResponse->hardwareNodeId);

	// If our partner map has been initialized, we need to make sure
	// the node ID response's hardware partner ID is matching the expected.
	// If not, the link is held in limbo and we will not create channels.
	// This is so we can track all the misconnected links.
	if (_partnerMap.initialized) {
		auto expectedPartner = _partnerMap.hardwareNodes[path->getLink()->getRID()];
		if (nodeIdResponse->hardwareNodeId != expectedPartner) {
			path->getLink()->setMismatchedHardwareParther(true);

			LOG("!!!!!! Mismatch ACIO%d, expecting hardware partner [%d]. Got [%d]\n", path->getLink()->getRID(), expectedPartner,
			    nodeIdResponse->hardwareNodeId);
			return;
		}
	}

	path->getLink()->setMismatchedHardwareParther(false);
	_assignLinkToPartnerNodeGated(path->getLink());
}

void
AppleCIOMeshService::linkIdHandlerGated(AppleCIOMeshControlPath * path, LinkIdentificationCommand * linkId)
{
	auto channel = path->getLink()->getChannel();

	LOG("linkIdHandler: Node:%d LinkIdx:%d link[%d]\n", linkId->nodeId, linkId->linkIdx,
	    path->getLink()->getController()->getRID());

	// if the channel is not set, then we got told by the other side
	// what their link order is, that's fine. we just have to save it
	// in pending, and when we make the channel add it in.

	// we can still send our link identification whenever, and things
	// will sync up
	if (!channel) {
		LOG("channel not assigned for link[%d]\n", path->getLink()->getController()->getRID());
		path->getLink()->setPendingLinkId(linkId);
		return;
	}

	channel->connectingNodeRegister(path->getLink(), linkId->nodeId, linkId->linkIdx);
}

void
AppleCIOMeshService::channelLinkSwapHandlerGated(AppleCIOMeshControlPath * path)
{
	LOG("channelLinkSwapHandler for link %d\n", path->getLink()->getController()->getRID());
	auto channel = path->getLink()->getChannel();
	if (!channel) {
		LOG("Got a channel link swap when link %d does not have a channel", path->getLink()->getController()->getRID());
		return;
	}

	channel->channelSwapRequested();
}

void
AppleCIOMeshService::channelReadyHandlerGated(AppleCIOMeshControlPath * path, ChannelReadyCommand * ready)
{
	LOG("channelReadyHandler\n");
	auto channel = path->getLink()->getChannel();
	if (!channel) {
		LOG("Got a channel ready when link %d does not have a channel", path->getLink()->getController()->getRID());
		return;
	}

	LOG("channelReady: principal:%d agent:%d\n", ready->nodeIdA, ready->nodeIdB);

	channel->channelReady(ready->nodeIdA, ready->nodeIdB);
}

void
AppleCIOMeshService::pingHandlerGated(AppleCIOMeshControlPath * path)
{
	LOG("pingHandler %d\n", path->getLink()->getController()->getRID());
	auto channel = path->getLink()->getChannel();
	if (!channel) {
		LOG("Got a ping when link %d does not have a channel", path->getLink()->getController()->getRID());
		return;
	}

	channel->pingReceived(path->getLink());
	notifyMeshChannelChange(path->getLink()->getChannel());
}

void
AppleCIOMeshService::pongHandlerGated(AppleCIOMeshControlPath * path)
{
	LOG("pongHandler %d\n", path->getLink()->getController()->getRID());
	auto channel = path->getLink()->getChannel();
	if (!channel) {
		LOG("Got a pong when link %d does not have a channel", path->getLink()->getController()->getRID());
		return;
	}

	channel->pongReceived(path->getLink());
	notifyMeshChannelChange(path->getLink()->getChannel());
}

void
AppleCIOMeshService::txAssignmentHandlerGated(AppleCIOMeshControlPath * controlPath, TxAssignmentNotificationCommand * txAssignment)
{
	LOG("txAssignmentHandler %d source:%d path:%d\n", controlPath->getLink()->getController()->getRID(), txAssignment->sourceNodeId,
	    txAssignment->pathIndex);
	auto channel = controlPath->getLink()->getChannel();
	if (!channel) {
		LOG("Got a tx assignment notification when link %d does not have a channel",
		    controlPath->getLink()->getController()->getRID());
		return;
	}

	channel->receiveTxAssignmentNotification(txAssignment);
}

void
AppleCIOMeshService::txForwardNotificationHandlerGated(AppleCIOMeshControlPath * controlPath,
                                                       TxForwardNotificationCommand * txForward)
{
	LOG("txForwardNotification source:%d forwarder:%d receiver:%d\n", txForward->sourceNode, txForward->forwarder,
	    txForward->receiver);

	// Bump up the numNodesMesh if it is set, we will reset it
	_numNodesMesh++;

	// someone is forwarding our data, let's save this route to the node
	if (txForward->sourceNode == getLocalNodeId()) {
		_commandRouter->addRouteTo(txForward->receiver, txForward->forwarder);
		return;
	}

	// we are not the source, we need to forward this message to the source
	MCUCI::MeshChannelIdx destChannel = _commandRouter->getCIOChannelForDestination(txForward->sourceNode);
	if (destChannel == controlPath->getLink()->getChannel()->getChannelIndex()) {
		LOG("Source node[%d] channel[%d] is the same as forwarder[%d] channel[%d]. This is a loop.", txForward->sourceNode,
		    destChannel, txForward->forwarder, controlPath->getLink()->getChannel()->getChannelIndex());
		return;
	}

	MeshControlCommand forwardNotificationCmd;
	forwardNotificationCmd.commandType = MeshControlCommandType::TxForwardNotificationCommand;

	forwardNotificationCmd.data.txForward.forwarder  = txForward->forwarder;
	forwardNotificationCmd.data.txForward.sourceNode = txForward->sourceNode;
	forwardNotificationCmd.data.txForward.receiver   = txForward->receiver;

	if (destChannel >= 0 && destChannel < kMaxMeshChannelCount && _meshChannels[destChannel] != NULL) {
		_meshChannels[destChannel]->sendControlCommand(&forwardNotificationCmd);
	}
}

void
AppleCIOMeshService::controlMessageHandlerGated(AppleCIOMeshControlPath * path, MeshControlMessage * message)
{
	//		LOG("controlMessageHandlerGated source:%d dest:%d\n", message->header.sourceNode, message->header.destinationNode);
	if (message->header.data.controlMessage.destinationNode == getLocalNodeId()) {
		_dummyRxMeshMessage.node   = message->header.data.controlMessage.sourceNode;
		_dummyRxMeshMessage.length = message->header.data.controlMessage.length;
		memcpy(_dummyRxMeshMessage.rawData, message->data, kCommandMessageDataSize);

		IOLockLock(_ucLock);
		for (uint32_t i = 0; i < _configUserClients->getCount(); i++) {
			auto uc = (AppleCIOMeshConfigUserClient *)_configUserClients->getObject(i);
			uc->notifyControlMessage(&_dummyRxMeshMessage);
		}
		IOLockUnlock(_ucLock);
		return;
	}

	MCUCI::MeshChannelIdx destChannel =
	    _commandRouter->getCIOChannelForDestination(message->header.data.controlMessage.destinationNode);
	auto link    = path->getLink();
	auto channel = link ? link->getChannel() : nullptr;
	if (channel == nullptr || destChannel == channel->getChannelIndex()) {
		LOG("Sending control message from sourceNode[%d] to destinationNode[%d] is the same channel[%d] or it's a non-existent "
		    "channel (%p).",
		    message->header.data.controlMessage.sourceNode, message->header.data.controlMessage.destinationNode, destChannel,
		    channel);
		return;
	}

	if (destChannel >= 0 && destChannel < kMaxMeshChannelCount && _meshChannels[destChannel] != NULL) {
		_meshChannels[destChannel]->sendRawControlMessage(message);
	}
}

void
AppleCIOMeshService::newGenerationHandlerGated(__unused AppleCIOMeshControlPath * path, StartGenerationCommand * generation)
{
	if (generation->destinationNode == getLocalNodeId()) {
		uint32_t sourceNodeIndex = generation->sourceNode;
		if (sourceNodeIndex >= kMaxCIOMeshNodes) {
			ERROR("Source node %d exceeds the maximum number of nodes (%d)", sourceNodeIndex, kMaxCIOMeshNodes);
			return;
		}
		if (generation->generation != _receivedGeneration[sourceNodeIndex]) {
			LOG("node %d has a new client with generation %d (old gen: %d)\n", generation->sourceNode, generation->generation,
			    _receivedGeneration[sourceNodeIndex]);
			_newClient[sourceNodeIndex]          = true;
			_receivedGeneration[sourceNodeIndex] = (int32_t)generation->generation;
		}
		_checkGenerationReady();
	} else {
		if (generation->destinationNode >= kMaxCIOMeshNodes) {
			ERROR("Destination node %d exceeds the maximum number of nodes (%d)", generation->destinationNode, kMaxCIOMeshNodes);
			return;
		}
		// We need to forward the generation message to the receiver.
		MCUCI::MeshChannelIdx destChannel = _commandRouter->getCIOChannelForDestination(generation->destinationNode);

		if (destChannel != MCUCI::kUnassignedNode && destChannel < kMaxMeshChannelCount) {
			MeshControlCommand generationCmd;
			generationCmd.commandType                          = MeshControlCommandType::NewGeneration;
			generationCmd.data.startGeneration.sourceNode      = generation->sourceNode;
			generationCmd.data.startGeneration.destinationNode = generation->destinationNode;
			generationCmd.data.startGeneration.generation      = generation->generation;

			if (destChannel >= 0 && destChannel < kMaxMeshChannelCount && _meshChannels[destChannel] != NULL) {
				_meshChannels[destChannel]->sendControlCommand(&generationCmd);
			}
		}
	}
}

// MARK: - User Client Methods

IOReturn
AppleCIOMeshService::allocateSharedMemory(const MUCI::SharedMemory * memory, task_t owningTask, AppleCIOMeshUserClient * uc)
{
	IOWorkLoop::Action action = OSMemberFunctionCast(IOWorkLoop::Action, this, &AppleCIOMeshService::_allocateSharedMemoryUCGated);
	return getWorkLoop()->runAction(action, this, (void *)memory, (void *)owningTask, (void *)uc);
}

IOReturn
AppleCIOMeshService::deallocateSharedMemory(const MUCI::SharedMemoryRef * memory, task_t owningTask, AppleCIOMeshUserClient * uc)
{
	IOWorkLoop::Action action =
	    OSMemberFunctionCast(IOWorkLoop::Action, this, &AppleCIOMeshService::_deallocateSharedMemoryUCGated);
	return getWorkLoop()->runAction(action, this, (void *)memory, (void *)owningTask, (void *)uc);
}

IOReturn
AppleCIOMeshService::assignMemoryChunk(const MUCI::AssignChunks * assignment)
{
	IOWorkLoop::Action action = OSMemberFunctionCast(IOWorkLoop::Action, this, &AppleCIOMeshService::_assignMemoryChunkUCGated);
	return getWorkLoop()->runAction(action, this, (void *)assignment);
}

IOReturn
AppleCIOMeshService::printBufferState(const MUCI::BufferId * bufferId)
{
	IOWorkLoop::Action action = OSMemberFunctionCast(IOWorkLoop::Action, this, &AppleCIOMeshService::_printBufferStateUCGated);
	return getWorkLoop()->runAction(action, this, (void *)bufferId);
}

IOReturn
AppleCIOMeshService::overrideRuntimePrepare(const MUCI::BufferId * bufferId)
{
	IOWorkLoop::Action action =
	    OSMemberFunctionCast(IOWorkLoop::Action, this, &AppleCIOMeshService::_overrideRuntimePrepareUCGated);
	return getWorkLoop()->runAction(action, this, (void *)bufferId);
}

IOReturn
AppleCIOMeshService::setForwardChain(const MUCI::ForwardChain * forwardChain, MUCI::ForwardChainId * chainId)
{
	IOWorkLoop::Action action = OSMemberFunctionCast(IOWorkLoop::Action, this, &AppleCIOMeshService::_setForwardChainUCGated);
	return getWorkLoop()->runAction(action, this, (void *)forwardChain, (void *)chainId);
}

IOReturn
AppleCIOMeshService::startNewGeneration()
{
	IOWorkLoop::Action action = OSMemberFunctionCast(IOWorkLoop::Action, this, &AppleCIOMeshService::_startNewGenerationUCGated);
	return getWorkLoop()->runAction(action, this);
}

IOReturn
AppleCIOMeshService::setMaxWaitTime(uint64_t maxWaitTime)
{
	IOWorkLoop::Action action = OSMemberFunctionCast(IOWorkLoop::Action, this, &AppleCIOMeshService::_setMaxWaitTimeUCGated);
	return getWorkLoop()->runAction(action, this, (void *)maxWaitTime);
}

IOReturn
AppleCIOMeshService::_overrideRuntimePrepareUCGated(void * bufferIdArg)
{
	MUCI::BufferId * bufferId = (MUCI::BufferId *)bufferIdArg;

	auto sm = getSharedMemory(*bufferId);
	if (!sm) {
		ERROR("Invalid bufferId: %lld\n", *bufferId);
		return kIOReturnBadArgument;
	}

	sm->setRequiresRuntimePrepare(false);
	return kIOReturnSuccess;
}

IOReturn
AppleCIOMeshService::_startThreadsUCGated()
{
	if (_sharedMemoryRegions->getCount() != 0) {
		// Threads should be started before any shared memory buffers are created.
		panic("Starting threads when %d sharedMemory are allocated.\n", _sharedMemoryRegions->getCount());
	}

	if (!_forwarder) {
		panic("No forwarder to start");
	}

	// Wait for the previous threads to stop.
	uint64_t start = mach_absolute_time();
	uint64_t now, limit;
	nanoseconds_to_absolutetime(kThreadStartStopTimeNs, &limit);
	uint64_t ctr = 0;

	while (atomic_load(&_commandeerActive) == true || !_forwarder->isStopped()) {
		ctr++;

		if ((ctr % 10000000) == 0) {
			now = mach_absolute_time();

			if ((now - start) > limit) {
				LOG("Forwarder or commandeer did not stop within timeout.\n")
				return kIOReturnTimeout;
			}
		}
	}

	if (_forwarder->isStarted()) {
		LOG("Forwarder is already active, cannot start twice.\n");
		return kIOReturnStillOpen;
	}

	// Start the commandeer thread
	atomic_store(&_commandeerActivated, true);
	_commandeerEventSource->enable();
	LOG("Kicking the commandeer!\n");
	_commandeerEventSource->interruptOccurred(this, nullptr, 0);

	// Now start the forwarder too
	_forwarder->start();

	// Wait for forwarder and commandeer to start -- upto 30 seconds
	start = mach_absolute_time();
	ctr   = 0;

	while (atomic_load(&_commandeerActive) == false || _forwarder->isStarted() == false) {
		ctr++;
		if ((ctr % 10000000) == 0) {
			now = mach_absolute_time();

			if ((now - start) > limit) {
				LOG("Forwarder or commandeer did not start within timeout.\n")
				return kIOReturnTimeout;
			}
		}
	}

	return kIOReturnSuccess;
}

IOReturn
AppleCIOMeshService::_stopThreadsUCGated()
{
	if (_sharedMemoryRegions->getCount() != 0) {
		// Stop should be called after all shared memory regions are torn down
		panic("Stopping threads when %d sharedMemory are allocated.\n", _sharedMemoryRegions->getCount());
	}

	// This is only called after all the forwards are finished.
	if (!_forwarder) {
		panic("No forwarder to stop");
	}

	// Stop the commandeer and forwarder thread, wait for both of them to
	// stop.
	atomic_store(&_commandeerActivated, false);
	_commandeerEventSource->disable();

	_forwarder->stopAllForwardChains();
	_forwarder->stop();

	uint64_t start = mach_absolute_time();
	uint64_t now, limit;
	nanoseconds_to_absolutetime(kThreadStartStopTimeNs, &limit);
	uint64_t ctr = 0;

	while (atomic_load(&_commandeerActive) || _forwarder->isStarted()) {
		ctr++;
		if ((ctr % 10000000) == 0) {
			now = mach_absolute_time();

			if ((now - start) > limit) {
				LOG("Forwarder or commandeer did not stop within timeout.\n")
				return kIOReturnTimeout;
			}
		}
	}

	return kIOReturnSuccess;
}

IOReturn
AppleCIOMeshService::setExtendedNodeId(const MCUCI::NodeId * nodeId)
{
	IOWorkLoop::Action action = OSMemberFunctionCast(IOWorkLoop::Action, this, &AppleCIOMeshService::_setNodeIdUCGated);
	return getWorkLoop()->runAction(action, this, (void *)nodeId);
}

IOReturn
AppleCIOMeshService::setEnsembleSize(const MCUCI::EnsembleSize * ensembleSize)
{
	IOWorkLoop::Action action = OSMemberFunctionCast(IOWorkLoop::Action, this, &AppleCIOMeshService::_setEnsembleSizeUCGated);
	return getWorkLoop()->runAction(action, this, (void *)ensembleSize);
}

IOReturn
AppleCIOMeshService::setChassisId(const MCUCI::ChassisId * chassisId)
{
	IOWorkLoop::Action action = OSMemberFunctionCast(IOWorkLoop::Action, this, &AppleCIOMeshService::_setChassisIdUCGated);
	return getWorkLoop()->runAction(action, this, (void *)chassisId);
}

IOReturn
AppleCIOMeshService::addPeerHostname(const MCUCI::PeerNode * peerHostname)
{
	IOWorkLoop::Action action = OSMemberFunctionCast(IOWorkLoop::Action, this, &AppleCIOMeshService::_addPeerHostnameUCGated);
	return getWorkLoop()->runAction(action, this, (void *)peerHostname);
}

IOReturn
AppleCIOMeshService::getPeerHostnames(MCUCI::PeerHostnames * outPeerHostnames)
{
	IOWorkLoop::Action action = OSMemberFunctionCast(IOWorkLoop::Action, this, &AppleCIOMeshService::_getPeerHostnamesUCGated);
	return getWorkLoop()->runAction(action, this, outPeerHostnames);
}

IOReturn
AppleCIOMeshService::activateMesh()
{
	IOWorkLoop::Action action = OSMemberFunctionCast(IOWorkLoop::Action, this, &AppleCIOMeshService::_activateMeshUCGated);
	return getWorkLoop()->runAction(action, this);
}

IOReturn
AppleCIOMeshService::deactivateMesh()
{
	IOWorkLoop::Action action = OSMemberFunctionCast(IOWorkLoop::Action, this, &AppleCIOMeshService::_deactivateMeshUCGated);
	return getWorkLoop()->runAction(action, this);
}

IOReturn
AppleCIOMeshService::lockCIO()
{
	IOWorkLoop::Action action = OSMemberFunctionCast(IOWorkLoop::Action, this, &AppleCIOMeshService::_lockCIOUCGated);
	return getWorkLoop()->runAction(action, this);
}

bool
AppleCIOMeshService::isCIOLocked()
{
	return _acioLock;
}

IOReturn
AppleCIOMeshService::disconnectChannel(const MCUCI::MeshChannelIdx * channelIdx)
{
	IOWorkLoop::Action action = OSMemberFunctionCast(IOWorkLoop::Action, this, &AppleCIOMeshService::_disconnectChannelUCGated);
	return getWorkLoop()->runAction(action, this, (void *)channelIdx);
}

IOReturn
AppleCIOMeshService::establishTXConnection(const MCUCI::NodeConnectionInfo * connection)
{
	IOWorkLoop::Action action = OSMemberFunctionCast(IOWorkLoop::Action, this, &AppleCIOMeshService::_establishTXConnectionUCGated);
	return getWorkLoop()->runAction(action, this, (void *)connection);
}

IOReturn
AppleCIOMeshService::sendControlMessage(const MCUCI::MeshMessage * message)
{
	IOWorkLoop::Action action = OSMemberFunctionCast(IOWorkLoop::Action, this, &AppleCIOMeshService::_sendControlMessageUCGated);
	return getWorkLoop()->runAction(action, this, (void *)message);
}

IOReturn
AppleCIOMeshService::getConnectedNodes(MCUCI::ConnectedNodes * connectedNodes)
{
	IOWorkLoop::Action action = OSMemberFunctionCast(IOWorkLoop::Action, this, &AppleCIOMeshService::_getConnectedNodesUCGated);
	return getWorkLoop()->runAction(action, this, (void *)connectedNodes);
}

IOReturn
AppleCIOMeshService::getCIOConnectionState(MCUCI::CIOConnections * cioConnections)
{
	IOWorkLoop::Action action = OSMemberFunctionCast(IOWorkLoop::Action, this, &AppleCIOMeshService::_getCIOConnectionStateUCGated);
	return getWorkLoop()->runAction(action, this, (void *)cioConnections);
}

IOReturn
AppleCIOMeshService::cryptoKeyReset()
{
	IOWorkLoop::Action action = OSMemberFunctionCast(IOWorkLoop::Action, this, &AppleCIOMeshService::_cryptoKeyResetUCGated);
	return getWorkLoop()->runAction(action, this);
}

IOReturn
AppleCIOMeshService::cryptoKeyMarkUsed()
{
	IOWorkLoop::Action action = OSMemberFunctionCast(IOWorkLoop::Action, this, &AppleCIOMeshService::_cryptoKeyMarkUsedUCGated);
	return getWorkLoop()->runAction(action, this);
}

bool
AppleCIOMeshService::cryptoKeyCheckUsed()
{
	return atomic_load(&_cryptoKeyUsed);
}

IOReturn
AppleCIOMeshService::getBuffersAllocatedCounter(uint64_t * buffersAllocated)
{
	IOWorkLoop::Action action =
	    OSMemberFunctionCast(IOWorkLoop::Action, this, &AppleCIOMeshService::_getBuffersAllocatedCounterUCGated);
	return getWorkLoop()->runAction(action, this, (void *)buffersAllocated);
}

bool
AppleCIOMeshService::canActivate(const MCUCI::MeshNodeCount * nodeCount)
{
	if (_meshConfig != kJ236Hypercube) {
		panic("Only supported for kJ236Hypercube configuration");
	}

	LOG("Node count is %d\n", *nodeCount);

	if (*nodeCount == 1) {
		return true;
	}

	bool canActivateMesh           = false;
	auto armIODeviceEntry          = IORegistryEntry::fromPath("IODeviceTree:/arm-io");
	OSCollectionIterator * devices = IODTFindMatchingEntries(armIODeviceEntry, kIODTExclusive, 0);
	OSSafeReleaseNULL(armIODeviceEntry);

	if (devices == NULL) {
		return false;
	}

	devices->reset();

	if (*nodeCount == kMaxCIOMeshNodes) {
		canActivateMesh = _canActivate8(devices);
	} else if (*nodeCount == 4) {
		canActivateMesh = _canActivate4(devices);
	} else if (*nodeCount == 2) {
		canActivateMesh = _canActivate2(devices);
	}

	OSSafeReleaseNULL(devices);

	LOG("canActivate in meshservice returning %d\n", canActivateMesh);
	return canActivateMesh;
}

bool
AppleCIOMeshService::_canActivate8(OSCollectionIterator * devices)
{
	OSString * acioCompatible = OSString::withCString("acio");
	uint8_t xdomainlinkcount  = 0;

	// For 8 node ensembles, all 8 acio ports should have a thunderbolt link
	while (auto device = (IORegistryEntry *)devices->getNextObject()) {
		if (!strncmp(device->getName(), "acio", 4) && device->propertyHasValue("compatible", acioCompatible)) {
			if (!_checkForXDomainLinkService(device)) {
				LOG("%s failed to find xdomain link\n.", device->getName());
				return false;
			} else {
				LOG("Found xdomain link for %s\n.", device->getName());
				xdomainlinkcount += 1;
			}
		}
	}

	OSSafeReleaseNULL(acioCompatible);

	LOG("Found %d xdomain links\n.", xdomainlinkcount);

	return xdomainlinkcount == 8;
}

bool
AppleCIOMeshService::_canActivate4(OSCollectionIterator * devices)
{
	OSString * acioCompatible = OSString::withCString("acio");
	uint8_t xdomainlinkcount  = 0;

	// For 4 node ensembles, all acio ports except 1 and 3 should have an x domain
	// link.
	while (auto device = (IORegistryEntry *)devices->getNextObject()) {
		if (!strncmp(device->getName(), "acio", 4) && device->propertyHasValue("compatible", acioCompatible)) {
			auto deviceName = device->getName();
			int acioNumber  = deviceName[4] - '0';

			if (acioNumber != 1 && acioNumber != 3) {
				if (!_checkForXDomainLinkService(device)) {
					LOG("%s failed to find xdomain link\n.", device->getName());
					return false;
				} else {
					LOG("Found xdomain link for %s\n.", device->getName());
					xdomainlinkcount += 1;
				}
			}
		}
	}

	OSSafeReleaseNULL(acioCompatible);

	LOG("Found %d xdomain links\n.", xdomainlinkcount);

	return xdomainlinkcount == 6;
}

bool
AppleCIOMeshService::_canActivate2(OSCollectionIterator * devices)
{
	OSString * acioCompatible = OSString::withCString("acio");
	uint8_t xdomainlinkcount  = 0;

	// For 2 node ensembles, acio ports 4 and 7 should have an x domain link.
	while (auto device = (IORegistryEntry *)devices->getNextObject()) {
		if (!strncmp(device->getName(), "acio", 4) && device->propertyHasValue("compatible", acioCompatible)) {
			auto deviceName = device->getName();
			int acioNumber  = deviceName[4] - '0';

			if (acioNumber == 4 || acioNumber == 7) {
				if (!_checkForXDomainLinkService(device)) {
					LOG("%s failed to find xdomain link\n.", device->getName());
					return false;
				} else {
					LOG("Found xdomain link for %s\n.", device->getName());
					xdomainlinkcount += 1;
				}
			}
		}
	}

	OSSafeReleaseNULL(acioCompatible);

	LOG("Found %d xdomain links\n.", xdomainlinkcount);

	return xdomainlinkcount == 2;
}

bool
AppleCIOMeshService::_checkForXDomainLinkService(IORegistryEntry * reg)
{
	OSIterator * childIterator = reg->getChildIterator(gIOServicePlane);
	if (childIterator != NULL) {
		OSObject * child = NULL;
		while ((child = childIterator->getNextObject()) != NULL) {
			IORegistryEntry * childEntry = OSDynamicCast(IORegistryEntry, child);
			if (childEntry == NULL) {
				continue;
			}

			IOService * service = OSDynamicCast(IOService, child);
			if (service == NULL) {
				continue;
			}

			IOThunderboltXDomainLink * xdomainLink = OSDynamicCast(IOThunderboltXDomainLink, child);
			if (xdomainLink != NULL) {
				return true;
			}

			if (_checkForXDomainLinkService(childEntry)) {
				return true;
			}
		}
	}

	return false;
}

// MARK: - User Client Methods Not Gated

IOReturn
AppleCIOMeshService::sendAssignedData(
    AppleCIOMeshSharedMemory * sharedMem, const int64_t offset, const uint8_t linkIterMask, char * tag, size_t tagSz)
{
	sharedMem->dispatch(offset, linkIterMask, tag, tagSz);

	return kIOReturnSuccess;
}

IOReturn
AppleCIOMeshService::prepareCommand(AppleCIOMeshSharedMemory * sharedMem, const int64_t offset)
{
	sharedMem->prepareCommand(offset);

	return kIOReturnSuccess;
}

void
AppleCIOMeshService::markForwardIncomplete(AppleCIOMeshSharedMemory * sharedMem, const int64_t offset)
{
	sharedMem->markCommandForwardIncomplete(offset);
}

IOReturn
AppleCIOMeshService::waitData(
    AppleCIOMeshSharedMemory * sharedMem, const int64_t offset, bool * interrupted, char * tag, size_t tagSz)
{
	uint64_t ctr = 0;
	uint64_t start, now;
	start = mach_absolute_time();
	now   = start;

	while (!sharedMem->checkAssignmentReady(offset, interrupted) && (now - start) < _maxWaitTime) {
		ctr++;
		if ((ctr % 10000000) == 0) {
			now = mach_absolute_time();
		}
	}
	if ((now - start) >= _maxWaitTime) {
		*interrupted = true;
		ERROR("waitData timedout offset 0x%llx...\n", offset);
		return kIOReturnTimeout;
	}

	if (*interrupted) {
		LOG("waitData %s offset 0x%llx in bufferId %lld... ctr %lld\n", interrupted ? "interupted" : "failed", offset,
		    sharedMem->getBufferId(), ctr);
		return kIOReturnIOError; // not really great but there is no equivalent to EINTR
	}

	if (sharedMem->isAssignmentInput(offset)) {
		// wait for forwards to complete too if there are any
		while (!sharedMem->checkAssignmentForwardComplete(offset, interrupted) && (now - start) < _maxWaitTime) {
			ctr++;
			if ((ctr % 10000000) == 0) {
				now = mach_absolute_time();
			}
		}
		if ((now - start) >= _maxWaitTime) {
			*interrupted = true;
			ERROR("waitData timedout during Forward offset 0x%llx...\n", offset);
			return kIOReturnTimeout;
		}

		if (*interrupted) {
			LOG("waitData %s during forward offset 0x%llx in bufferId %lld... ctr %lld\n", interrupted ? "interupted" : "failed",
			    offset, sharedMem->getBufferId(), ctr);
			return kIOReturnIOError; // not really great but there is no equivalent to EINTR
		}

		// If there are more than 2 links we will grab tag data on both and verify
		// they are equal. If they aren't, we will panic since we only return 1
		// tag in an assignment here.
		// TODO: Change waitData to return multiple tags.
		char tag1[kTagSize] = {0};
		char tag2[kTagSize] = {0};

		sharedMem->readAssignmentTagForLink(offset, 0, tag1, tagSz);
		if (_linksPerChannel > 1) {
			sharedMem->readAssignmentTagForLink(offset, 1, tag2, tagSz);
			if (memcmp(tag1, tag2, kTagSize) != 0) {
				panic("Tags are not identical for link0 and link1 %d-%d-%d-%d--%d-%d-%d-%d .. %d-%d-%d-%d--%d-%d-%d-%d ..", tag1[0],
				      tag1[1], tag1[2], tag1[3], tag1[4], tag1[5], tag1[6], tag1[7], tag2[0], tag2[1], tag2[2], tag2[3], tag2[4],
				      tag2[5], tag2[6], tag2[7]);
			}
		}

		memcpy(tag, tag1, tagSz);
	}

	return kIOReturnSuccess;
}

IOReturn
AppleCIOMeshService::startForwardChain(const MUCI::ForwardChainId forwardChainId, const uint32_t elements)
{
	if (_forwarder == nullptr) {
		LOG("no forwarder!\n");
		return kIOReturnIOError;
	}

	_forwarder->startForwardChain(forwardChainId, elements);

	return kIOReturnSuccess;
}

IOReturn
AppleCIOMeshService::stopForwardChain()
{
	// We will simply stop forward chains when the UC unregisters.
	return kIOReturnSuccess;
}

void
AppleCIOMeshService::forwarderFinishedClearingMemory()
{
	atomic_store(&_forwarderFinishedRelease, true);
}

void
AppleCIOMeshService::commandeerSend(
    AppleCIOMeshSharedMemory * sm, int64_t offset, AppleCIOMeshUserClient * uc, char * tag, size_t tagSz)
{
	uint64_t ctr = 0;
	while (atomic_load(&_commandeerSendData) && ctr < kMaxCommandeerWaitCount) {
		// burn, baby burn (because we can't stomp on the work that it's currently doing)
		ctr++;
	}

	if (atomic_load(&_commandeerSendData)) {
		panic("can't send while sending is going on SMSend bufId %lld / sm bufId %lld SMOffset 0x%llx offset 0x%llx ctr %llu!\n",
		      _commandeerSMSend ? _commandeerSMSend->getId() : 0, sm->getId(), _commandeerSMSendOffset, offset, ctr);
	}

	sm->retain();
	uc->retain();

	_commandeerSMSend         = sm;
	_commandeerSMSendOffset   = offset;
	_commandeerSendUserClient = uc;
	_commandeerSendTag        = tag;
	_commandeerSendTagSz      = tagSz;
	_commanderSMSendStart     = mach_absolute_time();
	_commanderSMSendCounter   = 0;
	atomic_store(&_commandeerSendData, true);
}

void
AppleCIOMeshService::commandeerDripPrepare(AppleCIOMeshSharedMemory * sm, int64_t offset, AppleCIOMeshSharedMemory * sendingSM)
{
	uint64_t ctr = 0;
	while (atomic_load(&_commandeerPrepareData) && ctr < kMaxCommandeerWaitCount) {
		// burn, baby burn (because we can't stomp on the work that it's currently doing)
		ctr++;
	}

	if (atomic_load(&_commandeerPrepareData)) {
		panic(
		    "can't prepare while preparing is going on SMPrepare bufId %lld / sm bufId %lld SMOffset 0x%llx offset 0x%llx ctr "
		    "%llu!\n",
		    _commandeerSMPrepare ? _commandeerSMPrepare->getId() : 0, sm->getId(), _commandeerSMPrepareOffset, offset, ctr);
	}

	sm->retain();
	sendingSM->retain();

	_commandeerSMPrepare                = sm;
	_commandeerPreparePreviousSM        = sendingSM;
	_commandeerPreparePreviousComplete  = false;
	_commandeerSMPrepareOffset          = offset;
	_commandeerPrepareDripAssignmentIdx = 0;
	_commandeerPrepareDripOffsetIdx     = 0;
	_commandeerPrepareDripLinkIdx       = 0;

	atomic_store(&_commandeerPrepareData, true);
}

void
AppleCIOMeshService::commandeerBulkPrepare(AppleCIOMeshAssignment * assignment, uint8_t linkIdx)
{
	if (linkIdx == 0) {
		_commandeerPrepareAssignmentQueue0->add((uintptr_t)assignment);
	} else {
		_commandeerPrepareAssignmentQueue1->add((uintptr_t)assignment);
	}
}

void
AppleCIOMeshService::commandeerPendingPrepare(NodeAssignmentMap * nodeMap, uint8_t linkIdx)
{
	if (linkIdx == 0) {
		_commandeerPendingPrepareQueue0->add((uintptr_t)nodeMap);
	} else {
		_commandeerPendingPrepareQueue1->add((uintptr_t)nodeMap);
	}
}

void
AppleCIOMeshService::commandeerPrepareForwardElement(ForwardActionChainElement * chainElement)
{
	_commandeerForwardPrepareQueue->add((uintptr_t)chainElement);
}

bool
AppleCIOMeshService::commandeerForwardHelp(ForwardAction * action)
{
	uintptr_t expected = 0;

	return atomic_compare_exchange_strong(&_commandeerForwardAction, &expected, (uintptr_t)action);
}

void
AppleCIOMeshService::clearCommandeerForwardHelp(ForwardAction * action)
{
	uintptr_t expected = (uintptr_t)action;

	if (atomic_compare_exchange_strong(&_commandeerForwardAction, &expected, 0)) {
		// XXXdbg - should wait for the commandeer to be done with this action
		LOG("successfully cleared out the Forward Action %p\n", action);
	}
}

// MARK: - Notifications
void
AppleCIOMeshService::notifySendComplete(MUCI::DataChunk & dataChunk)
{
	for (uint32_t i = 0; i < _userClients->getCount(); i++) {
		auto uc = (AppleCIOMeshUserClient *)_userClients->getObject(i);
		uc->notifySendDataComplete(dataChunk);
	}
}

void
AppleCIOMeshService::notifyDataAvailable(MUCI::DataChunk & dataChunk)
{
	for (uint32_t i = 0; i < _userClients->getCount(); i++) {
		auto uc = (AppleCIOMeshUserClient *)_userClients->getObject(i);
		uc->notifyDataAvailable(dataChunk);
	}
}

// MARK: - Config Notifications
void
AppleCIOMeshService::notifyMeshChannelChange(AppleCIOMeshChannel * channel)
{
	MCUCI::MeshChannelInfo channelInfo;
	channelInfo.node         = channel->getPartnerNodeId();
	channelInfo.channelIndex = 0xFF;

	for (uint8_t i = 0; i < _meshChannels.length(); i++) {
		if (channel == _meshChannels[i]) {
			channelInfo.channelIndex = i;
			break;
		}
	}

	assertf(channelInfo.channelIndex != 0xFF, "Could not find channel in meshChannels");

	if (channel->isReady()) {
		bool chassisIdSuccess = channel->getConnectedChassisId(&channelInfo.chassis);
		assertf(chassisIdSuccess == true, "Failed to get connected chassisId for a ready channel");
		LOG("chassis in notifymeshchannelchange is <%s> for channel %d.\n", channelInfo.chassis.id, channelInfo.channelIndex);
	}

	IOLockLock(_ucLock);
	for (uint32_t i = 0; i < _configUserClients->getCount(); i++) {
		auto uc = (AppleCIOMeshConfigUserClient *)_configUserClients->getObject(i);
		uc->notifyChannelChange(channelInfo, channel->isReady());
	}
	IOLockUnlock(_ucLock);
}

void
AppleCIOMeshService::notifyConnectionChange(const MCUCI::NodeConnectionInfo & connection, bool connected, bool TX)
{
	if (!TX && connected) {
		_commandRouter->addSourceNodeCIOChannel(connection.node, connection.channelIndex);
	}

	IOLockLock(_ucLock);
	for (uint32_t i = 0; i < _configUserClients->getCount(); i++) {
		auto uc = (AppleCIOMeshConfigUserClient *)_configUserClients->getObject(i);
		uc->notifyConnectionChange(connection, connected, TX);
	}
	IOLockUnlock(_ucLock);
}

IOReturn
AppleCIOMeshService::_getUserKeyGated(AppleCIOMeshCryptoKey * key)
{
	if (atomic_load(&_cryptoKeyUsed) == true) {
		LOG("getUserKey() error: current key already marked as used");
		return kIOReturnError;
	}
	memcpy(key, &_userKey, sizeof(AppleCIOMeshCryptoKey));
	return kIOReturnSuccess;
}

IOReturn
AppleCIOMeshService::getUserKey(AppleCIOMeshCryptoKey * key)
{
	IOWorkLoop::Action action = OSMemberFunctionCast(IOWorkLoop::Action, this, &AppleCIOMeshService::_getUserKeyGated);
	return getWorkLoop()->runAction(action, this, (void *)key);
}

IOReturn
AppleCIOMeshService::_setUserKeyGated(AppleCIOMeshCryptoKey * key)
{
	memcpy(&_userKey, key, sizeof(AppleCIOMeshCryptoKey));
	return kIOReturnSuccess;
}

void
AppleCIOMeshService::setUserKey(AppleCIOMeshCryptoKey * key)
{
	IOWorkLoop::Action action = OSMemberFunctionCast(IOWorkLoop::Action, this, &AppleCIOMeshService::_setUserKeyGated);
	getWorkLoop()->runAction(action, this, (void *)key);
}

IOReturn
AppleCIOMeshService::_getCryptoFlagsGated(MCUCI::CryptoFlags * flags)
{
	memcpy(flags, &_userCryptoFlags, sizeof(MCUCI::CryptoFlags));
	return kIOReturnSuccess;
}

void
AppleCIOMeshService::getCryptoFlags(MCUCI::CryptoFlags * flags)
{
	IOWorkLoop::Action action = OSMemberFunctionCast(IOWorkLoop::Action, this, &AppleCIOMeshService::_getCryptoFlagsGated);
	getWorkLoop()->runAction(action, this, flags);
}

IOReturn
AppleCIOMeshService::_setCryptoFlagsGated(MCUCI::CryptoFlags * flags)
{
	_userCryptoFlags = *flags;
	return kIOReturnSuccess;
}

void
AppleCIOMeshService::setCryptoFlags(MCUCI::CryptoFlags flags)
{
	IOWorkLoop::Action action = OSMemberFunctionCast(IOWorkLoop::Action, this, &AppleCIOMeshService::_setCryptoFlagsGated);
	getWorkLoop()->runAction(action, this, &flags);
}

// MARK: - Private methods
IOReturn
AppleCIOMeshService::_allocateSharedMemoryUCGated(void * sharedMemoryArg, void * taskArg, void * ucArg)
{
	if (_meshLinksHealthy() == false) {
		LOG("Some links in the mesh are disconnected.");
		return kIOReturnNotReady;
	}

	if (_maxBuffersPerKey != 0) {
		if ((_buffersAllocated + 1) >= _maxBuffersPerKey) {
			LOG("Too many buffers allocated. MaxBuffers:%lld CurrentBuffers:%lld\n", _maxBuffersPerKey, _buffersAllocated);
			return kIOReturnError;
		}
	}

	if (_cryptoKeyTimeLimit != 0) {
		uint64_t currentTime = mach_absolute_time();
		if (currentTime > _cryptoKeyTimeLimit) {
			LOG("Crypto key expired. TimeLimit:%lld CurrentTime:%lld\n", _cryptoKeyTimeLimit, currentTime);
			return kIOReturnError;
		}
	}

	MUCI::SharedMemory * memory = (MUCI::SharedMemory *)sharedMemoryArg;
	const task_t owningTask     = (const task_t)taskArg;
	AppleCIOMeshUserClient * uc = (AppleCIOMeshUserClient *)ucArg;

	if (memory->bufferId == 0) {
		LOG("Can't create a buffer with Id zero.\n");
		return kIOReturnBadArgument;
	}

	if (getSharedMemory(memory->bufferId)) {
		LOG("Shared memory with bufferId: %lld already allocated\n", memory->bufferId);
		return kIOReturnBadArgument;
	}

	if (memory->size == 0 || memory->chunkSize == 0 || memory->address == 0) {
		LOG("Invalid memory size:%lld, chunkSize:%lld, address:%llx\n", memory->size, memory->chunkSize, memory->address);
		return kIOReturnBadArgument;
	}

	// Divide the chunk size by the number of links in each channel.
	memory->chunkSize /= getLinksPerChannel();
	if (memory->chunkSize > kMaxChunkSizePerLink) {
		LOG("Invalid chunk size: %lld\n", memory->chunkSize);
		return kIOReturnBadArgument;
	}

	int64_t runningBreakdown = 0;
	for (int i = 0; i < kMaxTBTCommandCount; i++) {
		runningBreakdown += memory->forwardBreakdown[i];
	}
	if (runningBreakdown > memory->chunkSize) {
		LOG("Running breakdown %lld is greater than chunk size %lld\n", runningBreakdown, memory->chunkSize);
		return kIOReturnBadArgument;
	}

	// just in case...
	if (_dataPathRestartRequired) {
		LOG("gotcha!  dataPathRestart required before allocating shared memory so we gonna do it.\n");
		for (int j = 0; j < _meshLinks.length(); j++) {
			if (_meshLinks[j] != nullptr) {
				_meshLinks[j]->startDataPath();
			}
		}
		_dataPathRestartRequired = false;
	}

	AppleCIOMeshSharedMemory * sm =
	    AppleCIOMeshSharedMemory::allocate(this, memory, OSBoundedArrayRef<AppleCIOMeshLink *>(_meshLinks), owningTask, uc);

	if (sm == nullptr) {
		LOG("Failed to allocate shared memory: %lld\n", memory->bufferId);
		return kIOReturnNoMemory;
	}

	IOLockLock(_ucLock);

	// Start the threads before the first buffer allocation.
	if (_sharedMemoryRegions->getCount() == 0) {
		IOReturn ret = _startThreadsUCGated();
		if (ret != kIOReturnSuccess) {
			LOG("Failed to start threads: %x\n", ret);
			OSSafeReleaseNULL(sm);

			IOLockUnlock(_ucLock);
			return ret;
		}
	}

	_sharedMemoryRegions->setObject(sm);

	OSSafeReleaseNULL(sm); // because the array retains it

	IOLockUnlock(_ucLock);

	_buffersAllocated++;

	return kIOReturnSuccess;
}

IOReturn
AppleCIOMeshService::_deallocateSharedMemoryUCGated(void * sharedMemoryRefArg, __unused void * taskArg, __unused void * ucArg)
{
	MUCI::SharedMemoryRef * memory = (MUCI::SharedMemoryRef *)sharedMemoryRefArg;

	IOLockLock(_ucLock);

	if (_freeSharedMemoryUCGated(memory->bufferId) < 0) {
		IOLockUnlock(_ucLock);
		return kIOReturnNoMemory;
	}

	IOLockUnlock(_ucLock);
	return kIOReturnSuccess;
}

IOReturn
AppleCIOMeshService::_assignMemoryChunkUCGated(void * assignmentArg)
{
	if (_meshLinksHealthy() == false) {
		LOG("Some links in the mesh are disconnected.");
		return kIOReturnNotReady;
	}

	const MUCI::AssignChunks * assignment = (const MUCI::AssignChunks *)assignmentArg;

	if (assignment->direction == MUCI::MeshDirection::In) {
		return _assignInputMemory(assignment);
	} else if (assignment->direction == MUCI::MeshDirection::Out) {
		return _assignOutputMemory(assignment);
	} else {
		LOG("Invalid assignment direction: %hhx\n", assignment->direction);
		return kIOReturnBadArgument;
	}
}

IOReturn
AppleCIOMeshService::_printBufferStateUCGated(void * bufferIdArg)
{
	MUCI::BufferId * bufferId = (MUCI::BufferId *)bufferIdArg;

	auto sm = getSharedMemory(*bufferId);
	if (!sm) {
		ERROR("Invalid bufferId: %lld\n", *bufferId);
		return kIOReturnBadArgument;
	}

	sm->printState();
	return kIOReturnSuccess;
}

IOReturn
AppleCIOMeshService::_setForwardChainUCGated(void * forwardChainArg, void * forwardChainIdArg)
{
	MUCI::ForwardChain * forwardChain = (MUCI::ForwardChain *)forwardChainArg;
	MUCI::ForwardChainId * chainId    = (MUCI::ForwardChainId *)forwardChainIdArg;

	// create all the chains, only the last is returned back.
	for (int i = 0; i < _linksPerChannel; i++) {
		MUCI::ForwardChainId tmp;
		AppleCIOForwardChain * newChain = _forwarder->createForwardChain(&tmp);

		for (MUCI::BufferId buffer = forwardChain->startBufferId; buffer <= forwardChain->endBufferId; buffer++) {
			auto sm = getSharedMemory(buffer);
			sm->associateForwardChain(newChain);

			auto sectionStart = forwardChain->startOffset;
			auto sectionEnd   = forwardChain->endOffset;

			// Setup the forward chain across sections too. We will save the start offset,
			// and add the section size after finishing the block.
			for (int64_t sCounter = 0; sCounter < forwardChain->sectionCount; sCounter++) {
				for (int64_t offset = sectionStart; offset <= sectionEnd; offset += (sm->getChunkSize() * _linksPerChannel)) {
					int64_t realOffset = offset + (i * sm->getChunkSize());

					_forwarder->addToForwardChain(tmp, buffer, realOffset, i);
				}

				sectionStart = (sectionStart + forwardChain->sectionOffset) % sm->getSize();
				sectionEnd   = (sectionEnd + forwardChain->sectionOffset) % sm->getSize();
			}

			// for the last link, we will group everything from start to end offset
			// We should adjust offsets by the chunkSize * lastLinkIndex because
			// this is what is saved in THIS forward chain. We are going to count on
			// all indices being equal and referring to the same user client chunk.
			if (i == _linksPerChannel - 1) {
				auto startOffset = forwardChain->startOffset + (i * sm->getChunkSize());
				auto endOffset   = forwardChain->endOffset + (i * sm->getChunkSize());

				_forwarder->groupChainElements(tmp, buffer, forwardChain, sm->getSize());
			}
		}

		if (i == 0) {
			*chainId = tmp;
		}

		LOG("created 1 chain: %d\n", tmp);
	}

	return kIOReturnSuccess;
}

IOReturn
AppleCIOMeshService::_setMaxWaitTimeUCGated(void * maxWaitTimeArg)
{
	// expressed in mach_absolute_time() units
	_maxWaitTime = (uint64_t)maxWaitTimeArg;

	return kIOReturnSuccess;
}

IOReturn
AppleCIOMeshService::_startNewGenerationUCGated()
{
	// We are in a new generation
	_expectedGeneration++;
	LOG("*** client starting new generation %d\n", _expectedGeneration);

	MCUCI::NodeId myNodeId = getLocalNodeId();
	MeshControlCommand generationCmd;
	generationCmd.commandType = MeshControlCommandType::NewGeneration;

	generationCmd.data.startGeneration.sourceNode = myNodeId;
	generationCmd.data.startGeneration.generation = _expectedGeneration;

	_receivedGeneration[myNodeId] = (int32_t)_expectedGeneration;
	_newClient[myNodeId]          = true;

	// Send a message to all nodes in the mesh, we are at a new generation
	for (auto i = 0; i < _numNodesMesh; i++) {
		if (i == myNodeId) {
			continue;
		}

		generationCmd.data.startGeneration.destinationNode = i;

		MCUCI::MeshChannelIdx nodeChannel = _commandRouter->getCIOChannelForDestination((uint32_t)i);
		if (nodeChannel == MCUCI::kUnassignedNode) {
			ERROR("No route to node:%d when sending generation message\n", i);
			return kIOReturnError;
		}

		if (nodeChannel >= 0 && nodeChannel < kMaxMeshChannelCount && _meshChannels[nodeChannel] != NULL) {
			_meshChannels[nodeChannel]->sendControlCommand(&generationCmd);
		}
	}

	_checkGenerationReady();
	return kIOReturnSuccess;
}

void
AppleCIOMeshService::_checkGenerationReady()
{
	MCUCI::NodeId myNodeId    = getLocalNodeId();
	uint8_t newclients        = 0;
	bool newGenerationStarted = true;

	for (auto i = 0; i < _numNodesMesh; i++) {
		if (!_newClient[i]) {
			newGenerationStarted = false;
			// we could break out here but let's keep going so that
			// we know how many clients are ready in the log msgs
		} else {
			newclients++;
		}
	}

	if (newGenerationStarted) {
		LOG("All nodes have a new client (my generation: %d _numNodesMesh %d NumNewClients: %d)\n", _expectedGeneration,
		    _numNodesMesh, newclients);
	} else if (!_newClient[myNodeId]) {
		LOG("Other nodes are restarting: my generation: %d numNodesInMesh: %d NumNewClients: %d\n", _expectedGeneration,
		    _numNodesMesh, newclients);
	} else {
		LOG("New client check: my generation: %d numNodesInMesh: %d NumNewClients: %d\n", _expectedGeneration, _numNodesMesh,
		    newclients);
	}

	if (!newGenerationStarted) {
		return;
	}

	IOLockLock(_ucLock);
	AppleCIOMeshUserClient * uc = (AppleCIOMeshUserClient *)_userClients->getObject(0);
	if (!uc) {
		IOLockUnlock(_ucLock);
		return;
	}
	uc->retain();

	if (_dataPathRestartRequired) {
		for (int j = 0; j < _meshLinks.length(); j++) {
			if (_meshLinks[j] != nullptr) {
				_meshLinks[j]->startDataPath();
			}
		}
		_dataPathRestartRequired = false;
	}

	IOLockUnlock(_ucLock);

	for (auto i = 0; i < _numNodesMesh; i++) {
		_newClient[i] = false;
		// we intentionally leave the _receivedGeneration entry alone so that
		// we can know when a node starts a new client (its gencount will bump)
	}

	uc->notifyMeshSynchronized();

	// Mesh has been synchronized
	OSSafeReleaseNULL(uc);
}

IOReturn
AppleCIOMeshService::_assignInputMemory(const MUCI::AssignChunks * assignment)
{
	auto sharedMem = getSharedMemory(assignment->bufferId);
	if (sharedMem == nullptr) {
		LOG("No sharedMem for assignment: %lld\n", assignment->bufferId);
		return kIOReturnBadArgument;
	}

	// Verify only 1 channel is selected, and the channel is good.
	int selectedChannel = -1;
	for (int i = 0; i < _meshChannels.size(); i++) {
		if (assignment->meshChannelMask & (0x1 << i)) {
			selectedChannel = i;
			break;
		}
	}

	if (selectedChannel == -1) {
		LOG("No channel selected for assignment. AssignmentMask:%llx.\n", assignment->meshChannelMask);
		return kIOReturnBadArgument;
	}

	auto meshChannel = _meshChannels[selectedChannel];
	if (meshChannel == nullptr) {
		LOG("No meshChannel for assignment: %d. AssignmentMask:%llx\n", selectedChannel, assignment->meshChannelMask);
		return kIOReturnBadArgument;
	}

	if (!meshChannel->isReady()) {
		LOG("MeshChannel %d is not ready\n", selectedChannel);
		return kIOReturnBadArgument;
	}

	if (!meshChannel->isPartnerTxReady(assignment->sourceNode)) {
		LOG("CIOPartner has not assigned TX to MeshChannel %d for source node %d\n", selectedChannel, assignment->sourceNode);
		return kIOReturnBadArgument;
	}

	auto numChunks = assignment->size / sharedMem->getChunkSize();
	if (numChunks % getLinksPerChannel() != 0) {
		LOG("Unable to assign memory without using the full channel effectively. AssignmentSize:%lld chunkSize:%lld "
		    "linksPerChannel:%d\n",
		    assignment->size, sharedMem->getChunkSize(), getLinksPerChannel());
		return kIOReturnBadArgument;
	}

	if (!sharedMem->createAssignment(assignment->offset, MUCI::MeshDirection::In, assignment->sourceNode, assignment->size)) {
		ERROR("Unable to create assignment. Is there already an output or input assignment at offset: %lld\n", assignment->offset);
		return kIOReturnBadArgument;
	}

	auto chunksPerLink   = numChunks / getLinksPerChannel();
	int currentChunk     = 0;
	int previousLinkIter = -1;

	for (int64_t offset = assignment->offset; offset < assignment->offset + assignment->size;
	     offset += sharedMem->getChunkSize(), currentChunk++) {
		auto linkIter    = (uint8_t)(currentChunk / chunksPerLink);
		auto meshLinkIdx = meshChannel->getLinkIndex(linkIter);

		// Always add the offset to the assignment
		sharedMem->addChunkOffsetToAssignment(assignment->offset, offset);

		// Always set the last one, the last one will be the last one
		sharedMem->setChannelLastOffsetForLink(assignment->offset, offset, linkIter);

		// set the first link offset when the linkIdx changes
		if (linkIter != previousLinkIter) {
			sharedMem->setChannelFirstOffsetForLink(assignment->offset, offset, linkIter);
		}
		previousLinkIter = linkIter;

		auto meshLink = _meshLinks[meshLinkIdx];
		assertf(meshLink, "meshlink for linkIdx:%d and channel:%d is null", meshLinkIdx, selectedChannel);

		auto rxDataCommand = sharedMem->getReceiveCommand(meshLinkIdx, offset);
		if (rxDataCommand == nullptr) {
			LOG("Could not find MeshReceiveCommand for bufferId:%lld at:%lld\n", assignment->bufferId, offset);
			return kIOReturnBadArgument;
		}

		if (rxDataCommand->getProvider()->getAssignedForOutput()) {
			panic("RX commands have to be assigned before TX commands");
		}

		if (meshLink->getRxPathAssignment(assignment->sourceNode) == MCUCI::kUnassignedNode) {
			LOG("RX Ring for node[%d] not assigned on mesh link: %d for offset: %lld\n", assignment->sourceNode,
			    meshLink->getController()->getRID(), assignment->offset);
			return kIOReturnError;
		}

		// LOG("Assigning %lld offset to %d INPUT\n", assignment->offset, meshLink->getRxPathAssignment(assignment->sourceNode));

		rxDataCommand->setAssignedChunk(assignment);
		rxDataCommand->getProvider()->setAccessMode(assignment->accessMode);
		rxDataCommand->getProvider()->setAssignedInputLink(meshLinkIdx);
		RETURN_IF_FAIL(rxDataCommand->createTBTCommands(), kIOReturnNoMemory, "create tx tbt commands");

		auto rxTbtCommandsLength = rxDataCommand->getCommandsLength();

		auto dataReceivedAction =
		    OSMemberFunctionCast(IOThunderboltReceiveCommand::Action, this, &AppleCIOMeshService::dataReceived);
		rxDataCommand->setCompletion(rxTbtCommandsLength - 1, this, dataReceivedAction);
	}

	return kIOReturnSuccess;
}

IOReturn
AppleCIOMeshService::_assignOutputMemory(const MUCI::AssignChunks * assignment)
{
	_signpostSequenceNumber = 0;
	auto sharedMem          = getSharedMemory(assignment->bufferId);
	if (sharedMem == nullptr) {
		LOG("No sharedMem for assignment: %lld\n", assignment->bufferId);
		return kIOReturnBadArgument;
	}

	// Figure out the number of channels we expect to be ready based on the
	// number of nodes we are outputting to. For output only meshChannelMask
	// is actually a node mask indiciating which nodes we are outputting to.
	auto outputNodes = __builtin_popcountll((uint64_t)assignment->meshChannelMask);
	int expectedChannels;
	if (outputNodes == 7) {
		expectedChannels = 4;
	} else if (outputNodes == 6) {
		// this is a forwarding node
		expectedChannels = 3;
	} else {
		expectedChannels = outputNodes;
	}

	auto numReadyChannels = 0;
	// verify every single channel is ready in the assignment
	for (int i = 0; i < _meshChannels.length(); i++) {
		// For output channels, meshChannelMask is actually a node
		// mask where each bit corresponds to the node ID. We need
		// to check if the node ID that the current channel is
		// outputting to is part of the mask.
		if (_meshChannels[i] && (assignment->meshChannelMask & (0x1 << _meshChannels[i]->getPartnerNodeId()))) {
			if (!_meshChannels[i]->isReady()) {
				LOG("MeshChannel %d not ready. AssignmentMask:0x%llx\n", i, assignment->meshChannelMask);
				return kIOReturnBadArgument;
			}
			numReadyChannels++;
		}
	}

	if (numReadyChannels != expectedChannels) {
		LOG("Not all mesh channels are ready.\n");
		return kIOReturnBadArgument;
	}

	MCUCI::NodeId assignedSource = assignment->sourceNode;

	auto numChunks = assignment->size / sharedMem->getChunkSize();
	if (numChunks % getLinksPerChannel() != 0) {
		LOG("Unable to assign memory without using the full channel effectively. AssignmentSize:%lld chunkSize:%lld "
		    "linksPerChannel:%d\n",
		    assignment->size, sharedMem->getChunkSize(), getLinksPerChannel());
		return kIOReturnBadArgument;
	}

	bool isForward = false;

	if (!sharedMem->createAssignment(assignment->offset, MUCI::MeshDirection::Out, _nodeId, assignment->size)) {
		isForward = true;
	}

	auto chunksPerLink     = numChunks / getLinksPerChannel();
	int currentChunk       = 0;
	int previousLinkIter   = -1;
	uint64_t runningOffset = 0;

	for (int64_t offset = assignment->offset; offset < assignment->offset + assignment->size;
	     offset += sharedMem->getChunkSize(), currentChunk++, runningOffset += sharedMem->getChunkSize()) {
		if (!isForward) {
			// For forwards, the expectation is the chunks were already added by input
			sharedMem->addChunkOffsetToAssignment(assignment->offset, offset);

			auto channelLinkIter = (uint8_t)(currentChunk / chunksPerLink);
			sharedMem->setChannelLastOffsetForLink(assignment->offset, offset, channelLinkIter);

			if (channelLinkIter != previousLinkIter) {
				sharedMem->setChannelFirstOffsetForLink(assignment->offset, offset, channelLinkIter);
			}
			previousLinkIter = (int)channelLinkIter;
		}

		// Add all commands into the links to prepare submission
		for (int meshC = 0; meshC < (int)_meshChannels.length(); meshC++) {
			uint64_t mask = assignment->meshChannelMask;
			if (_meshChannels[meshC] == nullptr) {
				continue;
			}
			uint64_t nodeMask = 0x1 << (uint64_t)_meshChannels[meshC]->getPartnerNodeId();

			if ((mask & nodeMask) == 0) {
				continue;
			}

			auto linkIdx       = _meshChannels[meshC]->getLinkIndex((uint8_t)(currentChunk / chunksPerLink));
			auto txDataCommand = sharedMem->getTransmitCommand(linkIdx, offset);
			if (txDataCommand == nullptr) {
				LOG("Could not find MeshTransmitCommand for bufferId:%lld at:%lld. Link:%d\n", assignment->bufferId, offset,
				    linkIdx);
				return kIOReturnBadArgument;
			}

			// Self node id are automatically created by the links and do not need
			// assignment at the link.
			if (_meshLinks[linkIdx]->getTxPathAssignment(assignedSource) == MCUCI::kUnassignedNode) {
				LOG("TX Ring for node[%d] not assigned on mesh link: %d for offset: %lld\n", assignedSource, linkIdx,
				    assignment->offset);
				return kIOReturnError;
			}

			uint64_t header[3];
			header[0] = (uint64_t)assignment->bufferId;
			header[1] = (uint64_t)offset;
			header[2] = linkIdx;
			txDataCommand->setTrailerData((void *)&header[0], sizeof(header));

			txDataCommand->setAssignedChunk(assignment);
			txDataCommand->getProvider()->setAccessMode(assignment->accessMode);
			txDataCommand->getProvider()->setAssignedForOutput(true);
			RETURN_IF_FAIL(txDataCommand->createTBTCommands(), kIOReturnNoMemory, "create tx tbt commands");

			_meshLinks[linkIdx]->setupTXBuffer(assignedSource, txDataCommand, sharedMem);

			auto txTbtCommandsLength = txDataCommand->getCommandsLength();
			auto dataSentAction = OSMemberFunctionCast(IOThunderboltTransmitCommand::Action, this, &AppleCIOMeshService::dataSent);
			txDataCommand->setCompletion(txTbtCommandsLength - 1, this, dataSentAction);

			// This is a forward, so we have to change some of the completions
			if (txDataCommand->getProvider()->getAssignedInputLink() != -1) {
				auto rxCommand =
				    sharedMem->getReceiveCommand((uint8_t)txDataCommand->getProvider()->getAssignedInputLink(), offset);

				_addForwardingCommand(txDataCommand, rxCommand, assignedSource);

				// First, all the TX commands that will be forwarded need to send back
				// flow control information to the forwarder (except the last one)
				auto txFlowControlAction =
				    OSMemberFunctionCast(IOThunderboltTransmitCommand::Action, this, &AppleCIOMeshService::commandSentFlowControl);
				for (int commandI = 0; commandI < txTbtCommandsLength - 1; commandI++) {
					txDataCommand->setCompletion((uint32_t)commandI, this, txFlowControlAction);
				}

				// Next we have to change the RX commands actions, everything but the
				// last one will be flow control.
				auto rxFlowControlAction = OSMemberFunctionCast(IOThunderboltReceiveCommand::Action, this,
				                                                &AppleCIOMeshService::commandReceivedFlowControl);
				for (int commandI = 0; commandI < txTbtCommandsLength - 1; commandI++) {
					rxCommand->setCompletion((uint32_t)commandI, this, rxFlowControlAction);
				}
			}
		}
	}

	return kIOReturnSuccess;
}

IOReturn
AppleCIOMeshService::_dripPrepareBuffer(AppleCIOMeshSharedMemory * sm,
                                        int64_t * assignmentIdx,
                                        int64_t * offsetIdx,
                                        int64_t * linkIdx)
{
	auto finishedPrepare = sm->dripPrepare(assignmentIdx, offsetIdx, linkIdx);

	if (finishedPrepare) {
		*assignmentIdx = 0;
		*offsetIdx     = 0;
		*linkIdx       = 0;

		return kIOReturnSuccess;
	}

	return kIOReturnStillOpen;
}

void
AppleCIOMeshService::_addForwardingCommand(AppleCIOMeshTransmitCommand * transmitCommand,
                                           AppleCIOMeshReceiveCommand * receiveCommand,
                                           MCUCI::NodeId sourceNode)
{
	assertf(transmitCommand->getMeshLink() != receiveCommand->getMeshLink(), "forwardTX link == forwardRX link");

	_forwarder->addForwardingAction(transmitCommand, receiveCommand, sourceNode);
}

IOService *
AppleCIOMeshService::_resolvePHandle(const char * key, const char * className)
{
	IOReturn status = kIOReturnSuccess;

	IOService * found_service = NULL;

	// Setup the phandle matching dictionary.
	const OSSymbol * phandleKey = NULL;
	if (status == kIOReturnSuccess) {
		phandleKey = OSSymbol::withCString("AAPL,phandle");
		if (phandleKey == NULL) {
			status = kIOReturnNoMemory;
		}
	}

	OSObject * phandleObject = NULL;
	if (status == kIOReturnSuccess) {
		phandleObject = OSDynamicCast(OSObject, getProperty(key, gIOServicePlane));
		if (phandleObject == NULL) {
			status = kIOReturnDeviceError;
		}
	}

	OSDictionary * phandleDictionary = NULL;
	if (status == kIOReturnSuccess) {
		phandleDictionary = propertyMatching(phandleKey, phandleObject);
		if (phandleDictionary == NULL) {
			status = kIOReturnNoMemory;
		}
	}

	OSDictionary * matchingDictionary = NULL;
	if (status == kIOReturnSuccess) {
		matchingDictionary = serviceMatching(className);
		if (matchingDictionary == NULL) {
			status = kIOReturnNoMemory;
		}
	}

	if (status == kIOReturnSuccess) {
		matchingDictionary->setObject(gIOParentMatchKey, phandleDictionary);
	}

	// Search for our object.
	if (status == kIOReturnSuccess) {
		found_service = waitForMatchingService(matchingDictionary, kComputeMCUMatchingWaitingTimeNs);
		if (found_service == NULL) {
			status = kIOReturnNotFound;
		}
	}

	// Clean up.
	if (phandleKey) {
		phandleKey->release();
		phandleKey = NULL;
	}

	if (matchingDictionary) {
		matchingDictionary->release();
		matchingDictionary = NULL;
	}

	if (phandleDictionary) {
		phandleDictionary->release();
		phandleDictionary = NULL;
	}

	return found_service;
}

IOReturn
AppleCIOMeshService::_setNodeIdUCGated(void * nodeIdArg)
{
	const MCUCI::NodeId * nodeId = (const MCUCI::NodeId *)nodeIdArg;

	if (_active) {
		ERROR("Unable to change NodeID while active");
		return kIOReturnBusy;
	}

	_partitionIdx = *nodeId / 8;
	_nodeId       = *nodeId % 8;
	LOG("Setting node id to %d\n", _nodeId)
	LOG("partition index is %d\n", _partitionIdx);
	setProperty(kAppleCIOMeshNodeId, &_nodeId, sizeof(_nodeId));

	return kIOReturnSuccess;
}

IOReturn
AppleCIOMeshService::_setEnsembleSizeUCGated(void * ensembleSizeArg)
{
	const MCUCI::EnsembleSize * ensembleSize = (const MCUCI::EnsembleSize *)ensembleSizeArg;

	if (_active) {
		ERROR("Unable to change ensemble size while active");
		return kIOReturnBusy;
	}

	_ensembleSize = *ensembleSize;
	LOG("Setting ensemble size to %d", _ensembleSize);

	return kIOReturnSuccess;
}
IOReturn
AppleCIOMeshService::_setChassisIdUCGated(void * chassisIdArg)
{
	const MCUCI::ChassisId * chassisId = (const MCUCI::ChassisId *)chassisIdArg;

	if (_active) {
		ERROR("Unable to change chassisID while active");
		return kIOReturnBusy;
	}

	memcpy(&_chassisId, chassisId, sizeof(_chassisId));
	return kIOReturnSuccess;
}

IOReturn
AppleCIOMeshService::_addPeerHostnameUCGated(void * hostnameArg)
{
	const auto * peerNode = (const MCUCI::PeerNode *)hostnameArg;
	if (_active) {
		ERROR("Unable to change hostname while active");
		return kIOReturnBusy;
	}

	const auto count = _peerHostnames.count;
	if (count >= kMaxPeerCount) {
		ERROR("Cannot add more peers to the current node. Max peers: %d\n", kMaxPeerCount);
		return kIOReturnInvalid;
	}

	memcpy(&_peerHostnames.peers[count], peerNode, sizeof(MCUCI::PeerNode));
	_peerHostnames.count++;
	return kIOReturnSuccess;
}

IOReturn
AppleCIOMeshService::_getPeerHostnamesUCGated(void * hostnamesArg)
{
	auto * hostnames = (MCUCI::PeerHostnames *)hostnamesArg;
	*hostnames       = _peerHostnames;
	return kIOReturnSuccess;
}

IOReturn
AppleCIOMeshService::_activateMeshUCGated()
{
	if (_hasBeenDeactivated) {
		LOG("Mesh has been deactivated once.  Cannot restart it - all nodes in the mesh must reboot.\n");
		return kIOReturnError;
	}
	if (!_active) {
		_active = true;

		for (unsigned i = 0; i < _acioCount; i++) {
			auto acioName        = OSRequiredCast(OSString, _acioNames->getObject(i));
			auto thunderboltNode = _getThunderboltLocalNode(acioName);

			auto listener = OSDynamicCast(AppleCIOMeshProtocolListener, _meshProtocolListeners->getObject(i));
			if (listener == nullptr) {
				listener = AppleCIOMeshProtocolListener::withLocalNode(thunderboltNode);
				_meshProtocolListeners->setObject(i, listener);
			}

			if (_tbtControllers->getObject(i) == nullptr) {
				_tbtControllers->setObject(i, thunderboltNode->getController());
			}

			_meshLinksLocked[i] = false;
			listener->publish();

			LOG("Published USBMesh XDService on acio%d\n", i);
		}
	}

	return kIOReturnSuccess;
}

IOReturn
AppleCIOMeshService::_deactivateMeshUCGated()
{
	if (_active) {
		_active             = false;
		_hasBeenDeactivated = true;

		_commandRouter->removeAllChannels();

		for (unsigned i = 0; i < _acioCount; i++) {
			AppleCIOMeshProtocolListener * listener =
			    OSDynamicCast(AppleCIOMeshProtocolListener, _meshProtocolListeners->getObject(i));
			listener->unpublish();

			LOG("Unpublished USBMesh XDService on acio%d\n", i);
		}

		// TODO invalidate all meshlinks in allocated sharedMemory and commands

		_acioLock = false;
		for (uint8_t i = 0; i < _meshLinksLocked.length(); i++) {
			_meshLinksLocked[i] = false;
			if (_meshLinks[i]) {
				_meshLinks[i]->terminate();
			}
		}
	}

	return kIOReturnSuccess;
}

IOReturn
AppleCIOMeshService::_lockCIOUCGated()
{
	// the mesh configuration is now locked.
	_acioLock = true;

	// Figure out the current node count, and this is how many generation starts
	// are needed to synchronize the mesh.
	_numNodesMesh = (uint32_t)_commandRouter->getNumNodesInMesh();
	LOG("numNodesMesh: %d\n", _numNodesMesh);

	// find all the links NOT associated with a channel and disable them.
	for (uint8_t i = 0; i < _acioCount; i++) {
		_meshLinksLocked[i] = true;

		if (_meshLinks[i] == nullptr || _meshLinks[i]->getChannel()) {
			continue;
		}

		AppleCIOMeshProtocolListener * listener = OSDynamicCast(AppleCIOMeshProtocolListener, _meshProtocolListeners->getObject(i));
		listener->unpublish();

		if (_meshLinks[i]) {
			_meshLinks[i]->terminate();
		}
	}

	return kIOReturnSuccess;
}

IOReturn
AppleCIOMeshService::_disconnectChannelUCGated(void * channelIdxArg)
{
	const MCUCI::MeshChannelIdx * channelIdx = (const MCUCI::MeshChannelIdx *)channelIdxArg;

	if (_meshChannels[*channelIdx] == nullptr) {
		ERROR("Invalid channel index to disable: %d\n", *channelIdx);
		return kIOReturnBadArgument;
	}

	// find all the links associated with this channel and disable them.
	for (uint8_t i = 0; i < getLinksPerChannel(); i++) {
		auto linkIdx = _meshChannels[*channelIdx]->getLinkIndex(i);

		AppleCIOMeshProtocolListener * listener =
		    OSDynamicCast(AppleCIOMeshProtocolListener, _meshProtocolListeners->getObject(linkIdx));
		listener->unpublish();

		_meshLinksLocked[linkIdx] = true;
		if (_meshLinks[linkIdx]) {
			_meshLinks[linkIdx]->terminate();
		}
	}

	_commandRouter->removeChannel(*channelIdx);

	return kIOReturnSuccess;
}

IOReturn
AppleCIOMeshService::_establishTXConnectionUCGated(void * connectionArg)
{
	const MCUCI::NodeConnectionInfo * connection = (const MCUCI::NodeConnectionInfo *)connectionArg;

	if (!_active || _hasBeenDeactivated) {
		ERROR("Can't establish TX on: %d because the mesh has been deactivated\n", connection->channelIndex);
		return kIOReturnNoDevice;
	}

	if (connection->channelIndex < 0 || connection->channelIndex >= kMaxMeshChannelCount ||
	    _meshChannels[connection->channelIndex] == nullptr) {
		ERROR("Invalid channel index to establish TX on: %d\n", connection->channelIndex);
		return kIOReturnBadArgument;
	}

	// verify the channel is ready
	if (!_meshChannels[connection->channelIndex]->isReady()) {
		ERROR("Establishing TX connection with a not-ready channel: %d\n", connection->channelIndex);
		return kIOReturnBadArgument;
	}

	if (connection->node == MCUCI::kUnassignedNode) {
		ERROR("Invalid node id: %d\n", connection->node);
		return kIOReturnBadArgument;
	}

	// This is the path for the
	int32_t firstPath = -1;

	for (uint8_t i = 0; i < getLinksPerChannel(); i++) {
		auto linkIdx = _meshChannels[connection->channelIndex]->getLinkIndex(i);

		auto assignedPath = _meshLinks[linkIdx]->assignTxNode(connection->node);
		if (assignedPath == MCUCI::kUnassignedNode) {
			panic("Failed to assign TX node[%d] to link[%d]. Do not overassign.\n", connection->node, linkIdx);
		}

		if (firstPath == -1) {
			firstPath = (int32_t)assignedPath;
		}

		if (assignedPath != firstPath) {
			panic("Assigning a different path[%d] to TX node[%d]. Previous path: %d\n", assignedPath, connection->node, firstPath);
		}
	}

	// Send control message to announce source node ID and path ID for
	// this TX connection.
	_meshChannels[connection->channelIndex]->sendTxAssignmentNotification(connection->node, (uint32_t)firstPath);

	// Notify user space, we have a TX connection.
	notifyConnectionChange(*connection, true, true);

	// If we are setting up a TX connection on behalf of someone else.
	if (connection->node != getLocalNodeId()) {
		// We now need to notify the originator, we are forwarding their data, so they
		// can setup their routes through us.
		// The working assumption here is userspace is not setting up inefficient
		// routes or multiple routes to the same node.
		MeshControlCommand forwardNotificationCmd;
		forwardNotificationCmd.commandType = MeshControlCommandType::TxForwardNotificationCommand;

		forwardNotificationCmd.data.txForward.forwarder  = getLocalNodeId();
		forwardNotificationCmd.data.txForward.sourceNode = connection->node;
		forwardNotificationCmd.data.txForward.receiver   = _meshChannels[connection->channelIndex]->getPartnerNodeId();

		// Get the CIO channel for this source node and send the forward command on it
		// even if it is not the partner, the node in the middle will forward it
		// to the source.
		MCUCI::MeshChannelIdx sourceChannel = _commandRouter->getCIOChannelForDestination(connection->node);
		if (sourceChannel != MCUCI::kUnassignedNode && sourceChannel < kMaxMeshChannelCount && _meshChannels[sourceChannel]) {
			_meshChannels[sourceChannel]->sendControlCommand(&forwardNotificationCmd);
		} else {
			LOG("No mesh channel for node %d\n", connection->node);
		}
	} else {
		// For a TX connection from self, the receiver is the meshChannelPartner,
		// and we are the forwarder.

		// Forward connections will come from the previous if statement back to us.
		_commandRouter->addRouteTo(_meshChannels[connection->channelIndex]->getPartnerNodeId(), getLocalNodeId());
	}

	return kIOReturnSuccess;
}

IOReturn
AppleCIOMeshService::_sendControlMessageUCGated(void * messageArg)
{
	const MCUCI::MeshMessage * message = (const MCUCI::MeshMessage *)messageArg;

	if (message->length > kCommandMessageDataSize) {
		return kIOReturnBadArgument;
	}

	_dummyTxControlMessage.header.commandType                         = MeshControlCommandType::RawMessage;
	_dummyTxControlMessage.header.data.controlMessage.length          = message->length;
	_dummyTxControlMessage.header.data.controlMessage.destinationNode = message->node;
	_dummyTxControlMessage.header.data.controlMessage.sourceNode      = getLocalNodeId();
	memcpy(_dummyTxControlMessage.data, message->rawData, message->length);

	if (message->node == getLocalNodeId()) {
		// send it to ourselves; passing NULL is ok for the
		// path because controlMessageHandlerGated() won't
		// use the pathpointer since we are the destination
		// for the message
		controlMessageHandlerGated(NULL, &_dummyTxControlMessage);
	} else {
		MCUCI::MeshChannelIdx nodeChannel = _commandRouter->getCIOChannelForDestination(message->node);
		if (nodeChannel == MCUCI::kUnassignedNode) {
			ERROR("No route to node:%d when sending control message\n", message->node);
			return kIOReturnIOError;
		}
		if (nodeChannel >= 0 && nodeChannel < kMaxMeshChannelCount) {
			_meshChannels[nodeChannel]->sendRawControlMessage(&_dummyTxControlMessage);
		}
	}

	return kIOReturnSuccess;
}

IOReturn
AppleCIOMeshService::_getConnectedNodesUCGated(void * connectedNodesArg)
{
	MCUCI::ConnectedNodes * nodes = (MCUCI::ConnectedNodes *)connectedNodesArg;

	nodes->nodeCount = 0;
	for (uint8_t i = 0; i < kMaxCIOMeshNodes; i++) {
		AppleCIOMeshChannel * channel;
		MCUCI::MeshChannelIdx chIdx;

		bzero(&nodes->nodes[i].chassisId, sizeof(MCUCI::ChassisId));

		chIdx = _commandRouter->getSourceNodeCIOChannel((MCUCI::NodeId)i);
		if (chIdx == -1) {
			// if there is no channel index for nodeof -1 is either us or an unassigned node
			if (i == _nodeId) {
				// fill in our info
				nodes->nodes[nodes->nodeCount].rank         = i;
				nodes->nodes[nodes->nodeCount].partitionIdx = _partitionIdx;
				nodes->nodes[nodes->nodeCount].inputChannel = -1;
				uint8_t j, k = 0;
				for (j = 0; j < _meshChannels.length(); j++) {
					if (_meshChannels[j] != nullptr && _meshChannels[j]->isReady()) {
						nodes->nodes[nodes->nodeCount].outputChannels[k++] = j;
					}
				}
				nodes->nodes[nodes->nodeCount].outputChannelCount = k;
				memcpy(&nodes->nodes[nodes->nodeCount].chassisId, &_chassisId, sizeof(_chassisId));
			} else {
				// it's not us so this node isn't connected (which is
				// valid if there are only 4 or 2 nodes connected)
				nodes->nodes[nodes->nodeCount].rank               = -1;
				nodes->nodes[nodes->nodeCount].inputChannel       = -1;
				nodes->nodes[nodes->nodeCount].outputChannelCount = 0;
			}

			nodes->nodeCount++;
			continue;
		}

		channel                                     = _meshChannels[chIdx];
		nodes->nodes[nodes->nodeCount].rank         = i;
		nodes->nodes[nodes->nodeCount].partitionIdx = _partitionIdx;
		nodes->nodes[nodes->nodeCount].inputChannel = (int8_t)chIdx;

		MCUCI::ChassisId chassisId;
		if (channel->getConnectedChassisId(&chassisId) == false) {
			// hmmm, the channel must not be ready
			nodes->nodes[nodes->nodeCount].outputChannelCount = 0;
			nodes->nodeCount++;
			continue;
		}

		// When copying the chassisId, we can always blindly copy from the channel
		// if the channel is established. If the channel points to a node in our
		// chassis, then we are copying our chassis ID (from the channel).
		// If the node is not in our chassis, it is either the partner node (in the
		// other chassis), or the partner node is forwarding, and the channel index
		// points to the partner node's channel, which again is the same chassis id.
		memcpy(&nodes->nodes[nodes->nodeCount].chassisId, &chassisId, sizeof(chassisId));

		if (memcmp((void *)&chassisId, (void *)&_chassisId, sizeof(chassisId)) == 0 || channel->getPartnerNodeId() != i) {
			// then the channel is connected to a node in the same
			// chassis as me, or its data is forwarded to us by
			// another node; in both cases there are no output
			// channels for this node.
			nodes->nodes[nodes->nodeCount].outputChannelCount = 0;
			nodes->nodeCount++;
			continue;
		}

		// if we're here then this is a node from a different chassis
		// and it is a forwarding node so we need to set its output
		// channels appropriately.

		uint8_t j, k = 0;
		for (j = 0; j < _meshChannels.length(); j++) {
			// if the channel isn't the one going to this node and it's valid,
			// set it as an output channel for this node
			if (_meshChannels[j] != channel && _meshChannels[j] != nullptr && _meshChannels[j]->isReady()) {
				nodes->nodes[nodes->nodeCount].outputChannels[k++] = j;
			}
		}
		nodes->nodes[nodes->nodeCount].outputChannelCount = k;
		nodes->nodeCount += 1;
	}

	return kIOReturnSuccess;
}

IOReturn
AppleCIOMeshService::_getCIOConnectionStateUCGated(void * cioConnectionsArg)
{
	MCUCI::CIOConnections * cioConnections = (MCUCI::CIOConnections *)cioConnectionsArg;

	cioConnections->cioCount = _acioCount;

	for (int i = 0; i < _acioCount; i++) {
		cioConnections->cio[i].expectedPeerHardwareNodeId =
		    _partnerMap.initialized ? _partnerMap.hardwareNodes[i] : kNonDCHardwarePlatform;

		if (!_meshLinks[i]) {
			cioConnections->cio[i].cableConected            = false;
			cioConnections->cio[i].actualPeerHardwareNodeId = kNonDCHardwarePlatform;
		} else {
			cioConnections->cio[i].cableConected            = true;
			cioConnections->cio[i].actualPeerHardwareNodeId = _meshLinks[i]->getConnectedHardwareNodeId();
		}
	}

	return kIOReturnSuccess;
}

IOReturn
AppleCIOMeshService::_cryptoKeyResetUCGated()
{
	_buffersAllocated = 0;
	atomic_store(&_cryptoKeyUsed, false);
	if (_maxTimePerKey != 0) {
		uint64_t current = mach_absolute_time();
		uint64_t timeAhead;
		nanoseconds_to_absolutetime(_maxTimePerKey * kNsPerSecond, &timeAhead);
		_cryptoKeyTimeLimit = current + timeAhead;
	} else {
		_cryptoKeyTimeLimit = 0;
	}

	return kIOReturnSuccess;
}

IOReturn
AppleCIOMeshService::_cryptoKeyMarkUsedUCGated()
{
	bool expected = false;
	if (!atomic_compare_exchange_strong(&_cryptoKeyUsed, &expected, true)) {
		panic("Crypto key already marked as used\n");
	}
	return kIOReturnSuccess;
}

IOReturn
AppleCIOMeshService::_getBuffersAllocatedCounterUCGated(uint64_t * buffersAllocated)
{
	*buffersAllocated = _buffersAllocated;
	return kIOReturnSuccess;
}

// MARK: - Other

IOThunderboltLocalNode *
AppleCIOMeshService::_getThunderboltLocalNode(OSString * acioName)
{
	OSDictionary * localNodeMatch = serviceMatching("IOThunderboltLocalNode");
	if (localNodeMatch == nullptr) {
		LOG("Could not make IOThunderboltLocalNode matching dictionary\n");
		return nullptr;
	}
	OSDictionary * acioParentMatch = nameMatching(acioName);
	if (acioParentMatch == nullptr) {
		LOG("Could not make %s matching dictionary\n", acioName->getCStringNoCopy());
		OSSafeReleaseNULL(localNodeMatch);
		return nullptr;
	}
	localNodeMatch->setObject(gIOParentMatchKey, acioParentMatch);

	IOService * acioLocalNode = waitForMatchingService(localNodeMatch, 60ULL * kSecondScale);
	if (acioLocalNode == nullptr) {
		LOG("Could not find IOThunderboltLocalNode for %s\n", acioName->getCStringNoCopy());
	}

	OSSafeReleaseNULL(acioParentMatch);
	OSSafeReleaseNULL(localNodeMatch);

	LOG("Found thunderbolt local node for %s : %p\n", acioName->getCStringNoCopy(), acioLocalNode);

	return OSRequiredCast(IOThunderboltLocalNode, acioLocalNode);
}

int
AppleCIOMeshService::_freeSharedMemoryUCGated(int64_t bufferId)
{
	bool dealWithForwarder = _forwarder && _forwarder->isStarted();

	for (unsigned int i = 0; i < _sharedMemoryRegions->getCount(); i++) {
		auto sm = OSRequiredCast(AppleCIOMeshSharedMemory, _sharedMemoryRegions->getObject(i));

		if (sm->getId() != bufferId) {
			continue;
		}

		uint64_t start       = mach_absolute_time();
		uint64_t start_nanos = 0;
		absolutetime_to_nanoseconds(start, &start_nanos);

		uint64_t last_nanos = start_nanos;

		while (sm->forwardsCompleted() == false) {
			uint64_t now       = mach_absolute_time();
			uint64_t now_nanos = 0;
			absolutetime_to_nanoseconds(now, &now_nanos);

			if (now_nanos - last_nanos > kNsPerSecond) {
				LOG("Forwards still happening for bufferId: %lld\n", sm->getId());
				last_nanos = now_nanos;
			}

			if (now_nanos - start_nanos > kForwardStopTimeNs) {
				LOG("Bailing out waiting for forwards to complete on bufferId: %lld\n", sm->getId());
				break;
			}
		}

		// First, we mark the buffer as interrupted, then wait for
		// the sm's retain count to go to 1, where the service is the only
		// thing holding onto the SM. Now, it is safe to release.

		// This will automatically kick the commandeer who is constantly looping
		// but the forwarder may be done all its forwards and it is waiting for
		// RX which will never come in. Let's notify it just in case.
		sm->interruptIOThreads();

		if (dealWithForwarder) {
			atomic_store(&_forwarderFinishedRelease, false);
			_forwarder->disableActionsForSharedMemory(sm);
		}

		// Get the current timestamp and let's log every 5 seconds,
		// after 30 seconds, we panic.
		start       = mach_absolute_time();
		start_nanos = 0;
		absolutetime_to_nanoseconds(start, &start_nanos);

		last_nanos = start_nanos;

		while (dealWithForwarder && (atomic_load(&_forwarderFinishedRelease) == false)) {
			uint64_t now       = mach_absolute_time();
			uint64_t now_nanos = 0;
			absolutetime_to_nanoseconds(now, &now_nanos);

			if (now_nanos - last_nanos > 5000000000) {
				LOG("Still freeing Shared Memory : %lld\n", sm->getId());
				last_nanos = now_nanos;
			}

			if (now_nanos - start_nanos > 300000000000) {
				panic("Could not free in 300seconds.\n");
			}
		}

		if (sm->getPreparedCount() != 0) {
			//
			// in case the commandeer thread (or anyone else) happens
			// to be waiting on this shared memory, mark it as
			// interrupted so those folks break out before we release
			// the object.  arguably we need a mechanism to wait and
			// make sure no one is using the sm any longer...
			//
			LOG("Restarting data paths. Clearing %d prepared commands\n", sm->getPreparedCount());
			for (int j = 0; j < _meshLinks.length(); j++) {
				if (_meshLinks[j] != nullptr) {
					_meshLinks[j]->stopDataPath();
				}
			}
			_dataPathRestartRequired = true;
		}

		if (dealWithForwarder) {
			_forwarder->safeToForward();
			_forwarder->cleanupActionsForSharedMemory(sm);
		}

		LOG("deallocating memory region w/bufferId %lld w/retain count %d\n", bufferId, sm->getRetainCount());
		_sharedMemoryRegions->removeObject((unsigned int)i);

		if (_sharedMemoryRegions->getCount() == 0) {
			IOReturn ret = _stopThreadsUCGated();
			if (ret != kIOReturnSuccess) {
				LOG("Failed to stop threads: %x\n", ret);
				return -1;
			}
		}

		return 0;
	}

	LOG("Did not find bufferId %lld\n", bufferId);
	return -1;
}

bool
AppleCIOMeshService::_meshLinksHealthy() const
{
	// The mesh links are considered healthy if they are connected to a channel and the channel is ready.
	// If the cable is unplugged or the partner node is not longer connected, the link becomes null.
	// However, in some setups like a 4-node mesh, one link will always be null. So, we need to distinguish between a
	// link that is expected to be null and a link that got disconnected.
	uint32_t expectedLinksNum = _channelCount * kMaxMeshLinksPerChannel;
	for (int i = 0; i < _meshLinks.length(); i++) {
		if (_meshLinks[i] == nullptr) {
			continue;
		}
		if (_meshLinks[i]->getChannel()->isReady() == false) {
			return false;
		}
		expectedLinksNum--;
	}
	return expectedLinksNum == 0;
}
