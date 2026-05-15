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

#pragma once

#include <IOKit/IOUserClient.h>
#include <sys/proc.h>

#include "AppleCIOMeshSharedMemory.h"
#include "AppleCIOMeshThunderboltCommands.h"
#include "AppleCIOMeshUserClientInterface.h"

namespace MUCI = AppleCIOMeshUserClientInterface;

#define kAppleCIOMeshUserAccessEntitlement "com.apple.private.appleciomesh.data-access"

class AppleCIOMeshService;

class AppleCIOMeshUserClient final : public IOUserClient2022
{
	OSDeclareDefaultStructors(AppleCIOMeshUserClient);
	using super = IOUserClient2022;

  public:
	virtual bool
	initWithTask(task_t owning_task, void * security_token, UInt32 type, OSDictionary * properties) APPLE_KEXT_OVERRIDE;

	virtual bool start(IOService * provider) APPLE_KEXT_OVERRIDE;
	virtual void stop(IOService * provider) APPLE_KEXT_OVERRIDE;
	virtual void free() APPLE_KEXT_OVERRIDE;
	task_t getOwningTask();
	pid_t getOwningPid();

	virtual IOReturn clientClose() APPLE_KEXT_OVERRIDE;

	virtual IOReturn externalMethod(uint32_t selector, IOExternalMethodArgumentsOpaque * args) APPLE_KEXT_OVERRIDE;
	virtual IOExternalTrap * getTargetAndTrapForIndex(IOService ** targetP, uint32_t index) APPLE_KEXT_OVERRIDE;

	void notifyDataAvailable(const MUCI::DataChunk & data);
	void notifySendDataComplete(const MUCI::DataChunk & data);
	void notifyMeshSynchronized();

	inline void
	commandeerSendComplete()
	{
		atomic_fetch_add(&_sendDispatchCount, 1);
	}

  private:
	void sendNotification(io_user_reference_t * args, uint32_t count);

	// Methods
	static IOReturn notificationRegister(OSObject * target, void * reference, IOExternalMethodArguments * arguments);
	static IOReturn notificationUnregister(OSObject * target, void * reference, IOExternalMethodArguments * arguments);
	static IOReturn allocateSharedMemory(OSObject * target, void * reference, IOExternalMethodArguments * arguments);
	static IOReturn deallocateSharedMemory(OSObject * target, void * reference, IOExternalMethodArguments * arguments);
	static IOReturn assignSharedMemoryChunk(OSObject * target, void * reference, IOExternalMethodArguments * arguments);
	static IOReturn printBufferState(OSObject * target, void * reference, IOExternalMethodArguments * arguments);
	static IOReturn setForwardChain(OSObject * target, void * reference, IOExternalMethodArguments * arguments);
	static IOReturn setMaxWaitTime(OSObject * target, void * reference, IOExternalMethodArguments * arguments);
	static IOReturn setMaxWaitTimeNodeBatch(OSObject * target, void * reference, IOExternalMethodArguments * arguments);
	static IOReturn meshSynchronize(OSObject * target, void * reference, IOExternalMethodArguments * arguments);
	static IOReturn overrideRuntimePrepare(OSObject * target, void * reference, IOExternalMethodArguments * arguments);

	// Traps
	IOReturn trapWaitSharedMemoryChunk(uintptr_t bufferId_, uintptr_t offset_, uintptr_t outTagPtr_);
	IOReturn trapSendChunk(uintptr_t bufferId_, uintptr_t offset_, uintptr_t tagsPtr);
	IOReturn trapSendAllChunks(uintptr_t bufferId_, uintptr_t tagsPtr_);

	IOReturn trapPrepareChunk(uintptr_t bufferId_, uintptr_t offset_);
	IOReturn trapPrepareAllChunks(uintptr_t bufferId_, uintptr_t direction);
	IOReturn trapSendAndPrepareChunk(
	    uintptr_t sendBufferId_, uintptr_t sendOffset_, uintptr_t prepareBufferId_, uintptr_t prepareOffset_, uintptr_t tagsPtr);
	IOReturn trapReceiveAll(uintptr_t bufferId_);
	IOReturn trapReceiveNext(uintptr_t bufferId_, uintptr_t outReceivedOffsetPtr_, uintptr_t outTagPtr);
	IOReturn trapReceiveBatch(uintptr_t bufferId_,
	                          uintptr_t batchCount_,
	                          uintptr_t timeoutUS_,
	                          uintptr_t outReceivedCount_,
	                          uintptr_t outReceivedOffsetsPtr_,
	                          uintptr_t outReceivedTagsPtr_);
	IOReturn trapReceiveBatchForNode(uintptr_t bufferId_,
	                                 uintptr_t nodeId_,
	                                 uintptr_t batchCount_,
	                                 uintptr_t outReceivedCount_,
	                                 uintptr_t outReceivedOffsetsPtr_,
	                                 uintptr_t outReceivedTagsPtr_);
	IOReturn trapClearInterruptState(uintptr_t bufferId_);
	IOReturn trapInterruptWaitingThreads(uintptr_t bufferId_);
	IOReturn trapInterruptReceiveBatch();
	IOReturn trapStartForwardChain(uintptr_t forwardChainId_, uintptr_t elements_);
	IOReturn trapStopForwardChain();
    IOReturn trapResetBuffer(uintptr_t bufferId_);

	static const IOExternalMethodDispatch2022 _methods[MUCI::Method::NumMethods];
	static const IOExternalTrap _traps[MUCI::Trap::NumTraps];
	AppleCIOMeshService * _provider;

	_Atomic(bool) _hasBeenInterrupted;
	bool _notify_ref_valid;
	OSAsyncReference64 _notify_ref;
	IOLock * _notify_lock;
	task_t _owningTask;
	pid_t _owningPid;
	_Atomic(bool) _batchRunning;

	// Cache for sendAndPrepare
	MUCI::BufferId _preparedBufferId;
	int64_t _preparedOffset;
	uint64_t _maxWaitTime;          // in mach_absolute_time() units
	uint64_t _maxWaitTimeBatchNode; // in mach_absolute_time() units

	// temp buffer for tags so we don't have to malloc it on the fast path
	char _tags[kMaxAssignmentCount][kTagSize];

	// Commandeer related
	_Atomic(uint8_t) _sendDispatchCount;
	bool _commandeerAvailable = true;

	uint64_t _signpostSyncCount;

	uint64_t _receivePrepareTime;
};
