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
//  VirtIOChannel.cpp
//  AppleVirtMesh
//
//  Created by Zixuan Wang on 1/31/25.
//

#include "VirtMesh/Guest/AppleVirtMesh/VirtIOChannel.h"
#include "VirtMesh/Utils/Log.h"

#include <AppleVirtIO/AppleVirtIOQueue.hpp>
#include <AppleVirtIO/AppleVirtIOTransport.hpp>

using namespace VirtMesh::Guest::Mesh;

OSDefineMetaClassAndStructors(AppleVirtMeshVirtIOChannel, super);

static constexpr uint64_t kMaxMessageSize = 8192;

bool
AppleVirtMeshVirtIOChannel::init_workloop()
{
	construct_logger();

	_command_gate = IOCommandGate::commandGate(this);
	if (nullptr == _command_gate) {
		return false;
	}

	_work_loop = IOWorkLoop::workLoop();
	if (nullptr == _work_loop) {
		return false;
	}

	_work_loop->addEventSource(_command_gate.get());

	return true;
}

bool
AppleVirtMeshVirtIOChannel::init_virtio_queue(
    Message::Channel                  assigned_channel,
    AppleVirtMeshDriver *             owner,
    OSSharedPtr<AppleVirtIOTransport> transport
)
{
	construct_logger();

	_channel               = assigned_channel;
	_transport             = transport;
	_message_handler_owner = owner;

	_mode = VirtIOChannelMode::Active;

	auto queue = _transport->allocateQueue(
	    static_cast<uint16_t>(_channel),
	    this,
	    &AppleVirtMeshVirtIOChannel::virtio_queue_handler_wrapper,
	    nullptr
	);

	if (nullptr == queue) {
		os_log_error(_logger, "VirtIOChannel[%u]: Failed to allocate virtio queue", _channel);
		return false;
	}

	_virtio_queue.reset(queue, OSNoRetain);

	DEV_LOG(_logger, "VirtIOChannel[%u]: Initialized virtio queue with size [%d]", _channel, _virtio_queue->getQueueSize());
	return true;
}

bool
AppleVirtMeshVirtIOChannel::init_virtio_queue(
    Message::Channel                  assigned_channel,
    AppleVirtMeshDriver *             owner,
    message_handler_f                 handler,
    OSSharedPtr<AppleVirtIOTransport> transport
)
{
	if (!init_virtio_queue(assigned_channel, owner, transport)) {
		return false;
	}

	_message_handler = handler;
	_mode            = VirtIOChannelMode::Passive;

	return true;
}

bool
AppleVirtMeshVirtIOChannel::launch_once()
{
	if (_mode != VirtIOChannelMode::Passive) {
		os_log_error(
		    _logger,
		    "VirtIOChannel[%u]: Should not launch message monitoring thread in a non-passive virt io channel",
		    _channel
		);
		return false;
	}

	if (!_thread_lock) {
		_thread_lock = IOLockAlloc();
		if (!_thread_lock) {
			os_log_error(_logger, "VirtIOChannel[%u]: Failed to allocate queue thread_lock", _channel);
			return false;
		}
	}

	IOLockLock(_thread_lock);
	if (_thread_launched) {
		DEV_LOG(_logger, "VirtIOChannel[%u]: VirtIO message thread already launched", _channel);
	} else {
		DEV_LOG(_logger, "VirtIOChannel[%u]: Launching message thread", _channel);

		auto res = kernel_thread_start(reinterpret_cast<thread_continue_t>(virtio_loop_message_thread), this, &_message_thread);
		assertf(kIOReturnSuccess == res, "VirtIOChannel[%u]: Failed to launch message thread: 0x%x", _channel, res);

		_thread_launched = true;
		DEV_LOG(_logger, "VirtIOChannel[%u]: Launched message thread: 0x%x", _channel, res);
	}
	IOLockUnlock(_thread_lock);

	return true;
}

void
AppleVirtMeshVirtIOChannel::stop()
{
	if ((nullptr != _command_gate) && (nullptr != _work_loop)) {
		_work_loop->removeEventSource(_command_gate.get());
	}

	if (_virtio_queue) {
		_transport->freeQueue(_virtio_queue.get());
	}

	if (_thread_lock) {
		IOLockFree(_thread_lock);
		_thread_lock = nullptr;
		/* TODO: terminate message thread */
	}
}

void
AppleVirtMeshVirtIOChannel::virtio_queue_handler_wrapper(
    OSObject *              owner,
    AppleVirtIOQueue *      queue,
    [[maybe_unused]] void * ref_con
)
{
	auto mesh_channel = OSDynamicCast(AppleVirtMeshVirtIOChannel, owner);
	assert(mesh_channel);
	mesh_channel->virtio_queue_handler(queue);
}

void
AppleVirtMeshVirtIOChannel::virtio_queue_handler(AppleVirtIOQueue * queue [[maybe_unused]])
{
	_command_gate->runActionBlock(^{
	  uint32_t length = 0;
	  while (auto transaction = OSRequiredCast(Bridge::AppleVirtMeshIOTransaction, _virtio_queue->getTransaction(&length))) {
		  _command_gate->commandWakeup(transaction);
		  transaction->release();
	  }
	  return kIOReturnSuccess;
	});
}

void
AppleVirtMeshVirtIOChannel::virtio_loop_message_thread(void * owner, [[maybe_unused]] wait_result_t wait_result)
{
	auto mesh_channel = reinterpret_cast<AppleVirtMeshVirtIOChannel *>(owner);

	DEV_LOG(OS_LOG_DEFAULT, "Looping requests from message queue [%hu]: start", mesh_channel->_channel);

	/* It should not return, but if so, there must be some reason and we should log */
	auto res = mesh_channel->virtio_loop_message();

	os_log_error(OS_LOG_DEFAULT, "Looping requests from message queue [%hu]: end with 0x%x", mesh_channel->_channel, res);

	/* TODO: Should we set _thread_launched to false so that the next call can re-launch the loop message thread? */

	thread_terminate(current_thread());
}

IOReturn
AppleVirtMeshVirtIOChannel::virtio_loop_message()
{
	if (nullptr == _virtio_queue || nullptr == _work_loop || nullptr == _transport) {
		os_log_error(_logger, "VirtIOChannel[%u]: VirtIO set up is incomplete", _channel);
		return kIOReturnAborted;
	}

	auto transaction = Bridge::AppleVirtMeshIOTransaction::transaction();
	if (nullptr == transaction) {
		os_log_error(_logger, "VirtIOChannel[%u]: Failed to allocate transaction", _channel);
		return kIOReturnNoMemory;
	}

	while (true) {
		auto result = _command_gate->runActionBlock(^{
		  /* TODO: Consider reusing this message buffer */
		  auto message = Message{
			  Message::Command::GuestRecv,
			  Message::SubCommand::GuestRecv_FromGuest,
			  _channel,
			  Message::PayloadSize{kMaxMessageSize}
		  };

		  if (auto res = recv_message_gated(&message, transaction); kIOReturnSuccess != res) {
			  os_log_error(_logger, "VirtIOChannel[%u]: Failed to loop message in passive mode", _channel);
			  return res;
		  }

		  if (auto res = incoming_message_handler(&message); kIOReturnSuccess != res) {
			  os_log_error(_logger, "VirtIOChannel[%u]: Failed to process the incoming message, reason: 0x%x", _channel, res);
			  return res;
		  }

		  return kIOReturnSuccess;
		});

		if (kIOReturnSuccess != result) {
			os_log_error(_logger, "VirtIOChannel[%u]: failed with result 0x%x", _channel, result);
			return result;
		}
	}

	return kIOReturnOffline;
}

IOReturn
AppleVirtMeshVirtIOChannel::incoming_message_handler(Message * message)
{
	if (nullptr == _message_handler) {
		os_log_error(_logger, "VirtIOChannel[%u]: No message handler assigned", _channel);
		return kIOReturnInternalError;
	}

	return _message_handler(_message_handler_owner, _channel, message);
}

IOReturn
AppleVirtMeshVirtIOChannel::send_message(const Message * message)
{
	DEV_LOG(_logger, "AppleVirtMeshVirtIOChannel::send_message()");
	return _command_gate->runActionBlock(^{ return send_message_gated(message); });
}

IOReturn
AppleVirtMeshVirtIOChannel::recv_message(Message * message)
{
	/* Receive message explicitly should only be used in active mode. */
	if (_mode != VirtIOChannelMode::Active) {
		os_log_error(_logger, "VirtIOChannel[%u]: Should not call recv message in a non-active virt io channel", _channel);
		return kIOReturnInternalError;
	}

	return _command_gate->runActionBlock(^{ return recv_message_gated(message, nullptr); });
}

IOReturn
AppleVirtMeshVirtIOChannel::check_message(const Message * message, Message::Command expected_command)
{
	if (expected_command != message->_header.command) {
		os_log_error(
		    _logger,
		    "VirtIOChannel[%u]: Unexpected command, got [0x%hx] but expect [0x%hx]",
		    _channel,
		    message->_header.command,
		    expected_command
		);
		return kIOReturnBadArgument;
	}

	if (_channel != message->_header.channel) {
		os_log_error(
		    _logger,
		    "VirtIOChannel[%u]: Unexpected channel, got [%u] but expect [%u]",
		    _channel,
		    message->_header.channel,
		    _channel
		);
		return kIOReturnBadArgument;
	}

	return kIOReturnSuccess;
}

IOReturn
AppleVirtMeshVirtIOChannel::send_message_gated(const Message * message)
{
	DEV_LOG(
	    _logger,
	    "AppleVirtMeshVirtIOChannel::send_message_gated(): command [%hu], sub-command [%hhu], "
	    "channel [%hhu], "
	    "value [%llu], "
	    "src_node [%u], "
	    "payload_size [%llu]",
	    message->_header.command,
	    message->_header.sub_command,
	    message->_header.channel,
	    message->_header.value,
	    message->_header.src_node,
	    message->_header.payload_size
	);
	/* Send message can be used in both passive and active mode */
	if (auto res = check_message(message, Message::Command::GuestSend); kIOReturnSuccess != res) {
		os_log_error(_logger, "VirtIOChannel[%u]: message invalid", _channel);
		return res;
	}

	auto transaction = Bridge::AppleVirtMeshIOTransaction::transaction();
	if (nullptr == transaction) {
		os_log_error(_logger, "VirtIOChannel[%u]: failed to allocate VirtIO transaction", _channel);
		return kIOReturnNoMemory;
	}

	if (!transaction->encodeMessage(message, true)) {
		os_log_error(_logger, "VirtIOChannel[%u]: failed to encode message", _channel);
		return kIOReturnInternalError;
	}

	if (auto res = _virtio_queue->addTransaction(transaction.get()); kIOReturnSuccess != res) {
		os_log_error(_logger, "VirtIOChannel[%u]: failed to add send transaction: 0x%x", _channel, res);
		return res;
	}

	DEV_LOG(_logger, "AppleVirtMeshVirtIOChannel::send_message_gated() finished processing");
	return kIOReturnSuccess;
}

IOReturn
AppleVirtMeshVirtIOChannel::recv_message_gated(Message * message, OSSharedPtr<Bridge::AppleVirtMeshIOTransaction> transaction)
{
	/* Don't check virtio mode here because this func is also called from message monitoring thread in passive mode, see
	 * virtio_loop_message(). The check is done in recv_message().
	 */
	if (auto res = check_message(message, Message::Command::GuestRecv); kIOReturnSuccess != res) {
		os_log_error(_logger, "VirtIOChannel[%u]: message invalid: 0x%x", _channel, res);
		return res;
	}

	DEV_LOG(_logger, "AppleVirtMeshVirtIOChannel::recv_message_gated() allocate transaction");
	if (nullptr == transaction) {
		transaction = Bridge::AppleVirtMeshIOTransaction::transaction();
		if (nullptr == transaction) {
			os_log_error(_logger, "VirtIOChannel[%u]: failed to allocate VirtIO transaction", _channel);
			return kIOReturnNoMemory;
		}
	}

	DEV_LOG(_logger, "AppleVirtMeshVirtIOChannel::recv_message_gated() encodeMessage");
	if (!transaction->encodeMessage(message, false)) {
		os_log_error(_logger, "VirtIOChannel[%u]: failed to encode message", _channel);
		return kIOReturnInternalError;
	}

	DEV_LOG(_logger, "AppleVirtMeshVirtIOChannel::recv_message_gated() addTransaction");
	if (auto res = _virtio_queue->addTransaction(transaction.get()); kIOReturnSuccess != res) {
		os_log_error(_logger, "VirtIOChannel[%u]: failed to add recv transaction: 0x%x", _channel, res);
		return res;
	}

	DEV_LOG(_logger, "AppleVirtMeshVirtIOChannel::recv_message_gated() notify queue");
	_virtio_queue->notify();

	DEV_LOG(_logger, "AppleVirtMeshVirtIOChannel::recv_message_gated() sleep");
	if (auto res = _command_gate->commandSleep(transaction.get()); THREAD_AWAKENED != res) {
		os_log_error(_logger, "VirtIOChannel[%u]: Thread awakened with error: 0x%x", _channel, res);
		return res;
	}

	DEV_LOG(_logger, "AppleVirtMeshVirtIOChannel::recv_message_gated() decode");
	message->reset();
	if (!transaction->decodeMessage(message)) {
		os_log_error(_logger, "VirtIOChannel[%u]: Failed to decode message", _channel);
		return kIOReturnInternalError;
	}

	if (message->_header.sub_command == Message::SubCommand::Error) {
		os_log_error(
		    _logger,
		    "VirtIOChannel[%u]: Received an error from the host plugin: 0x%llx",
		    _channel,
		    message->_header.value
		);
		return kIOReturnError;
	}

	DEV_LOG(_logger, "AppleVirtMeshVirtIOChannel::recv_message_gated() done");
	return kIOReturnSuccess;
}
