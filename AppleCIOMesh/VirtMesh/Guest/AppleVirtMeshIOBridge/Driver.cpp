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
//  AppleVirtMeshIOBridge
//
// Created by Zixuan Wang on 11/13/24.
//

#include "VirtMesh/Guest/AppleVirtMeshIOBridge/Driver.h"
#include "VirtMesh/Guest/AppleVirtMeshIOBridge/Transaction.h"
#include "VirtMesh/Utils/Log.h"
#include <AppleVirtIO/AppleVirtIOQueue.hpp>
#include <AppleVirtIO/AppleVirtIOTransport.hpp>
#include <AssertMacros.h>
#include <IOKit/IOCommandGate.h>
#include <IOKit/IOCommandPool.h>
#include <IOKit/IOReturn.h>
#include <kern/queue.h>
#include <libkern/c++/OSSharedPtr.h>
#include <os/log.h>
#include <virtio/virtio_config.h>

using namespace VirtMesh::Guest::Bridge;

OSDefineMetaClassAndStructors(AppleVirtMeshIOBridgeDriver, super);

static constexpr size_t kMaxTransactions = 4;

bool
AppleVirtMeshIOBridgeDriver::start(IOService * provider)
{
	construct_logger();
	DEV_LOG(_logger, "AppleVirtMeshIOBridgeDriver: Start");

	if (!super::start(provider)) {
		os_log_error(_logger, "Super class failed to start");
		return false;
	}

	_terminating = false;
	_stopping    = false;

	auto providerTransport = OSDynamicCast(AppleVirtIOTransport, provider);
	if (providerTransport == nullptr) {
		os_log_error(_logger, "Provider transport object is null");
		return false;
	}
	_transport.reset(providerTransport, OSRetain);

	init_work_loop();

	_transport->updateStatus(VIRTIO_CONFIG_S_ACKNOWLEDGE);
	_transport->updateStatus(VIRTIO_CONFIG_S_DRIVER);

	auto deviceFeatures = _transport->getDeviceFeatures();
	DEV_LOG(_logger, "AppleVirtMeshIOBridgeDriver: Start deviceFeatures: %llx", deviceFeatures);

	if (0 == (deviceFeatures & (1ULL << VIRTIO_F_VERSION_1))) {
		os_log_error(_logger, "VirtIO device feature is not version 1");
		return false;
	}

	auto driverFeatures = _transport->getTransportFeatures();

	/* Write out the features we support. */
	if (kIOReturnSuccess != _transport->finalizeGuestFeatures(deviceFeatures & driverFeatures)) {
		os_log_error(_logger, "Failed to finalize guest features to VirtIO");
		return false;
	}

	/* Tell the device that we've completed writing the features we support. */
	if (!_transport->updateStatus(VIRTIO_CONFIG_S_FEATURES_OK)) {
		DEV_LOG(_logger, "AppleVirtMeshIOBridgeDriver: Start device reject our feature: %0llx", driverFeatures);
		_transport->updateStatus(VIRTIO_CONFIG_S_FAILED);
		_work_loop->removeEventSource(_command_gate.get());
		os_log_error(_logger, "Start device reject our feature: %0llx", driverFeatures);
		return false;
	}

	if (!init_queue_handlers()) {
		os_log_error(_logger, "Failed to init queue handlers");
		return false;
	}

	_transport->setInterruptsEnabled(true);

	_transport->updateStatus(VIRTIO_CONFIG_S_DRIVER_OK);

	registerService();

	DEV_LOG(_logger, "Start done");
	return true;
}

void
AppleVirtMeshIOBridgeDriver::init_work_loop()
{
	/* NOTE: AppleVirtualPlatform's Identity plugin borrows _transport's work_loop, may not be necessary to do so here. */
	_command_gate = IOCommandGate::commandGate(this);
	_work_loop    = IOWorkLoop::workLoop();
	_work_loop->addEventSource(_command_gate.get());
	_command_pool = IOCommandPool::withWorkLoop(_work_loop.get());

	/* Pre allocate commands to reduce allocation overhead at runtime */
	for (size_t i = 0; i < kMaxTransactions; i++) {
		auto curr = AppleVirtMeshIOTransaction::transaction();
		_command_pool->returnCommand(curr.detach());
	}
}

bool
AppleVirtMeshIOBridgeDriver::init_queue_handlers()
{
	DEV_LOG(_logger, "AppleVirtMeshIOBridgeDriver: Set up general message queue");

	auto queue = _transport->allocateQueue(0, this, &AppleVirtMeshIOBridgeDriver::general_queue_event_handler, nullptr);
	if (nullptr == queue) {
		os_log_error(_logger, "Failed to allocate general queue");
		return false;
	}

	_queue.reset(queue, OSNoRetain);

	DEV_LOG(_logger, "AppleVirtMeshIOBridgeDriver: initialized general queue with size %d", _queue->getQueueSize());

	return true;
}

void
AppleVirtMeshIOBridgeDriver::stop(IOService * provider)
{
	DEV_LOG(_logger, "AppleVirtMeshIOBridgeDriver: Stop");

	_stopping = true;

	assert(_work_loop);

	if (_command_gate) {
		_work_loop->removeEventSource(_command_gate.get());
	}

	if (_queue) {
		_transport->freeQueue(_queue.get());
	}

	super::stop(provider);
}

bool
AppleVirtMeshIOBridgeDriver::willTerminate(IOService * provider, IOOptionBits options)
{
	DEV_LOG(_logger, "AppleVirtMeshIOBridgeDriver: WillTerminate");
	_terminating = true;
	return super::willTerminate(provider, options);
}

bool
AppleVirtMeshIOBridgeDriver::didTerminate(IOService * provider, IOOptionBits options, bool * defer)
{
	DEV_LOG(_logger, "AppleVirtMeshIOBridgeDriver: DidTerminate");

	/* All inflight transmit I/O has completed, safe to tear down stack. */
	return IOService::didTerminate(provider, options, defer);
}

template <typename T>
T
AppleVirtMeshIOBridgeDriver::runBlock(T (^block)(void))
{
	__block T result{};
	_command_gate->runActionBlock(^{
	  result = block();
	  return kIOReturnSuccess;
	});
	return result;
}

IOReturn
AppleVirtMeshIOBridgeDriver::send_message(const Message * message)
{
	return runBlock(^{ return send_message_gated(message); });
}

IOReturn
AppleVirtMeshIOBridgeDriver::recv_message(Message * message)
{
	return runBlock(^{ return recv_message_gated(message); });
}

IOReturn
AppleVirtMeshIOBridgeDriver::send_message_gated(const Message * message)
{
	DEV_LOG(_logger, "AppleVirtMeshIOBridgeDriver: send_message_gated()");
	IOReturn                                result = kIOReturnError;
	OSSharedPtr<AppleVirtMeshIOTransaction> transaction;

	transaction = OSDynamicPtrCast<AppleVirtMeshIOTransaction>(_command_pool->getCommand(false));
	if (!transaction) {
		transaction = AppleVirtMeshIOTransaction::transaction();
	}
	DEV_LOG(_logger, "AppleVirtMeshIOBridgeDriver: send_message_gated() require transaction initialized");
	require(transaction, exit);

	DEV_LOG(_logger, "AppleVirtMeshIOBridgeDriver: send_message_gated() craft request message");
	require(transaction->encodeMessage(message, true), exit);

	result = _queue->addTransaction(transaction.get());
	if (kIOReturnSuccess != result) {
		os_log_error(_logger, "AppleVirtMeshIOBridgeDriver: send_message_gated() add transaction failed %016x", result);
		goto exit;
	}

	/* NOTE: no crash if return error here */

	DEV_LOG(_logger, "AppleVirtMeshIOBridgeDriver: send_message_gated() done");
	result = kIOReturnSuccess;

exit:
	/* NOTE: the following code causes crash during multiple user space calls, no idea why but commenting it out would workaround.
	 * Not sure if commenting will cause other issues, this code is copied from AppleVirtioPlatform. */

	/* if (transaction) {
	 *    _command_pool->returnCommand(transaction.detach());
	 *}
	 */

	return result;
}

IOReturn
AppleVirtMeshIOBridgeDriver::recv_message_gated(Message * message)
{
	DEV_LOG(_logger, "AppleVirtMeshIOBridgeDriver: (blocking) recv_message_gated()");
	IOReturn                                result = kIOReturnError;
	OSSharedPtr<AppleVirtMeshIOTransaction> transaction;

	transaction = AppleVirtMeshIOTransaction::transaction();

	if (message->_header.command != Message::Command::GuestRecv) {
		os_log_error(
		    _logger,
		    "Wrong message command, got [0x%hx] but expect [0x%hx]",
		    message->_header.command,
		    Message::Command::GuestRecv
		);
		return kIOReturnBadArgument;
	}

	if (!transaction->encodeMessage(message, false)) {
		os_log_error(_logger, "Failed to encode message");
		return kIOReturnBadArgument;
	}

	if (kIOReturnSuccess != _queue->addTransaction(transaction.get())) {
		os_log_error(_logger, "Failed to add message transaction");
		return kIOReturnDeviceError;
	}

	_queue->notify();

	DEV_LOG(_logger, "AppleVirtMeshIOBridgeDriver: (blocking) recv_message_gated() waiting to receive message");

	/* commandSleep() requires to run inside a command gate, othersize it panic the kernel and crashes the guest vm before any
	 * meaningful log is printed.
	 */
	result = _command_gate->commandSleep(transaction.get());
	if (result != THREAD_AWAKENED) {
		os_log_error(_logger, "Thread awakened with error: 0x%x", result);
		return kIOReturnUnsupported;
	}

	/* TODO: Need to check if the input message pointer contains the enough data[] array to store the decoded message */
	DEV_LOG(
	    _logger,
	    "AppleVirtMeshIOBridgeDriver: (blocking) recv_message_gated() resuming from queue event, decoding received message"
	);

	/* Reset message object to use it for deserialization */
	message->reset();
	if (!transaction->decodeMessage(message)) {
		os_log_error(_logger, "Failed to decode message");
		return kIOReturnError;
	}

	/* FIXME: the host could return an all zeroed message, which should be treated as an error because the host may have a bug for
	 * not replying with any meaningful message. */
	if (message->_header.sub_command == Message::SubCommand::Error) {
		os_log_error(_logger, "Host returned an error: 0x%llx", message->_header.value);
		return kIOReturnError;
	}

	return kIOReturnSuccess;
}

void
AppleVirtMeshIOBridgeDriver::general_queue_event_handler(OSObject * owner, AppleVirtIOQueue * queue, void __unused * ref_con)
{
	auto messenger = OSDynamicCast(AppleVirtMeshIOBridgeDriver, owner);
	assert(messenger);
	messenger->general_queue_event_handler(queue);
}

void
AppleVirtMeshIOBridgeDriver::general_queue_event_handler(AppleVirtIOQueue * queue)
{
	runBlock(^{
	  DEV_LOG(_logger, "AppleVirtMeshIOBridgeDriver: general_queue_event_handler()");
	  uint32_t length = 0;
	  while (auto transaction = OSRequiredCast(AppleVirtMeshIOTransaction, queue->getTransaction(&length))) {
		  _command_gate->commandWakeup(transaction);
		  transaction->release();
	  }
	  return kIOReturnSuccess;
	});
}

uint32_t
AppleVirtMeshIOBridgeDriver::get_hardware_node_id()
{
	if (_hardware_node_id == UINT32_MAX) {
		auto message = Message{
		    Message::Command::GuestRecv,
		    Message::SubCommand::GuestRecv_GetNodeId,
		    Message::Channel::General,
		    Message::PayloadSize{0}
		};

		auto res = recv_message(&message);
		if (kIOReturnSuccess != res) {
			os_log_error(_logger, "Failed to get hardware node id: 0x%x", res);
			return UINT32_MAX;
		}

		_hardware_node_id = message._header.src_node;
	}

	return _hardware_node_id;
}
