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
//  VirtIOChannel.h
//  AppleVirtMesh
//
//  Created by Zixuan Wang on 1/31/25.
//

#pragma once

#include "VirtMesh/Guest/AppleVirtMeshIOBridge/Transaction.h"
#include "VirtMesh/Utils/Message.h"
#include <IOKit/IOCommandGate.h>
#include <IOKit/IOService.h>
#include <IOKit/IOWorkLoop.h>
#include <os/atomic.h>

class AppleVirtIOQueue;
class AppleVirtIOTransport;

namespace VirtMesh::Guest::Mesh
{

class AppleVirtMeshDriver;

/**
 * @brief Use `active` mode to explicitly send and receive message in this channel, use `passive` to register a message handler to
 * automatically receive message in this channel.
 */
enum class VirtIOChannelMode : uint8_t {
	Active  = 0,
	Passive = 1,
};

class AppleVirtMeshVirtIOChannel final : public OSObject
{
	OSDeclareDefaultStructors(AppleVirtMeshVirtIOChannel);
	using super             = OSObject;
	using message_handler_f = IOReturn (*)(AppleVirtMeshDriver * owner, Message::Channel channel, const Message * message);

  public:
	bool init_workloop();

	/* Provide no handler to set it in `Active` mode */
	bool
	init_virtio_queue(Message::Channel assigned_channel, AppleVirtMeshDriver * owner, OSSharedPtr<AppleVirtIOTransport> transport);

	/* Give it a handler to set it in `Passive` mode. */
	bool init_virtio_queue(
	    Message::Channel                  assigned_channel,
	    AppleVirtMeshDriver *             owner,
	    message_handler_f                 handler,
	    OSSharedPtr<AppleVirtIOTransport> transport
	);

	void stop();

	/**
	 * @brief This launches a single thread to monitor the virtio message queue, used only in `Passive` mode.
	 * @note This thread should be launched a bit later than the server set up (i.e., not launched in the start()) because
	 * launching it early will cause plugin to occasionally not getting the initial monitoring request. Although I don't know
	 * why yet, I guess it's the some part of Guest OS is not ready to actually send the message at the early stage,
	 * occasionally it does, but sometimes doesn't.
	 */
	bool launch_once();

	/**
	 * @brief Send and receive message in `Active` mode.
	 */
	IOReturn send_message(const Message * message);
	IOReturn recv_message(Message * message);

  private:
	IOReturn send_message_gated(const Message * message);
	IOReturn recv_message_gated(Message * message, OSSharedPtr<Bridge::AppleVirtMeshIOTransaction> transaction);
	IOReturn check_message(const Message * message, Message::Command expected_command);

	/* TODO: Use template to get buffer size in constexpr */
	static void virtio_queue_handler_wrapper(OSObject * owner, AppleVirtIOQueue * queue, void * ref_con);
	void        virtio_queue_handler(AppleVirtIOQueue * queue);
	static void virtio_loop_message_thread(void * owner, wait_result_t wait_result);
	IOReturn    virtio_loop_message();
	IOReturn    incoming_message_handler(Message * message);

	/* TODO: Implement a `send_message()` interface here. */

  private:
	os_log_t                          _logger          = nullptr;
	bool                              _thread_launched = false;
	IOLock *                          _thread_lock     = nullptr;
	thread_t                          _message_thread;
	message_handler_f                 _message_handler       = nullptr;
	AppleVirtMeshDriver *             _message_handler_owner = nullptr;
	Message::Channel                  _channel               = Message::Channel::Invalid;
	VirtIOChannelMode                 _mode                  = VirtIOChannelMode::Passive;
	OSSharedPtr<IOWorkLoop>           _work_loop;
	OSSharedPtr<IOCommandGate>        _command_gate;
	OSSharedPtr<AppleVirtIOQueue>     _virtio_queue;
	OSSharedPtr<AppleVirtIOTransport> _transport;

	void
	construct_logger()
	{
		if (nullptr == _logger) {
			_logger = os_log_create(kDriverLoggerSubsystem, "AppleVirtMeshVirtIOChannel");
		}
	}
};

}; // namespace VirtMesh::Guest::Mesh
