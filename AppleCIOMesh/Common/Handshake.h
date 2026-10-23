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

#pragma once
#include "Common/TcpConnection.h"
#include <cstdint>
#include <cstring>

constexpr uint64_t kHandshakeVersion    = 20250117;
constexpr uint8_t kHandshakeMessageType = 10;
const char kHandshakeMessage[]          = "HelloCIOMesh";

namespace AppleCIOMeshNet
{
class [[gnu::visibility("hidden")]] ByteReader
{
	const uint8_t * _src;
	uint64_t _length;
	uint64_t _head;

  public:
	ByteReader(const uint8_t * src, uint64_t length) : _src(src), _length(length), _head(0) {};

	bool
	read8(uint8_t * value)
	{
		if (_head + 1 > _length) {
			return false;
		}

		*value = _src[_head];
		++_head;
		return true;
	}

	bool
	read16(uint16_t * value)
	{
		if (_head + 2 > _length) {
			return false;
		}

		uint16_t local = _src[_head];
		local          = (uint16_t)(local << 8) | _src[_head + 1];
		*value         = local;

		_head += 2;
		return true;
	}

	bool
	read32(uint32_t * value)
	{
		if (_head + 4 > _length) {
			return false;
		}

		uint32_t local = _src[_head];
		local          = local << 8 | _src[_head + 1];
		local          = local << 8 | _src[_head + 2];
		local          = local << 8 | _src[_head + 3];

		*value = local;
		_head += 4;
		return true;
	}

	bool
	read64(uint64_t * value)
	{
		if (_head + 8 > _length) {
			return false;
		}

		uint32_t local = _src[_head];
		local          = local << 8 | _src[_head + 1];
		local          = local << 8 | _src[_head + 2];
		local          = local << 8 | _src[_head + 3];
		local          = local << 8 | _src[_head + 4];
		local          = local << 8 | _src[_head + 5];
		local          = local << 8 | _src[_head + 6];
		local          = local << 8 | _src[_head + 7];

		*value = local;
		_head += 8;
		return true;
	}

	bool
	read(uint8_t * dst, uint64_t length)
	{
		if (_head + length > _length) {
			return false;
		}

		memcpy(dst, _src + _head, length);

		_head += length;
		return true;
	}
};

class [[gnu::visibility("hidden")]] ByteWriter
{
	uint8_t * _dst;
	uint64_t _length;
	uint64_t _head;

  public:
	ByteWriter(uint8_t * dst, uint64_t length) : _dst(dst), _length(length), _head(0) {};

	bool
	write8(uint8_t value)
	{
		if (_head + 1 > _length) {
			return false;
		}

		_dst[_head] = value;
		++_head;
		return true;
	}

	bool
	write16(uint16_t value)
	{
		if (_head + 2 > _length) {
			return false;
		}

		_dst[_head]     = value >> 8;
		_dst[_head + 1] = value & 0xFF;
		_head += 2;
		return true;
	}

	bool
	write32(uint32_t value)
	{
		if (_head + 4 > _length) {
			return false;
		}

		_dst[_head]     = value >> 24;
		_dst[_head + 1] = (value >> 16) & 0xFF;
		_dst[_head + 2] = (value >> 8) & 0xFF;
		_dst[_head + 3] = value & 0xFF;
		_head += 4;
		return true;
	}

	bool
	write64(uint64_t value)
	{
		if (_head + 8 > _length) {
			return false;
		}

		_dst[_head]     = value >> 56;
		_dst[_head + 1] = (value >> 48) & 0xFF;
		_dst[_head + 2] = (value >> 40) & 0xFF;
		_dst[_head + 3] = (value >> 32) & 0xFF;
		_dst[_head + 4] = (value >> 24) & 0xFF;
		_dst[_head + 5] = (value >> 16) & 0xFF;
		_dst[_head + 6] = (value >> 8) & 0xFF;
		_dst[_head + 7] = value & 0xFF;
		_head += 8;
		return true;
	}

	bool
	write(const uint8_t * src, uint64_t length)
	{
		if (_head + length > _length) {
			return false;
		}

		memcpy(_dst + _head, src, length);

		_head += length;
		return true;
	}
};

struct Handshake {
	uint64_t version;
	uint8_t message_type;
	uint32_t sender_rank;
	uint32_t message_length;
	uint8_t message[64];
	char tag[kTagSize];
};

inline bool
WriteHandshake(uint8_t * buffer, uint64_t length, Handshake const & handshake)
{
	if (length < sizeof(Handshake)) {
		return false;
	}
	ByteWriter writer(buffer, length);
	// Write version (date)
	if (!writer.write64(handshake.version)) {
		return false;
	}

	// Write message type
	if (!writer.write8(handshake.message_type)) {
		return false;
	}

	// Write sender rank
	if (!writer.write32(handshake.sender_rank)) {
		return false;
	}

	// Write message length
	if (!writer.write32(handshake.message_length)) {
		return false;
	}

	// Write message
	if (!writer.write(handshake.message, handshake.message_length)) {
		return false;
	}

	// Write the tag
	if (!writer.write((const uint8_t *)handshake.tag, kTagSize)) {
		return false;
	}
	return true;
}

inline bool
ReadHandshake(const uint8_t * buffer, size_t length, Handshake * handshake)
{
	if (length < sizeof(Handshake)) {
		return false;
	}
	ByteReader reader(buffer, length);
	uint64_t version;
	if (!reader.read64(&version)) {
		return false;
	}
	uint8_t message_type;
	if (!reader.read8(&message_type)) {
		return false;
	}
	uint32_t sender_rank;
	if (!reader.read32(&sender_rank)) {
		return false;
	}
	uint32_t message_length;
	if (!reader.read32(&message_length)) {
		return false;
	}
	if (message_length > sizeof(handshake->message)) {
		return false;
	}

	uint8_t message[64];
	if (!reader.read(message, message_length)) {
		return false;
	}

	if (!reader.read((uint8_t *)handshake->tag, kTagSize)) {
		return false;
	}

	handshake->version        = version;
	handshake->message_type   = message_type;
	handshake->sender_rank    = sender_rank;
	handshake->message_length = message_length;
	memcpy(handshake->message, message, message_length);
	return true;
}

static bool
sendHandshake(Handshake const & handshake, os_log_t logger, TcpConnection & conn)
{
	uint8_t payload[sizeof(Handshake)];
	if (!WriteHandshake(payload, sizeof(payload), handshake)) {
		os_log_error(logger, "Failed to write handshake\n");
		return false;
	}
	const auto [written, err] = conn.write(payload, sizeof(payload));
	if (err != 0) {
		os_log_error(logger, "Failed to write handshake to the socket.\n");
		return false;
	}
	return true;
}

static bool
verifyHandshake(os_log_t logger, TcpConnection & conn, Handshake * handshake, uint32_t expectedNodeId)
{
	uint8_t buffer[sizeof(Handshake)];
	int maxRetries = 10;
	fd_set readfds;
	while (maxRetries-- > 0) {
		FD_ZERO(&readfds);
		FD_SET(conn.socket(), &readfds);
		struct timeval timeout;
		timeout.tv_sec  = 1; // if we can't connect for 10 seconds, we should give up.
		timeout.tv_usec = 0;
		const int maxfd = conn.socket();
		int ret         = ::select(maxfd + 1, &readfds, NULL, NULL, &timeout);
		if (ret < 0) {
			os_log_error(logger, "Failed to select on the socket\n");
			return false;
		}

		if (ret == 0) { // timeout
			continue;
		}
		break;
	}

	if (maxRetries == 0) {
		os_log_error(logger, "Did not receive handshake from the peer.\n");
		return false;
	}

	const auto [read, err] = conn.read(buffer, sizeof(buffer));
	if (err != 0) {
		os_log_error(logger, "Failed to read handshake from the socket. Error: %d\n", err);
		return false;
	}

	ReadHandshake(buffer, sizeof(buffer), handshake);
	if (handshake->version != kHandshakeVersion) {
		os_log_error(logger, "Handshake version mismatch\n");
		return false;
	}

	if (handshake->message_type != kHandshakeMessageType) {
		os_log_error(logger, "Handshake message type mismatch\n");
		return false;
	}

	if (handshake->sender_rank != expectedNodeId) {
		os_log_error(logger, "Handshake sender rank mismatch\n");
		return false;
	}

	if (handshake->message_length != sizeof(kHandshakeMessage)) {
		os_log_error(logger, "Handshake message length mismatch\n");
		return false;
	}

	return true;
}
} // namespace AppleCIOMeshNet
