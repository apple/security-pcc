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

#include "AppleCIOMeshUserClient.h"
#include "AppleCIOMeshService.h"
#include "AppleCIOMeshSharedMemory.h"
#include "AppleCIOMeshSharedMemoryHelpers.h"
#include "AppleCIOMeshThunderboltCommands.h"
#include "Signpost.h"
#include "UserClientHelpers.h"
#include <IOKit/IOKitKeys.h>

#include <AssertMacros.h>
#define LOG_PREFIX "AppleCIOMeshUserClient"
#include "Util/Log.h"

#define SEND_ALL_MAX_CHUNKS 64

OSDefineMetaClassAndStructors(AppleCIOMeshUserClient, AppleCIOMeshUserClient::super);

const IOExternalMethodDispatch2022 AppleCIOMeshUserClient::_methods[MUCI::Method::NumMethods] = {
    [MUCI::Method::NotificationRegister] =
        {
            &AppleCIOMeshUserClient::notificationRegister,
            0,
            0,
            0,
            0,
            true,
        },
    [MUCI::Method::NotificationUnregister] =
        {
            &AppleCIOMeshUserClient::notificationUnregister,
            0,
            0,
            0,
            0,
            false,
        },
    [MUCI::Method::AllocateSharedMemory] =
        {
            &AppleCIOMeshUserClient::allocateSharedMemory,
            0,
            sizeof(MUCI::SharedMemory),
            0,
            0,
            false,
        },
    [MUCI::Method::DeallocateSharedMemory] =
        {
            &AppleCIOMeshUserClient::deallocateSharedMemory,
            0,
            sizeof(MUCI::SharedMemoryRef),
            0,
            0,
            false,
        },
    [MUCI::Method::AssignSharedMemoryChunk] =
        {
            &AppleCIOMeshUserClient::assignSharedMemoryChunk,
            0,
            sizeof(MUCI::AssignChunks),
            0,
            0,
            false,
        },
    [MUCI::Method::PrintBufferState] =
        {
            &AppleCIOMeshUserClient::printBufferState,
            0,
            sizeof(MUCI::BufferId),
            0,
            0,
            false,
        },
    [MUCI::Method::SetupForwardChainBuffers] =
        {
            &AppleCIOMeshUserClient::setForwardChain,
            0,
            sizeof(MUCI::ForwardChain),
            0,
            sizeof(MUCI::ForwardChainId),
            false,
        },
    [MUCI::Method::SetMaxWaitTime] =
        {
            &AppleCIOMeshUserClient::setMaxWaitTime,
            0,
            sizeof(MUCI::SetMaxWaitTime),
            0,
            0,
            false,
        },
    [MUCI::Method::SetMaxWaitPerNodeBatch] =
        {
            &AppleCIOMeshUserClient::setMaxWaitTimeNodeBatch,
            0,
            sizeof(MUCI::SetMaxWaitTime),
            0,
            0,
            false,
        },
    [MUCI::Method::SynchronizeGeneration] =
        {
            &AppleCIOMeshUserClient::meshSynchronize,
            0,
            0,
            0,
            0,
            false,
        },
    [MUCI::Method::OverrideRuntimePrepare] =
        {
            &AppleCIOMeshUserClient::overrideRuntimePrepare,
            0,
            sizeof(MUCI::BufferId),
            0,
            0,
            false,
        },
};

const IOExternalTrap AppleCIOMeshUserClient::_traps[MUCI::Trap::NumTraps] = {
    [MUCI::Trap::WaitSharedMemoryChunk] =
        {
            NULL,
            (IOTrap)&AppleCIOMeshUserClient::trapWaitSharedMemoryChunk,
        },
    [MUCI::Trap::SendAssignedData] =
        {
            NULL,
            (IOTrap)&AppleCIOMeshUserClient::trapSendChunk,
        },
    [MUCI::Trap::SendAllAssignedChunks] =
        {
            NULL,
            (IOTrap)&AppleCIOMeshUserClient::trapSendAllChunks,
        },
    [MUCI::Trap::PrepareChunk] =
        {
            NULL,
            (IOTrap)&AppleCIOMeshUserClient::trapPrepareChunk,
        },
    [MUCI::Trap::PrepareAllChunks] =
        {
            NULL,
            (IOTrap)&AppleCIOMeshUserClient::trapPrepareAllChunks,
        },
    [MUCI::Trap::SendAndPrepareChunk] =
        {
            NULL,
            (IOTrap)&AppleCIOMeshUserClient::trapSendAndPrepareChunk,
        },
    [MUCI::Trap::ReceiveAll] =
        {
            NULL,
            (IOTrap)&AppleCIOMeshUserClient::trapReceiveAll,
        },
    [MUCI::Trap::ReceiveNext] =
        {
            NULL,
            (IOTrap)&AppleCIOMeshUserClient::trapReceiveNext,
        },
    [MUCI::Trap::ReceiveBatch] =
        {
            NULL,
            (IOTrap)&AppleCIOMeshUserClient::trapReceiveBatch,
        },
    [MUCI::Trap::ReceiveBatchForNode] =
        {
            NULL,
            (IOTrap)&AppleCIOMeshUserClient::trapReceiveBatchForNode,
        },
    [MUCI::Trap::InterruptWaitingThreads] =
        {
            NULL,
            (IOTrap)&AppleCIOMeshUserClient::trapInterruptWaitingThreads,
        },
    [MUCI::Trap::ClearInterruptState] =
        {
            NULL,
            (IOTrap)&AppleCIOMeshUserClient::trapClearInterruptState,
        },
    [MUCI::Trap::InterruptReceiveBatch] =
        {
            NULL,
            (IOTrap)&AppleCIOMeshUserClient::trapInterruptReceiveBatch,
        },
    [MUCI::Trap::StartForwardChain] =
        {
            NULL,
            (IOTrap)&AppleCIOMeshUserClient::trapStartForwardChain,
        },
    [MUCI::Trap::StopForwardChain] =
        {
            NULL,
            (IOTrap)&AppleCIOMeshUserClient::trapStopForwardChain,
        },
    [MUCI::Trap::ResetBuffer] =
        {
            NULL,
            (IOTrap)&AppleCIOMeshUserClient::trapResetBuffer,
        },
};

bool
AppleCIOMeshUserClient::initWithTask(task_t owning_task, void * security_token, UInt32 type, OSDictionary * properties)
{
	require(super::initWithTask(owning_task, security_token, type, properties), fail);

	_notify_lock = IOLockAlloc();
	require(_notify_lock != nullptr, fail);
	_owningTask = owning_task;
	_owningPid  = proc_selfpid();
	atomic_store(&_hasBeenInterrupted, false);

	// initialize the max wait time to the default
	nanoseconds_to_absolutetime(kMaxWaitTimeInSeconds * kNsPerSecond, &_maxWaitTime);

	return true;

fail:
	return false;
}

bool
AppleCIOMeshUserClient::start(IOService * provider)
{
	require(super::start(provider), fail);

	setProperty(kIOUserClientDefaultLockingKey, kOSBooleanTrue);
	setProperty(kIOUserClientDefaultLockingSetPropertiesKey, kOSBooleanTrue);
	setProperty(kIOUserClientDefaultLockingSingleThreadExternalMethodKey, kOSBooleanTrue);
	setProperty(kIOUserClientEntitlementsKey, kAppleCIOMeshUserAccessEntitlement);

	_provider = OSDynamicCast(AppleCIOMeshService, provider);
	require(_provider != nullptr, fail);

	_provider->retain();

	_commandeerAvailable = _provider->getLinksPerChannel() == 2;
	atomic_store(&_batchRunning, false);

	require(_provider->registerUserClient(this), fail);

	_signpostSyncCount = 0;

	// Initialize max wait time for node receive batch
	nanoseconds_to_absolutetime(kDefaultMaxWaitBatchNodeNS, &_maxWaitTimeBatchNode);

	return true;

fail:
	return false;
}

void
AppleCIOMeshUserClient::stop(IOService * provider)
{
	_provider->unregisterUserClient(this);

	IOLockLock(_notify_lock);

	if (_notify_ref_valid) {
		_notify_ref_valid = false;
		releaseAsyncReference64(_notify_ref);
	}

	IOLockUnlock(_notify_lock);

	super::stop(provider);
}

void
AppleCIOMeshUserClient::free()
{
	OSSafeReleaseNULL(_provider);

	if (_notify_lock) {
		IOLockFree(_notify_lock);
		_notify_lock = nullptr;
	}

	super::free();
}

task_t
AppleCIOMeshUserClient::getOwningTask()
{
	return _owningTask;
}

pid_t
AppleCIOMeshUserClient::getOwningPid()
{
	return _owningPid;
}

IOReturn
AppleCIOMeshUserClient::clientClose()
{
	terminate();
	return kIOReturnSuccess;
}

IOReturn
AppleCIOMeshUserClient::externalMethod(uint32_t selector, IOExternalMethodArgumentsOpaque * args)
{
	return dispatchExternalMethod(selector, args, _methods, sizeof(_methods) / sizeof(_methods[0]), this, NULL);
}

// MARK: - Notifications

void
AppleCIOMeshUserClient::notifyDataAvailable(const MUCI::DataChunk & data)
{
	io_user_reference_t arg[4];
	arg[0] = static_cast<io_user_reference_t>(MUCI::Notification::IncomingData);
	arg[1] = static_cast<io_user_reference_t>(data.bufferId);
	arg[2] = static_cast<io_user_reference_t>(data.offset);
	arg[3] = static_cast<io_user_reference_t>(data.size);

	sendNotification(arg, 4);
}

void
AppleCIOMeshUserClient::notifySendDataComplete(const MUCI::DataChunk & data)
{
	io_user_reference_t arg[4];
	arg[0] = static_cast<io_user_reference_t>(MUCI::Notification::SendDataComplete);
	arg[1] = static_cast<io_user_reference_t>(data.bufferId);
	arg[2] = static_cast<io_user_reference_t>(data.offset);
	arg[3] = static_cast<io_user_reference_t>(data.size);

	sendNotification(arg, 4);
}

void
AppleCIOMeshUserClient::notifyMeshSynchronized()
{
	io_user_reference_t arg[4];
	arg[0] = static_cast<io_user_reference_t>(MUCI::Notification::MeshSynchronized);

	sendNotification(arg, 4);
}

void
AppleCIOMeshUserClient::sendNotification(io_user_reference_t * args, uint32_t count)
{
	if (_notify_ref_valid) {
		sendAsyncResult64(_notify_ref, kIOReturnSuccess, args, count);
	}
}

// MARK: - External Methods

IOReturn
AppleCIOMeshUserClient::notificationRegister(OSObject * target, __unused void * reference, IOExternalMethodArguments * arguments)
{
	auto me = OSRequiredCast(AppleCIOMeshUserClient, target);

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
AppleCIOMeshUserClient::notificationUnregister(OSObject * target,
                                               __unused void * reference,
                                               __unused IOExternalMethodArguments * arguments)
{
	auto me = OSRequiredCast(AppleCIOMeshUserClient, target);

	IOLockLock(me->_notify_lock);

	if (me->_notify_ref_valid) {
		me->_notify_ref_valid = false;
		releaseAsyncReference64(me->_notify_ref);
	}

	IOLockUnlock(me->_notify_lock);

	return kIOReturnSuccess;
}

IOReturn
AppleCIOMeshUserClient::overrideRuntimePrepare(OSObject * target, __unused void * reference, IOExternalMethodArguments * arguments)
{
	auto me = OSRequiredCast(AppleCIOMeshUserClient, target);
	EMAInputExtractor<MUCI::BufferId> bufferId(arguments);

	return me->_provider->overrideRuntimePrepare(bufferId.get());
}

IOReturn
AppleCIOMeshUserClient::allocateSharedMemory(OSObject * target, __unused void * reference, IOExternalMethodArguments * arguments)
{
	auto me = OSRequiredCast(AppleCIOMeshUserClient, target);
	EMAInputExtractor<MUCI::SharedMemory> memory(arguments);

	if (me->_provider->isShuttingDown()) {
		LOG("system is shutting down.  go away");
		return kIOReturnError;
	}

	return me->_provider->allocateSharedMemory(memory.get(), me->_owningTask, me);
}

IOReturn
AppleCIOMeshUserClient::deallocateSharedMemory(OSObject * target, __unused void * reference, IOExternalMethodArguments * arguments)
{
	auto me = OSRequiredCast(AppleCIOMeshUserClient, target);
	EMAInputExtractor<MUCI::SharedMemoryRef> memory(arguments);

	me->_receivePrepareTime = 0;
	return me->_provider->deallocateSharedMemory(memory.get(), me->_owningTask, me);
}

IOReturn
AppleCIOMeshUserClient::assignSharedMemoryChunk(OSObject * target, __unused void * reference, IOExternalMethodArguments * arguments)
{
	auto me = OSRequiredCast(AppleCIOMeshUserClient, target);
	EMAInputExtractor<MUCI::AssignChunks> assignment(arguments);

	if (me->_provider->isShuttingDown()) {
		LOG("system is shutting down.  go away");
		return kIOReturnError;
	}

	return me->_provider->assignMemoryChunk(assignment.get());
}

IOReturn
AppleCIOMeshUserClient::printBufferState(OSObject * target, __unused void * reference, IOExternalMethodArguments * arguments)
{
	auto me = OSRequiredCast(AppleCIOMeshUserClient, target);
	EMAInputExtractor<MUCI::BufferId> buffer(arguments);

	return me->_provider->printBufferState(buffer.get());
}

IOReturn
AppleCIOMeshUserClient::setForwardChain(OSObject * target, __unused void * reference, IOExternalMethodArguments * arguments)
{
	auto me = OSRequiredCast(AppleCIOMeshUserClient, target);
	EMAInputExtractor<MUCI::ForwardChain> forwardChain(arguments);
	EMAOutputExtractor<MUCI::ForwardChainId> forwardChainId(arguments);

	MUCI::ForwardChainId * chainId = (MUCI::ForwardChainId *)forwardChainId.get();
	if (me->_provider->isShuttingDown()) {
		LOG("system is shutting down.  go away");
		return kIOReturnError;
	}

	return me->_provider->setForwardChain(forwardChain.get(), chainId);
}

IOReturn
AppleCIOMeshUserClient::setMaxWaitTime(OSObject * target, __unused void * reference, IOExternalMethodArguments * arguments)
{
	auto me = OSRequiredCast(AppleCIOMeshUserClient, target);
	EMAInputExtractor<MUCI::SetMaxWaitTime> setMaxWaitTime(arguments);

	uint64_t maxWaitNanos = setMaxWaitTime->maxWaitTime;
	LOG("Setting the max wait time to: %lld\n", maxWaitNanos);
	if (maxWaitNanos == 0) {
		// let's wait for 100 years.  that's more or less infinite.
		maxWaitNanos = (kNsPerSecond * 86400 * 365 * 100);
	}

	nanoseconds_to_absolutetime(maxWaitNanos, &me->_maxWaitTime);

	return me->_provider->setMaxWaitTime(me->_maxWaitTime);
}

IOReturn
AppleCIOMeshUserClient::setMaxWaitTimeNodeBatch(OSObject * target, __unused void * reference, IOExternalMethodArguments * arguments)
{
	auto me = OSRequiredCast(AppleCIOMeshUserClient, target);
	EMAInputExtractor<MUCI::SetMaxWaitTime> setMaxWaitTime(arguments);

	uint64_t maxWaitNanos = setMaxWaitTime->maxWaitTime;
	LOG("Setting the max wait time for node batch receive to: %lld\n", maxWaitNanos);
	if (maxWaitNanos == 0) {
		// let's wait for 100 years.  that's more or less infinite.
		maxWaitNanos = (kNsPerSecond * 86400 * 365 * 100);
	}

	nanoseconds_to_absolutetime(maxWaitNanos, &me->_maxWaitTimeBatchNode);
	return kIOReturnSuccess;
}

IOReturn
AppleCIOMeshUserClient::meshSynchronize(OSObject * target,
                                        __unused void * reference,
                                        __unused IOExternalMethodArguments * arguments)
{
	auto me = OSRequiredCast(AppleCIOMeshUserClient, target);
	if (me->_provider->isShuttingDown()) {
		LOG("system is shutting down.  go away");
		return kIOReturnError;
	}

	return me->_provider->startNewGeneration();
}

IOExternalTrap *
AppleCIOMeshUserClient::getTargetAndTrapForIndex(IOService ** targetP, uint32_t index)
{
	if (index >= MUCI::Trap::NumTraps) {
		return NULL;
	}

	*targetP = this;
	return (IOExternalTrap *)&_traps[index];
}

IOReturn
AppleCIOMeshUserClient::trapWaitSharedMemoryChunk(uintptr_t bufferId_, uintptr_t offset_, uintptr_t outTagPtr_)
{
	if (_provider->isShuttingDown()) {
		static int nprint = 0;
		if (nprint++ < 10) {
			LOG("system is shutting down.  go away");
		}
		return kIOReturnError;
	}

	MUCI::BufferId bufferId = (MUCI::BufferId)bufferId_;
	int64_t offset          = (int64_t)offset_;

	int ret;
	bool interrupted = false;
	char tag[kTagSize];

	auto sm = _provider->getRetainSharedMemory(bufferId);
	if (sm == nullptr) {
		LOG("Invalid bufferId: %lld\n", (MUCI::BufferId)bufferId_);
		return kIOReturnBadArgument;
	}

	ret = _provider->waitData(sm, offset, &interrupted, &tag[0], sizeof(tag));
	if (ret != 0 || interrupted) {
		LOG("waitSharedMemory %s... offset 0x%llx in bufferId %lld ret 0x%x\n", interrupted ? "interrupted" : "failed", offset,
		    bufferId, ret);
		atomic_store(&_hasBeenInterrupted, true);
		sm->release();
		return kIOReturnIOError;
	} else {
		int err = copyout((int64_t *)&tag[0], outTagPtr_, sizeof(tag));
		if (err != 0) {
			LOG("waitSharedMemory failed to copyOut tag for bufferId %lld\n", bufferId);
			sm->release();
			return kIOReturnVMError;
		}
	}

	sm->release();
	return ret;
}

IOReturn
AppleCIOMeshUserClient::trapSendChunk(uintptr_t bufferId_, uintptr_t offset_, uintptr_t tagsPtr)
{
	if (_provider->isShuttingDown()) {
		static int nprint = 0;
		if (nprint++ < 10) {
			LOG("system is shutting down.  go away");
		}
		return kIOReturnError;
	}

	_signpostSyncCount++;

	if (atomic_load(&_hasBeenInterrupted)) {
		LOG("we have already been interrupted\n")
		return kIOReturnError;
	}

	AppleCIOMeshSharedMemory * sm;
	sm = _provider->getRetainSharedMemory((MUCI::BufferId)bufferId_);
	if (sm == nullptr) {
		LOG("Invalid bufferId: %lld\n", (MUCI::BufferId)bufferId_);
		return kIOReturnBadArgument;
	}

	SEND_TR((MUCI::BufferId)bufferId_, _signpostSyncCount, SEND_META_SEND_CHUNK);
	bool usingCommandeer = _commandeerAvailable;

	// Wait for the commandeer to fully prepare the whole buffer before we start
	// sending data
	IOReturn errRet = kIOReturnSuccess;
	while (1) {
		if (sm->hasBeenInterrupted()) {
			LOG("sm %lld has been interrupted\n", sm->getId());
			errRet = kIOReturnIOError;
			break;
		}
		int bits = 0;
		if (atomic_load(&_hasBeenInterrupted) || (bits = vfs_context_issignal(vfs_context_current(), (sigset_t)~0)) != 0) {
			atomic_store(&_hasBeenInterrupted, true);
			LOG("sendChunk interrupted (bits 0x%x)... bufferId %lld offset 0x%lx\n", bits, sm->getId(), offset_);
			errRet = kIOReturnIOError;
			break;
		}
		if (sm->checkAssignmentPrepared((int64_t)offset_)) {
			// then all is good, break out of the loop
			break;
		}
	}
	if (errRet != kIOReturnSuccess) {
		sm->release();
		return errRet;
	}

	SEND_TR((MUCI::BufferId)bufferId_, (int64_t)offset_, SEND_META_CHUNK_PREPARED);

	// There is no next command or next offset so invalidate the cached
	// pointers
	_preparedBufferId = MUCI::kInvalidBufferId;
	_preparedOffset   = -1;

	char tag[kMaxMeshLinkCount][kTagSize];
	if (copyin(tagsPtr, &tag[0][0], kTagSize * _provider->getLinksPerChannel()) != 0) {
		LOG("could not copy in the user tags!\n");
		sm->release();
		return kIOReturnBadArgument;
	}

	if (usingCommandeer) {
		atomic_store(&_sendDispatchCount, 0);
		_provider->commandeerSend(sm, (int64_t)offset_, this, &tag[1][0], kTagSize);
	}

	uint64_t ctr = 0;
	uint64_t start, now;
	start = mach_absolute_time();
	now   = start;

	bool dispatched      = false;
	bool interrupted     = false;
	bool finishedSending = false;

	while (atomic_load(&_hasBeenInterrupted) == false && (now - start) < _maxWaitTime) {
		if (_provider->isShuttingDown()) {
			static int nprint = 0;
			if (nprint++ < 10) {
				LOG("system is shutting down.  go away");
			}
			sm->interruptIOThreads();
			sm->release();
			return kIOReturnError;
		}

		if (sm->hasBeenInterrupted()) {
			LOG("shared mem %lld has been interrupted\n", sm->getId());
			sm->release();
			return kIOReturnError;
		}

		ctr++;
		if ((ctr % 1000) == 0) {
			now = mach_absolute_time();
		}

		if (!dispatched) {
			if (!sm->assignmentDispatched((int64_t)offset_, usingCommandeer ? 0x1 : 0x3)) {
				if (usingCommandeer) {
					_provider->sendAssignedData(sm, (int64_t)offset_, 0x1, &tag[0][0], kTagSize);
				} else {
					_provider->sendAssignedData(sm, (int64_t)offset_, 0x3, &tag[0][0], kTagSize * _provider->getLinksPerChannel());
				}
			}

			if (sm->assignmentDispatched((int64_t)offset_, usingCommandeer ? 0x1 : 0x3)) {
				dispatched = true;
				SEND_TR((MUCI::BufferId)bufferId_, (int64_t)offset_, SEND_META_CHUNK_DISPATCHED);

				if (usingCommandeer) {
					atomic_fetch_add(&_sendDispatchCount, 1);
				}
			}
		}

		if (!finishedSending) {
			finishedSending = sm->checkTXAssignmentReady((int64_t)offset_, usingCommandeer ? 0x1 : 0x3, &interrupted);
			if (interrupted) {
				ERROR("sendChunk Interrupted offset 0x%llx...\n", (int64_t)offset_);
				sm->interruptIOThreads();
				sm->release();
				return kIOReturnIOError;
			}

			if (finishedSending) {
				SEND_TR((MUCI::BufferId)bufferId_, (int64_t)offset_, SEND_META_SEND_COMPLETE);
			}
		}

		if (finishedSending) {
			if (usingCommandeer) {
				while (atomic_load(&_sendDispatchCount) != 2 && atomic_load(&_hasBeenInterrupted) == false &&
				       (now - start) < _maxWaitTime) {
					int bits = 0;
					if ((bits = vfs_context_issignal(vfs_context_current(), (sigset_t)~0)) != 0) {
						atomic_store(&_hasBeenInterrupted, true);
						LOG("sendChunk interrupted (bits 0x%x) while waiting for commandeer... bufferId %lld offset 0x%lx\n", bits,
						    sm->getId(), offset_);
						sm->interruptIOThreads();
						sm->release();
						return kIOReturnIOError;
					}
					ctr++;
					if ((ctr % 1000) == 0) {
						now = mach_absolute_time();
					}
				}
				if ((now - start) >= _maxWaitTime) {
					LOG("commandeer wait loop timed out!!!! bufferId %lld _sendDispatchCount %d\n", sm->getId(),
					    (int)_sendDispatchCount);
					_provider->dumpCommandeerState();
					sm->interruptIOThreads();
					sm->release();
					return kIOReturnTimeout;
				}
				SEND_TR((MUCI::BufferId)bufferId_, (int64_t)offset_, SEND_META_COMMANDEER_SEND_COMPLETE);
			}
			break;
		}

		// check ctrl-c now
		int bits = 0;
		if ((bits = vfs_context_issignal(vfs_context_current(), (sigset_t)~0)) != 0) {
			atomic_store(&_hasBeenInterrupted, true);
			LOG("sendChunk interrupted (bits 0x%x) bufferId %lld offset 0x%llx\n", bits, sm->getId(), (int64_t)offset_);
			sm->interruptIOThreads();
			sm->release();
			return kIOReturnIOError;
		}
	}

	if (atomic_load(&_hasBeenInterrupted)) {
		sm->release();
		return kIOReturnError;
	}

	if ((now - start) >= _maxWaitTime) {
		ERROR("sendChunk timedout offset 0x%llx...\n", (int64_t)offset_);
		sm->interruptIOThreads();
		sm->release();
		return kIOReturnTimeout;
	}

	SEND_TR((MUCI::BufferId)bufferId_, (int64_t)offset_, SEND_META_USER_SPACE_RETURN);

	sm->release();
	return kIOReturnSuccess;
}

IOReturn
AppleCIOMeshUserClient::trapSendAllChunks(uintptr_t bufferId_, uintptr_t tagptr_)
{
	if (_provider->isShuttingDown()) {
		static int nprint = 0;
		if (nprint++ < 10) {
			LOG("system is shutting down.  go away");
		}
		return kIOReturnError;
	}

	MUCI::BufferId bufferId = (MUCI::BufferId)bufferId_;
	uint32_t myNodeId       = _provider->getLocalNodeId();

	if (atomic_load(&_hasBeenInterrupted)) {
		LOG("we have already been interrupted\n")
		return kIOReturnError;
	}

	auto sm = _provider->getRetainSharedMemory(bufferId);
	if (sm == nullptr) {
		LOG("Invalid bufferId: %lld\n", bufferId);
		return kIOReturnBadArgument;
	}

	if (copyin(tagptr_, &_tags[0][0], sizeof(_tags)) != 0) {
		LOG("could not copy in the user tags!\n");
		sm->release();
		return kIOReturnBadArgument;
	}

	// There is no next command or next offset so invalidate the cached
	// pointers
	_preparedBufferId = MUCI::kInvalidBufferId;
	_preparedOffset   = -1;

	int64_t chunkSize = sm->getChunkSize();          // XXXdbg * _provider->getLinksPerChannel();
	int64_t numChunks = (sm->getSize() / chunkSize); // Note: our own chunk doesn't get sent
	int64_t numSent   = 1;                           // it's 1 instead of 0 because we don't send our own chunk

	bool chunkSent[SEND_ALL_MAX_CHUNKS]        = {false};
	bool chunkSendPending[SEND_ALL_MAX_CHUNKS] = {false};
	if (numChunks >= SEND_ALL_MAX_CHUNKS) {
		LOG("*** Limiting numChunks %lld to %d.\n", numChunks, SEND_ALL_MAX_CHUNKS);
		numChunks = SEND_ALL_MAX_CHUNKS;
	}

	chunkSent[myNodeId] = true;
	if (numChunks <= 0) {
		sm->release();
		return 0;
	}

	while (numSent < numChunks) {
		if (_provider->isShuttingDown()) {
			LOG("system is shutting down.  go away");
			sm->release();
			return kIOReturnError;
		}

		if (sm->hasBeenInterrupted()) {
			LOG("shared mem %lld has been interrupted\n", sm->getId());
			sm->release();
			return kIOReturnError;
		}

		for (int64_t i = 0; i < numChunks; i++) {
			// check this each time
			if (atomic_load(&_hasBeenInterrupted)) {
				sm->interruptIOThreads();
				sm->release();
				return kIOReturnError;
			}

			if (chunkSent[i]) {
				continue;
			}

			int64_t offset = chunkSize * i;

			IOReturn retVal = kIOReturnSuccess;
			if (!chunkSendPending[i]) {
				// XXXdbg - I think this should be:
				//				retVal              = _provider->sendAssignedData(sm, offset, 0x3, &_tags[i*2][0], kTagSize*2);
				retVal              = _provider->sendAssignedData(sm, offset, 0x3, &_tags[i][0], kTagSize);
				chunkSendPending[i] = true;
			}
			if (sm->assignmentDispatched(offset, 0x3)) {
				numSent++;
				chunkSent[i] = true;
			}

			if (retVal != kIOReturnSuccess) {
				sm->release();
				return retVal;
			}
		}
	}

	IOReturn ret = 0;
	for (int64_t i = 0; i < numChunks; i++) {
		int64_t offset   = chunkSize * i;
		bool interrupted = false;

		if (((uint64_t)myNodeId) == i) {
			// printf("Skipping my own chunk %lld\n", i);
			continue;
		}

		if (sm->hasBeenInterrupted()) {
			LOG("shared mem %lld has been interrupted\n", sm->getId());
			sm->release();
			return kIOReturnError;
		}

		char tag[kTagSize];
		// note: the tag is not used when waiting on output assignments
		ret = _provider->waitData(sm, offset, &interrupted, &tag[0], sizeof(tag));
		if (ret != 0 || interrupted) {
			atomic_store(&_hasBeenInterrupted, true);
			break;
		}
	}

	sm->release();
	return ret;
}

IOReturn
AppleCIOMeshUserClient::trapPrepareChunk(uintptr_t bufferId_, uintptr_t offset_)
{
	if (_provider->isShuttingDown()) {
		static int nprint = 0;
		if (nprint++ < 10) {
			LOG("system is shutting down.  go away");
		}
		return kIOReturnError;
	}

	auto sm = _provider->getRetainSharedMemory((MUCI::BufferId)bufferId_);
	if (sm == nullptr) {
		LOG("Invalid bufferId: %lld\n", (MUCI::BufferId)bufferId_);
		return kIOReturnBadArgument;
	}

	IOReturn ret = _provider->prepareCommand(sm, (int64_t)offset_);
	if (ret != kIOReturnSuccess) {
		LOG("Failed to prepare chunk for buffer:%lld at offset:%lld\n", sm->getId(), (int64_t)offset_);
		sm->release();
		return ret;
	}

	// This function will only mark the thunderbolt commands are forward
	// incomplete if the command is doing a forward and if it is not part of
	// a forward chain (the chain will self manage marking forward incomplete).
	_provider->markForwardIncomplete(sm, (int64_t)offset_);

	sm->release();
	return ret;
}

IOReturn
AppleCIOMeshUserClient::trapPrepareAllChunks(uintptr_t bufferId_, uintptr_t direction)
{
	if (_provider->isShuttingDown()) {
		static int nprint = 0;
		if (nprint++ < 10) {
			LOG("system is shutting down.  go away");
		}
		return kIOReturnError;
	}

	auto sm = _provider->getRetainSharedMemory((MUCI::BufferId)bufferId_);
	if (sm == nullptr) {
		LOG("Invalid bufferId: %lld\n", (MUCI::BufferId)bufferId_);
		return kIOReturnBadArgument;
	}

	sm->setRuntimePrepareDisabled(true);

	auto assignmentMap =
	    (MUCI::MeshDirection)direction == MUCI::MeshDirection::In ? sm->getReceiveAssignmentMap() : sm->getOutputAssignmentMap();

	assignmentMap->reset();
	assignmentMap->hold();

	for (uint8_t i = 0; i < assignmentMap->assignmentCount; i++) {
		if (assignmentMap->linkIdx[i] == 0) {
			auto node                  = assignmentMap->assignedNode[i];
			auto nodeMap               = &(assignmentMap->nodeMap[node]);
			auto offset                = assignmentMap->getAssignmentOffset(i);
			auto assignmentSizePerLink = sm->getAssignment(offset)->getAssignmentSizePerLink();
			auto linkIdx               = assignmentMap->linkIdx[i];
			bool prepare               = true;

			if (sm->requiresRuntimePrepare() && (nodeMap->totalPrepared[linkIdx] + assignmentSizePerLink) >= kMaxNHIQueueByteSize) {
				prepare = false;
			}

			if (prepare) {
				for (int l = 0; l < kMaxMeshLinksPerChannel; l++) {
					nodeMap->totalPrepared[l] += assignmentSizePerLink;
					atomic_fetch_add(&nodeMap->linkCurrentIdx[l], 1);
				}

				_provider->prepareCommand(sm, assignmentMap->getAssignmentOffset(i));
			}

			if ((MUCI::MeshDirection)direction == MUCI::MeshDirection::In) {
				_provider->markForwardIncomplete(sm, (int64_t)assignmentMap->getAssignmentOffset(i));
				if (!prepare) {
					sm->holdCommand(offset);
				}
			}
		}
	}

	if ((MUCI::MeshDirection)direction == MUCI::MeshDirection::In) {
		_receivePrepareTime                    = mach_absolute_time();
		AppleCIOMeshAssignmentMap * receiveMap = sm->getReceiveAssignmentMap();
		if (!sm->requiresRuntimePrepare()) {
			if (!receiveMap->checkPrepared()) {
				panic("Receive assignments not prepared for buffer %lld", (MUCI::BufferId)bufferId_);
			}
		}
	}

	sm->setRuntimePrepareDisabled(false);

	sm->release();
	return kIOReturnSuccess;
}

IOReturn
AppleCIOMeshUserClient::trapSendAndPrepareChunk(
    uintptr_t sendBufferId_, uintptr_t sendOffset_, uintptr_t prepareBufferId_, uintptr_t prepareOffset_, uintptr_t tagsPtr)
{
	if (_provider->isShuttingDown()) {
		static int nprint = 0;
		if (nprint++ < 10) {
			LOG("system is shutting down.  go away");
		}
		return kIOReturnError;
	}

	_signpostSyncCount++;

	if (sendBufferId_ == prepareBufferId_ && sendOffset_ == prepareOffset_) {
		LOG("Cannot prepare and send the same buffer at this time\n");
		return kIOReturnBadArgument;
	}

	if (atomic_load(&_hasBeenInterrupted)) {
		LOG("we have already been interrupted\n")
		return kIOReturnError;
	}

	SEND_TR((MUCI::BufferId)sendBufferId_, _signpostSyncCount, SEND_META_SEND_AND_PREPARE);
	bool usingCommandeer = _commandeerAvailable;
	AppleCIOMeshSharedMemory * sendSM;
	bool prepareFullBuffer =
	    ((int64_t)prepareOffset_ == MUCI::PrepareFullBuffer) && ((int64_t)sendBufferId_ != (int64_t)prepareBufferId_);

	atomic_store(&_sendDispatchCount, 0);
	sendSM = _provider->getRetainSharedMemory((MUCI::BufferId)sendBufferId_);
	if (sendSM == nullptr) {
		LOG("Invalid sendBufferId_: %lld\n", (MUCI::BufferId)sendBufferId_);
		return kIOReturnBadArgument;
	}

	if (_preparedBufferId == MUCI::kInvalidBufferId || _preparedBufferId != (MUCI::BufferId)sendBufferId_) {
		// The expectation is the whole buffer was actually prepared but because
		// the first buffer was prepared with trapPrepare, the assignment/prepared
		// commands think the whole thing was not fully prepared, so override it
		// here.
		sendSM->overrideOutputAssignmentForWholeBuffer();
	}

	// Wait for the commandeer to fully prepare the whole buffer before we start
	// sending data
	IOReturn errRet = kIOReturnSuccess;

	while (1) {
		if (sendSM->hasBeenInterrupted()) {
			LOG("sm %lld has been interrupted\n", sendSM->getId());
			errRet = kIOReturnIOError;
			break;
		}
		int bits = 0;
		if (atomic_load(&_hasBeenInterrupted) || (bits = vfs_context_issignal(vfs_context_current(), (sigset_t)~0)) != 0) {
			atomic_store(&_hasBeenInterrupted, true);
			LOG("sendAndPrepareChunk interrupted (bits 0x%x) bufferId %lld offset 0x%lx\n", bits, sendSM->getId(), sendOffset_);
			errRet = kIOReturnIOError;
			break;
		}
		if (sendSM->checkAssignmentPrepared((int64_t)sendOffset_)) {
			// then all is good, break out of the loop
			break;
		}
	}
	if (errRet != kIOReturnSuccess) {
		sendSM->interruptIOThreads();
		sendSM->release();
		return errRet;
	}

	SEND_TR((MUCI::BufferId)sendBufferId_, (int64_t)sendOffset_, SEND_META_CHUNK_PREPARED);

	char tag[kMaxMeshLinkCount][kTagSize];
	if (copyin(tagsPtr, &tag[0][0], kTagSize * _provider->getLinksPerChannel()) != 0) {
		LOG("could not copy in the user tags!\n");
		sendSM->interruptIOThreads();
		sendSM->release();
		return kIOReturnBadArgument;
	}

	if (usingCommandeer) {
		_provider->commandeerSend(sendSM, (int64_t)sendOffset_, this, &tag[1][0], kTagSize);
	}

	uint64_t ctr = 0;
	uint64_t start, now;
	start = mach_absolute_time();
	now   = start;

	bool dispatched      = false;
	bool interrupted     = false;
	bool finishedSending = false;

	while (atomic_load(&_hasBeenInterrupted) == false && (now - start) < _maxWaitTime) {
		if (_provider->isShuttingDown()) {
			LOG("system is shutting down.  go away");
			sendSM->interruptIOThreads();
			sendSM->release();
			return kIOReturnError;
		}

		if (sendSM->hasBeenInterrupted()) {
			LOG("sm %lld has been interrupted\n", sendSM->getId());
			sendSM->release();
			return kIOReturnIOError;
		}

		ctr++;
		if ((ctr % 1000) == 0) {
			now = mach_absolute_time();
		}

		if (!dispatched) {
			if (!sendSM->assignmentDispatched((int64_t)sendOffset_, usingCommandeer ? 0x1 : 0x3)) {
				if (usingCommandeer) {
					_provider->sendAssignedData(sendSM, (int64_t)sendOffset_, 0x1, &tag[0][0], kTagSize);
				} else {
					_provider->sendAssignedData(sendSM, (int64_t)sendOffset_, 0x3, &tag[0][0],
					                            kTagSize * _provider->getLinksPerChannel());
				}
			}

			if (sendSM->assignmentDispatched((int64_t)sendOffset_, usingCommandeer ? 0x1 : 0x3)) {
				dispatched = true;
				SEND_TR((MUCI::BufferId)sendBufferId_, (int64_t)sendOffset_, SEND_META_CHUNK_DISPATCHED);

				if (usingCommandeer) {
					atomic_fetch_add(&_sendDispatchCount, 1);
				}
			}
		}

		if (!finishedSending) {
			finishedSending = sendSM->checkTXAssignmentReady((int64_t)sendOffset_, usingCommandeer ? 0x1 : 0x3, &interrupted);
			if (interrupted) {
				ERROR("sendAndPrepare Interrupted offset 0x%llx...\n", (int64_t)sendOffset_);
				sendSM->interruptIOThreads();
				sendSM->release();
				return kIOReturnIOError;
			}

			if (finishedSending) {
				SEND_TR((MUCI::BufferId)sendBufferId_, (int64_t)sendOffset_, SEND_META_SEND_COMPLETE);
			}
		}

		if (finishedSending) {
			if (usingCommandeer) {
				while (atomic_load(&_sendDispatchCount) != 2 && atomic_load(&_hasBeenInterrupted) == false &&
				       (now - start) < _maxWaitTime) {
					int bits = 0;
					if ((bits = vfs_context_issignal(vfs_context_current(), (sigset_t)~0)) != 0) {
						atomic_store(&_hasBeenInterrupted, true);
						LOG("sendAndPrepareChunk interrupted (bits 0x%x) while waiting for commandeer bufferId %lld offset 0x%lx\n",
						    bits, sendSM->getId(), sendOffset_);
						sendSM->interruptIOThreads();
						sendSM->release();
						return kIOReturnIOError;
					}
					ctr++;
					if ((ctr % 1000) == 0) {
						now = mach_absolute_time();
					}
				}
				if ((now - start) >= _maxWaitTime) {
					LOG("commandeer wait loop timed out!!!! bufferId %lld _sendDispatchCount %d\n", sendSM->getId(),
					    (int)_sendDispatchCount);
					_provider->dumpCommandeerState();
					sendSM->interruptIOThreads();
					sendSM->release();
					return kIOReturnTimeout;
				}
				SEND_TR((MUCI::BufferId)sendBufferId_, (int64_t)sendOffset_, SEND_META_COMMANDEER_SEND_COMPLETE);
			}
			break;
		}

		// Check ctrl-c now

		int bits = 0;
		if ((bits = vfs_context_issignal(vfs_context_current(), (sigset_t)~0)) != 0) {
			atomic_store(&_hasBeenInterrupted, true);
			LOG("sendAndPrepareChunk interrupted (bits 0x%x) bufferId %lld offset 0x%lx\n", bits, sendSM->getId(), sendOffset_);
			sendSM->interruptIOThreads();
			sendSM->release();
			return kIOReturnIOError;
		}
	}

	if (atomic_load(&_hasBeenInterrupted)) {
		sendSM->interruptIOThreads();
		sendSM->release();
		return kIOReturnIOError;
	}

	if ((now - start) >= _maxWaitTime) {
		ERROR("sendAndPrepareChunk timedOut offset 0x%llx...\n", (int64_t)sendOffset_);
		sendSM->interruptIOThreads();
		sendSM->release();
		return kIOReturnTimeout;
	}

	SEND_TR((MUCI::BufferId)sendBufferId_, (int64_t)sendOffset_, SEND_META_USER_SPACE_RETURN);

	if (prepareFullBuffer) {
		_preparedBufferId = (MUCI::BufferId)prepareBufferId_;
		auto preparingSM  = _provider->getRetainSharedMemory((MUCI::BufferId)prepareBufferId_);
		_preparedOffset   = (int64_t)prepareOffset_;

		// Hold the preparing SM for output so we don't send it
		preparingSM->getOutputAssignmentMap()->reset();
		preparingSM->holdOutput();

		_provider->commandeerDripPrepare(preparingSM, (int64_t)prepareOffset_, sendSM);

		OSSafeReleaseNULL(preparingSM);
	}

	sendSM->release();
	return kIOReturnSuccess;
}

IOReturn
AppleCIOMeshUserClient::trapReceiveAll(uintptr_t bufferId_)
{
	if (_provider->isShuttingDown()) {
		static int nprint = 0;
		if (nprint++ < 10) {
			LOG("system is shutting down.  go away");
		}
		return kIOReturnError;
	}

	auto sm = _provider->getRetainSharedMemory((MUCI::BufferId)bufferId_);
	if (!sm) {
		LOG("Invalid bufferId_: %lld\n", (MUCI::BufferId)bufferId_);
		return kIOReturnBadArgument;
	}

	AppleCIOMeshAssignmentMap * receiveMap = sm->getReceiveAssignmentMap();

	uint64_t start, now;
	start        = mach_absolute_time();
	now          = start;
	uint64_t ctr = 0;

	bool interrupted = false;
	while (1) {
		if (sm->hasBeenInterrupted()) {
			LOG("shared memory %lld has been interrupted.\n", sm->getId());
			sm->release();
			return kIOReturnError;
		}
		if (receiveMap->checkAllReady(&interrupted)) {
			break;
		}
		if ((now - start) >= _maxWaitTime) {
			break;
		}
		if (_provider->isShuttingDown()) {
			LOG("system is shutting down.  go away");
			sm->release();
			return kIOReturnError;
		}

		ctr++;
		if ((ctr % 1000) == 0) {
			now = mach_absolute_time();
		}

		if (interrupted) {
			break;
		}
	}

	if ((now - start) >= _maxWaitTime) {
		ERROR("receiveall timedout \n");
		sm->release();
		return kIOReturnTimeout;
	}

	if (interrupted) {
		LOG("receiveAll was interrupted on bufferId %lld....\n", (MUCI::BufferId)bufferId_);
		atomic_store(&_hasBeenInterrupted, true);
		sm->release();
		return kIOReturnIOError;
	}

	sm->release();

	return kIOReturnSuccess;
}

IOReturn
AppleCIOMeshUserClient::trapReceiveNext(uintptr_t bufferId_, uintptr_t outReceivedOffsetPtr_, uintptr_t outTagPtr_)
{
	if (_provider->isShuttingDown()) {
		static int nprint = 0;
		if (nprint++ < 10) {
			LOG("system is shutting down.  go away");
		}
		return kIOReturnError;
	}

	auto sm = _provider->getRetainSharedMemory((MUCI::BufferId)bufferId_);
	if (!sm) {
		LOG("Invalid bufferId_: %lld\n", (MUCI::BufferId)bufferId_);
		return kIOReturnBadArgument;
	}

	AppleCIOMeshAssignmentMap * receiveMap = sm->getReceiveAssignmentMap();

	bool interrupted = false;
	int64_t i        = receiveMap->startingIdx;
	uint64_t start, now, ctr = 0;
	start = mach_absolute_time();
	now   = start;

	while ((now - start) < _maxWaitTime) {
		if (_provider->isShuttingDown()) {
			LOG("system is shutting down.  go away");
			sm->release();
			return kIOReturnError;
		}

		if (sm->hasBeenInterrupted()) {
			LOG("shared memory %lld has been interrupted.\n", sm->getId());
			sm->release();
			return kIOReturnError;
		}

		if (atomic_load(&_hasBeenInterrupted)) {
			sm->release();
			return kIOReturnError;
		}
		if (receiveMap->assignmentNotified[i]) {
			goto nextiter;
		}

		if (receiveMap->assignmentReady[i]) {
			receiveMap->assignmentNotified[i] = true;

			int64_t offset = receiveMap->getAssignmentOffset(i);
			int err        = copyout((int64_t *)&offset, outReceivedOffsetPtr_, sizeof(int64_t));
			if (err != 0) {
				LOG("receiveNext failed to copyOut for bufferId %lld\n", (uint64_t)bufferId_);
				sm->release();
				return kIOReturnVMError;
			}

			err = copyout((int64_t *)&receiveMap->assignmentTag[i][0], outTagPtr_, kTagSize);
			if (err != 0) {
				LOG("receiveNext failed to copyOut tag for bufferId %lld\n", (uint64_t)bufferId_);
				sm->release();
				return kIOReturnVMError;
			}

			return kIOReturnSuccess;
		}

		if (receiveMap->checkReady((uint32_t)i, &interrupted)) {
			if (interrupted) {
				LOG("receiveNext was interrupted from user space on bufferId %lld\n", (uint64_t)bufferId_);
				atomic_store(&_hasBeenInterrupted, true);
				int64_t tmp = -1;
				copyout((int64_t *)&tmp, outReceivedOffsetPtr_, sizeof(int64_t));
				// not checking copyout here, we are failing anywways
				sm->release();

				return kIOReturnIOError;
			}

			receiveMap->assignmentNotified[i] = true;

			int64_t offset = receiveMap->getAssignmentOffset(i);
			int err        = copyout((int64_t *)&offset, outReceivedOffsetPtr_, sizeof(int64_t));
			if (err != 0) {
				LOG("receiveNext failed to copyOut receivedOffset %lld for bufferId %lld\n", receiveMap->getAssignmentOffset(i),
				    (uint64_t)bufferId_);
				sm->release();

				return kIOReturnVMError;
			}

			err = copyout((int64_t *)&receiveMap->assignmentTag[i][0], outTagPtr_, kTagSize);
			if (err != 0) {
				LOG("receiveNext failed to copyOut tag for bufferId %lld\n", (uint64_t)bufferId_);
				sm->release();

				return kIOReturnVMError;
			}

			sm->release();
			return kIOReturnSuccess;
		}

	nextiter:
		ctr++;
		if ((ctr % 1000) == 0) {
			now = mach_absolute_time();
		}

		if (++i == receiveMap->assignmentCount) {
			i = 0;
		}
	}

	LOG("receiveNext timedout on bufferId %lld: waited %lld, maxWait %lld; remainingAssignments %d/%d interrupted %s\n",
	    (uint64_t)bufferId_, (now - start), _maxWaitTime, (int)atomic_load(&receiveMap->remainingAssignments),
	    (int)receiveMap->assignmentCount, interrupted ? "YES" : "NO");
	for (int j = 0; j < receiveMap->assignmentCount; j++) {
		LOG("  receiveMap assignment %d node %lld: offset %lld ready %s checkReady %s notified %s\n", j,
		    receiveMap->getAssignmentOffset(j), receiveMap->assignedNode[i], receiveMap->assignmentReady[j] ? "YES" : "NO",
		    receiveMap->checkReady((uint32_t)j, &interrupted) ? "YES" : "NO", receiveMap->assignmentNotified[j] ? "YES" : "NO");
	}

	sm->release();
	return kIOReturnError;
}

IOReturn
AppleCIOMeshUserClient::trapReceiveBatch(uintptr_t bufferId_,
                                         uintptr_t batchCount_,
                                         uintptr_t timeoutUS_,
                                         uintptr_t outReceivedCount_,
                                         uintptr_t outReceivedOffsetsPtr_,
                                         uintptr_t outReceivedTagsPtr_)
{
	auto sm = _provider->getRetainSharedMemory((MUCI::BufferId)bufferId_);
	if (!sm) {
		LOG("Invalid bufferId_: %lld\n", (MUCI::BufferId)bufferId_);
		return kIOReturnBadArgument;
	}

	RECEIVE_BATCH_TR(bufferId_, RECEIVE_BATCH_META_ENTRY, 0xFF);

	AppleCIOMeshAssignmentMap * receiveMap = sm->getReceiveAssignmentMap();

	bool interrupted = false;
	uint32_t i       = (uint32_t)receiveMap->startingIdx;

	uint64_t start, end, now, ctr = 0;
	start = mach_absolute_time();

	// End time is either the timeout or the maxWaitTime (if 0)
	if ((int64_t)timeoutUS_ != 0) {
		uint64_t addition = 0;
		nanoseconds_to_absolutetime((uint64_t)timeoutUS_ * kNsPerMicrosecond, &addition);

		end = start + addition;
	} else {
		end = start + (uint64_t)_maxWaitTime;
	}

	// We will receive up to the remaining assignments or the batch count.
	// If batch count is 0, then remaining assignments.
	int64_t receiveCount = (int64_t)batchCount_;
	if (receiveCount == 0) {
		receiveCount = atomic_load(&receiveMap->remainingAssignments);
	} else {
		receiveCount = min(receiveCount, atomic_load(&receiveMap->remainingAssignments));
	}

	int64_t * receivedOffsets = (int64_t *)outReceivedOffsetsPtr_;
	char * receivedTag        = (char *)outReceivedTagsPtr_;
	int64_t curReceive        = 0;

	atomic_store(&_batchRunning, true);
	now = mach_absolute_time();

	RECEIVE_BATCH_TR(bufferId_, RECEIVE_BATCH_META_BEGIN_READS, 0xFF);

	while (atomic_load(&_batchRunning) && (now < end) && (curReceive < receiveCount)) {
		if (atomic_load(&_hasBeenInterrupted)) {
			sm->release();
			return kIOReturnError;
		}

		if (_provider->isShuttingDown()) {
			LOG("system is shutting down.  go away");
			sm->release();
			return kIOReturnError;
		}

		if (sm->hasBeenInterrupted()) {
			LOG("shared memory %lld has been interrupted.\n", sm->getId());
			sm->release();
			return kIOReturnError;
		}

		if (receiveMap->assignmentNotified[i]) {
			goto nextiter;
		}

		if (receiveMap->assignmentReady[i]) {
			receiveMap->assignmentNotified[i] = true;

			int64_t offset = receiveMap->getAssignmentOffset(i);
			int err        = copyout((int64_t *)&offset, (uintptr_t)&(receivedOffsets[curReceive]), sizeof(int64_t));
			if (err != 0) {
				LOG("receiveBatch failed to copyOut\n");
				sm->release();
				return kIOReturnVMError;
			}

			err = copyout((int64_t *)&receiveMap->assignmentTag[i][0], (uintptr_t)receivedTag, kTagSize);
			if (err != 0) {
				LOG("receiveBatch failed to copyOut tag\n");
				sm->release();
				return kIOReturnVMError;
			}

			receivedTag += kTagSize;
			curReceive++;

			goto nextiter;
		}

		RECEIVE_BATCH_TR(bufferId_, RECEIVE_BATCH_META_READING_OFFSET, receiveMap->getAssignmentOffset(i));
		if (receiveMap->checkReady((uint32_t)i, &interrupted)) {
			if (interrupted) {
				LOG("receiveBatch interrupted from user space on bufferId %lld\n", (uint64_t)bufferId_);
				for (int j = 0; j < receiveMap->assignmentCount; j++) {
					LOG("  receiveMap assignment %d node %lld: offset %lld ready %s checkReady %s notified %s\n", j,
					    receiveMap->getAssignmentOffset(j), receiveMap->assignedNode[i],
					    receiveMap->assignmentReady[j] ? "YES" : "NO",
					    receiveMap->checkReady((uint32_t)j, &interrupted) ? "YES" : "NO",
					    receiveMap->assignmentNotified[j] ? "YES" : "NO");
				}

				atomic_store(&_hasBeenInterrupted, true);
				sm->release();
				return kIOReturnIOError;
			}

			receiveMap->assignmentNotified[i] = true;

			int64_t offset = receiveMap->getAssignmentOffset(i);
			int err        = copyout((int64_t *)&offset, (uintptr_t)&(receivedOffsets[curReceive]), sizeof(int64_t));
			if (err != 0) {
				LOG("receiveBatch failed to copyOut\n");
				sm->release();
				return kIOReturnVMError;
			}

			err = copyout((int64_t *)&receiveMap->assignmentTag[i][0], (uintptr_t)receivedTag, kTagSize);
			if (err != 0) {
				LOG("receiveBatch failed to copyOut tag\n");
				sm->release();
				return kIOReturnVMError;
			}

			receivedTag += kTagSize;
			curReceive++;

			goto nextiter;
		}

	nextiter:
		ctr++;
		if ((ctr % 1000) == 0) {
			now = mach_absolute_time();
		}

		i++;
		if (i == receiveMap->assignmentCount) {
			i = 0;
		}
	}

	int err = copyout((int64_t *)&curReceive, outReceivedCount_, sizeof(int64_t));
	if (err != 0) {
		LOG("receiveBatch failed to copyOut\n");
		sm->release();
		return kIOReturnVMError;
	}

	RECEIVE_BATCH_TR(bufferId_, RECEIVE_BATCH_META_EXIT, 0xFF);

	sm->release();
	return kIOReturnSuccess;
}

IOReturn
AppleCIOMeshUserClient::trapReceiveBatchForNode(uintptr_t bufferId_,
                                                uintptr_t nodeId_,
                                                uintptr_t batchCount_,
                                                uintptr_t outReceivedCount_,
                                                uintptr_t outReceivedOffsetsPtr_,
                                                uintptr_t outReceivedTagsPtr_)
{
	IOReturn ret = kIOReturnSuccess;
	auto sm      = _provider->getRetainSharedMemory((MUCI::BufferId)bufferId_);
	if (!sm) {
		LOG("Invalid bufferId_: %lld\n", (MUCI::BufferId)bufferId_);
		return kIOReturnBadArgument;
	}

	AppleCIOMeshAssignmentMap * receiveMap = sm->getReceiveAssignmentMap();
	NodeAssignmentMap * nodeMap            = &(receiveMap->nodeMap[(uint8_t)nodeId_]);

	bool interrupted               = false;
	bool lastReceiveForMaxWaitTime = false;
	uint32_t nodeMapIdx            = 0;

	uint64_t start, end, now, ctr = 0;

	start = mach_absolute_time();
	end   = start + _maxWaitTimeBatchNode;

	if (_receivePrepareTime != 0) {
		if ((_receivePrepareTime + _maxWaitTime) < end) {
			lastReceiveForMaxWaitTime = true;
			end                       = _receivePrepareTime + _maxWaitTime;
		}
	}

	int64_t receiveCount      = (int64_t)batchCount_;
	int64_t * receivedOffsets = (int64_t *)outReceivedOffsetsPtr_;
	char * receivedTag        = (char *)outReceivedTagsPtr_;
	int64_t curReceive        = 0;

	uint8_t idx;
	int64_t offset;
	int err;

	now = mach_absolute_time();

	while ((now < end) && (curReceive < receiveCount) && !sm->hasBeenInterrupted()) {
		if (atomic_load(&_hasBeenInterrupted)) {
			ret = kIOReturnError;
			goto exit;
		}

		if (_provider->isShuttingDown()) {
			LOG("system is shutting down.  go away");
			return kIOReturnError;
		}

		if (sm->hasBeenInterrupted()) {
			LOG("shared memory %lld has been interrupted.\n", sm->getId());
			return kIOReturnError;
		}

		idx = nodeMap->assignedIdx[nodeMapIdx];
		if (receiveMap->assignmentNotified[idx]) {
			goto nextiter;
		}

		if (receiveMap->assignmentReady[idx]) {
			receiveMap->assignmentNotified[idx] = true;

			offset = receiveMap->getAssignmentOffset(idx);
			err    = copyout((int64_t *)&offset, (uintptr_t)&(receivedOffsets[curReceive]), sizeof(int64_t));
			if (err != 0) {
				LOG("receiveBatchForNode failed to copyOut\n");
				ret = kIOReturnVMError;
				goto exit;
			}

			err = copyout((int64_t *)&receiveMap->assignmentTag[idx][0], (uintptr_t)receivedTag, kTagSize);
			if (err != 0) {
				LOG("receiveBatchForNode failed to copyOut tag\n");
				ret = kIOReturnVMError;
				goto exit;
			}

			receivedTag += kTagSize;
			curReceive++;

			goto nextiter;
		}

		if (receiveMap->checkReady((uint32_t)idx, &interrupted)) {
			if (interrupted) {
				LOG("receiveBatchForNode interrupted from user space on bufferId %lld\n", (uint64_t)bufferId_);
				atomic_store(&_hasBeenInterrupted, true);
				ret = kIOReturnIOError;
				goto exit;
			}

			receiveMap->assignmentNotified[idx] = true;

			offset = receiveMap->getAssignmentOffset(idx);
			err    = copyout((int64_t *)&offset, (uintptr_t)&(receivedOffsets[curReceive]), sizeof(int64_t));
			if (err != 0) {
				LOG("receiveBatch failed to copyOut\n");
				ret = kIOReturnVMError;
				goto exit;
			}

			err = copyout((int64_t *)&receiveMap->assignmentTag[idx][0], (uintptr_t)receivedTag, kTagSize);
			if (err != 0) {
				LOG("receiveBatch failed to copyOut tag\n");
				ret = kIOReturnVMError;
				goto exit;
			}

			receivedTag += kTagSize;
			curReceive++;

			goto nextiter;
		}

	nextiter:
		ctr++;
		if ((ctr % 1000) == 0) {
			now = mach_absolute_time();
		}

		nodeMapIdx++;
		if (nodeMapIdx == nodeMap->assignCount) {
			nodeMapIdx = 0;
		}
	}

	// We hit the end of maxWaitTime and didnt get all the remaining receives
	// let's print an error now and return timeout.
	if (now >= end && lastReceiveForMaxWaitTime && curReceive < receiveCount) {
		LOG("receiveBatchForNode(%d) timedout on bufferId %lld: waited %lld, maxWait %lld; remainingAssignments %d/%d interrupted "
		    "%s\n",
		    (uint8_t)nodeId_, (uint64_t)bufferId_, (now - start), _maxWaitTime, (int)atomic_load(&receiveMap->remainingAssignments),
		    (int)receiveMap->assignmentCount, interrupted ? "YES" : "NO");

		for (uint32_t j = 0; j < receiveMap->assignmentCount; j++) {
			LOG("  receiveMap assignment %d node %lld: offset %lld ready %s checkReady %s notified %s\n", j,
			    receiveMap->assignedNode[j], receiveMap->getAssignmentOffset(j), receiveMap->assignmentReady[j] ? "YES" : "NO",
			    receiveMap->checkReady((uint32_t)j, &interrupted) ? "YES" : "NO", receiveMap->assignmentNotified[j] ? "YES" : "NO");
		}
		ret = kIOReturnTimeout;
		goto exit;
	}

	err = copyout((int64_t *)&curReceive, outReceivedCount_, sizeof(int64_t));
	if (err != 0) {
		LOG("receiveBatchForNode failed to copyOut\n");
		ret = kIOReturnVMError;
		goto exit;
	}

exit:
	OSSafeReleaseNULL(sm);
	return ret;
}

IOReturn
AppleCIOMeshUserClient::trapClearInterruptState(uintptr_t bufferId_)
{
	atomic_store(&_hasBeenInterrupted, false);

	auto sm = _provider->getRetainSharedMemory((MUCI::BufferId)bufferId_);
	if (sm == nullptr) {
		LOG("Invalid bufferId: %lld\n", (MUCI::BufferId)bufferId_);
		return kIOReturnBadArgument;
	}

	sm->clearInterruptState();
	sm->release();
	return kIOReturnSuccess;
}

IOReturn
AppleCIOMeshUserClient::trapInterruptWaitingThreads(uintptr_t bufferId_)
{
	// this is intentionally coded to set this before getting the sm
	// associated with the bufferId
	atomic_store(&_hasBeenInterrupted, true);

	auto sm = _provider->getRetainSharedMemory((MUCI::BufferId)bufferId_);
	if (sm == nullptr) {
		LOG("Invalid bufferId: %lld\n", (MUCI::BufferId)bufferId_);
		return kIOReturnBadArgument;
	}

	sm->interruptIOThreads();
	sm->release();
	return kIOReturnSuccess;
}

IOReturn
AppleCIOMeshUserClient::trapInterruptReceiveBatch()
{
	bool expected = true;
	atomic_compare_exchange_strong(&_batchRunning, &expected, false);

	return kIOReturnSuccess;
}

IOReturn
AppleCIOMeshUserClient::trapStartForwardChain(uintptr_t forwardChainId_, uintptr_t elements_)
{
	if (_provider->isShuttingDown()) {
		LOG("system is shutting down.  go away");
		return kIOReturnError;
	}

	return _provider->startForwardChain((MUCI::ForwardChainId)forwardChainId_, (uint32_t)elements_);
}

IOReturn
AppleCIOMeshUserClient::trapStopForwardChain()
{
	if (_provider->isShuttingDown()) {
		LOG("system is shutting down.  go away");
		return kIOReturnError;
	}

	return _provider->stopForwardChain();
}

IOReturn
AppleCIOMeshUserClient::trapResetBuffer(uintptr_t bufferId_)
{
    if (_provider->isShuttingDown()) {
        LOG("system is shutting down.  go away");
        return kIOReturnError;
    }

    auto sm = _provider->getRetainSharedMemory((MUCI::BufferId)bufferId_);
    if (sm == nullptr) {
        LOG("Invalid bufferId: %lld\n", (MUCI::BufferId)bufferId_);
        return kIOReturnBadArgument;
    }

    sm->resetForwardingChains();
    sm->release();

    return kIOReturnSuccess;
}
