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
//  Plugin.h
//  AppleVirtMeshPlugin
//
//  Created by Zixuan Wang on 11/18/24.
//

#pragma once

#include "VirtMesh/Utils/Message.h"
#include <AssertMacros.h>
#include <Virtualization/Virtualization_Private.h>
#include <chrono>
#include <deque>
#include <expected>
#include <functional>
#include <limits>
#include <mach-o/dyld.h>
#include <memory>
#include <os/log.h>
#include <string>
#include <system_error>
#include <thread>

namespace VirtMesh::Host::Plugin
{

class AppleVirtMeshPlugin
{
  private:
	dispatch_queue_t _dispatch_queue = dispatch_queue_create("com.apple.AppleVirtMeshPlugin.MessageQueue", DISPATCH_QUEUE_SERIAL);
	/**
	 * @brief Incoming messages from other plugins
	 */
	using message_queue_t = std::deque<std::shared_ptr<Message>>;
	/* TODO: remove the usage of array */
	std::array<message_queue_t, int(Message::Channel::TotalChannels)> _incoming_channels;

	/**
	 * @brief Requests from guest, waiting for messages from other plugins (i.e., other guests) thgough the corresponding channel.
	 */
	using request_queue_t = std::deque<_VZVirtioQueueElement *>;
	std::array<request_queue_t, int(Message::Channel::TotalChannels)> _pending_requests;

	/* Peer node info */
	static constexpr uint32_t node_id_invalid = std::numeric_limits<uint32_t>::max();
	xpc_session_t             _peer_endpoint  = nullptr;
	uint32_t                  _this_node_id   = node_id_invalid;
	uint32_t                  _peer_node_id   = node_id_invalid;

	/* Message channel methods */
  private:
	void                     enqueue(std::shared_ptr<Message> msg);
	std::shared_ptr<Message> dequeue(Message::Channel channel);
	void                     process_requests(Message::Channel channel);

	/* XPC methods: submit brokers, connect to brokers and peers, and handle incoming messages */
  public:
	void xpc_init(void);
	void set_node_id(uint32_t this_node_id);

  private:
	void connect_to_broker(
	    xpc_session_incoming_message_handler_t  broker_message_handler,
	    xpc_listener_incoming_session_handler_t peer_message_handler
	);
	void submit_broker();
	void register_with_broker(xpc_session_t session, xpc_listener_incoming_session_handler_t peer_handler);
	void handle_session_from_peer(xpc_session_t peer);
	void handle_message_from_broker(xpc_object_t message);
	void send_message_to_peer(xpc_session_t peer, Message * message);

	os_log_t _logger = os_log_create("com.apple.AppleVirtMesh", "Plugin");

	/* VirtIO methods: process VirtIO queue element, used by the IOBridgePlugin */
  public:
	void process_guest_element(_VZVirtioQueueElement *);

  private:
	enum class ElementOperation : int {
		ReturnToQueue = 0, /* Return the element to the guest */
		HoldAtPlugin  = 1, /* Hold the element at the plugin, return it later when the requested data arrives */
	};

	void issue_pending_request(_VZVirtioQueueElement * element, Message::Channel channel);
	bool
	is_connection_valid()
	{
		if (_this_node_id == node_id_invalid || _peer_node_id == node_id_invalid || _peer_endpoint == nullptr) {
			return false;
		}
		return true;
	}

	std::expected<std::shared_ptr<Message>, std::error_code> decode_element(_VZVirtioQueueElement *);

	using process_result_t = std::expected<ElementOperation, std::error_code>;
	process_result_t process_guest_send(_VZVirtioQueueElement *, Message *);
	process_result_t process_guest_recv(_VZVirtioQueueElement *, Message *);

	std::expected<void, std::error_code> reply_to_guest(_VZVirtioQueueElement *, std::shared_ptr<Message> message, bool immediate);
	std::expected<void, std::error_code> reply_error_immediately(_VZVirtioQueueElement *, Message::ErrorCode);

	std::expected<void, std::error_code> encode_element(_VZVirtioQueueElement * element, std::shared_ptr<Message> message);
};

}; // namespace VirtMesh::Host::Plugin
