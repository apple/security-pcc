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
//  Message.h
//  AppleCIOMesh
//
//  Created by Zixuan Wang on 11/18/24.
//

#pragma once

#include "VirtMesh/Utils/Log.h"
#include <os/log.h>

#ifdef KERNEL
#include <IOKit/IOLib.h>
#include <libkern/c++/OSLib.h>
#include <libkern/c++/OSObject.h>
#include <libkern/c++/OSSharedPtr.h>
#else
#include <cassert>
#include <cstdint>
#include <memory>
#endif

namespace VirtMesh
{

/**
 * @brief Message class for serialization and deserialization in VirtMesh, used in kext and host-side plugins.
 *
 * @note The message data are stored in either `_header` as a C/C++ typed value, or in `_payload_data` as a raw blob. No other class
 * member has any data for serialization/deserialization. Any newly added data field should go to the `Header` struct, not in the
 * `Message` class.
 */
class Message
{
  public:
	enum class Command : uint16_t {
		GuestSend = 0,
		GuestRecv = 1,
		TotalCommands,
	};

	enum class SubCommand : uint8_t {
		Invalid             = 0, /* Force the guest kext to use sub-command explicitly */
		Error               = 1,
		GuestSend_ToGuest   = 2,
		GuestRecv_FromGuest = 3,
		GuestRecv_GetNodeId = 4,
		TotalSubCommands,
	};

	enum class Channel : uint8_t {
		General = 0,
		Control = 1,
		Data    = 2,
		TotalChannels,

		Invalid = UINT8_MAX,
	};

	enum class ErrorCode : uint32_t {
		GeneralError             = 0,
		GuestRecvMessageOverflow = 1,
		Unsupported              = 2,
	};

	/* Used in Message constructor to enforce typed argument such that src_node value does not accidentally gets swapped with other
	 * values. The internal value matches the Header definition.
	 */
	struct NodeId {
		uint32_t id;
	};

	struct PayloadSize {
		uint64_t size;
	};

	/* Set a size limit to prevent a guest request asking the host to allocate a very large buffer which may cause oom and maybe
	 * some security exploits.
	 *
	 * Additionally, the VirtIO queue is hard limit to 256 queue elements, 4KiB each, so it supports upto 2MiB transactions.
	 */
	static constexpr uint64_t kMaxHeaderSize  = 1024;
	static constexpr uint64_t kMaxPayloadSize = 1 * 1024 * 1024 - kMaxHeaderSize;

	static constexpr uint64_t kMaxAdditionalValues = 8;
	/**
	 * @brief The header of the message object, it is asserted to be trivial and standard layout in Message.cpp
	 */
	using Header = struct MessageHeader {
		Command    command;
		SubCommand sub_command;
		Channel    channel;
		uint64_t   value;
		uint64_t   additional_values[kMaxAdditionalValues];
		uint32_t   src_node;
		uint64_t   payload_size; /* In byte */
	};

	Header _header;

  private:
	/* Avoid other code to temper with the raw payload pointer */
	uint8_t * _payload_data = nullptr;

	/* Only for decode, not for encode */
	uint64_t _payload_max_size = 0;

  public:
	/* Prevent copying */
	Message(const Message &)             = delete;
	Message & operator=(const Message &) = delete;

	/** @brief When constructed without any data, this message object is to be used for deserialization only. */
	Message()
	{
		construct_logger();
	}

	/**
	 * @brief Construct a message object to receive data
	 *
	 * @note The kext uses this constructor to allocate a payload buffer with the specified max size. This large message object is
	 * later encoded and sent to the host, which will check incoming message size and needs this buffer to be large enough to
	 * hold the incoming message.
	 *
	 * @note Set src_node to "invalid", because this message will receive a src_node from host side.
	 */
	Message(Command command, SubCommand sub_command, Channel channel, PayloadSize payload_max_size)
	    : _header{.command = command, .sub_command = sub_command, .channel = channel, .value = 0, .additional_values = {0}, .src_node = UINT32_MAX, .payload_size = payload_max_size.size},
	      _payload_max_size(payload_max_size.size)
	{
		construct_logger();
		/* Allocate the buffer to be large enough to receive incoming data. */
		if (_payload_max_size > 0) {
			alloc_payload(_payload_max_size);
		}
	}

	/**
	 * @brief Construct a message object to send data
	 */
	explicit Message(
	    Command         command,
	    SubCommand      sub_command,
	    Channel         channel,
	    uint64_t        value,
	    NodeId          src_node,
	    PayloadSize     payload_size,
	    const uint8_t * payload_data
	)
	    : _header{
	          .command           = command,
	          .sub_command       = sub_command,
	          .channel           = channel,
	          .value             = value,
	          .additional_values = {0},
	          .src_node          = src_node.id,
	          .payload_size      = payload_size.size
	      }
	{
		construct_logger();

		if (payload_size.size > 0) {
			if (payload_size.size > kMaxPayloadSize) {
				os_log_error(
				    _logger,
				    "Failed to construct message object with size [%llu] over the limit [%llu]",
				    payload_size.size,
				    kMaxPayloadSize
				);
				assert(false);
			}

			if (payload_data) {
				copy_in_payload(payload_size.size, payload_data);
			} else {
				alloc_payload(payload_size.size);
				memset(_payload_data, 0, payload_size.size);
			}
		}
	}

#ifdef KERNEL
	/**
	 * @brief Construct a message object to send data, this ctor is used in kext to copy the buffer from userspace to this kernel
	 * space message object.
	 */
	explicit Message(
	    Command           command,
	    SubCommand        sub_command,
	    Channel           channel,
	    uint64_t          value,
	    NodeId            src_node,
	    PayloadSize       payload_size,
	    mach_vm_address_t payload_user_address
	)
	    : _header{
	          .command           = command,
	          .sub_command       = sub_command,
	          .channel           = channel,
	          .value             = value,
	          .additional_values = {0},
	          .src_node          = src_node.id,
	          .payload_size      = payload_size.size
	      }
	{
		construct_logger();

		if (payload_size.size > 0) {
			alloc_payload(payload_size.size);
			copy_in_payload_from_user(payload_size.size, payload_user_address);
		}
	}
#endif

	virtual ~Message()
	{
		if (_payload_data) {
			free_payload();
		}
	}

	/** @brief encode the message into the buffer
	 *  @note An encoded message's layout:
	 *        1. `_header` fields
	 *        2. Byte array pointed by `_payload_data`, if any
	 * @return True if successfully encoded the message, False if failed; Return the used size through buffer_size pointer.
	 */
	bool encode(uint8_t * buffer, uint64_t * buffer_size) const;

	/** @brief decode message from the buffer
	 *  @note It assumes the buffer layout is encoded by the encode() function.
	 */
	bool decode(const uint8_t * buffer, uint64_t buffer_size);

	bool
	encode(void * buffer, uint64_t * buffer_size) const
	{
		return encode(reinterpret_cast<uint8_t *>(buffer), buffer_size);
	}

	bool
	decode(const void * buffer, uint64_t buffer_size)
	{
		return decode(reinterpret_cast<const uint8_t *>(buffer), buffer_size);
	}

	bool validate_header();
	bool validate_payload();

	uint8_t *
	get_payload()
	{
		return _payload_data;
	}

	uint64_t
	size() const
	{
		DEV_LOG(_logger, "Message::size() header size [0x%lx] payload size [0x%llx]", sizeof(Header), _header.payload_size);
		return sizeof(Header) + _header.payload_size;
	}

	/**
	 * @brief Reset the message so that it can be reused for deserialization.
	 */
	void
	reset()
	{
		/* TODO: reset header fields */
		/* Free the payload buffer because the decode() will allocate buffer. */
		free_payload();
	}

	void
	copy_out_payload(uint8_t * buffer, size_t buffer_size) const
	{
		assert(buffer_size == _header.payload_size);
		memcpy(buffer, _payload_data, buffer_size);
	}

#ifdef KERNEL
	void
	copy_out_payload_to_user(mach_vm_address_t buffer_user_address, size_t buffer_size) const
	{
		assert(buffer_size == _header.payload_size);
		if (auto res = copyout(_payload_data, buffer_user_address, buffer_size); 0 != res) {
			os_log_error(_logger, "Failed to copy message payload out to user buffer, error code: 0x%x", res);
			assert(0 == res);
		}
	}
#endif

  private:
	void
	alloc_payload(uint64_t payload_size)
	{
		assert(!_payload_data);
#ifdef KERNEL
		_payload_data = static_cast<uint8_t *>(IOMalloc(payload_size));
#else
		_payload_data = static_cast<uint8_t *>(malloc(payload_size));
#endif
		/* TODO: zero out the payload buffer */
		assert(_payload_data);
	}

	void
	free_payload()
	{
		if (_payload_data == nullptr) {
			return;
		}

#ifdef KERNEL
		IOFree(_payload_data, _header.payload_size);
#else
		free(_payload_data);
#endif

		_payload_data = nullptr;
	}

	void
	copy_in_payload(uint64_t payload_size, const uint8_t * payload_data_in)
	{
		if (payload_size > kMaxPayloadSize) {
			os_log_error(
			    _logger,
			    "Failed to construct message object with size [%llu] over the limit [%llu]",
			    payload_size,
			    kMaxPayloadSize
			);
			assert(false);
		}
		alloc_payload(payload_size);
		memcpy(_payload_data, payload_data_in, payload_size);
	}

#ifdef KERNEL
	void
	copy_in_payload_from_user(uint64_t buffer_size, mach_vm_address_t buffer_user_address)
	{
		if (auto res = copyin(buffer_user_address, _payload_data, buffer_size); 0 != res) {
			os_log_error(_logger, "Failed to copy user buffer to message payload, error code: 0x%x", res);
			assert(0 == res);
		}
	}
#endif

  private:
	os_log_t _logger;

	void
	construct_logger()
	{
		_logger = os_log_create("com.apple.driver.AppleVirtMesh", "Message");
	}
};

}; // namespace VirtMesh
