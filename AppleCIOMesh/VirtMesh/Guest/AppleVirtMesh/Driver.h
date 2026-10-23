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
//  Driver.h
//  AppleVirtMesh
//
//  Created by Zixuan Wang on 11/13/24.
//

#pragma once

#include "VirtMesh/Guest/AppleVirtMesh/SharedMemory.h"
#include "VirtMesh/Guest/AppleVirtMesh/UserClientConfig.h"
#include "VirtMesh/Guest/AppleVirtMesh/UserClientMain.h"
#include "VirtMesh/Guest/AppleVirtMesh/VirtIOChannel.h"
#include "VirtMesh/Guest/AppleVirtMeshIOBridge/Driver.h"

#include <AppleVirtIO/AppleVirtIOQueue.hpp>
#include <IOKit/IOCommandGate.h>
#include <IOKit/IOService.h>
#include <IOKit/IOWorkLoop.h>
#include <os/atomic.h>

#define GATED_METHOD_NO_PARAM(func_name)                                                                         \
  private:                                                                                                       \
	IOReturn func_name##_gated();                                                                                \
                                                                                                                 \
  public:                                                                                                        \
	IOReturn func_name()                                                                                         \
	{                                                                                                            \
		auto action = (OSMemberFunctionCast(IOWorkLoop::Action, this, &AppleVirtMeshDriver::func_name##_gated)); \
		return this->_work_loop->runAction(action, this);                                                        \
	}

#define GATED_0_PARAMS ()
#define GATED_1_PARAMS (void *)
#define GATED_2_PARAMS (void *, void *)
#define GATED_3_PARAMS (void *, void *, void *)

#define GATED_METHOD(func_name, GATED_PARAMS, PARAMS, ...)                                                       \
  private:                                                                                                       \
	IOReturn func_name##_gated GATED_PARAMS;                                                                     \
                                                                                                                 \
  public:                                                                                                        \
	IOReturn func_name PARAMS                                                                                    \
	{                                                                                                            \
		auto action = (OSMemberFunctionCast(IOWorkLoop::Action, this, &AppleVirtMeshDriver::func_name##_gated)); \
		return this->_work_loop->runAction(action, this, __VA_ARGS__);                                           \
	}

#define PROPERTY_GATED_METHOD(func_name, prop_type, prop_name) \
	GATED_METHOD(func_name##_##prop_name, GATED_1_PARAMS, (const prop_type * prop_name), (void *)prop_name);

#define PROPERTY_DEFAULT_GET_GATED_SET(prop_type, prop_name)    \
  private:                                                      \
	prop_type _##prop_name;                                     \
	PROPERTY_GATED_METHOD(set, prop_type, prop_name)            \
  public:                                                       \
	IOReturn get_##prop_name(prop_type * output)                \
	{                                                           \
		memcpy(output, &this->_##prop_name, sizeof(prop_type)); \
		return kIOReturnSuccess;                                \
	}

#define PROPERTY_GATED_GET_GATED_SET(prop_type, prop_name, prop_set_type) \
  private:                                                                \
	prop_type _##prop_name;                                               \
	PROPERTY_GATED_METHOD(set, prop_set_type, prop_name)                  \
	PROPERTY_GATED_METHOD(get, prop_type, prop_name)

#define PROPERTY_GATED_GET_NO_SET(prop_type, prop_name) \
  private:                                              \
	prop_type _##prop_name;                             \
	PROPERTY_GATED_METHOD(get, prop_type, prop_name)

#define PROPERTY(prop_type, prop_return_type, prop_name, prop_default_value) \
  private:                                                                   \
	prop_type _##prop_name = prop_default_value;                             \
                                                                             \
  public:                                                                    \
	prop_return_type get_##prop_name(void)                                   \
	{                                                                        \
		return _##prop_name;                                                 \
	}                                                                        \
	void set_##prop_name(prop_type value)                                    \
	{                                                                        \
		this->_##prop_name = value;                                          \
	}

namespace VirtMesh::Guest::Mesh
{

class AppleVirtMeshDriver final : public Bridge::AppleVirtMeshIOBridgeDriver
{
	OSDeclareFinalStructors(AppleVirtMeshDriver);
	using super = Bridge::AppleVirtMeshIOBridgeDriver;

  public:
	/* IOUserClient2022 */
	IOReturn newUserClient(
	    task_t                                   owningTask,
	    void *                                   securityID,
	    UInt32                                   type,
	    OSDictionary *                           properties,
	    LIBKERN_RETURNS_RETAINED IOUserClient ** handler
	) APPLE_KEXT_OVERRIDE final;

	/**
	 * @brief Constructing additional message channels (WorkLoop + VirtIOQueue + Monitoring Thread) for control and data messages.
	 */
  public:
	bool init_queue_handlers() final;
	void init_work_loop() final;
	void stop(IOService * provider) final;

  private:
	OSSharedPtr<AppleVirtMeshVirtIOChannel> _ctrl_queue;
	OSSharedPtr<AppleVirtMeshVirtIOChannel> _data_queue;

	static IOReturn handle_virtio_message(AppleVirtMeshDriver * owner, Message::Channel channel, const Message * message);
	IOReturn        handle_ctrl_message(const Message * message);

  public:
	/**
	 * @brief Config user client methods
	 */
	bool     register_config_user_client(AppleVirtMeshConfigUserClient * config_client);
	void     unregister_config_user_client(AppleVirtMeshConfigUserClient * config_client);
	IOReturn send_control_message(const ConfigClient::MeshMessage * msg);
	IOReturn activate();

	/**
	 * @brief Config user client data
	 *
	 * @note For every PROPERTY_GATED_SET, you need to define the gated setter function in the cpp file, not doing so would not
	 * cause any compiler errors
	 *
	 * @todo Give a compiler error if setter is not defined.
	 */
	/* clang-format off */
	PROPERTY_DEFAULT_GET_GATED_SET	(ConfigClient::NodeId					, node_id										);
	PROPERTY_DEFAULT_GET_GATED_SET	(ConfigClient::ChassisId				, chassis_id									);
	PROPERTY_DEFAULT_GET_GATED_SET	(ConfigClient::AppleCIOMeshCryptoKey	, user_key										); /* FIXME: should check if user key is used and return error if already used */
	PROPERTY_DEFAULT_GET_GATED_SET	(ConfigClient::CryptoFlags				, crypto_flags									);
	PROPERTY_DEFAULT_GET_GATED_SET	(uint64_t								, buffers_allocated								);
	PROPERTY_DEFAULT_GET_GATED_SET	(ConfigClient::EnsembleSize				, ensemble_size									);
	PROPERTY_GATED_GET_GATED_SET	(ConfigClient::PeerHostnames			, peer_hostnames    , ConfigClient::PeerNode	);
	PROPERTY_GATED_GET_NO_SET		(ConfigClient::CIOConnections			, cio_connections								);
	PROPERTY_GATED_GET_NO_SET		(ConfigClient::ConnectedNodes			, connected_nodes								);

	PROPERTY						(atomic_bool							, bool				, crypto_key_used	, true	);
	PROPERTY						(atomic_bool							, bool				, active			, false	);
	PROPERTY						(atomic_bool							, bool				, was_deactivated	, false	);
	PROPERTY						(atomic_bool							, bool				, cio_locked		, false	);
	/* clang-format on */

	/**
	 * @brief Main user client data
	 */
	/* clang-format off */
	PROPERTY_DEFAULT_GET_GATED_SET	(uint64_t								, max_wait_time									);
	PROPERTY						(uint64_t								, uint64_t			, generation		, 1		);
	/* clang-format on */

	/**
	 * @brief Main user client methods
	 */
	bool register_main_user_client(AppleVirtMeshMainUserClient * main_client);
	void unregister_main_user_client(AppleVirtMeshMainUserClient * main_client);

	IOReturn send_assigned_data(MainClient::BufferId buffer_id, uint64_t offset, MainClient::CryptoTag tag);
	IOReturn recv_assigned_data(MainClient::BufferId buffer_id, uint64_t offset, MainClient::CryptoTag & tag);

	IOReturn send_all_assigned_data(MainClient::BufferId buffer_id, MainClient::CryptoTag tag);
	IOReturn recv_all_assigned_data(
	    MainClient::BufferId     buffer_id,
	    uint64_t &               count_batch,
	    uint64_t *&              offset_received_out,
	    MainClient::CryptoTag *& tag_out
	);

	AppleVirtMeshSharedMemory * get_shared_memory(MainClient::BufferId buffer_id);

	GATED_METHOD(
	    allocate_shared_memory,
	    GATED_3_PARAMS,
	    (const MainClient::SharedMemoryConfig * config, task_t owning_task, AppleVirtMeshMainUserClient * client),
	    (void *)config,
	    (void *)owning_task,
	    (void *)client
	);

	GATED_METHOD(deallocate_shared_memory, GATED_1_PARAMS, (const MainClient::SharedMemoryRef * ref), (void *)ref);
	GATED_METHOD(assign_shared_memory_chunk, GATED_1_PARAMS, (const MainClient::AssignChunks * assignment), (void *)assignment);
	GATED_METHOD_NO_PARAM(start_new_generation);

  private:
	IOReturn free_shared_memory(MainClient::BufferId buffer_id);
	IOReturn send_and_recv_message(Message * msg);

	GATED_METHOD(free_all_shared_memory, GATED_1_PARAMS, (AppleVirtMeshMainUserClient * client), (void *)client);

	// /**
	//  * Get the buffer info (size, start address, and node id) for caller to construct a message to host.
	//  */
	// IOReturn get_buffer_info(
	//     MainClient::BufferId      buffer_id,
	//     uint64_t                  offset,
	//     MainClient::MeshDirection direction,
	//     mach_vm_address_t &       buf_start,
	//     uint64_t &                buf_size,
	//     uint32_t &                curr_node_id
	// );

  private:
	struct UserClientArray {
		/* TODO: CIOMesh kext defines it as an array with only one object,
		 *       consider refactoring it to a single config user client pointer
		 */
		OSSharedPtr<OSArray> clients = nullptr;
		IOLock *             lock;

		UserClientArray()
		{
			lock    = IOLockAlloc();
			clients = OSArray::withCapacity(1);
		}

		~UserClientArray()
		{
			if (lock) {
				IOLockFree(lock);
			}
			OSSafeReleaseNULL(clients);
		}
	};

	struct UserClientArray _config_user;
	struct UserClientArray _main_user;

	/* For the main client */
	OSSharedPtr<OSArray> _shared_memory_regions = OSArray::withCapacity(1);

  protected:
	void
	construct_logger() final
	{
		/**
		 * @brief Don't check _logger against nullptr as I intentionally want to override the super class's _logger, if it exists.
		 *
		 * @todo Maybe we need a better check-and-destroy code, but this code works fine now.
		 *
		 * @todo Consider changing to use IOLog instead of os_log(), if IOLog provides more convenience.
		 */
		_logger = os_log_create(kDriverLoggerSubsystem, "AppleVirtMeshDriver");
	}
};

}; // namespace VirtMesh::Guest::Mesh

#undef PROPERTY
#undef PROPERTY_GATED_METHOD
#undef PROPERTY_DEFAULT_GET_GATED_SET
#undef PROPERTY_GATED_GET_NO_SET
