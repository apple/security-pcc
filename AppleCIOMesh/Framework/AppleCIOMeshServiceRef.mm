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

#import <AssertMacros.h>
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#include <cctype>
#import <os/log.h>
#include <unordered_map>

#import "AppleCIOMeshUserClientInterface.h"
#import <AppleCIOMeshSupport/AppleCIOMeshServiceRef.h>

namespace MUCI = AppleCIOMeshUserClientInterface;

#define LogDebug(format, args...) os_log_debug(_logger, format, ##args)
#define LogInfo(format, args...) os_log_info(_logger, format, ##args)
#define Log(format, args...) os_log(_logger, format, ##args)
#define LogError(format, args...) os_log_error(_logger, format, ##args)

@implementation AppleCIOMeshServiceRef {
	os_log_t _logger;

	io_service_t _service;
	io_connect_t _connection;

	dispatch_queue_t _queue;
	IONotificationPortRef _notifyPort;

	IncomingDataChunkBlock _incomingDataChunkBlock;
	SendCompleteBlock _sendCompleteBlock;
	MeshSynchronizedBlock _meshSyncBlock;
}

#pragma mark - Init/deinit

- (instancetype)init
{
	self = [super init];

	if (self != nil) {
		_logger = os_log_create("AppleCIOMeshSupport", "ServiceRef");

		_service    = IO_OBJECT_NULL;
		_connection = IO_OBJECT_NULL;

		_queue      = nil;
		_notifyPort = nullptr;

		_incomingDataChunkBlock = nil;
		_sendCompleteBlock      = nil;
		_meshSyncBlock          = nil;
	}

	return self;
}

- (instancetype)initWithIOService:(io_service_t)service
{
	self = [self init];

	if (self != nil) {
		_service = service;
	}

	return self;
}

- (void)dealloc
{
	[self notifyUnregister];
	[self close];
}

+ (instancetype)fromIOService:(io_service_t)service
{
	return [[AppleCIOMeshServiceRef alloc] initWithIOService:service];
}

+ (NSArray<AppleCIOMeshServiceRef *> *)all
{
	auto found = [NSMutableArray<AppleCIOMeshServiceRef *> arrayWithCapacity:1];
	io_iterator_t iter;
	io_object_t obj;

	static const char * services[2] = {MUCI::matchingName, "AppleVirtMeshDriver"};

	bool succ = false;
	for (auto service : services) {
		if (kIOReturnSuccess == IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(service), &iter)) {
			if (IOIteratorIsValid(iter)) {
				succ = true;
				break;
			}
		}
	}

	if (!succ) {
		os_log_error(OS_LOG_DEFAULT, "Failed to match any of services");
		return nil;
	}

	while ((obj = IOIteratorNext(iter)) != IO_OBJECT_NULL) {
		AppleCIOMeshServiceRef * service = [AppleCIOMeshServiceRef fromIOService:obj];
		if ([service open]) {
			[found addObject:service];
		} else {
			fprintf(stderr, "Was able to find the driver but not open it.  Is another AppleCIOMesh client running?\n");
		}
	}

	IOObjectRelease(iter);
	iter = IO_OBJECT_NULL;

	return found;
}

#pragma mark - User client connection

- (BOOL)isOpen
{
	return _connection != IO_OBJECT_NULL;
}

- (BOOL)open
{
	BOOL success;

	if ([self isOpen])
		return YES;

	success = IOServiceOpen(_service, mach_task_self(), MUCI::AppleCIOMeshUserClientType, &_connection) == kIOReturnSuccess;

	Log("opening connection: %s", success ? "ok" : "failed");
	return success;
}

- (void)close
{
	if (![self isOpen])
		return;

	Log("closing connection");

	IOServiceClose(_connection);
	_connection = IO_OBJECT_NULL;
}

#pragma mark - Notifications

- (void)setDispatchQueue:(dispatch_queue_t)queue
{
	if (_queue != nil) {
		[self notifyUnregister];
	}
	_queue = queue;
}

- (BOOL)registeredForNotifications
{
	return _notifyPort != nullptr;
}

- (BOOL)notifyRegister
{
	BOOL success;

	io_async_ref64_t asyncRef = {};

	if ([self registeredForNotifications])
		return YES;

	require(_queue != nullptr, fail);

	_notifyPort = IONotificationPortCreate(kIOMainPortDefault);
	require(_notifyPort != nullptr, failNoPort);

	IONotificationPortSetDispatchQueue(_notifyPort, _queue);

	asyncRef[kIOAsyncCalloutFuncIndex]   = reinterpret_cast<uintptr_t>(&notificationReceived);
	asyncRef[kIOAsyncCalloutRefconIndex] = reinterpret_cast<uintptr_t>((__bridge void *)self);

	require([self open], failNoConnect);

	success = IOConnectCallAsyncMethod(_connection, MUCI::Method::NotificationRegister, IONotificationPortGetMachPort(_notifyPort),
	                                   asyncRef, kIOAsyncCalloutCount, nullptr, 0, nullptr, 0, nullptr, nullptr, nullptr,
	                                   nullptr) == kIOReturnSuccess;
	Log("registering for notifications: %s", success ? "ok" : "failed");
	require(success, failNoConnect);

	return success;

failNoConnect:
	IONotificationPortDestroy(_notifyPort);
	_notifyPort = nullptr;

failNoPort:
fail:
	return NO;
}

- (void)notifyUnregister
{
	if (![self registeredForNotifications])
		return;

	Log("unregistering for notifications");

	if ([self isOpen]) {
		IOConnectCallStructMethod(_connection, MUCI::Method::NotificationUnregister, nullptr, 0, nullptr, nullptr);
	}

	IONotificationPortDestroy(_notifyPort);
	_notifyPort = nullptr;
}

static void
notificationReceived(void * refcon, __unused IOReturn result, io_user_reference_t * arg)
{
	AppleCIOMeshServiceRef * me = (__bridge AppleCIOMeshServiceRef *)refcon;

	[me notificationReceived:arg];
}

- (void)notificationReceived:(io_user_reference_t *)args
{
	MUCI::Notification notification = static_cast<MUCI::Notification>(args[0]);

	//  LogInfo("notification received: %u", notification);

	switch (notification) {
	case MUCI::Notification::IncomingData: {
		MUCI::BufferId bufferId = static_cast<MUCI::BufferId>(args[1]);
		int64_t offset          = static_cast<int64_t>(args[2]);
		int64_t size            = static_cast<int64_t>(args[3]);

		if (_incomingDataChunkBlock != nil) {
			dispatch_async(_queue, ^{ self->_incomingDataChunkBlock(bufferId, size, offset); });
		}
		break;
	}
	case MUCI::Notification::SendDataComplete: {
		MUCI::BufferId bufferId = static_cast<MUCI::BufferId>(args[1]);
		int64_t offset          = static_cast<int64_t>(args[2]);
		int64_t size            = static_cast<int64_t>(args[3]);

		if (_sendCompleteBlock != nil) {
			dispatch_async(_queue, ^{ self->_sendCompleteBlock(bufferId, size, offset); });
		}
		break;
	}
	case MUCI::Notification::MeshSynchronized: {
		if (_meshSyncBlock != nil) {
			dispatch_async(_queue, ^{ self->_meshSyncBlock(); });
		}
		break;
	}
	}
}

- (BOOL)onIncomingDataChunk:(IncomingDataChunkBlock)block
{
	if (_queue == nullptr || ![self notifyRegister]) {
		return NO;
	}

	LogInfo("incoming data chunk block registered");

	_incomingDataChunkBlock = block;
	return YES;
}

- (BOOL)onSendComplete:(SendCompleteBlock)block
{
	if (_queue == nullptr || ![self notifyRegister]) {
		return NO;
	}

	LogInfo("send complete block registered");

	_sendCompleteBlock = block;
	return YES;
}

- (BOOL)onMeshSynchronized:(MeshSynchronizedBlock)block
{
	if (_queue == nullptr || ![self notifyRegister]) {
		return NO;
	}

	LogInfo("mesh sync block registered");

	_meshSyncBlock = block;
	return YES;
}

#pragma mark - API

- (BOOL)synchronizeMesh
{
	require([self open], fail);

	if (IOConnectCallStructMethod(_connection, MUCI::Method::SynchronizeGeneration, nullptr, 0, nullptr, 0) != kIOReturnSuccess) {
		LogError("could not begin mesh synchronization");
		goto fail;
	}

	return YES;

fail:
	return NO;
}

- (BOOL)allocateSharedMemory:(uint64_t)bufferId
                   atAddress:(mach_vm_address_t)bufferAddress
                      ofSize:(uint64_t)bufferSize
               withChunkSize:(uint64_t)chunkSize
              withStrideSkip:(uint64_t)strideSkip
             withStrideWidth:(uint64_t)strideWidth
        withCommandBreakdown:(int64_t *)breakdown
{
	MUCI::SharedMemory sm;
	sm.bufferId    = bufferId;
	sm.address     = bufferAddress;
	sm.size        = bufferSize;
	sm.chunkSize   = chunkSize;
	sm.strideSkip  = strideSkip;
	sm.strideWidth = strideWidth;
	for (int i = 0; i < kMaxTBTCommandCount; i++) {
		sm.forwardBreakdown[i] = breakdown[i];
	}

	require([self open], fail);

	if (IOConnectCallStructMethod(_connection, MUCI::Method::AllocateSharedMemory, &sm, sizeof(sm), nullptr, 0) !=
	    kIOReturnSuccess) {
		LogError("could not allocate shared memory");
		goto fail;
	}

	return YES;

fail:
	return NO;
}

- (BOOL)deallocateSharedMemory:(uint64_t)bufferId ofSize:(uint64_t)bufferSize
{
	MUCI::SharedMemoryRef sm;
	sm.bufferId = bufferId;
	sm.size     = bufferSize;

	require([self open], fail);

	if (IOConnectCallStructMethod(_connection, MUCI::Method::DeallocateSharedMemory, &sm, sizeof(sm), nullptr, 0) !=
	    kIOReturnSuccess) {
		LogError("could not deallocate shared memory id %lld", bufferId);
		goto fail;
	}

	return YES;

fail:
	return NO;
}

- (BOOL)assignSharedMemory:(uint64_t)bufferId
                  atOffset:(uint64_t)offset
                    ofSize:(uint64_t)size
     toIncomingMeshChannel:(uint64_t)channel
            withAccessMode:(uint8_t)mode
                  fromNode:(uint32_t)node
{
	MUCI::AssignChunks assignment;
	assignment.bufferId        = bufferId;
	assignment.offset          = offset;
	assignment.size            = size;
	assignment.direction       = MUCI::MeshDirection::In;
	assignment.meshChannelMask = 0x1 << channel;
	assignment.accessMode      = (MUCI::AccessMode)mode;
	assignment.sourceNode      = node;

	require([self open], fail);

	if (IOConnectCallStructMethod(_connection, MUCI::Method::AssignSharedMemoryChunk, &assignment, sizeof(assignment), nullptr,
	                              0) != kIOReturnSuccess) {
		LogError("could not assign incoming data chunk");
		goto fail;
	}

	return YES;

fail:
	return NO;
}

- (BOOL)assignSharedMemory:(uint64_t)bufferId
                  atOffset:(uint64_t)offset
                    ofSize:(uint64_t)size
    toOutgoingMeshChannels:(uint64_t)channelMask
            withAccessMode:(uint8_t)mode
                  fromNode:(uint32_t)node
{
	MUCI::AssignChunks assignment;
	assignment.bufferId        = bufferId;
	assignment.offset          = offset;
	assignment.size            = size;
	assignment.direction       = MUCI::MeshDirection::Out;
	assignment.meshChannelMask = channelMask;
	assignment.accessMode      = (MUCI::AccessMode)mode;
	assignment.sourceNode      = node;

	require([self open], fail);

	if (IOConnectCallStructMethod(_connection, MUCI::Method::AssignSharedMemoryChunk, &assignment, sizeof(assignment), nullptr,
	                              0) != kIOReturnSuccess) {
		LogError("could not assign outgoing data chunk");
		goto fail;
	}

	return YES;

fail:
	return NO;
}

- (BOOL)setupForwardChainWithId:(uint8_t *)chainId
                           from:(uint64_t)startBufferId
                             to:(uint64_t)endBufferId
                    startOffset:(uint64_t)startOffset
                      endOffset:(uint64_t)endOffset
              withSectionOffset:(uint64_t)sectionOffset
                   sectionCount:(uint64_t)sectionCount
{
	size_t outSize = sizeof(MUCI::ForwardChainId);
	MUCI::ForwardChain chain;
	chain.startBufferId = startBufferId;
	chain.endBufferId   = endBufferId;
	chain.startOffset   = startOffset;
	chain.endOffset     = endOffset;
	chain.sectionOffset = sectionOffset;
	chain.sectionCount  = sectionCount;

	require([self open], fail);

	if (IOConnectCallStructMethod(_connection, MUCI::Method::SetupForwardChainBuffers, &chain, sizeof(chain), chainId, &outSize) !=
	    kIOReturnSuccess) {
		LogError("could not set forward chain");
		goto fail;
	}

	return YES;

fail:
	return NO;
}

- (BOOL)startForwardChain:(uint8_t)chainId forIteration:(uint32_t)iterations
{
	kern_return_t ret;
	require([self open], fail);

	ret = IOConnectTrap2(_connection, MUCI::Trap::StartForwardChain, (uintptr_t)chainId, (uintptr_t)iterations);

	if (ret != KERN_SUCCESS) {
		LogError("failed to call StartForwardChain trap %u\n", ret);
		return NO;
	}

	return YES;

fail:
	return NO;
}

- (BOOL)setMaxWaitTime:(uint64_t)maxWaitNanos
{
	kern_return_t ret;
	require([self open], fail);

	MUCI::SetMaxWaitTime smt;

	smt.maxWaitTime = maxWaitNanos;

	ret = IOConnectCallStructMethod(_connection, MUCI::Method::SetMaxWaitTime, &smt, sizeof(smt), nullptr, 0);
	if (ret != KERN_SUCCESS) {
		LogError("failed to call SetMaxWaitTime %u\n", ret);
		return NO;
	}

	return YES;

fail:
	return NO;
}

- (BOOL)stopForwardChain
{
	kern_return_t ret;
	require([self open], fail);

	ret = IOConnectTrap0(_connection, MUCI::Trap::StopForwardChain);

	if (ret != KERN_SUCCESS) {
		LogError("failed to call StopForwardChain trap %u\n", ret);
		return NO;
	}

	return YES;

fail:
	return NO;
}

- (BOOL)overrideRuntimePrepareFor:(uint64_t)bufferId
{
	MUCI::BufferId bufferId_ = (MUCI::BufferId)bufferId;
	kern_return_t ret;
	require([self open], fail);

	ret = IOConnectCallStructMethod(_connection, MUCI::Method::OverrideRuntimePrepare, &bufferId, sizeof(bufferId), nullptr, 0);

	if (ret != KERN_SUCCESS) {
		LogError("failed to call OverrideRuntimePrepare method %u\n", ret);
		return NO;
	}

	return YES;

fail:
	return NO;
}

- (BOOL)prepareDataChunkTransferFor:(uint64_t)bufferId atOffset:(uint64_t)offset
{
	MUCI::BufferId bufferId_ = (MUCI::BufferId)bufferId;
	int64_t offset_          = offset;
	kern_return_t ret;
	require([self open], fail);

	ret = IOConnectTrap2(_connection, MUCI::Trap::PrepareChunk, (uintptr_t)bufferId_, (uintptr_t)offset_);

	if (ret != KERN_SUCCESS) {
		LogError("failed to call PrepareChunk trap %u\n", ret);
		return NO;
	}

	return YES;

fail:
	return NO;
}

- (BOOL)prepareAllIncomingTransferFor:(uint64_t)bufferId
{
	MUCI::BufferId bufferId_ = (MUCI::BufferId)bufferId;
	kern_return_t ret;
	require([self open], fail);

	ret = IOConnectTrap2(_connection, MUCI::Trap::PrepareAllChunks, (uintptr_t)bufferId_, (uintptr_t)MUCI::MeshDirection::In);

	if (ret != KERN_SUCCESS) {
		LogError("failed to call PrepareAllChunks(In) trap %u\n", ret);
		return NO;
	}

	return YES;

fail:
	return NO;
}

- (BOOL)prepareAllOutgoingTransferFor:(uint64_t)bufferId
{
	MUCI::BufferId bufferId_ = (MUCI::BufferId)bufferId;
	kern_return_t ret;
	require([self open], fail);

	ret = IOConnectTrap2(_connection, MUCI::Trap::PrepareAllChunks, (uintptr_t)bufferId_, (uintptr_t)MUCI::MeshDirection::Out);

	if (ret != KERN_SUCCESS) {
		LogError("failed to call PrepareAllChunks(Out) trap %u\n", ret);
		return NO;
	}

	return YES;

fail:
	return NO;
}

- (BOOL)waitOnSharedMemory:(uint64_t)bufferId atOffset:(uint64_t)offset withTag:(char *)tag
{
	MUCI::BufferId bufferId_ = (MUCI::BufferId)bufferId;
	int64_t offset_          = offset;
	kern_return_t ret;
	require([self open], fail);

	ret = IOConnectTrap3(_connection, MUCI::Trap::WaitSharedMemoryChunk, (uintptr_t)bufferId_, (uintptr_t)offset_, (uintptr_t)tag);

	if (ret != KERN_SUCCESS) {
		LogError("failed to call WaitSharedMemoryChunk trap %u\n", ret);
		return NO;
	}

	return YES;

fail:
	return NO;
}

- (BOOL)waitOnAllIncomingChunksOf:(uint64_t)bufferId
{
	MUCI::BufferId bufferId_ = bufferId;
	kern_return_t ret;
	require([self open], fail);

	ret = IOConnectTrap1(_connection, MUCI::Trap::ReceiveAll, (uintptr_t)bufferId_);

	if (ret != KERN_SUCCESS) {
		LogError("failed to call ReceiveAll trap %u\n", ret);
		return NO;
	}

	return YES;

fail:
	return NO;
}

- (BOOL)waitOnNextIncomingChunkOf:(uint64_t)bufferId withOffset:(uint64_t *)receivedOffset withTag:(char *)tag
{
	MUCI::BufferId bufferId_ = bufferId;
	int ret;
	require([self open], fail);

	ret = IOConnectTrap3(_connection, MUCI::Trap::ReceiveNext, (uintptr_t)bufferId_, (uintptr_t)receivedOffset, (uintptr_t)tag);

	if (ret != KERN_SUCCESS) {
		LogError("failed to call ReceiveNext trap %u\n", ret);
		return NO;
	}

	return YES;

fail:
	return NO;
}

- (BOOL)waitOnNextBatchIncomingChunkOf:(uint64_t)bufferId
                         withBatchSize:(uint64_t)batch
                           withTimeout:(uint64_t)timeoutMicroseconds
                     withReceivedCount:(uint64_t *)receivedCount
                   withReceivedOffsets:(uint64_t *)receivedOffsets
                      withReceivedTags:(char *)receivedTags
{
	MUCI::BufferId bufferId_ = bufferId;
	int ret;
	require([self open], fail);

	ret = IOConnectTrap6(_connection, MUCI::Trap::ReceiveBatch, (uintptr_t)bufferId_, (uintptr_t)batch,
	                     (uintptr_t)timeoutMicroseconds, (uintptr_t)receivedCount, (uintptr_t)receivedOffsets,
	                     (uintptr_t)receivedTags);

	if (ret != KERN_SUCCESS) {
		LogError("failed to call ReceiveBatch trap %u for bufferId %lld\n", ret, bufferId);
		return NO;
	}

	return YES;

fail:
	return NO;
}

- (BOOL)waitOnNextBatchIncomingChunkOf:(uint64_t)bufferId
                              fromNode:(uint32_t)nodeId
                         withBatchSize:(uint64_t)batch
                     withReceivedCount:(uint64_t *)receivedCount
                   withReceivedOffsets:(uint64_t *)receivedOffsets
                      withReceivedTags:(char *)receivedTags
{
	MUCI::BufferId bufferId_ = bufferId;
	int ret;
	require([self open], fail);

	ret = IOConnectTrap6(_connection, MUCI::Trap::ReceiveBatchForNode, (uintptr_t)bufferId_, (uintptr_t)nodeId, (uintptr_t)batch,
	                     (uintptr_t)receivedCount, (uintptr_t)receivedOffsets, (uintptr_t)receivedTags);

	if (ret != KERN_SUCCESS) {
		LogError("failed to call ReceiveBatchForNode trap %u for bufferId %lld fromNode %d\n", ret, bufferId, nodeId);
		return NO;
	}

	return YES;

fail:
	return NO;
}

- (BOOL)sendAssignedDataChunkFrom:(uint64_t)bufferId atOffset:(uint64_t)offset withTags:(char *)tags
{
	MUCI::BufferId bufferId_ = (MUCI::BufferId)bufferId;
	int64_t offset_          = offset;
	kern_return_t ret;

	require([self open], fail);

	ret = IOConnectTrap3(_connection, MUCI::Trap::SendAssignedData, (uintptr_t)bufferId_, (uintptr_t)offset_, (uintptr_t)tags);

	if (ret != KERN_SUCCESS) {
		LogError("failed to call SendAssignedData trap %u\n", ret);
		return NO;
	}

	return YES;

fail:
	return NO;
}

- (BOOL)sendAllAssignedDataFrom:(uint64_t)bufferId withTags:(char *)tags
{
	MUCI::BufferId bufferId_ = (MUCI::BufferId)bufferId;
	kern_return_t ret;
	require([self open], fail);

	ret = IOConnectTrap2(_connection, MUCI::Trap::SendAllAssignedChunks, (uintptr_t)bufferId_, (uintptr_t)tags);

	if (ret != KERN_SUCCESS) {
		LogError("failed to call SendAllAssignedChunks trap %u\n", ret);
		return NO;
	}

	return YES;

fail:
	return NO;
}

- (BOOL)sendAssignedDataChunkFrom:(uint64_t)sendBufferId
                           atOffset:(uint64_t)sendOffset
                           withTags:(char *)tags
    andPrepareAssignedDataChunkFrom:(uint64_t)prepareBufferId
                           atOffset:(uint64_t)prepareOffset
{
	MUCI::BufferId sendBufferId_    = (MUCI::BufferId)sendBufferId;
	int64_t sendOffset_             = sendOffset;
	MUCI::BufferId prepareBufferId_ = (MUCI::BufferId)prepareBufferId;
	int64_t prepareOffset_          = prepareOffset;

	kern_return_t ret;
	require([self open], fail);

	ret = IOConnectTrap5(_connection, MUCI::Trap::SendAndPrepareChunk, (uintptr_t)sendBufferId_, (uintptr_t)sendOffset_,
	                     (uintptr_t)prepareBufferId_, (uintptr_t)prepareOffset_, (uintptr_t)tags);

	if (ret != KERN_SUCCESS) {
		LogError("failed to call SendAndPrepareChunk trap %u\n", ret);
		return NO;
	}

	return YES;

fail:
	return NO;
}

- (BOOL)interruptWaitingThreads:(uint64_t)bufferId
{
	kern_return_t ret;
	require([self open], fail);

	ret = IOConnectTrap1(_connection, MUCI::Trap::InterruptWaitingThreads, (uintptr_t)bufferId);

	if (ret != KERN_SUCCESS) {
		LogError("failed to call interruptWaitingThreads trap %u\n", ret);
		return NO;
	}

	return YES;
fail:
	return NO;
}

- (BOOL)clearInterruptState:(uint64_t)bufferId
{
	kern_return_t ret;
	require([self open], fail);

	ret = IOConnectTrap1(_connection, MUCI::Trap::ClearInterruptState, (uintptr_t)bufferId);

	if (ret != KERN_SUCCESS) {
		LogError("failed to call ClearInterruptState trap %u\n", ret);
		return NO;
	}

	return YES;

fail:
	return NO;
}

- (BOOL)interruptPendingReceiveBatch
{
	kern_return_t ret;
	require([self open], fail);

	ret = IOConnectTrap0(_connection, MUCI::Trap::InterruptReceiveBatch);

	if (ret != KERN_SUCCESS) {
		LogError("failed to call InterruptReceiveBatch trap %u\n", ret);
		return NO;
	}

	return YES;

fail:
	return NO;
}

- (BOOL)printAssignmentStateFor:(uint64_t)bufferId
{
	require([self open], fail);

	if (IOConnectCallStructMethod(_connection, MUCI::Method::PrintBufferState, &bufferId, sizeof(bufferId), nullptr, 0) !=
	    kIOReturnSuccess) {
		LogError("could not print buffer state");
		goto fail;
	}

	return YES;

fail:
	return NO;
}

- (BOOL)resetBuffer:(uint64_t)bufferId
{
    kern_return_t ret;
    require([self open], fail);

    ret = IOConnectTrap1(_connection, MUCI::Trap::ResetBuffer, (uintptr_t)bufferId);

    if (ret != KERN_SUCCESS) {
        LogError("failed to call ResetBuffer trap %u\n", ret);
        return NO;
    }

    return YES;

fail:
    return NO;
}

@end
