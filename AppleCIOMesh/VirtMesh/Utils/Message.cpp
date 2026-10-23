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
//  Message.cpp
//  AppleCIOMesh
//
//  Created by Zixuan Wang on 11/18/24.
//

#include "VirtMesh/Utils/Message.h"
#include "VirtMesh/Utils/Type.h"

using namespace VirtMesh;

static_assert(is_standard_layout<Message::Header>::value == true, "The class is not in standard layout");
static_assert(is_trivial<Message::Header>::value == true, "The class is not trivial");
static_assert(sizeof(Message::Header) <= Message::kMaxHeaderSize, "The message header struct is over the limit");

bool
Message::encode(uint8_t * buffer, uint64_t * buffer_size) const
{
	if (nullptr == buffer || nullptr == buffer_size) {
		os_log_error(_logger, "Failed to encode message: input buffer or buffer_size ptr is null");
		return false;
	}

	if (*buffer_size < size()) {
		os_log_error(
		    _logger,
		    "Failed to encode message: input buffer size [%llu] is smaller than required [%llu]",
		    *buffer_size,
		    size()
		);
		return false;
	}

	memcpy(buffer, &_header, sizeof(Header));

	if (_payload_data) {
		memcpy(buffer + sizeof(Header), _payload_data, _header.payload_size);
	}

	*buffer_size = size();

	return true;
}

bool
Message::decode(const uint8_t * buffer, uint64_t buffer_size)
{
	if (nullptr == buffer) {
		os_log_error(_logger, "Failed to decode message: input buffer is null");
		return false;
	}

	if (nullptr != _payload_data) {
		os_log_error(
		    _logger,
		    "Failed to decode message: the current message object already has meaningful message data, it "
		    "should not be used for deserialization again which will overwrite the existing data"
		);
		return false;
	}

	if (buffer_size < sizeof(Header)) {
		os_log_error(
		    _logger,
		    "Failed to decode message: the input buffer size [%llu] is smaller than the header size [%lu]",
		    buffer_size,
		    sizeof(Header)
		);
		return false;
	}

	memcpy(&_header, buffer, sizeof(Header));

	if (!validate_header()) {
		os_log_error(_logger, "Failed to decode message: header field is not valid");
		dev_log_dump_buffer(_logger, buffer, buffer_size);
		return false;
	}

	if (_header.payload_size > 0) {
		/** @brief The incoming buffer could be larger than expected, this is an expected behavior between guest and host, because
		 *         the host-size virtio element processing requires the guest to first send a large enough buffer to the host. So in
		 *         practice, to receive a message:
		 * 		     1. A guest first send a large enough buffer to host
		 * 		     2. Then receives the same amounts of bytes
		 * 		     3. Once host returned, the guest should decode the actual payload data from the buffer, likely to be a small
		 *              portion of the entire buffer.
		 */
		auto expected_buffer_size = sizeof(Header) + _header.payload_size;
		if (buffer_size < expected_buffer_size) {
			os_log_error(
			    _logger,
			    "Failed to decode message: buffer size mismatch, got [%llu] but expect [%llu]",
			    buffer_size,
			    expected_buffer_size
			);
			dev_log_dump_buffer(_logger, buffer, buffer_size);
			return false;
		}

		copy_in_payload(_header.payload_size, buffer + sizeof(Header));
	}

	if (!validate_payload()) {
		os_log_error(_logger, "Failed to decode message: payload field is not valid");
		return false;
	}

	DEV_LOG(
	    _logger,
	    "Message::decode() decoded payload size [0x%llx] incoming buffer size [0x%llx]",
	    _header.payload_size,
	    buffer_size
	);

	return true;
}

bool
Message::validate_header()
{
	/* TODO: Check `src_node` value */
	if ((_header.command >= Command::TotalCommands) || (_header.sub_command >= SubCommand::TotalSubCommands) ||
	    (_header.channel >= Channel::TotalChannels) || (_header.payload_size > kMaxPayloadSize)) {
		os_log_error(
		    _logger,
		    "The message header is invalid: command [0x%hx] sub_command [0x%hx] channel [0x%hx] payload_size [%llu]",
		    _header.command,
		    _header.sub_command,
		    _header.channel,
		    _header.payload_size
		);
		return false;
	}

	return true;
}

bool
Message::validate_payload()
{
	if (_header.payload_size > 0 && _payload_data == nullptr) {
		os_log_error(
		    _logger,
		    "The message object is invalid: the payload_size is [%llu] but the payload_data is null",
		    _header.payload_size
		);
		return false;
	}

	return true;
}
