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
//  Plugin.cpp
//  AppleVirtMeshPlugin
//
//  Created by Zixuan Wang on 11/18/24.
//

#include "VirtMesh/Host/AppleVirtMeshPlugin/Plugin.h"
#include "VirtMesh/Host/AppleVirtMeshPlugin/BrokerSubmitter.h"
#include "VirtMesh/Utils/Log.h"
#include <AppServerSupport/AppServerSupport.h>
#include <CoreFoundation/CFXPCBridge.h>
#include <Foundation/Foundation.h>
#include <launch_priv.h>
#include <memory>
#include <unistd.h>
#include <xpc/private.h>

using namespace VirtMesh;
using namespace VirtMesh::Host::Plugin;

void
AppleVirtMeshPlugin::enqueue(std::shared_ptr<Message> msg)
{
	dispatch_sync(_dispatch_queue, ^{
	  DEV_LOG(_logger, "AppleVirtMeshPlugin: enqueue msg with command [%hu]", msg->_header.command);
	  /* TODO: check if enum is out of bound */
	  auto channel = msg->_header.channel;
	  if (channel >= Message::Channel::TotalChannels) {
		  os_log_error(_logger, "AppleVirtMeshPlugin: message channel out of bound [%hhu]", msg->_header.channel);
		  return;
	  }

	  _incoming_channels[static_cast<uint8_t>(channel)].push_back(std::move(msg));
	  process_requests(msg->_header.channel);
	});
}

/**
 * @brief Try to dequeue the requests and reply to guest if success.
 */
void
AppleVirtMeshPlugin::process_requests(Message::Channel channel)
{
	auto channel_idx = static_cast<uint8_t>(channel);
	DEV_LOG(_logger, "AppleVirtMeshPlugin[%d]: processing request queue %hhu", _this_node_id, channel_idx);

	if (_pending_requests[channel_idx].empty()) {
		DEV_LOG(
		    _logger,
		    "AppleVirtMeshPlugin[%d] queue [%hhu]: no guest is requesting message from this queue, skipping",
		    _this_node_id,
		    channel_idx
		);
		return;
	}

	if (_incoming_channels[channel_idx].empty()) {
		DEV_LOG(
		    _logger,
		    "AppleVirtMeshPlugin[%d] queue [%hhu]: no incoming message from other plugins, skipping",
		    _this_node_id,
		    channel_idx
		);
		return;
	}

	DEV_LOG(_logger, "AppleVirtMeshPlugin[%d]: replying one request from queue %hhu", _this_node_id, channel_idx);

	auto element = _pending_requests[channel_idx].front();
	auto message = _incoming_channels[channel_idx].front();

	auto res = reply_to_guest(element, message, true);
	if (!res) {
		os_log_error(
		    _logger,
		    "AppleVirtMeshPlugin: Failed to reply to guest from the pending requests %s",
		    res.error().message().c_str()
		);
		while (true) {}; /* TODO: need a more meaningful error handling than busy hanging. */
	} else {
		_pending_requests[channel_idx].pop_front();
		_incoming_channels[channel_idx].pop_front();
	}
}

void
AppleVirtMeshPlugin::issue_pending_request(_VZVirtioQueueElement * element, Message::Channel channel)
{
	auto channel_idx = static_cast<uint8_t>(channel);

	DEV_LOG(_logger, "AppleVirtMeshPlugin[%d]: issue pending request to channel %hhu", _this_node_id, channel_idx);

	dispatch_sync(_dispatch_queue, ^{
	  _pending_requests[channel_idx].push_back(element);

	  process_requests(channel);
	});
}

void
AppleVirtMeshPlugin::xpc_init()
{
	os_log(_logger, "AppleVirtMeshPlugin: xpc_init()");

	submit_broker();

	os_log_info(_logger, "AppleVirtMeshPlugin: borker submition finished, now connecting to the broker");

	connect_to_broker(
	    ^(xpc_object_t message) { this->handle_message_from_broker(message); },
	    ^(xpc_session_t peer) { this->handle_session_from_peer(peer); }
	);
}

void
AppleVirtMeshPlugin::submit_broker()
{
	/* TODO: I suspect that the following submit process has some timing issue that causes one plugin's `_peer_endpoint` to be
	 * invalid. My hypophesis is: plugin A launches first and submit the broker, then the plugin B launches, tries but fails to
	 * submit the broker, at this time the broker has not yet fully started but B already started the follow-up processes, which do
	 * not actually hit the broker and thus not communicating with A.
	 *
	 * An evidence: when this crash happens, the host log shows that broker only got one plugin connection.
	 */
	plugin_submit_broker();
}

void
AppleVirtMeshPlugin::register_with_broker(xpc_session_t session, xpc_listener_incoming_session_handler_t peer_handler)
{
	xpc_listener_t listener     = xpc_listener_create_anonymous(dispatch_get_main_queue(), XPC_LISTENER_CREATE_NONE, peer_handler);
	xpc_object_t   registration = xpc_dictionary_create_empty();
	uuid_t         own_instance;

	if (xpc_get_instance(own_instance)) {
		xpc_dictionary_set_uuid(registration, "instance", own_instance);
	}
	xpc_dictionary_set_value(registration, "endpoint", xpc_listener_create_endpoint(listener));

	xpc_rich_error_t error = xpc_session_send_message(session, registration);
	if (error != nil) {
		os_log_error(_logger, "AppleVirtMeshPlugin: error registering with broker - %@", error);
	}
}

void
AppleVirtMeshPlugin::connect_to_broker(
    xpc_session_incoming_message_handler_t  broker_handler,
    xpc_listener_incoming_session_handler_t peer_handler
)
{
	xpc_rich_error_t error   = nil;
	xpc_session_t    session = xpc_session_create_mach_service(
        "com.apple.AppleVirtMeshBroker",
        dispatch_get_main_queue(),
        XPC_SESSION_CREATE_INACTIVE,
        &error
    );

	if (session == nil) {
		os_log_error(_logger, "AppleVirtMeshPlugin: error connecting to broker - %s", xpc_rich_error_copy_description(error));
		return;
	}

	xpc_session_set_incoming_message_handler(session, broker_handler);
	xpc_session_set_cancel_handler(session, ^(xpc_rich_error_t error) {
	  os_log(_logger, "AppleVirtMeshPlugin: error on broker session - %s", xpc_rich_error_copy_description(error));
	  if (xpc_rich_error_can_retry(error)) {
		  os_log(_logger, "AppleVirtMeshPlugin: re-connecting to broker");
		  this->connect_to_broker(broker_handler, peer_handler);
	  }
	  xpc_session_cancel(session); // retain the session until it errors out
	});

	xpc_session_activate(session, &error);
	register_with_broker(session, peer_handler);
}

void
AppleVirtMeshPlugin::handle_session_from_peer(xpc_session_t peer)
{
	xpc_session_set_incoming_message_handler(peer, ^(xpc_object_t message) {
	  /* Decode the incoming message payload, then enqueue it to corresponding message queue based on message->channel */
	  size_t payload_len = 0;
	  auto   payload     = xpc_dictionary_get_data(message, "message", &payload_len);

	  auto decoded = std::make_shared<Message>();
	  decoded->decode(payload, payload_len);

	  DEV_LOG(
		  _logger,
		  "AppleVirtMeshPlugin[%d]: Plugin received a message from peer plugin: command [%hu], sub-command [%hhu], "
		  "channel [%hhu], "
		  "value [%llu], "
		  "src_node [%u], "
		  "payload_size [%llu]",
		  _this_node_id,
		  decoded->_header.command,
		  decoded->_header.sub_command,
		  decoded->_header.channel,
		  decoded->_header.value,
		  decoded->_header.src_node,
		  decoded->_header.payload_size
	  );

	  if (decoded->_header.command == Message::Command::GuestSend) {
		  enqueue(decoded);
	  }
	});
}

void
AppleVirtMeshPlugin::send_message_to_peer(xpc_session_t peer, Message * message)
{
	auto buffer_size = message->size();
	auto buffer      = reinterpret_cast<uint8_t *>(malloc(buffer_size));
	message->encode(buffer, &buffer_size);

	xpc_object_t payload = xpc_dictionary_create_empty();
	xpc_dictionary_set_data(payload, "message", buffer, message->size());

	free(buffer);

	xpc_rich_error_t error = xpc_session_send_message(peer, payload);
	if (error != nil) {
		os_log_error(_logger, "AppleVirtMeshPlugin: failed to send a message to peer - %s", xpc_rich_error_copy_description(error));
	}
}

void
AppleVirtMeshPlugin::set_node_id(uint32_t this_node_id)
{
	if (this_node_id > 1) {
		os_log_error(_logger, "AppleVirtMeshPlugin: Node ID invalid: [%u]", this_node_id);
		return;
	}

	_this_node_id = this_node_id;
	_peer_node_id = 1 - this_node_id;

	DEV_LOG(_logger, "AppleVirtMeshPlugin: this_node_id [%u] peer_node_id [%u]", _this_node_id, _peer_node_id);
}

void
AppleVirtMeshPlugin::handle_message_from_broker(xpc_object_t message)
{
	xpc_object_t     endpoint = xpc_dictionary_get_value(message, "peer");
	xpc_rich_error_t error    = nil;
	xpc_session_t    peer = xpc_session_create_xpc_endpoint(endpoint, dispatch_get_main_queue(), XPC_SESSION_CREATE_NONE, &error);
	if (peer != nil) {
		_peer_endpoint = peer;
	} else {
		os_log_error(_logger, "AppleVirtMeshPlugin: error connecting to peer - %s", xpc_rich_error_copy_description(error));
	}
}

std::expected<std::shared_ptr<Message>, std::error_code>
AppleVirtMeshPlugin::decode_element(_VZVirtioQueueElement * element)
{
	NSError * error              = nil;
	auto      guest_message_size = element.readBuffersAvailableByteCount;

	/* TODO: According to readBytes() doc, the returned pointer is a new NSData buffer holding the data, do we need to free it once
	 * the buffer is consumed? I think the NSData is auto deallocated once the ref to it is invalid?
	 */
	auto payload = [element readBytes:guest_message_size error:&error];
	if (error) {
		return std::unexpected{std::make_error_code(std::errc::bad_message)};
	}

	/* TODO: Continue from here Jan 07 10:56 */
	/* TODO: Try to reduce the buffer copy here, this function already has two, readBytes() and decode(). Maybe hold the raw
	 * `payload` pointer and decode only the header for processing? */
	auto payload_buffer = (uint8_t *)[payload bytes];
	auto message        = std::make_shared<Message>();
	message->decode(payload_buffer, guest_message_size);
	return message;
}

/**
 * @brief Process guest's send requests. Such requests are non-blocking at the guest side, so always ReturnToQueue.
 */
std::expected<AppleVirtMeshPlugin::ElementOperation, std::error_code>
AppleVirtMeshPlugin::process_guest_send(_VZVirtioQueueElement __unused * element, Message * message)
{
	switch (message->_header.sub_command) {
	case Message::SubCommand::GuestSend_ToGuest:
		DEV_LOG(
		    _logger,
		    "AppleVirtMeshPlugin[%d]: Guest request to send message to peer guest, forwarding to peer plugin for further process.",
		    _this_node_id
		);

		if (!is_connection_valid()) {
			os_log_error(_logger, "XPC connection to peer is invalid");
			return std::unexpected(std::make_error_code(std::errc::connection_refused));
		}

		dev_log_dump_buffer(_logger, message->get_payload(), message->_header.payload_size);
		send_message_to_peer(_peer_endpoint, message);
		break;
	default:
		return std::unexpected(std::make_error_code(std::errc::invalid_argument));
	}

	return ElementOperation::ReturnToQueue;
}

std::expected<void, std::error_code>
AppleVirtMeshPlugin::encode_element(_VZVirtioQueueElement * element, std::shared_ptr<Message> message)
{
	NSError * error;

	/* Write the header */
	if (![element writeData:&(message->_header) length:sizeof(message->_header) error:&error]) {
		os_log_error(_logger, "Failed to encode message header: err code %lx description %@", error.code, error.description);
		return std::unexpected(std::make_error_code(std::errc::broken_pipe));
	}

	/* Write the payload if exists, the writeData() will append it to the existing buffer. */
	if ((message->_header.payload_size > 0)) {
		if (![element writeData:message->get_payload() length:message->_header.payload_size error:&error]) {
			os_log_error(
			    _logger,
			    "Failed to encode message payload: err code [%lx] description [%@] message payload size [%llu] element write "
			    "buffer size [%lu]",
			    error.code,
			    error.description,
			    message->_header.payload_size,
			    [element writeBuffersByteCount]
			);
			return std::unexpected(std::make_error_code(std::errc::broken_pipe));
		}
	}

	return {};
}

std::expected<void, std::error_code>
AppleVirtMeshPlugin::reply_to_guest(_VZVirtioQueueElement * element, std::shared_ptr<Message> message, bool immediate)
{
	/* TODO: Check if `message` is null? */

	DEV_LOG(
	    _logger,
	    "AppleVirtMeshPlugin[%d]: Replying guest with a message command [%hu], sub-command [%hhu], channel [%hhu], "
	    "value [%llu], "
	    "src_node [%u], "
	    "payload_size [%llu]",
	    _this_node_id,
	    message->_header.command,
	    message->_header.sub_command,
	    message->_header.channel,
	    message->_header.value,
	    message->_header.src_node,
	    message->_header.payload_size
	);
	dev_log_dump_buffer(_logger, message->get_payload(), message->_header.payload_size);

	auto res = encode_element(element, message);
	if (!res) {
		return std::unexpected(res.error());
	}

	if (immediate) {
		[element returnToQueue];
	}

	return {};
}

std::expected<void, std::error_code>
AppleVirtMeshPlugin::reply_error_immediately(_VZVirtioQueueElement * element, Message::ErrorCode error_code)
{
	auto origin_message = decode_element(element);
	assert(origin_message);
	auto error_message = std::make_shared<Message>(
	    Message::Command::GuestRecv,
	    Message::SubCommand::Error,
	    origin_message.value()->_header.channel,
	    static_cast<uint32_t>(error_code),
	    Message::NodeId{_this_node_id},
	    Message::PayloadSize{0},
	    nullptr
	);

	return reply_to_guest(element, error_message, true);
}

std::expected<AppleVirtMeshPlugin::ElementOperation, std::error_code>
AppleVirtMeshPlugin::process_guest_recv(_VZVirtioQueueElement * element, Message * message)
{
	auto                     op            = ElementOperation::ReturnToQueue;
	std::shared_ptr<Message> reply_message = nullptr;

	DEV_LOG(
	    _logger,
	    "AppleVirtMeshPlugin[%d]: Guest request to receive a message at channel %hhu with payload size no more than %llu",
	    _this_node_id,
	    static_cast<uint8_t>(message->_header.channel),
	    message->_header.payload_size
	);

	switch (message->_header.sub_command) {
	case Message::SubCommand::GuestRecv_FromGuest: {
		issue_pending_request(element, message->_header.channel);
		op = ElementOperation::HoldAtPlugin; /* FIXME: should check `issue_pending_requres()` result to see if the element has
		                                        alredy been returned */
		reply_message = nullptr;
	} break;
	case Message::SubCommand::GuestRecv_GetNodeId: {
		reply_message = std::make_shared<Message>(
		    Message::Command::GuestRecv,
		    Message::SubCommand::GuestRecv_GetNodeId,
		    Message::Channel::General,
		    _this_node_id,
		    Message::NodeId{_this_node_id},
		    Message::PayloadSize{0},
		    nullptr
		);
	} break;
	default: {
		return std::unexpected(std::make_error_code(std::errc::invalid_argument));
	} break;
	}

	/* TODO: refactor this logic */
	if (reply_message) {
		reply_to_guest(element, reply_message, false); /* Let the upper-level to return element */
	}
	return op;
}

void
AppleVirtMeshPlugin::process_guest_element(_VZVirtioQueueElement * element)
{
	auto message = decode_element(element);
	if (!message) {
		os_log_error(_logger, "Decode element failed");
		return;
	}

	auto message_ptr = message.value();
	DEV_LOG(
	    _logger,
	    "AppleVirtMeshPlugin[%d]: Plugin received a message from guest: command [%hu], sub-command [%hhu], channel [%hhu], "
	    "value [%llu], "
	    "payload_size [%llu]",
	    _this_node_id,
	    message_ptr->_header.command,
	    message_ptr->_header.sub_command,
	    message_ptr->_header.channel,
	    message_ptr->_header.value,
	    message_ptr->_header.payload_size
	);
	dev_log_dump_buffer(_logger, message_ptr->get_payload(), message_ptr->_header.payload_size);

	/* The guest handlers expect peer_endpoint to be valid ahead of time. */
	if (_peer_endpoint == nullptr) {
		/* FIXME: occationally the _peer_endpoint is not valid, maybe due to broker issues. In this case we should let the guest
		 * attest if _peer_endpoint is valid, through the canActivate() and some other ensemble APIs.
		 * TODO: May need a better way of report erros instead of direct crash
		 */
		os_log_error(_logger, "Failed to discover the peer plugin, intentionally crash the plugin here");
		return;
	}

	process_result_t result;

	switch (message_ptr->_header.command) {
	case Message::Command::GuestSend:
		result = process_guest_send(element, message_ptr.get());
		break;
	case Message::Command::GuestRecv:
		result = process_guest_recv(element, message_ptr.get());
		break;
	default:
		result = std::unexpected(std::make_error_code(std::errc::not_supported));
		break;
	}

	if (!result) {
		os_log_error(_logger, "Failed to process message: [%s]", result.error().message().c_str());
		reply_error_immediately(element, Message::ErrorCode::GeneralError);
		return;
	}

	if (result.value() == ElementOperation::ReturnToQueue) {
		dispatch_sync(_dispatch_queue, ^{ [element returnToQueue]; });
	}
}
