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
//  Driver.cpp
//  AppleVirtMesh
//
//  Created by Zixuan Wang on 11/13/24.
//

#include "VirtMesh/Guest/AppleVirtMesh/Driver.h"
#include "VirtMesh/Guest/AppleVirtMesh/Interfaces.h"
#include "VirtMesh/Guest/AppleVirtMesh/SharedMemory.h"
#include "VirtMesh/Guest/AppleVirtMesh/UserClientConfig.h"
#include "VirtMesh/Guest/AppleVirtMesh/UserClientMain.h"
#include "VirtMesh/Guest/AppleVirtMeshIOBridge/Transaction.h"
#include "VirtMesh/Utils/Log.h"

#include <AppleVirtIO/AppleVirtIOTransport.hpp>
#include <IOKit/IOReturn.h>

using namespace VirtMesh::Guest::Mesh;
using VirtMesh::Guest::Bridge::AppleVirtMeshIOTransaction;

OSDefineMetaClassAndFinalStructors(AppleVirtMeshDriver, super);

IOReturn
AppleVirtMeshDriver::newUserClient(
    task_t                                   owningTask,
    void *                                   securityID,
    UInt32                                   type,
    OSDictionary *                           properties,
    LIBKERN_RETURNS_RETAINED IOUserClient ** handler
)
{
	IOUserClient * client = nullptr;

	switch (static_cast<MeshClientType>(type)) {
	case MeshClientType::MainClient:
		client = OSTypeAlloc(AppleVirtMeshMainUserClient);
		break;
	case MeshClientType::ConfigClient:
		/* Not implemented yet */
		client = OSTypeAlloc(AppleVirtMeshConfigUserClient);
		break;
	default:
		os_log_error(_logger, "Unknown client type %u", type);
		return kIOReturnUnsupported;
	}

	if (!client->initWithTask(owningTask, securityID, type, properties)) {
		client->release();
		os_log_error(_logger, "Failed to init client with task");
		return kIOReturnBadArgument;
	}

	if (!client->attach(this)) {
		client->release();
		os_log_error(_logger, "Failed to attach to the client");
		return kIOReturnUnsupported;
	}

	if (!client->start(this)) {
		*handler = nullptr;
		client->detach(this);
		client->release();
		os_log_error(_logger, "Failed to start user client");
		return kIOReturnUnsupported;
	}

	*handler = client;
	return kIOReturnSuccess;
}

void
AppleVirtMeshDriver::init_work_loop()
{
	super::init_work_loop();

	_ctrl_queue = OSMakeShared<AppleVirtMeshVirtIOChannel>();
	_data_queue = OSMakeShared<AppleVirtMeshVirtIOChannel>();

	_ctrl_queue->init_workloop();
	_data_queue->init_workloop();
}

bool
AppleVirtMeshDriver::init_queue_handlers()
{
	if (!super::init_queue_handlers()) {
		os_log_error(_logger, "Super class failed to init queue handlers");
		return false;
	}

	DEV_LOG(_logger, "Set up message queues");

	/* Init ctrl queue to be passive mode, data queue to be active mode. */
	if (!_ctrl_queue->init_virtio_queue(Message::Channel::Control, this, &AppleVirtMeshDriver::handle_virtio_message, _transport) ||
	    !_data_queue->init_virtio_queue(Message::Channel::Data, this, _transport)) {
		os_log_error(_logger, "Failed to init virtio queues");
		return false;
	}

	return true;
}

void
AppleVirtMeshDriver::stop(IOService * provider)
{
	DEV_LOG(_logger, "Stop");

	_stopping = true;

	_ctrl_queue->stop();
	_data_queue->stop();

	super::stop(provider);
}

bool
AppleVirtMeshDriver::register_config_user_client(AppleVirtMeshConfigUserClient * client)
{
	{
		IOLockGuard guard(_config_user.lock);
		_config_user.clients->setObject(client);
		_ctrl_queue->launch_once();
		// launch_once_loop_control_message();
	}

	return true;
}

void
AppleVirtMeshDriver::unregister_config_user_client(AppleVirtMeshConfigUserClient * client)
{
	{
		IOLockGuard guard(_config_user.lock);

		int idx = -1;
		for (unsigned int i = 0; i < _config_user.clients->getCount(); i++) {
			auto iter = _config_user.clients->getObject(i);
			if (client == iter) {
				idx = (int)i;
				break;
			}
		}

		if (-1 == idx) {
			os_log_error(_logger, "Could not find config user client to unregister");
			return;
		}

		_config_user.clients->removeObject((unsigned int)idx);

		/* TODO: Kill the control message monitoring thread, and clear the host side control message queue. */
	}
}

bool
AppleVirtMeshDriver::register_main_user_client(AppleVirtMeshMainUserClient * client)
{
	/* Note: CIOMesh kext considers the `forwarder` as a user client, we do not consider that in VRE yet, so ignoring those
	 * implementations. Will need to implement that if the higher-level logic -- e.g., llmsim and MetalLM -- uses forwarder
	 * logic.
	 */

	{
		IOLockGuard guard(_main_user.lock);
		_main_user.clients->setObject(client);
	}

	return true;
}

void
AppleVirtMeshDriver::unregister_main_user_client(AppleVirtMeshMainUserClient * client)
{
	{
		IOLockGuard guard(_main_user.lock);

		int idx = -1;
		for (unsigned int i = 0; i < _main_user.clients->getCount(); i++) {
			auto iter = _main_user.clients->getObject(i);
			if (client == iter) {
				idx = (int)i;
				break;
			}
		}

		if (-1 == idx) {
			os_log_error(_logger, "Could not find main user client to unregister");
			return;
		}

		free_all_shared_memory(client);

		_main_user.clients->removeObject((unsigned int)idx);
	}
}

IOReturn
AppleVirtMeshDriver::set_peer_hostnames_gated(void * peer_hostnames_arg)
{
	if (_active) {
		os_log_error(_logger, "Failed to set peer_hostnames after activation");
		return kIOReturnBusy;
	}

	const auto count = _peer_hostnames.count;
	if (count >= ConfigClient::kMaxPeerCount) {
		os_log_error(_logger, "Cannot add more peers to the current node. Max peers: %d\n", ConfigClient::kMaxPeerCount);
		return kIOReturnInvalid;
	}

	/* Note: it's PeerNode type, not PeerHostnames type */
	auto peer_hostnames_input = static_cast<const ConfigClient::PeerNode *>(peer_hostnames_arg);
	memcpy(&this->_peer_hostnames.peers[count], peer_hostnames_input, sizeof(ConfigClient::PeerNode));
	this->_peer_hostnames.count++;

	return kIOReturnSuccess;
}

IOReturn
AppleVirtMeshDriver::get_peer_hostnames_gated(void * peer_hostnames_arg)
{
	auto hostnames = reinterpret_cast<ConfigClient::PeerHostnames *>(peer_hostnames_arg);
	*hostnames     = _peer_hostnames;
	return kIOReturnSuccess;
}

IOReturn
AppleVirtMeshDriver::get_cio_connections_gated(void * cio_connections_arg)
{
	/**
	 * @todo Need to verify if the current behavior is correct, i.e., for the current node set connected to false, and node id to be
	 * kNonDCHardwarePlatform.
	 *
	 * @todo This is a rather hacky way of getting the connection states for only two-node VREs:
	 *       1. Only return two cio connection states, including the current node
	 *       2. Get the current node's id from the host plugin, and set the other node's id from the kext. E.g., if the current node
	 *          is 0, then directly set the other node is 1, instead of actually getting the node id from the other VRE.
	 *       This is a temporary workaround, and we need to implement a more flexible approach later.
	 */
	uint32_t node_id = get_hardware_node_id();
	if (node_id == UINT32_MAX) {
		os_log_error(_logger, "Failed to get hardware node ID");
		return kIOReturnError;
	}

	if ((node_id != 0) && (node_id != 1)) {
		os_log_error(_logger, "Node ID [%u] is out of range", node_id);
		return kIOReturnUnsupported;
	}

	auto conn      = static_cast<ConfigClient::CIOConnections *>(cio_connections_arg);
	conn->cioCount = kMaxVRENodes;

	for (uint32_t i = 0; i < conn->cioCount; i++) {
		if (i == node_id) {
			conn->cio[i].cableConnected             = false;
			conn->cio[i].expectedPeerHardwareNodeId = ConfigClient::kNonDCHardwarePlatform;
			conn->cio[i].actualPeerHardwareNodeId   = ConfigClient::kNonDCHardwarePlatform;
		} else {
			conn->cio[i].cableConnected             = true;
			conn->cio[i].expectedPeerHardwareNodeId = 1 - node_id;
			conn->cio[i].actualPeerHardwareNodeId   = 1 - node_id;
		}
	}

	return kIOReturnSuccess;
}

/* FIXME: This function heavily diverges from the CIOMesh kext's behavior, will need more testing and checks here.
 */
IOReturn
AppleVirtMeshDriver::get_connected_nodes_gated(void * connected_nodes_arg)
{
	/* FIXME: Should we use the hardware_node_id assigned by host broker, or the node_id class member value assigned by
	 * ensembled/ensembleconfig? */
	auto node_id = get_hardware_node_id();
	if (node_id == UINT32_MAX) {
		os_log_error(_logger, "Failed to get this hardware node id");
		return kIOReturnError;
	}

	DEV_LOG(_logger, "Current node id: %u", node_id);

	auto nodes       = static_cast<ConfigClient::ConnectedNodes *>(connected_nodes_arg);
	nodes->nodeCount = kMaxVRENodes;

	for (uint32_t i = 0; i < nodes->nodeCount; i++) {
		bzero(&nodes->nodes[i].chassisId, sizeof(ConfigClient::ChassisId));

		if (i == node_id) {
			nodes->nodes[i].rank         = static_cast<uint8_t>(i);
			nodes->nodes[i].inputChannel = -1;
			memcpy(&nodes->nodes[i].chassisId, &_chassis_id, sizeof(_chassis_id));
			/* The current node has to know all output channels, and in VRE we simply assume they are available without checking,
			 * just to simplify the code.
			 */
			nodes->nodes[i].outputChannelCount = kMaxVRENodes;
			for (uint32_t j = 0; j < kMaxVRENodes; j++) {
				nodes->nodes[i].outputChannels[j] = static_cast<uint8_t>(j);
			}
		} else {
			nodes->nodes[i].rank = static_cast<uint8_t>(i);
			/* Two nodes are directly connected.
			 * TODO: double check this behavior with the real CIOMesh kext.
			 */
			nodes->nodes[i].inputChannel = static_cast<int8_t>(1 - i);
			/* Two node VRE should be set as the same chassis. */
			memcpy(&nodes->nodes[i].chassisId, &_chassis_id, sizeof(_chassis_id));
			nodes->nodes[i].outputChannelCount = 0;
		}

		nodes->nodes[i].partitionIdx = 0;
	}

	return kIOReturnSuccess;
}

IOReturn
AppleVirtMeshDriver::send_control_message(const ConfigClient::MeshMessage * mesh_message)
{
	uint32_t curr_node_id = get_hardware_node_id();
	if (curr_node_id == UINT32_MAX) {
		os_log_error(_logger, "Failed to get this hardware node id");
		return kIOReturnError;
	}

	/** @note: AppleCIOMesh kext wraps the `mesh_message` inside a ControlCommand struct. The ControlCommand is largely used for
	 * ThunderBolt controls and we don't need that in the VRE, so I'm instead folding `mesh_message` directly to VRE's Message
	 * struct.
	 */

	auto message = Message{
	    Message::Command::GuestSend,
	    Message::SubCommand::GuestSend_ToGuest,
	    Message::Channel::Control,
	    0,
	    Message::NodeId{curr_node_id},
	    Message::PayloadSize{sizeof(ConfigClient::MeshMessage)},
	    reinterpret_cast<const uint8_t *>(mesh_message)
	};

	if (mesh_message->node.id == curr_node_id) {
		handle_ctrl_message(&message);
		return kIOReturnSuccess;
	}

	/* TODO: Every message is sent through the default General channel, maybe better use the corresponding channel's queue for
	 * sending?
	 */
	// return send_message(&message);
	return _ctrl_queue->send_message(&message);
}

IOReturn
AppleVirtMeshDriver::activate()
{
	if (true == get_was_deactivated()) {
		os_log_error(_logger, "Cannot activate CIO, it's already deactivated");
		return kIOReturnError;
	}

	if (_active) {
		os_log_info(_logger, "CIO already activated, no need to re-activate it");
		return kIOReturnSuccess;
	}

	os_log_info(_logger, "Activating CIO: Sending activation message to the other node, and waiting for response from it");

	uint32_t curr_node_id = get_hardware_node_id();
	if (curr_node_id == UINT32_MAX) {
		os_log_error(
		    _logger,
		    "Cannot activate CIO: the node id is invalid, probably the host broker did not properly assign the node id."
		);
		return kIOReturnInvalid;
	}

	/**
	 * @brief Send the activate message to other nodes
	 *
	 * @todo: It should carry the info including the current node's chassis. But for two node vre we just assume they are under
	 * the same chassis and simplify some code here.
	 */
	char payload[]   = "activate";
	auto payload_len = strlen(payload) + 1;

	auto activate_msg = Message{
	    Message::Command::GuestSend,
	    Message::SubCommand::GuestSend_ToGuest,
	    Message::Channel::General,
	    0,
	    Message::NodeId{curr_node_id},
	    Message::PayloadSize{payload_len},
	    reinterpret_cast<const uint8_t *>(payload)
	};

	auto res = send_and_recv_message(&activate_msg);
	if (kIOReturnSuccess != res) {
		os_log_error(_logger, "Failed to activate: 0x%x", res);
		return res;
	}

	if (0 != strcmp(payload, reinterpret_cast<const char *>(activate_msg.get_payload()))) {
		os_log_error(_logger, "Failed to activate: the received message does not contain activation payload");
		return kIOReturnInternalError;
	}

	uint32_t peer_node_id = activate_msg._header.src_node;

	/* Channel change: for two node VRE, we assume only channel index 0 is used on both nodes */
	ConfigClient::MeshChannelInfo channel_info;
	channel_info.channelIndex = 0;
	channel_info.node.id      = peer_node_id;
	memcpy(channel_info.chassis.id, _chassis_id.id, kMaxChassisIdLength);

	atomic_for_each<AppleVirtMeshConfigUserClient>(_config_user.lock, _config_user.clients, [&](auto i, auto * client) {
		DEV_LOG(_logger, "Notifying config client %d for channel change", i);
		client->notify_channel_change(channel_info, true);
	});

	/* Connection change */
	ConfigClient::NodeConnectionInfo conn_info;
	conn_info.channelIndex = 0;

	/* TX from the current node to the peer node */
	conn_info.node.id = curr_node_id;
	atomic_for_each<AppleVirtMeshConfigUserClient>(_config_user.lock, _config_user.clients, [&](auto i, auto * client) {
		DEV_LOG(_logger, "Notifying config client %d for connection change", i);
		client->notify_connection_change(conn_info, true, true);
	});

	/* RX from the peer node to the current node */
	conn_info.node.id = peer_node_id;
	atomic_for_each<AppleVirtMeshConfigUserClient>(_config_user.lock, _config_user.clients, [&](auto i, auto * client) {
		DEV_LOG(_logger, "Notifying config client %d for connection change", i);
		client->notify_connection_change(conn_info, true, false);
	});

	/* The other node has responded, good to go */
	set_active(true);

	os_log_info(_logger, "Activating CIO: done");
	return kIOReturnSuccess;
}

IOReturn
AppleVirtMeshDriver::handle_virtio_message(AppleVirtMeshDriver * driver, Message::Channel channel, const Message * message)
{
	switch (channel) {
	case Message::Channel::Control:
		return driver->handle_ctrl_message(message);

	case Message::Channel::Data:
		os_log_error(
		    OS_LOG_DEFAULT,
		    "Cannot handle data queue message in handler, it is supposed to be in the 'active' mode and used with explicit "
		    "send/recv_message calls, not this callback handler."
		);
		return kIOReturnInternalError;

	default:
		os_log_error(OS_LOG_DEFAULT, "Cannot handle VirtIO message from channel %u", channel);
		return kIOReturnInternalError;
	}

	return kIOReturnError;
}

IOReturn
AppleVirtMeshDriver::handle_ctrl_message(const Message * message)
{
	ConfigClient::MeshMessage mesh_message;
	message->copy_out_payload(reinterpret_cast<uint8_t *>(&mesh_message), sizeof(mesh_message));

	/* Source node id is embedded in the _header. */
	mesh_message.node.id = message->_header.src_node;

	atomic_for_each<AppleVirtMeshConfigUserClient>(_config_user.lock, _config_user.clients, [&](auto i, auto * client) {
		DEV_LOG(_logger, "Notifying config client %d for control message", i);
		client->notify_control_message(&mesh_message);
	});

	return kIOReturnSuccess;
}

AppleVirtMeshSharedMemory *
AppleVirtMeshDriver::get_shared_memory(MainClient::BufferId buffer_id)
{
	for (unsigned i = 0; i < _shared_memory_regions->getCount(); i++) {
		auto memory = OSRequiredCast(AppleVirtMeshSharedMemory, _shared_memory_regions->getObject(i));

		if (memory->_config.bufferId == buffer_id) {
			return memory;
		}
	}

	/* It's up to the caller to log if this nullptr is actually an error, because some functions, e.g., `allocate_shared_memory` may
	 * proceed with this nullptr as a sign of requiring a new shared memory. */
	return nullptr;
}

IOReturn
AppleVirtMeshDriver::free_shared_memory(MainClient::BufferId buffer_id)
{
	for (unsigned i = 0; i < _shared_memory_regions->getCount(); i++) {
		auto memory = OSRequiredCast(AppleVirtMeshSharedMemory, _shared_memory_regions->getObject(i));

		if (buffer_id != memory->_config.bufferId) {
			continue;
		}

		/* FIXME: if needed, interrupt the shared memory IO thread as in CIOMesh kext */

		DEV_LOG(_logger, "Deallocating shared memory buffer_id [%lld] with retain count %d", buffer_id, memory->getRetainCount());
		_shared_memory_regions->removeObject(i);

		return kIOReturnSuccess;
	}

	os_log_error(_logger, "Did not find shared memory with buffer_id [%lld]", buffer_id);
	return kIOReturnNotFound;
}

IOReturn
AppleVirtMeshDriver::free_all_shared_memory_gated(void * client_arg)
{
	auto client = reinterpret_cast<AppleVirtMeshMainUserClient *>(client_arg);
	DEV_LOG(_logger, "Checking shared buffers allocated by client [0x%016llx]", (uint64_t)client);

	/**
	 * @brief Checking and removing unreleased buffers
	 * @note Reverse iterate the os array because if iterate from the front, and delete an array element, the array length
	 * changes and index can miss some elements.
	 */
	for (auto i = _shared_memory_regions->getCount(); i-- > 0;) {
		auto memory        = OSRequiredCast(AppleVirtMeshSharedMemory, _shared_memory_regions->getObject(i));
		auto id            = memory->_config.bufferId;
		auto memory_client = memory->get_main_client();
		DEV_LOG(_logger, "Checking shared buffer ID [%llu]: allocated by client [0x%016llx]", id, (uint64_t)(memory_client));

		if (memory_client == client) {
			os_log_error(
			    _logger,
			    "VirtMesh is deallocating buffer id [%llu] (array element [%d]) at process exit, but this buffer should be "
			    "deallocated by the userspace process. This could be the userspace process creashing, or a bug that does not "
			    "deallocate before exiting the process.",
			    id,
			    i
			);

			_shared_memory_regions->removeObject(i);
		}
	}

	return kIOReturnSuccess;
}

IOReturn
AppleVirtMeshDriver::allocate_shared_memory_gated(void * config_arg, void * owning_task_arg, void * client_arg)
{
	/* TODO: Test if host plugin is available for communication, occasionally the plugin fails to discover the peer plugin.
	 *
	 * NOTE: The CIOMesh kext's `_allocateSharedMemoryUCGated()` checks if `_maxBuffersPerKey` and `_cryptoKeyTimeLimit` are 0, but
	 *       those values are always 0, seems like a dead code so not implemented here.
	 */
	auto config      = reinterpret_cast<MainClient::SharedMemoryConfig *>(config_arg);
	auto client      = reinterpret_cast<AppleVirtMeshMainUserClient *>(client_arg);
	auto owning_task = reinterpret_cast<task_t>(owning_task_arg);

	DEV_LOG(_logger, "Allocate shared memory for buffer id: %lld", config->bufferId);

	if (0 == config->bufferId) {
		os_log_error(_logger, "Cannot create a buffer with ID zero");
		return kIOReturnBadArgument;
	}

	if (get_shared_memory(config->bufferId)) {
		os_log_error(_logger, "Shared memory with bufferId: %lld already allocated", config->bufferId);
		return kIOReturnBadArgument;
	}

	if (0 == config->size || 0 == config->chunkSize || 0 == config->address) {
		os_log_error(
		    _logger,
		    "Invalid memory config: size [%llu] chunkSize [%llu] address [%llu]",
		    config->size,
		    config->chunkSize,
		    config->address
		);
		return kIOReturnBadArgument;
	}

	/* Note: CIOMesh kext divides the chunk by the links per channel, no need to do it in VRE */

	uint64_t total = 0;
	for (uint32_t i = 0; i < MainClient::kMaxTBTCommandCount; i++) {
		total += config->forwardBreakdown[i];
	}

	if (total > config->chunkSize) {
		os_log_error(_logger, "Running breakdown [%llu] is greater than chunk size [%lld]", total, config->chunkSize);
		return kIOReturnBadArgument;
	}

	auto shared_memory = AppleVirtMeshSharedMemory::allocate(this, config, client, owning_task);
	if (nullptr == shared_memory) {
		os_log_error(_logger, "Failed to allocate shared memory for buffer id: %lld", config->bufferId);
		return kIOReturnNoMemory;
	}

	/* Note: CIOMesh kext starts threads here, no need to do it */

	_shared_memory_regions->setObject(shared_memory);

	_buffers_allocated++;

	return kIOReturnSuccess;
}

IOReturn
AppleVirtMeshDriver::deallocate_shared_memory_gated(void * ref_arg)
{
	auto ref = reinterpret_cast<MainClient::SharedMemoryRef *>(ref_arg);

	DEV_LOG(_logger, "Deallocate shared memory for buffer id: %lld", ref->bufferId);

	IOLockGuard(_main_user.lock);
	return free_shared_memory(ref->bufferId);
}

IOReturn
AppleVirtMeshDriver::assign_shared_memory_chunk_gated(void * assignment_arg)
{
	auto assignment = reinterpret_cast<MainClient::AssignChunks *>(assignment_arg);

	if (MainClient::MeshDirection::In != assignment->direction && MainClient::MeshDirection::Out != assignment->direction) {
		os_log_error(_logger, "Invalid assignment direction: 0x%hhx", assignment->direction);
		return kIOReturnBadArgument;
	}

	auto memory = get_shared_memory(assignment->bufferId);
	if (nullptr == memory) {
		os_log_error(_logger, "Cannot find shared memory for assignment buffer id [%lld]", assignment->bufferId);
		return kIOReturnBadArgument;
	}

	constexpr int vre_channel_id = 0;
	auto          mask           = assignment->meshChannelMask;
	if (assignment->direction == MainClient::MeshDirection::Out) {
		/* Inverse the mask if it's output, for checking purpose only. By default the framework assumes 8 nodes so it's 0xff here.
		 * TODO: with 16n this 0xff may not hold anymore
		 */
		mask = mask ^ 0xff;
	}
	if (mask != (0x1 << vre_channel_id)) {
		DEV_LOG(
		    _logger,
		    "VRE supports only two node where each node only uses its first channel, but got channel mask [0x%llx] with direction "
		    "[%hu]",
		    assignment->meshChannelMask,
		    assignment->direction
		);
		// return kIOReturnBadArgument;
	}

	if (auto res = memory->create_assignment(assignment->offset, assignment->direction, assignment->sourceNode);
	    kIOReturnSuccess != res) {
		os_log_error(
		    _logger,
		    "Unable to create assignment, there may be already an assignment at offset [%lld], error code [0x%x]",
		    assignment->offset,
		    res
		);
		return res;
	}

	/* Note: CIOMesh kext divides the assignment into chunks for each link, we only have one link in VRE, no need to do that */

	return kIOReturnSuccess;
}

IOReturn
AppleVirtMeshDriver::send_and_recv_message(Message * msg)
{
	auto res = send_message(msg);
	if (kIOReturnSuccess != res) {
		os_log_error(_logger, "Failed to send message: 0x%x", res);
		return res;
	}

	msg->reset();
	msg->_header.command     = Message::Command::GuestRecv;
	msg->_header.sub_command = Message::SubCommand::GuestRecv_FromGuest;

	res = recv_message(msg);
	if (kIOReturnSuccess != res) {
		os_log_error(_logger, "Failed to receive message: 0x%x", res);
		return res;
	}

	if (msg->_header.sub_command == Message::SubCommand::Error) {
		os_log_error(_logger, "Failed to receive message, the host return error: 0x%llx", msg->_header.value);
		return kIOReturnError;
	}

	return kIOReturnSuccess;
}

IOReturn
AppleVirtMeshDriver::start_new_generation_gated()
{
	_generation++;
	DEV_LOG(_logger, "Starting a new generation [%lld]", _generation);

	auto curr_node_id = get_hardware_node_id();
	if (curr_node_id == UINT32_MAX) {
		os_log_error(_logger, "Cannot start new generation: the node id is invalid");
		return kIOReturnInvalid;
	}

	char     payload[]    = "start new generation";
	uint64_t payload_size = strlen(payload) + 1;

	auto generation_msg = Message{
	    Message::Command::GuestSend,
	    Message::SubCommand::GuestSend_ToGuest,
	    Message::Channel::General,
	    _generation,
	    Message::NodeId{curr_node_id},
	    Message::PayloadSize{payload_size},
	    reinterpret_cast<const uint8_t *>(payload)
	};

	auto res = send_and_recv_message(&generation_msg);
	if (kIOReturnSuccess != res) {
		os_log_error(_logger, "Failed to send message to start new generation: 0x%x", res);
		return res;
	}

	if (0 != strcmp(payload, reinterpret_cast<const char *>(generation_msg.get_payload()))) {
		os_log_error(_logger, "Failed to start new generation: the received message does not contain activation payload");
		return kIOReturnInternalError;
	}

	if (_generation != generation_msg._header.value) {
		os_log_error(
		    _logger,
		    "Failed to start new generation: generation mismatch %lld != %lld",
		    _generation,
		    generation_msg._header.value
		);
		return kIOReturnInternalError;
	}

	atomic_for_each<AppleVirtMeshMainUserClient>(_main_user.lock, _main_user.clients, [&](auto i, auto _client) {
		DEV_LOG(_logger, "Notifying main client [%u] for generation [%lld] synchronized", i, _generation);
		_client->notify_mesh_synchronized();
	});

	DEV_LOG(_logger, "Started a new generation [%lld]", _generation);

	return kIOReturnSuccess;
}

template <typename Func>
concept SharedMemoryHandler = requires(Func f, uint32_t curr_node_id, AppleVirtMeshSharedMemory * shared_memory) {
	{ f(curr_node_id, shared_memory) };
};

template <typename Func>
concept AssignmentHandler =
    requires(Func f, uint32_t curr_node_id, AppleVirtMeshSharedMemory * shared_memory, AppleVirtMeshAssignment * assignment) {
	    { f(curr_node_id, shared_memory, assignment) };
    };

template <SharedMemoryHandler Func>
[[nodiscard]] static inline IOReturn
with_shared_memory(AppleVirtMeshDriver * driver, MainClient::BufferId buffer_id, Func func)
{
	auto shared_memory = driver->get_shared_memory(buffer_id);
	if (nullptr == shared_memory) {
		os_log_error(driver->_logger, "Cannot get shared memory to send assigned data, with buffer ID: %lld", buffer_id);
		return kIOReturnBadArgument;
	}

	auto curr_node_id = driver->get_hardware_node_id();
	if (UINT32_MAX == curr_node_id) {
		os_log_error(driver->_logger, "Cannot get hardware node id");
		return kIOReturnInvalid;
	}

	return func(curr_node_id, shared_memory);
}

template <AssignmentHandler Func>
[[nodiscard]] static inline IOReturn
with_assignment(
    AppleVirtMeshDriver *     driver,
    MainClient::BufferId      buffer_id,
    uint64_t                  offset,
    MainClient::MeshDirection direction,
    Func                      func
)
{
	return with_shared_memory(driver, buffer_id, [&](auto curr_node_id, auto shared_memory) {
		AppleVirtMeshAssignment * curr_assignment = nullptr;
		if (auto result = shared_memory->get_assignment(offset, curr_assignment); kIOReturnSuccess != result) {
			os_log_error(driver->_logger, "Failed to get assignment at offset [%lld]", offset);
			return result;
		}

		if (curr_assignment->get_direction() != direction) {
			os_log_error(
			    driver->_logger,
			    "Cannot get the buffer chunk: assigned direction [%d] != required direction [%d]",
			    curr_assignment->get_direction(),
			    direction
			);
			return kIOReturnUnsupportedMode;
		}

		return func(curr_node_id, shared_memory, curr_assignment);
	});
}

static inline uint64_t
get_virtio_chunks(uint64_t buffer_size)
{
	uint64_t virtio_chunks = (buffer_size + MainClient::kMaxSingleVirtIOTransfer - 1) / MainClient::kMaxSingleVirtIOTransfer;
	if (virtio_chunks == 0) {
		os_log_error(OS_LOG_DEFAULT, "AppleVirtMesh: virtio chunks should not be 0, buffer size might be incorrect");
		assert(virtio_chunks > 0);
	}
	return virtio_chunks;
}

IOReturn
AppleVirtMeshDriver::send_assigned_data(MainClient::BufferId buffer_id, uint64_t offset, MainClient::CryptoTag tag)
{
	/* This is a mix of CIOMesh kext's AppleCIOMeshUserClient::trapSendChunk() and AppleCIOMeshService::sendAssignedData()
	 * implementation, because I think such logics are better located in service not in user client.
	 */
	using enum MainClient::MeshDirection;

	return with_assignment(this, buffer_id, offset, Out, [&](auto curr_node_id, auto shared_memory, auto) {
		DEV_LOG(_logger, "Sending assigned data for buffer [%lld] at offset [%lld]", buffer_id, offset);

		auto buffer_start  = shared_memory->_config.address + offset;
		auto buffer_size   = shared_memory->get_assignment_size();
		auto virtio_chunks = get_virtio_chunks(buffer_size);

		DEV_LOG(
		    _logger,
		    "Sending user buffer [0x%llx] size [%lld] broken into [%llu] virtio chunks",
		    reinterpret_cast<uint64_t>(buffer_start),
		    buffer_size,
		    virtio_chunks
		);

		for (uint64_t curr_chunk = 0; curr_chunk < virtio_chunks; curr_chunk++) {
			auto curr_chunk_size = MainClient::kMaxSingleVirtIOTransfer;
			if (curr_chunk == virtio_chunks - 1) {
				/**
				 * @note this covers the case where virtio_chunks == 1 and curr_chunk_size will be buffer_size
				 */
				curr_chunk_size = buffer_size - (MainClient::kMaxSingleVirtIOTransfer * (virtio_chunks - 1));
			}

			auto remaining_chunks = virtio_chunks - curr_chunk - 1;
			if (!(curr_chunk_size > 0 && remaining_chunks >= 0)) {
				os_log_error(
				    _logger,
				    "Failed to send assigned data, curr_chunk_size [%llu] remaining_chunks [%d]",
				    curr_chunk_size,
				    remaining_chunks
				);
				assert(curr_chunk_size > 0);
				assert(remaining_chunks >= 0);
			}

			auto curr_chunk_offset = curr_chunk * MainClient::kMaxSingleVirtIOTransfer;
			auto curr_chunk_start  = buffer_start + curr_chunk_offset;

			DEV_LOG(
			    _logger,
			    "Creating message for buffer [%lld] virtio chunk [%lld] curr_chunk_size [0x%llx]",
			    buffer_id,
			    curr_chunk,
			    curr_chunk_size
			);
			auto outgoing_msg = Message{
			    Message::Command::GuestSend,
			    Message::SubCommand::GuestSend_ToGuest,
			    Message::Channel::Data,
			    0,
			    Message::NodeId{curr_node_id},
			    Message::PayloadSize{curr_chunk_size},
			    curr_chunk_start
			};

			outgoing_msg._header.additional_values[0] = static_cast<uint64_t>(buffer_id);
			outgoing_msg._header.additional_values[1] = offset;
			outgoing_msg._header.additional_values[2] = tag.value[0];
			outgoing_msg._header.additional_values[3] = tag.value[1];
			outgoing_msg._header.additional_values[4] = remaining_chunks;
			outgoing_msg._header.additional_values[5] = curr_chunk_offset;
			outgoing_msg._header.additional_values[6] = curr_chunk_size;

			if (auto res = _data_queue->send_message(&outgoing_msg); kIOReturnSuccess != res) {
				os_log_error(
				    _logger,
				    "Failed to send assigned data for buffer [0x%llx] at offset [0x%llx] virtio chunk [%llu] error [0x%x]",
				    buffer_id,
				    offset,
				    curr_chunk,
				    res
				);
				return res;
			}

			DEV_LOG(_logger, "Finished sending message for buffer [%lld] virtio chunk [%lld]", buffer_id, curr_chunk);

			DEV_LOG(
			    _logger,
			    "AppleVirtMeshDriver::send_assigned_data() outgoing msg "
			    "payload_size = [0x%llx] "
			    "additional_values[0] = [0x%llx] "
			    "additional_values[1] = [0x%llx] "
			    "additional_values[2] = [0x%llx] "
			    "additional_values[3] = [0x%llx] "
			    "additional_values[4] = [0x%llx] "
			    "additional_values[5] = [0x%llx] "
			    "additional_values[6] = [0x%llx] "
			    "additional_values[7] = [0x%llx] ",
			    outgoing_msg._header.payload_size,
			    outgoing_msg._header.additional_values[0],
			    outgoing_msg._header.additional_values[1],
			    outgoing_msg._header.additional_values[2],
			    outgoing_msg._header.additional_values[3],
			    outgoing_msg._header.additional_values[4],
			    outgoing_msg._header.additional_values[5],
			    outgoing_msg._header.additional_values[6],
			    outgoing_msg._header.additional_values[7]
			);
		}
		return kIOReturnSuccess;
	});
}

IOReturn
AppleVirtMeshDriver::send_all_assigned_data(MainClient::BufferId buffer_id, MainClient::CryptoTag tag)
{
	os_log_info(
	    _logger,
	    "send_all_assigned_data() is not used from any upper layer software at the time of development, this func may be unstable."
	);
	DEV_LOG(
	    _logger,
	    "AppleVirtMeshVirtIOChannel::send_all_assigned_data() buffer_id [%u] tag [0x%016llx]-[0x%016llx]",
	    buffer_id,
	    tag.value[0],
	    tag.value[1]
	);
	return with_shared_memory(this, buffer_id, [&](uint32_t curr_node_id, AppleVirtMeshSharedMemory * shared_memory) {
		/* This is defined in CIOMesh kext as SEND_ALL_MAX_CHUNKS, IDK why it defines it as 64 there. */
		static constexpr uint64_t kMaxChunksToSendAll = 64;

		/* FIXME: find a way to check for potential buffer overflow caused by all such calculations in CIOMesh framework, kext, and
		 * VirtMesh
		 */
		auto total_chunks = shared_memory->_config.size / shared_memory->_config.chunkSize;
		if (total_chunks > kMaxChunksToSendAll) {
			/* CIOMesh has a dangerous behavior here--limiting the total_chunks to be at most 64 and proceed--which may cause chunks
			 * over 64 to not being sent. I chose to return an error in such case.
			 */
			os_log_error(
			    _logger,
			    "Total number of chunks [%llu] exceeds the max allowed [%llu]",
			    total_chunks,
			    kMaxChunksToSendAll
			);
			return kIOReturnNoMemory;
		}

		if (curr_node_id > kMaxChunksToSendAll) {
			os_log_error(_logger, "Current node id [%u] exceeds allowed [%llu]", curr_node_id, kMaxChunksToSendAll);
			return kIOReturnInternalError;
		}

		bool chunk_sent[kMaxChunksToSendAll] = {false};
		chunk_sent[curr_node_id]             = true;

		for (uint64_t chunk_id = 0; chunk_id < total_chunks; chunk_id++) {
			DEV_LOG(
			    _logger,
			    "AppleVirtMeshVirtIOChannel::send_all_assigned_data() buffer_id [%u] send chunk id [%llu] total [%llu]",
			    buffer_id,
			    chunk_id,
			    total_chunks
			);
			if (chunk_sent[chunk_id]) {
				continue;
			}

			AppleVirtMeshAssignment * assignment;
			if (auto res = shared_memory->get_assignment_at_index(chunk_id, assignment); res != kIOReturnSuccess) {
				os_log_error(_logger, "Failed to get assignment for sending");
				assert(false);
			}

			if (assignment->get_direction() != MainClient::MeshDirection::Out) {
				DEV_LOG(
				    _logger,
				    "AppleVirtMeshVirtIOChannel::send_all_assigned_data() assignment direction is not out, don't send this buffer"
				);
				continue;
			}

			auto offset = chunk_id * shared_memory->_config.chunkSize;
			if (auto send_result = send_assigned_data(buffer_id, offset, tag); kIOReturnSuccess != send_result) {
				os_log_error(
				    _logger,
				    "Failed to send all chunks for buffer id [%llu]: chunk [%llu] errors with [0x%x]",
				    buffer_id,
				    chunk_id,
				    send_result
				);
				return send_result;
			}
		}

		return kIOReturnSuccess;
	});
}
IOReturn
AppleVirtMeshDriver::recv_assigned_data(MainClient::BufferId buffer_id, uint64_t offset, MainClient::CryptoTag & tag)
{
	using enum MainClient::MeshDirection;
	return with_assignment(this, buffer_id, offset, In, [&](auto, auto shared_memory, auto) {
		DEV_LOG(_logger, "Receiving assigned data for buffer [%lld] at offset [%lld]", buffer_id, offset);

		auto     buffer_start  = shared_memory->_config.address + offset;
		auto     buffer_size   = shared_memory->get_assignment_size();
		uint64_t virtio_chunks = get_virtio_chunks(buffer_size);

		DEV_LOG(
		    _logger,
		    "Receiving user buffer [0x%llx] size [%lld] expected virtio chunks [%llu]",
		    reinterpret_cast<uint64_t>(buffer_start),
		    buffer_size,
		    virtio_chunks
		);

		for (uint64_t curr_chunk = 0; curr_chunk < virtio_chunks; curr_chunk++) {
			auto incoming_msg = Message{
			    Message::Command::GuestRecv,
			    Message::SubCommand::GuestRecv_FromGuest,
			    Message::Channel::Data,
			    Message::PayloadSize{MainClient::kMaxSingleVirtIOTransfer}
			};

			if (auto res = _data_queue->recv_message(&incoming_msg); kIOReturnSuccess != res) {
				os_log_error(
				    _logger,
				    "Failed to receive assigned data for buffer [0x%llx] at offset [0x%llx] error [0x%x]",
				    buffer_id,
				    offset,
				    res
				);
				return res;
			}

			if ((static_cast<uint64_t>(buffer_id) != incoming_msg._header.additional_values[0]) ||
			    (offset != incoming_msg._header.additional_values[1])) {
				os_log_error(
				    _logger,
				    "Faield to receive assigned data because of mismatches: either buf id [0x%llx] != [0x%llx] or offset [%llu] != "
				    "[%llu]",
				    buffer_id,
				    incoming_msg._header.additional_values[0],
				    offset,
				    incoming_msg._header.additional_values[1]
				);
				return kIOReturnInternalError;
			}

			tag.value[0] = incoming_msg._header.additional_values[2];
			tag.value[1] = incoming_msg._header.additional_values[3];

			auto curr_chunk_offset = incoming_msg._header.additional_values[5];
			auto curr_chunk_start  = buffer_start + curr_chunk_offset;
			auto curr_chunk_size   = incoming_msg._header.additional_values[6];

			if (0 != copyout(incoming_msg.get_payload(), curr_chunk_start, curr_chunk_size)) {
				os_log_error(
				    _logger,
				    "Failed to copy incoming data to user buffer [0x%llx] size [%lld] at chunk [%llu] with chunk_size [%llu]",
				    buffer_id,
				    buffer_size,
				    curr_chunk,
				    curr_chunk_size
				);
				return kIOReturnInternalError;
			}

			auto remaining_chunks = incoming_msg._header.additional_values[7];
			if ((0 == remaining_chunks) && (curr_chunk != virtio_chunks - 1)) {
				DEV_LOG(
				    _logger,
				    "Received the last chunk at chunk id [%llu] compared to total chunk expected [%llu], it might be out-of-order "
				    "and it's an expected behavior.",
				    curr_chunk,
				    virtio_chunks
				);
			}
		}

		return kIOReturnSuccess;
	});
}

/* TODO: this may not be an informative func name, it receives a batch of data, but depending on the batch size it may not cover all
 * the chunks.
 */
IOReturn
AppleVirtMeshDriver::recv_all_assigned_data(
    MainClient::BufferId     buffer_id,
    uint64_t &               count_batch,
    uint64_t *&              offset_received_out,
    MainClient::CryptoTag *& tag_out
)
{
	using enum MainClient::MeshDirection;
	return with_shared_memory(this, buffer_id, [&](auto, auto shared_memory) {
		DEV_LOG(_logger, "Receiving assigned data batch for buffer [%llu] with batch size [%llu]", buffer_id, count_batch);

		auto buffer_chunk_size = shared_memory->get_assignment_size();

		/**
		 * @brief CIOMesh kext uses a producer-consumer approach to get batched data. In VirtMesh it can get quite complicated:
		 * specifically the producer thread--the VirtIOChannel thread that continuously receives messages from the host--would
		 * hit EFAULT when copyout data to userspace from its own thread context.  Because the user buffer's IOMemoryDescriptor is
		 * created in Driver thread, and there's no easy way of implementing such a dual-thread access. So the workaround is to have
		 * the current function actively receiving the specified number of messages from the host.
		 *
		 * @todo CIOMesh kext has a timeout and interrup check, ignoring it for now but may need to implement them if upper level
		 * logic needs them.
		 */

		auto assignement_count = shared_memory->get_assignment_count();
		if (assignement_count == 0) {
			os_log_error(_logger, "Failed to receive all assigned data: total assignments is zero");
			assert(assignement_count != 0);
		}

		uint64_t total_virtio_chunks = 0;
		for (uint64_t i = 0; i < shared_memory->get_assignment_count(); i++) {
			AppleVirtMeshAssignment * assignment;
			if (auto res = shared_memory->get_assignment_at_index(i, assignment); res != kIOReturnSuccess) {
				os_log_error(_logger, "Failed to iterate assignments to calculate total chunks");
				assert(false);
			}
			if (assignment->get_direction() == MainClient::MeshDirection::In) {
				total_virtio_chunks++;
			}
		}

		total_virtio_chunks *= get_virtio_chunks(shared_memory->_config.chunkSize);

		DEV_LOG(
		    _logger,
		    "AppleVirtMeshDriver::recv_all_assigned_data() buffer_id [0x%llx] buffer_chunk_size [0x%llx] assignement_count "
		    "[0x%llx] "
		    "total_virtio_chunks [0x%llx]",
		    buffer_id,
		    buffer_chunk_size,
		    assignement_count,
		    total_virtio_chunks
		);

		/* Corresponds to caller's expected number of batches received, this function further considers
		 * virtio sub-chunks so the total number of receives is determined by `total_virtio_chunks`
		 */
		uint64_t curr_batch = 0;

		for (uint64_t curr_virtio_chunk = 0; curr_virtio_chunk < total_virtio_chunks; curr_virtio_chunk++) {
			DEV_LOG(
			    _logger,
			    "AppleVirtMeshDriver::recv_all_assigned_data() curr virtio chunk [%llu] total [%llu]",
			    curr_virtio_chunk,
			    total_virtio_chunks
			);

			auto max_payload_size = shared_memory->_config.chunkSize < MainClient::kMaxSingleVirtIOTransfer
			                            ? shared_memory->_config.chunkSize
			                            : MainClient::kMaxSingleVirtIOTransfer;

			auto incoming_msg = Message{
			    Message::Command::GuestRecv,
			    Message::SubCommand::GuestRecv_FromGuest,
			    Message::Channel::Data,
			    Message::PayloadSize{max_payload_size}
			};

			if (auto res = _data_queue->recv_message(&incoming_msg); kIOReturnSuccess != res) {
				os_log_error(
				    _logger,
				    "Failed to receive data batches for buffer [%llu], failed at batch virtio sub chunk iter [%llu]",
				    buffer_id,
				    curr_virtio_chunk
				);
				return res;
			}

			DEV_LOG(
			    _logger,
			    "AppleVirtMeshDriver::recv_all_assigned_data() incoming msg "
			    "payload_size = [0x%llx] "
			    "additional_values[0] = [0x%llx] "
			    "additional_values[1] = [0x%llx] "
			    "additional_values[2] = [0x%llx] "
			    "additional_values[3] = [0x%llx] "
			    "additional_values[4] = [0x%llx] "
			    "additional_values[5] = [0x%llx] "
			    "additional_values[6] = [0x%llx] "
			    "additional_values[7] = [0x%llx] ",
			    incoming_msg._header.payload_size,
			    incoming_msg._header.additional_values[0],
			    incoming_msg._header.additional_values[1],
			    incoming_msg._header.additional_values[2],
			    incoming_msg._header.additional_values[3],
			    incoming_msg._header.additional_values[4],
			    incoming_msg._header.additional_values[5],
			    incoming_msg._header.additional_values[6],
			    incoming_msg._header.additional_values[7]
			);

			auto incoming_buffer_id     = incoming_msg._header.additional_values[0];
			auto incoming_buffer_offset = incoming_msg._header.additional_values[1];

			if (static_cast<uint64_t>(buffer_id) != incoming_buffer_id) {
				os_log_error(_logger, "Expect buffer id [%llu] but got [%llu]", buffer_id, incoming_buffer_id);
				return kIOReturnInternalError;
			}

			auto copy_buffer_res = with_assignment(this, buffer_id, incoming_buffer_offset, In, [&](auto, auto, auto) {
				auto buffer_start             = shared_memory->_config.address + incoming_buffer_offset;
				auto curr_virtio_chunk_offset = incoming_msg._header.additional_values[5];
				auto curr_virtio_chunk_start  = buffer_start + curr_virtio_chunk_offset;
				auto curr_virtio_chunk_size   = incoming_msg._header.additional_values[6];

				/* Copy out buffer chunk */
				if (auto copy_res = copyout(incoming_msg.get_payload(), curr_virtio_chunk_start, curr_virtio_chunk_size);
				    0 != copy_res) {
					os_log_error(
					    _logger,
					    "Failed to copy the incoming buffer chunk (id [%llu] offset [%llu]) at virtio chunk (start [0x%llx] size "
					    "[%llu]) to user buffer [0x%llx] with size [%llu]: error [0x%x]",
					    buffer_id,
					    incoming_buffer_offset,
					    curr_virtio_chunk_start,
					    curr_virtio_chunk_size,
					    buffer_start,
					    buffer_chunk_size,
					    copy_res
					);
					return kIOReturnInternalError;
				}

				auto remaining_virtio_chunks = incoming_msg._header.additional_values[4];
				if (remaining_virtio_chunks == 0) {
					/* This is the last virtio chunk of this buffer chunk, assign output values. This avoids writing the same output
					 * values many times, to save a bit of performance.
					 *
					 * Note: it's not necessarily the last virtio chunk we receive for this buffer chunk, because if send is
					 * out-of-order, this 'last chunk' may arrive earlier than other virtio chunks of this buffer chunk. So the
					 * total number of virtio chunk received should be guarded by `total_virtio_chunks`, not by determining how mnay
					 * 'last chunks' have been received.
					 */
					offset_received_out[curr_batch] = incoming_buffer_offset;
					tag_out[curr_batch].value[0]    = incoming_msg._header.additional_values[2];
					tag_out[curr_batch].value[1]    = incoming_msg._header.additional_values[3];
					curr_batch++;
				}

				return kIOReturnSuccess;
			});

			if (kIOReturnSuccess != copy_buffer_res) {
				os_log_error(_logger, "Failed to copy buffer results [0x%x]", copy_buffer_res);
				return copy_buffer_res;
			}
		}

		return kIOReturnSuccess;
	});
}

/* Define driver member variable's setters */
#define GATED_PROPERTY_SET(prop_type, prop_name, check_active)                      \
	IOReturn AppleVirtMeshDriver::set_##prop_name##_gated(void * prop_name)         \
	{                                                                               \
		if (check_active && _active) {                                              \
			os_log_error(_logger, "Failed to set %s after activation", #prop_name); \
			return kIOReturnBusy;                                                   \
		}                                                                           \
                                                                                    \
		auto prop_name##_input = static_cast<const prop_type *>(prop_name);         \
		memcpy(&this->_##prop_name, prop_name##_input, sizeof(prop_type));          \
                                                                                    \
		return kIOReturnSuccess;                                                    \
	}

/* clang-format off */
GATED_PROPERTY_SET(ConfigClient::NodeId, 				node_id				, true );
GATED_PROPERTY_SET(ConfigClient::ChassisId, 			chassis_id			, true );
GATED_PROPERTY_SET(ConfigClient::AppleCIOMeshCryptoKey, user_key			, false);
GATED_PROPERTY_SET(ConfigClient::CryptoFlags,			crypto_flags		, false);
GATED_PROPERTY_SET(uint64_t,							buffers_allocated	, true );
GATED_PROPERTY_SET(ConfigClient::EnsembleSize,			ensemble_size		, true );
GATED_PROPERTY_SET(uint64_t,							max_wait_time		, false);
/* clang-format on */
