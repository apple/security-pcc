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

#include <arpa/inet.h>
#include <cerrno>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/tcp.h> // for TCP_NODELAY
#include <os/log.h>
#include <unistd.h>

#include "ScopeGuard.h"
#include "TcpConnection.h"

namespace AppleCIOMeshNet
{

static bool
DnsResolve(const char * host, sockaddr_in6 * addr_out)
{
	addrinfo * result;
	addrinfo hints{};
	hints.ai_family   = AF_INET6;
	hints.ai_socktype = SOCK_STREAM;
	if (getaddrinfo(host, nullptr, &hints, &result) != 0) {
		return false;
	}
	*addr_out = *(sockaddr_in6 *)result->ai_addr;
	freeaddrinfo(result);
	return true;
}

TcpConnection::~TcpConnection()
{
	if (_sockfd >= 0) {
		::close(_sockfd);
	}
}

TcpConnection::TcpConnection(TcpConnection && other) : _sockfd(other._sockfd)
{
	other._sockfd = -1;
}

TcpConnection &
TcpConnection::operator=(TcpConnection && other)
{
	if (this == &other) {
		return *this;
	}

	if (_sockfd > 0) {
		::close(_sockfd);
	}
	_sockfd       = other._sockfd;
	other._sockfd = -1;
	return *this;
}

bool
TcpConnection::set_non_blocking()
{
	int flags = fcntl(_sockfd, F_GETFL, 0);
	int ret   = fcntl(_sockfd, F_SETFL, flags | O_NONBLOCK);
	return ret == 0;
}

bool
TcpConnection::set_blocking()
{
	int flags = fcntl(_sockfd, F_GETFL, 0);
	int ret   = fcntl(_sockfd, F_SETFL, flags & ~O_NONBLOCK);
	return ret == 0;
}

std::pair<int64_t, int>
TcpConnection::read(uint8_t * buffer, size_t len) const
{
	if (len > INT_MAX) {
		return {-1, EINVAL};
	}
	uint64_t bytes_read = 0;
	while (bytes_read < len) {
		int64_t ret = ::read(_sockfd, buffer + bytes_read, len - bytes_read);
		if (ret < 0) {
			return {ret, errno};
		}
		bytes_read += (uint64_t)ret; // should be safe to cast to uint64_t. It's always positive.
	}
	return {bytes_read, 0};
}

std::pair<int64_t, int>
TcpConnection::write(const uint8_t * buffer, size_t length) const
{
	if (length > INT_MAX) {
		return {-1, EINVAL};
	}
	uint64_t bytes_written = 0;
	while (bytes_written < length) {
		int64_t ret = ::write(_sockfd, buffer + bytes_written, length - bytes_written);
		if (ret < 0) {
			return {ret, errno};
		}
		bytes_written += (uint64_t)ret; // should be safe to cast to uint64_t. It's always positive.
	}
	return {bytes_written, 0};
}

AppleCIOMeshUtils::Optional<TcpConnection>
TcpConnection::connect(os_log_t logger, const char * hostname, uint16_t port)
{
	int sockfd;
	struct sockaddr_in6 addr;
	if (!DnsResolve(hostname, &addr)) {
		os_log_error(logger, "TcpConnection - Failed to resolve hostname: %s", hostname);
		return AppleCIOMeshUtils::nullopt;
	}

	sockfd = ::socket(AF_INET6, SOCK_STREAM, 0);
	if (sockfd < 0) {
		os_log_error(logger, "Failed to create socket: %s", strerror(errno));
		return AppleCIOMeshUtils::nullopt;
	}

	AppleCIOMeshUtils::ScopeGuard cleanup_socket = [sockfd] { ::close(sockfd); };

	int flag = 1;
	if (setsockopt(sockfd, IPPROTO_TCP, TCP_NODELAY, &flag, sizeof(int)) < 0) {
		os_log_error(logger, "TcpConnection - Failed to set TCP_NODELAY: %s", strerror(errno));
		return AppleCIOMeshUtils::nullopt;
	}

	flag = 1;
	if (setsockopt(sockfd, SOL_SOCKET, SO_REUSEADDR, &flag, sizeof(flag)) < 0) {
		os_log_error(logger, "TcpConnection - Failed to set SO_REUSEADDR: %s", strerror(errno));
		return AppleCIOMeshUtils::nullopt;
	}

	addr.sin6_port = htons(port);

	if (::connect(sockfd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
		os_log_error(logger, "TcpConnection - Failed to connect to hostname: %s, error: %s", hostname, strerror(errno));
		return AppleCIOMeshUtils::nullopt;
	}

	cleanup_socket.dismiss();
	os_log_info(logger, "TcpConnection - Connected to %s on socket %d", hostname, sockfd);
	return AppleCIOMeshNet::TcpConnection{sockfd};
}

TcpConnectionListener::~TcpConnectionListener()
{
	if (_sockfd > 0) {
		::close(_sockfd);
	}
}

TcpConnectionListener::TcpConnectionListener(TcpConnectionListener && other) noexcept : _sockfd(other._sockfd)
{
	other._sockfd = -1;
}

TcpConnectionListener &
TcpConnectionListener::operator=(TcpConnectionListener && other) noexcept
{
	if (this == &other) {
		return *this;
	}

	if (_sockfd > 0) {
		::close(_sockfd);
	}
	_sockfd       = other._sockfd;
	other._sockfd = -1;
	return *this;
}

AppleCIOMeshUtils::Optional<TcpConnectionListener>
TcpConnectionListener::listen(os_log_t logger, uint16_t port)
{
	int sockfd = ::socket(AF_INET6, SOCK_STREAM, 0);
	if (sockfd < 0) {
		os_log_error(logger, "TcpConnectionListener - Failed to create socket: %s", strerror(errno));
		return AppleCIOMeshUtils::nullopt;
	}

	AppleCIOMeshUtils::ScopeGuard cleanup_socket = [sockfd] { ::close(sockfd); };

	int flag = 1;
	if (setsockopt(sockfd, SOL_SOCKET, SO_REUSEADDR, &flag, sizeof(flag)) < 0) {
		os_log_error(logger, "TcpConnectionListener - Failed to set SO_REUSEADDR: %s", strerror(errno));
		return AppleCIOMeshUtils::nullopt;
	}

	struct sockaddr_in6 addr;
	addr.sin6_family = AF_INET6;
	addr.sin6_addr   = IN6ADDR_ANY_INIT;
	addr.sin6_port   = htons(port);

	if (::bind(sockfd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
		os_log_error(logger, "TcpConnectionListener - Failed to bind socket: %s", strerror(errno));
		return AppleCIOMeshUtils::nullopt;
	}

	if (::listen(sockfd, 6) < 0) {
		os_log_error(logger, "TcpConnectionListener - Failed to listen on socket: %s", strerror(errno));
		return AppleCIOMeshUtils::nullopt;
	}

	cleanup_socket.dismiss();

	os_log_info(logger, "TcpConnectionListener - Listening on port %d", port);
	return AppleCIOMeshNet::TcpConnectionListener{sockfd, logger};
}

AppleCIOMeshUtils::Optional<TcpConnection>
TcpConnectionListener::accept()
{
	struct sockaddr_in6 client_addr;
	socklen_t len     = sizeof(client_addr);
	int client_socket = ::accept(_sockfd, (struct sockaddr *)&client_addr, &len);
	if (client_socket < 0) {
		os_log_error(_logger, "TcpConnectionListener - Failed to accept connection: %s", strerror(errno));
		return AppleCIOMeshUtils::nullopt;
	}

	int flag = 1;
	if (setsockopt(client_socket, IPPROTO_TCP, TCP_NODELAY, &flag, sizeof(int)) < 0) {
		os_log_error(_logger, "TcpConnection - Failed to set TCP_NODELAY: %s", strerror(errno));
		return AppleCIOMeshUtils::nullopt;
	}

	os_log_info(_logger, "TcpConnectionListener - Accepted connection");
	return AppleCIOMeshNet::TcpConnection{client_socket};
}
void
TcpConnectionListener::stop()
{
	if (_sockfd > 0) {
		::close(_sockfd);
		_sockfd = -1;
	}
}

} // namespace AppleCIOMeshNet
