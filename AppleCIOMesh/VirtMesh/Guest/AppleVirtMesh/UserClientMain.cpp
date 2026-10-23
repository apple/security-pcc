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

//
//  UserClientMain.cpp
//  AppleVirtMesh
//
//  Created by Zixuan Wang on 11/19/24.
//

#include "VirtMesh/Guest/AppleVirtMesh/UserClientMain.h"
#include "VirtMesh/Guest/AppleVirtMesh/Common.h"
#include "VirtMesh/Guest/AppleVirtMesh/Driver.h"
#include "VirtMesh/Guest/AppleVirtMesh/Interfaces.h"

using namespace VirtMesh::Guest::Mesh;
using namespace VirtMesh::Guest::Mesh::MainClient;

OSDefineMetaClassAndStructors(AppleVirtMeshMainUserClient, super);

#define DEFINE_METHOD(selector, method, input_size, output_size, allow_async)                                  \
	[MainClient::Methods::selector] = {                                                                        \
	    .function                 = static_cast<IOExternalMethodAction>(&AppleVirtMeshMainUserClient::method), \
	    .checkScalarInputCount    = 0,                                                                         \
	    .checkStructureInputSize  = input_size,                                                                \
	    .checkScalarOutputCount   = 0,                                                                         \
	    .checkStructureOutputSize = output_size,                                                               \
	    .allowAsync               = allow_async,                                                               \
	    .checkEntitlement         = nullptr,                                                                   \
	}

#define DEFINE_TRAP(selector, trap)                                             \
	[MainClient::Traps::selector] = {                                           \
	    .object = nullptr,                                                      \
	    .func   = reinterpret_cast<IOTrap>(&AppleVirtMeshMainUserClient::trap), \
	}

/* clang-format off */
const IOExternalMethodDispatch2022 AppleVirtMeshMainUserClient::sExternalMethodDispatchTable[MainClient::Methods::TotalMethods] = {
	DEFINE_METHOD(NotificationRegister    , notification_register       , 0                          , 0                      , true ),
	DEFINE_METHOD(NotificationUnregister  , notification_unregister     , 0                          , 0                      , false),
	DEFINE_METHOD(AllocateSharedMemory    , allocate_shared_memory      , sizeof(SharedMemoryConfig) , 0                      , false),
	DEFINE_METHOD(DeallocateSharedMemory  , deallocate_shared_memory    , sizeof(SharedMemoryRef)    , 0                      , false),
	DEFINE_METHOD(AssignSharedMemoryChunk , assign_shared_memory_chunk  , sizeof(AssignChunks)       , 0                      , false),
	DEFINE_METHOD(PrintBufferState        , print_buffer_state          , sizeof(BufferId)           , 0                      , false),
	DEFINE_METHOD(SetupForwardChainBuffers, setup_forward_chain_buffers , sizeof(ForwardChain)       , sizeof(ForwardChainId) , false),
	DEFINE_METHOD(SetMaxWaitTime          , set_max_wait_time           , sizeof(MaxWaitTime)        , 0                      , false),
	DEFINE_METHOD(SetMaxWaitPerNodeBatch  , set_max_wait_per_node_batch , sizeof(MaxWaitTime)        , 0                      , false),
	DEFINE_METHOD(SynchronizeGeneration   , synchronize_generation      , 0                          , 0                      , false),
	DEFINE_METHOD(OverrideRuntimePrepare  , override_runtime_prepare    , sizeof(BufferId)           , 0                      , false),
};

const IOExternalTrap AppleVirtMeshMainUserClient::sExternalTrapDispatchTable[MainClient::Traps::TotalTraps] = {
	DEFINE_TRAP(WaitSharedMemoryChunk       , wait_shared_memory_chunk      ),
	DEFINE_TRAP(SendAssignedData            , send_assigned_data            ), /* Note: Named as `trapSendChunk()` in CIOMesh Kext */
	DEFINE_TRAP(PrepareChunk                , prepare_chunk                 ),
	DEFINE_TRAP(PrepareAllChunks            , prepare_all_chunks            ),
	DEFINE_TRAP(SendAndPrepareChunk         , send_and_prepare_chunk        ),
	DEFINE_TRAP(SendAllAssignedChunks       , send_all_assigned_chunks      ), /* Note: Named as `trapSendAllChunks()` in CIOMesh Kext*/
	DEFINE_TRAP(ReceiveAll                  , receive_all                   ),
	DEFINE_TRAP(ReceiveNext                 , receive_next                  ),
	DEFINE_TRAP(ReceiveBatch                , receive_batch                 ),
	DEFINE_TRAP(ReceiveBatchForNode         , receive_batch_for_node        ),
	DEFINE_TRAP(InterruptWaitingThreads     , interrupt_waiting_threads     ),
	DEFINE_TRAP(ClearInterruptState         , clear_interrupt_state         ),
	DEFINE_TRAP(InterruptReceiveBatch       , interrupt_receive_batch       ),
	DEFINE_TRAP(StartForwardChain           , start_forward_chain           ),
	DEFINE_TRAP(StopForwardChain            , stop_forward_chain            ),
};
/* clang-format on */

static inline AppleVirtMeshMainUserClient *
cast_to_client(OSObject * target)
{
	return OSRequiredCast(AppleVirtMeshMainUserClient, target);
}

template <typename Func>
concept ClientHandler = requires(Func f, AppleVirtMeshMainUserClient * client, AppleVirtMeshDriver * driver) {
	{ f(client, driver) };
};

template <ClientHandler Func>
[[nodiscard]] static inline IOReturn
with_client(OSObject * target, Func func)
{
	auto client = cast_to_client(target);

	return func(client, client->_driver);
}

bool
AppleVirtMeshMainUserClient::start(IOService * provider)
{
	construct_logger();

	if (!super::start(provider)) {
		os_log_error(_logger, "Super user client class failed to start");
		return false;
	}

	if (!_driver->register_main_user_client(this)) {
		os_log_error(_logger, "Failed to register this main user client in the driver");
		return false;
	}

	return true;
}

void
AppleVirtMeshMainUserClient::stop(IOService * provider)
{
	_driver->unregister_main_user_client(this);
	super::stop(provider);
}

void
AppleVirtMeshMainUserClient::notify_mesh_synchronized()
{
	io_user_reference_t arg[4];
	arg[0] = static_cast<io_user_reference_t>(MainClient::Notification::MeshSynchronized);
	notify_send(arg, 4);
}

IOReturn
AppleVirtMeshMainUserClient::externalMethod(uint32_t selector, IOExternalMethodArgumentsOpaque * args)
{
	auto arg = (IOExternalMethodArguments *)args;
	DEV_LOG(
	    _logger,
	    "Main client externalMethod: selector [%u] StructureInputSize [%u], StructureOutputSize = [%u]",
	    selector,
	    arg->structureInputSize,
	    arg->structureOutputSize
	);
	return dispatchExternalMethod(selector, args, sExternalMethodDispatchTable, MainClient::Methods::TotalMethods, this, nullptr);
}

/* Mark: - External Methods */

/**
 * @brief The user space program call this method to register a notification callback.
 *
 * @note The main framework registers a IONotificationPort with this method, and connects the port to the framework's dispatch
 * queue. So any notification from this kext through the notification port will get into framework's dispatch queue.
 *
 * @param args its syncReference is saved by the current kext, for future notification.
 */
IOReturn
AppleVirtMeshMainUserClient::notification_register(OSObject * target, [[maybe_unused]] void * ref, IOExternalMethodArguments * args)
{
	auto client = cast_to_client(target);

	if (MACH_PORT_NULL == args->asyncWakePort) {
		os_log_error(_logger, "Got an invalid wake port: 0x%llx", (uint64_t)args->asyncWakePort);
		return kIOReturnBadArgument;
	}

	{
		IOLockGuard guard(client->_notify.lock);

		if (client->_notify.ref_valid) {
			/* Zixuan's understanding: This is to de-register pre-existing notify reference, if any. Although I don't think it would
			 * be the case, probably the original CIOMesh kext ran into some issue and implemented this.
			 */
			releaseAsyncReference64(client->_notify.ref);
		}
		memcpy(client->_notify.ref, args->asyncReference, sizeof(client->_notify.ref));
		client->_notify.ref_valid = true;
	}

	return kIOReturnSuccess;
}

/**
 * @brief De-register the notification callback reference.
 */
IOReturn
AppleVirtMeshMainUserClient::notification_unregister(
    OSObject *                                   target,
    [[maybe_unused]] void *                      ref,
    [[maybe_unused]] IOExternalMethodArguments * args
)
{
	auto client = cast_to_client(target);

	{
		IOLockGuard guard(client->_notify.lock);

		if (!client->_notify.ref_valid) {
			os_log_error(_logger, "Notification ref is invalid.");
			return kIOReturnBadArgument;
		}

		releaseAsyncReference64(client->_notify.ref);
		client->_notify.ref_valid = false;
	}

	return kIOReturnSuccess;
}

/**
 * @brief Allocate shared memory
 *
 * @note CIOMesh kext checks if the driver is shutting down, I think no need to do it in VRE.
 */
IOReturn
AppleVirtMeshMainUserClient::allocate_shared_memory(
    OSObject *                  target,
    [[maybe_unused]] void *     ref,
    IOExternalMethodArguments * args
)
{
	return with_client(target, [&](auto client, auto driver) {
		auto config = UserClient::EMAInputExtractor<SharedMemoryConfig>(args);
		return driver->allocate_shared_memory(config.get(), client->_owning_task, client);
	});
}

/**
 * @brief Deallocate shared memory
 *
 * @note CIOMesh kext sets the `_receivePrepareTime`, I think no need to do it in VRE.
 */
IOReturn
AppleVirtMeshMainUserClient::deallocate_shared_memory(
    OSObject *                  target,
    [[maybe_unused]] void *     ref,
    IOExternalMethodArguments * args
)
{
	return with_client(target, [&](auto, auto driver) {
		auto ref = UserClient::EMAInputExtractor<SharedMemoryRef>(args);
		return driver->deallocate_shared_memory(ref.get());
	});
}

/**
 * @brief Assign chunk to shared memory
 *
 * @note CIOMesh kext checks if the driver is shutting down, I think no need to do it in VRE.
 */
IOReturn
AppleVirtMeshMainUserClient::assign_shared_memory_chunk(
    OSObject *                  target,
    [[maybe_unused]] void *     ref,
    IOExternalMethodArguments * args
)
{
	return with_client(target, [&](auto, auto driver) {
		auto assignment = UserClient::EMAInputExtractor<AssignChunks>(args);
		return driver->assign_shared_memory_chunk(assignment.get());
	});
}

/**
 * @brief Set the max wait time, in case the input time is 0, set the wait time to be infinite (100 years).
 */
IOReturn
AppleVirtMeshMainUserClient::set_max_wait_time(OSObject * target, [[maybe_unused]] void * ref, IOExternalMethodArguments * args)
{
	return with_client(target, [&](auto client, auto driver) {
		auto time    = UserClient::EMAInputExtractor<MaxWaitTime>(args);
		auto time_ns = time->maxWaitTime;

		if (0 == time_ns) {
			time_ns = kNsPerSecond * 86400 * 356 * 100;
		}

		DEV_LOG(_logger, "Setting the max wait time to: %lld\n", time_ns);

		nanoseconds_to_absolutetime(time_ns, &client->_max_wait_time);
		nanoseconds_to_absolutetime(time_ns, &client->_max_wait_time_per_node);
		return driver->set_max_wait_time(&client->_max_wait_time);
	});
}

/**
 * @brief Set the max wait time, in case the input time is 0, set the wait time to be infinite (100 years).
 */
IOReturn
AppleVirtMeshMainUserClient::set_max_wait_per_node_batch(
    OSObject *                  target,
    [[maybe_unused]] void *     ref,
    IOExternalMethodArguments * args
)
{
	return with_client(target, [&](auto client, auto) {
		auto time    = UserClient::EMAInputExtractor<MaxWaitTime>(args);
		auto time_ns = time->maxWaitTime;

		if (0 == time_ns) {
			time_ns = kNsPerSecond * 86400 * 356 * 100;
		}

		DEV_LOG(_logger, "Setting the max wait time per node to: %lld\n", time_ns);

		nanoseconds_to_absolutetime(time_ns, &client->_max_wait_time_per_node);
		return kIOReturnSuccess;
	});
}

IOReturn
AppleVirtMeshMainUserClient::synchronize_generation(
    OSObject *                                   target,
    [[maybe_unused]] void *                      ref,
    [[maybe_unused]] IOExternalMethodArguments * args
)
{
	return with_client(target, [&](auto, auto driver) { return driver->start_new_generation(); });
}

IOReturn
AppleVirtMeshMainUserClient::override_runtime_prepare(
    OSObject *                                   target,
    [[maybe_unused]] void *                      ref,
    [[maybe_unused]] IOExternalMethodArguments * args
)
{
	return with_client(target, [&](auto client, auto driver) {
		os_log_info(_logger, "OverrideRuntimePrepare is not implemented in VRE, it always return success");
		return kIOReturnSuccess;
	});
}

/* MARK: - Trap methods */

IOExternalTrap *
AppleVirtMeshMainUserClient::getTargetAndTrapForIndex(IOService ** target_ptr, uint32_t trap_index)
{
	DEV_LOG(_logger, "Main client Trap: selector [%u]", trap_index);

	if (trap_index > Traps::TotalTraps) {
		os_log_error(_logger, "Trap index [%u] out of range [%u]", trap_index, Traps::TotalTraps);
		return nullptr;
	}

	*target_ptr = this;

	/* FIXME: The trap table is defined as `const` but here casting away the `const` qualifier. This code is adapted from CIOMesh
	 * kext, maybe we should re-consider this casting?
	 */
	return (IOExternalTrap *)(&sExternalTrapDispatchTable[trap_index]);
}

IOReturn
AppleVirtMeshMainUserClient::prepare_chunk([[maybe_unused]] uintptr_t buffer_id, [[maybe_unused]] uintptr_t offset)
{
	return kIOReturnSuccess;
}

IOReturn
AppleVirtMeshMainUserClient::prepare_all_chunks([[maybe_unused]] uintptr_t buffer_id, [[maybe_unused]] uintptr_t direction)
{
	return kIOReturnSuccess;
}

IOReturn
AppleVirtMeshMainUserClient::send_assigned_data(uintptr_t buffer_id_arg, uintptr_t offset_arg, uintptr_t tag_all_arg)
{
	/**
	 * @note CIOMesh kext "prepares" the shared memory buffer, which seems to be some set up for CIO-specific protocol, we don't
	 * need that.
	 *
	 * @todo CIOMesh kext checks if it has been interrupted by user (e.g., Ctrl-C), not sure if it's useful in VRE so leaving it
	 * note implemented for now.
	 */

	auto buffer_id = static_cast<BufferId>(buffer_id_arg);
	auto offset    = static_cast<uint64_t>(offset_arg);

	uint8_t tag_all[kVREMeshLinksPerChannel][kTagSize];
	if (auto res = copyin(tag_all_arg, &(tag_all[0][0]), kTagSize * kVREMeshLinksPerChannel); 0 != res) {
		os_log_error(_logger, "Send assigned data failed to copy in tags from uaddr [0x%016lx], error [%x]", tag_all_arg, res);
		return kIOReturnInternalError;
	}

	CryptoTag curr_tag;
	memcpy(&curr_tag, &(tag_all[0][0]), kTagSize);

	DEV_LOG(
	    _logger,
	    "Send assigned data for buffer id [%llu] at offset [%llu] with crypto tag [0x%016llx]-[0x%016llx]",
	    buffer_id,
	    offset,
	    curr_tag.value[0],
	    curr_tag.value[1]
	);

	return _driver->send_assigned_data(buffer_id, offset, curr_tag);
}

IOReturn
AppleVirtMeshMainUserClient::send_all_assigned_chunks(uintptr_t buffer_id_arg, uintptr_t tag_all_arg)
{
	auto buffer_id = static_cast<BufferId>(buffer_id_arg);

	CryptoTag curr_tag;
	if (auto res = copyin(tag_all_arg, &(curr_tag), kTagSize); 0 != res) {
		os_log_error(_logger, "Send all assigned chunks failed to copy in tags, error [%x]", res);
		return kIOReturnInternalError;
	}

	DEV_LOG(_logger, "Send all assigned data chunks with crypto tag [0x%016llx]-[0x%016llx]", curr_tag.value[0], curr_tag.value[1]);

	return _driver->send_all_assigned_data(buffer_id, curr_tag);
}

IOReturn
AppleVirtMeshMainUserClient::wait_shared_memory_chunk(uintptr_t buffer_id_arg, uintptr_t offset_arg, uintptr_t tag_out_arg)
{
	auto buffer_id = static_cast<BufferId>(buffer_id_arg);
	auto offset    = static_cast<uint64_t>(offset_arg);

	/* FIXME: I think the tag needs to be sent/received for upper layer logics. */

	CryptoTag tag;

	if (auto res = _driver->recv_assigned_data(buffer_id, offset, tag); kIOReturnSuccess != res) {
		os_log_error(_logger, "Failed to receive assigned data");
		return res;
	}

	DEV_LOG(
	    _logger,
	    "Received assigned data for buffer id [%llu] at offset [%llu] with tag [0x%016llx]-[0x%016llx]",
	    buffer_id,
	    offset,
	    tag.value[0],
	    tag.value[1]
	);

	if (auto res = copyout(&tag, tag_out_arg, kTagSize); 0 != res) {
		os_log_error(_logger, "Failed to copy out tag: error [%x]", res);
		return kIOReturnInternalError;
	}

	return kIOReturnSuccess;
}

IOReturn
AppleVirtMeshMainUserClient::receive_batch_for_node(
    uintptr_t buffer_id_arg,
    uintptr_t node_id_arg,
    uintptr_t count_batch_arg,
    uintptr_t count_received_out_arg,
    uintptr_t offset_received_out_arg,
    uintptr_t tag_received_out_arg
)
{
	/* Call path:
	 * tmesh/llmsim
	 * -> MeshCreate()
	 * ->  StartReaders_Private()
	 * -> rypto_thread_assigned_receive()
	 * -> waitOnNextBatchIncomingChunkOf()
	 * -> kext interface
	 */

	auto buffer_id   = static_cast<BufferId>(buffer_id_arg);
	auto node_id     = static_cast<uint8_t>(node_id_arg); /* TODO: should check the value before converting */
	auto count_batch = static_cast<uint64_t>(count_batch_arg);

	auto offset_received = AutoMalloc<uint64_t>(count_batch, UINT64_MAX);
	auto offset_arr      = offset_received.get();

	auto tags_received = AutoMalloc<CryptoTag>(count_batch, {UINT64_MAX, UINT64_MAX});
	auto tags_arr      = tags_received.get();
	if (auto res = _driver->recv_all_assigned_data(buffer_id, count_batch, offset_arr, tags_arr); kIOReturnSuccess != res) {
		os_log_error(_logger, "Failed to receive batch data for buffer [%llu]", buffer_id);
		return res;
	}

	/* Copy out user output */
	if (auto copy_res = copyout(&count_batch, count_received_out_arg, sizeof(uint64_t)); 0 != copy_res) {
		os_log_error(_logger, "Failed to copy out received batch count: error [%x]", copy_res);
		return kIOReturnInternalError;
	}

	auto offset_out_arr      = reinterpret_cast<uint64_t *>(offset_received_out_arg);
	auto tags_out_arr        = reinterpret_cast<CryptoTag *>(tag_received_out_arg);
	bool all_chunks_received = true;

	DEV_LOG(_logger, "AppleVirtMeshMainUserClient::receive_batch_for_node() offset received count [%u]", offset_received.count());
	for (uint64_t i = 0; i < offset_received.count(); i++) {
		/* This check might be outdated, the offset_received should be filled from beginning, no matter the buffer_id or offset,
		 * it's an array instead of a hash map. CIOMesh framework's crypto_thread_assigned_receive() takes care of this by using
		 * receivedOffsets[currentiIdx+i] to further compute the buffer chunk id.
		 */
		if (UINT64_MAX == offset_arr[i]) {
			DEV_LOG(_logger, "Offset id [%llu] not received", i);
			if (i != static_cast<uint64_t>(node_id)) {
				all_chunks_received = false;
			}
			continue;
		}

		if (auto copy_res = copyout(&(offset_arr[i]), reinterpret_cast<uintptr_t>(&(offset_out_arr[i])), sizeof(uint64_t));
		    0 != copy_res) {
			os_log_error(_logger, "Failed to copy out received batch count: error [%x]", copy_res);
			return kIOReturnInternalError;
		}

		if (auto copy_res = copyout(&(tags_arr[i]), reinterpret_cast<uintptr_t>(&(tags_out_arr[i])), sizeof(CryptoTag));
		    0 != copy_res) {
			os_log_error(_logger, "Failed to copy out received tag: error [%x]", copy_res);
			return kIOReturnInternalError;
		}

		DEV_LOG(
		    _logger,
		    "Received chunk for node id [%u] at offset id [%llu] with offset [%llu] and crypto tag [0x%016llx]-[0x%016llx]",
		    node_id,
		    i,
		    offset_arr[i],
		    tags_arr[i].value[0],
		    tags_arr[i].value[1]
		);
	}

	if (!all_chunks_received) {
		DEV_LOG(
		    _logger,
		    "Not all chunks have been received for buffer [%llu], maybe some of the batch is overwriting the same chunk.",
		    buffer_id
		);
	}

	return kIOReturnSuccess;
}

IOReturn
AppleVirtMeshMainUserClient::send_and_prepare_chunk(
    uintptr_t buffer_id_send,
    uintptr_t offset_send,
    uintptr_t buffer_id_prep,
    uintptr_t offset_prep,
    uintptr_t tag_all
)
{
	if (auto res = send_assigned_data(buffer_id_send, offset_send, tag_all); kIOReturnSuccess != res) {
		os_log_error(_logger, "Failed to send-and-prepare chunk: send failed: 0x%x", res);
		return res;
	}

	if (auto res = prepare_chunk(buffer_id_prep, offset_prep); kIOReturnSuccess != res) {
		os_log_error(_logger, "Failed to send-and-prepare chunk: prepare failed: 0x%x", res);
		return res;
	}

	return kIOReturnSuccess;
}

IOReturn
AppleVirtMeshMainUserClient::interrupt_waiting_threads([[maybe_unused]] uintptr_t buffer_id)
{
	os_log_info(_logger, "VirtMesh does not have waiting threads for data messages, so always return success when interrupting");
	return kIOReturnSuccess;
}

IOReturn
AppleVirtMeshMainUserClient::clear_interrupt_state([[maybe_unused]] uintptr_t buffer_id)
{
	os_log_info(
	    _logger,
	    "VirtMesh does not have waiting threads for data messages, so always return success when clearing interrupts"
	);
	return kIOReturnSuccess;
}

IOReturn
AppleVirtMeshMainUserClient::start_forward_chain([[maybe_unused]] uintptr_t chain_id, [[maybe_unused]] uintptr_t elements)
{
	os_log_info(_logger, "VirtMesh does not have fordward chain, so always return success when starting forward chain");
	return kIOReturnSuccess;
}

IOReturn
AppleVirtMeshMainUserClient::stop_forward_chain()
{
	os_log_info(_logger, "VirtMesh does not have fordward chain, so always return success when stoping forward chain");
	return kIOReturnSuccess;
}
