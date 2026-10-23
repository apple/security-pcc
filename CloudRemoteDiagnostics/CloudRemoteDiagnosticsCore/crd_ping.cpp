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

#include <arpa/inet.h>       // for inet_ntoa, htons
#include <os/log.h>
#include <netdb.h>           // for addrinfo, getaddrinfo
#include <netinet/icmp6.h>   // for icmp6_hdr
#include <netinet/in.h>      // for sockaddr_in, IPPROTO_ICMP
#include <netinet/ip_icmp.h> // for icmp, ICMP_ECHO, ICMP_EC...
#include <stdint.h>          // for uint16_t, uint32_t, uint...
#include <sys/socket.h>      // for setsockopt, recvfrom
#include <sys/time.h>        // for timeval
#include <unistd.h>          // for size_t, close, getpid

#include <chrono>   // for chrono::duration_cast, seconds, microseconds
#include <optional> // for std::optional
#include <string>   // for std::string
#include <utility>  // for std::move 

#include "crd_core.h"
#include "crd_scope_guard.h"

namespace {
os_log_t logger;

class StopWatch {
    std::chrono::time_point<std::chrono::high_resolution_clock> m_start;

public:
    StopWatch()
        : m_start(std::chrono::high_resolution_clock::now())
    {
    }

    double elapsed_seconds() const
    {
        const auto now = std::chrono::high_resolution_clock::now();
        return std::chrono::duration_cast<std::chrono::seconds>(now - m_start).count();
    }

    double elapsed_us() const
    {
        const auto now = std::chrono::high_resolution_clock::now();
        return std::chrono::duration_cast<std::chrono::microseconds>(now - m_start).count();
    }
};

struct IpHeader {
    uint8_t ip_hl : 4; /* header length */
    uint8_t ip_v : 4;  /* version */
    uint8_t ip_tos;    /* type of service */
    uint16_t ip_len;   /* total length */
    uint16_t ip_id;    /* identification */
    uint16_t ip_off;   /* fragment offset field */
    uint8_t ip_ttl;    /* time to live */
    uint8_t ip_p;      /* protocol */
    uint16_t ip_sum;   /* checksum */
    uint32_t ip_src;   /* source address */
    uint32_t ip_dst;   /* dest address */
};

struct IcmpPacket {
    icmp header;
    static constexpr int ping_packet_size = 64;
    uint8_t msg[ping_packet_size - sizeof(icmp)];
    IcmpPacket()
        : header()
        , msg()
    {
        header.icmp_type = ICMP_ECHO;
        header.icmp_hun.ih_idseq.icd_id = htons(getpid());
        header.icmp_hun.ih_idseq.icd_seq = htons(1);
        static_assert(sizeof(IcmpPacket) == 64, "ICMP packet must be 64 bytes");
    }

    void sequence(uint16_t value) { header.icmp_hun.ih_idseq.icd_seq = htons(value); }
    uint16_t sequence() const { return ntohs(header.icmp_hun.ih_idseq.icd_seq); }
    int id() const { return ntohs(header.icmp_hun.ih_idseq.icd_id); }
};

struct IcmpPacket6 {
    icmp6_hdr header;
    static constexpr int ping_packet_size = 64;
    uint8_t msg[ping_packet_size - sizeof(icmp6_hdr)];
    IcmpPacket6()
        : header()
        , msg("infinite loop")
    {
        header.icmp6_type = ICMP6_ECHO_REQUEST;
        header.icmp6_code = 0;
        header.icmp6_id = htons(getpid());
        header.icmp6_seq = htons(1);
        static_assert(sizeof(IcmpPacket6) == 64, "ICMPv6 packet must be 64 bytes");
    }

    void sequence(uint16_t value) { header.icmp6_seq = htons(value); }
    uint16_t sequence() const { return ntohs(header.icmp6_seq); }
    int id() const { return ntohs(header.icmp6_id); }
};

class SocketHandle {
    int m_sockfd;
public:
    SocketHandle(int sockfd)
        : m_sockfd(sockfd)
    {
    }
    SocketHandle(SocketHandle&& other)
        : m_sockfd(other.m_sockfd)
    {
        other.m_sockfd = -1;
    }
    ~SocketHandle()
    {
        if (m_sockfd >= 0) {
            close(m_sockfd);
        }
    }
    int handle() const { return m_sockfd; }
};

class SocketAddress {
    sockaddr_in m_addr_con;
    std::string m_ip;

public:
    SocketAddress(sockaddr_in addr_con, std::string ip)
        : m_addr_con(addr_con)
        , m_ip(ip)
    {
    }
    sockaddr* address() const { return (sockaddr*)&m_addr_con; }
    uint8_t length() const { return m_addr_con.sin_len; }
    std::string const& ip() const { return m_ip; }
};

class SocketAddress6 {
    sockaddr_in6 m_addr_con;
    std::string m_ip;

public:
    SocketAddress6(sockaddr_in6 addr_con, std::string ip)
        : m_addr_con(addr_con)
        , m_ip(ip)
    {
    }
    sockaddr* address() const { return (sockaddr*)&m_addr_con; }
    uint8_t length() const { return m_addr_con.sin6_len; }
    std::string const& ipv6() const { return m_ip; }
};

struct EchoReplyResult {
    enum class Status {
        Success,
        InvalidCode,
        InvalidChecksum,
        InvalidIp,
        NotMine,
        UnexpectedPacket,
        Timeout,
        SocketError,
    } status;
    std::string ip;
};

static uint16_t checksum(IcmpPacket const& packet)
{
    auto len = sizeof(packet);
    auto* buf = reinterpret_cast<uint16_t const*>(&packet);
    uint64_t sum = 0;

    for (; len > 1; len -= 2) {
        sum += *buf++;
    }

    if (len == 1) {
        sum += *buf;
    }

    sum = (sum >> 16) + (sum & 0xFFFF);
    sum += (sum >> 16);
    uint16_t result = ~sum; // one's complement and truncate to 16 bits.
    return result;
}

class IcmpSocket;
class IcmpSocket6;

EchoReplyResult receive_echo_reply(IcmpSocket const& socket, int sequence);
EchoReplyResult receive_echo_reply(IcmpSocket6 const& socket, int sequence);
static std::optional<SocketAddress> dns_resolve(std::string const& domain)
{
    addrinfo hints {}, *res;
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_DGRAM;
    if (getaddrinfo(domain.c_str(), nullptr, &hints, &res) != 0) {
        return std::nullopt;
    }
    const auto addrinfo_guard = crd::ScopeGuard([res] { freeaddrinfo(res); });
    sockaddr_in const* dst = (sockaddr_in*)res->ai_addr;
    char buffer[INET_ADDRSTRLEN];
    auto* ping_ip = inet_ntop(AF_INET, &dst->sin_addr, buffer, INET_ADDRSTRLEN);
    if (ping_ip == nullptr) {
        return std::nullopt;
    }
    return SocketAddress{*dst, std::string(ping_ip)};
}

static std::optional<SocketAddress6> dns_resolve6(std::string const& domain)
{
    addrinfo hints {}, *res;
    hints.ai_family = AF_INET6;
    hints.ai_socktype = SOCK_DGRAM;
    if (getaddrinfo(domain.c_str(), nullptr, &hints, &res) != 0) {
        return std::nullopt;
    }
    const auto addrinfo_guard = crd::ScopeGuard([res] { freeaddrinfo(res); });
    sockaddr_in6 const* dst = (sockaddr_in6*)res->ai_addr;
    char buffer[INET6_ADDRSTRLEN];
    auto* ping_ip = inet_ntop(AF_INET6, &dst->sin6_addr, buffer, INET6_ADDRSTRLEN);
    if (ping_ip == nullptr) {
        return std::nullopt;
    }
    return SocketAddress6{*dst, std::string(ping_ip)};
}

class IcmpSocket {
    SocketHandle m_socket;
    IcmpSocket(SocketHandle socket)
        : m_socket(std::move(socket))
    {
    }

public:
    int fd() const { return m_socket.handle(); }

    static std::optional<IcmpSocket> create(std::string& error)
    {
        SocketHandle sockfd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP);
        if (sockfd.handle() < 0) {
            error = "Failed to create a socket";
            return {};
        }

        // set the TTL on the socket
        constexpr int ttl = 64;
        if (setsockopt(sockfd.handle(), IPPROTO_IP, IP_TTL, &ttl, sizeof(ttl)) != 0) {
            error = "Failed to set TTL option on socket";
            return {};
        }

        // set the receive timeout to 1 second
        constexpr int receive_timeout = 1;
        timeval tv_out;
        tv_out.tv_sec = receive_timeout;
        tv_out.tv_usec = 0;
        if (setsockopt(sockfd.handle(), SOL_SOCKET, SO_RCVTIMEO, &tv_out, sizeof tv_out) != 0) {
            error = "Failed to set receive timeout on socket";
            return {};
        }

        return IcmpSocket(std::move(sockfd));
    }

    // make a ping request
    crd_ping_packet_result ping(std::string const& domain, const int sequence = 1)
    {
        std::optional<SocketAddress> address_opt = dns_resolve(domain);
        if (!address_opt.has_value()) {
            return { nullptr, 0, false };
        }

        IcmpPacket packet;
        packet.sequence(sequence);
        packet.header.icmp_cksum = checksum(packet);

        // send packet
        StopWatch single_packet_ping_time;
        if (sendto(fd(), &packet, sizeof(packet), 0, address_opt->address(), address_opt->length())
                <= 0) {
            os_log_debug(logger, "Sendto failed");
            return { strdup(address_opt->ip().c_str()), 0, false };
        }

        while (true) {
            // receive packet
            const auto reply = receive_echo_reply(*this, sequence);
            if (reply.status == EchoReplyResult::Status::Success) {
                const double rtt_ms = single_packet_ping_time.elapsed_us() / 1000.0;
                return { strdup(reply.ip.c_str()),  rtt_ms, true };
            }

            if (reply.status == EchoReplyResult::Status::UnexpectedPacket) {
                // retry if the packet is not the one we are expecting until we either receive the correct packet
                // or we timeout.
                continue;
            }
            return { strdup(address_opt->ip().c_str()), 0, false };
        }

        // Exhaused all attempts and did not receive a valid response.
        // This could be due to many unexpected packets being received during our attempts.
        return { strdup(address_opt->ip().c_str()), 0, false };
    }
};

class IcmpSocket6 {
    SocketHandle m_socket;
    IcmpSocket6(SocketHandle socket)
        : m_socket(std::move(socket))
    {
    }

public:
    static std::optional<IcmpSocket6> create(std::string& error)
    {
        SocketHandle sockfd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_ICMPV6);
        if (sockfd.handle() < 0) {
            error = "Failed to create a socket";
            return {};
        }

        // set the receive timeout to 1 second
        constexpr int receive_timeout = 1;
        timeval tv_out;
        tv_out.tv_sec = receive_timeout;
        tv_out.tv_usec = 0;
        if (setsockopt(sockfd.handle(), SOL_SOCKET, SO_RCVTIMEO, &tv_out, sizeof(tv_out)) != 0) {
            error = "Failed to set receive timeout on socket";
            return {};
        }

        return IcmpSocket6(std::move(sockfd));
    }

    int fd() const { return m_socket.handle(); }

    crd_ping_packet_result ping6(std::string const& domain, const int sequence = 1)
    {
        std::optional<SocketAddress6> address_opt = dns_resolve6(domain);
        if (!address_opt.has_value()) {
            return { nullptr, 0, false };
        }

        IcmpPacket6 packet;
        packet.sequence(sequence);
        packet.header.icmp6_cksum = 0;

        // send packet
        StopWatch single_packet_ping_time;
        if (sendto(fd(), &packet, sizeof(packet), 0, address_opt->address(), address_opt->length())
                <= 0) {
            os_log_error(logger, "Sendto failed");
            return { strdup(address_opt->ipv6().c_str()), 0, false };
        }

        while (true) {
            // receive packet
            auto reply = receive_echo_reply(*this, sequence);
            reply.ip = address_opt->ipv6();
            if (reply.status == EchoReplyResult::Status::Success) {
                const double rtt_ms = single_packet_ping_time.elapsed_us() / 1000.0;
                return { strdup(reply.ip.c_str()),  rtt_ms, true };
            }

            if (reply.status == EchoReplyResult::Status::UnexpectedPacket) {
                // retry if the packet is not the one we are expecting until we either receive the correct packet
                // or we timeout.
                continue;
            }
            return { strdup(address_opt->ipv6().c_str()), 0, false };
        }

        // Exhaused all attempts and did not receive a valid response.
        // This could be due to many unexpected packets being received during our attempts.
        return { strdup(address_opt->ipv6().c_str()), 0, false };
    }
};

EchoReplyResult::Status validate_packet(IcmpPacket const& packet, int sequence)
{
    // Check if the packet is ICMP_ECHOREPLY
    if (packet.header.icmp_type != ICMP_ECHOREPLY) {
        return EchoReplyResult::Status::InvalidCode;
    }

    // Verify the packet originated from this process
    if (packet.id() != getpid()) {
        return EchoReplyResult::Status::NotMine;
    }

    // Verify the checksum
    if (checksum(packet) != 0) {
        return EchoReplyResult::Status::InvalidChecksum;
    }

    // Verify that we are receiving the response to the correct ping packet
    if (packet.sequence() != sequence) {
        return EchoReplyResult::Status::UnexpectedPacket;
    }

    return EchoReplyResult::Status::Success;
}

EchoReplyResult::Status validate_packet(IcmpPacket6 const& packet, int sequence)
{
    // Check if the packet is ICMP_ECHOREPLY
    if (packet.header.icmp6_type != ICMP6_ECHO_REPLY) {
        os_log_debug(logger, "ICMPv6 type is not echo reply");
        return EchoReplyResult::Status::InvalidCode;
    }

    // Verify the packet originated from this process
    if (packet.id() != getpid()) {
        return EchoReplyResult::Status::NotMine;
    }

    // Verify that we are receiving the response to the correct ping packet
    if (packet.sequence() != sequence) {
        os_log_debug(logger, "Unexpected sequence number");
        return EchoReplyResult::Status::UnexpectedPacket;
    }

    return EchoReplyResult::Status::Success;
}

// Receive ping reply and return the IP address of the sender if it is valid
// Otherwise return an empty string
static EchoReplyResult receive_echo_reply(IcmpSocket const& socket, int sequence)
{
    IpHeader ip_header;
    IcmpPacket icmp_packet;

    constexpr auto max_ip_header_size = 60;
    unsigned char received_packet[max_ip_header_size + sizeof(IcmpPacket)] { 0 };

    // Use 'select' to wait for the socket to be ready to read with a timeout of 1 second
    fd_set descriptors;
    FD_ZERO(&descriptors);
    FD_SET(socket.fd(), &descriptors);
    timeval tv_out;
    tv_out.tv_sec = 1;
    tv_out.tv_usec = 0;

    const auto select_result = select(socket.fd() + 1, &descriptors, nullptr/* writefds */, nullptr/* exceptfds */, &tv_out);
    if (select_result == 0) {
        os_log_debug(logger, "timeout");
        return { EchoReplyResult::Status::Timeout };
    }

    if (select_result < 0) {
        os_log_debug(logger, "select returned error %s", strerror(errno));
        return { EchoReplyResult::Status::SocketError };
    }

    // We have a packet to read
    const auto bytes_received =recv(socket.fd(), &received_packet, sizeof(received_packet), 0);
    if (bytes_received <= 0) {
        os_log_debug(logger, "recv returned error %s", strerror(errno));
        return { EchoReplyResult::Status::SocketError };
    }

    if (bytes_received != sizeof(icmp_packet) + sizeof(IpHeader)) {
        os_log_error(logger, "packet received might be truncated");
        return { EchoReplyResult::Status::SocketError };
    }

    // copy the IP header and the ICMP packet to avoid alignment issues.
    memcpy(&ip_header, received_packet, sizeof(ip_header));

    // Account for IP options if any which could increase the IP header size.
    // IP Header length is in 4-byte words, so multiply by 4 to get the actual size.
    memcpy(&icmp_packet, received_packet + ip_header.ip_hl * 4, sizeof(icmp_packet));

    const auto validation_result = validate_packet(icmp_packet, sequence);
    if (validation_result != EchoReplyResult::Status::Success) {
        return { validation_result };
    }

    // convert the IP address from binary to text form and return it
    char ip[INET_ADDRSTRLEN];
    if (inet_ntop(AF_INET, &(ip_header.ip_src), ip, INET_ADDRSTRLEN) == nullptr) {
        return { EchoReplyResult::Status::InvalidIp };
    }

    return { EchoReplyResult::Status::Success, ip };
}

static EchoReplyResult receive_echo_reply(IcmpSocket6 const& socket, int sequence)
{
    // Use 'select' to wait for the socket to be ready to read with a timeout of 1 second
    fd_set descriptors;
    FD_ZERO(&descriptors);
    FD_SET(socket.fd(), &descriptors);
    timeval tv_out;
    tv_out.tv_sec = 1;
    tv_out.tv_usec = 0;

    const auto select_result = select(socket.fd() + 1, &descriptors, nullptr/* writefds */, nullptr/* exceptfds */, &tv_out);
    if (select_result == 0) {
        os_log_debug(logger, "timeout");
        return { EchoReplyResult::Status::Timeout };
    }

    if (select_result < 0) {
        os_log_debug(logger, "select returned error %s", strerror(errno));
        return { EchoReplyResult::Status::SocketError };
    }

    // We have a packet to read
    unsigned char received_packet[sizeof(IcmpPacket6)] = { 0 };
    const auto bytes_received = recv(socket.fd(), &received_packet, sizeof(received_packet), 0);
    if (bytes_received <= 0) {
        os_log_debug(logger, "recv returned error %s", strerror(errno));
        return { EchoReplyResult::Status::SocketError };
    }

    if (bytes_received != sizeof(IcmpPacket6)) {
        os_log_error(logger, "packet received might be truncated");
        return { EchoReplyResult::Status::SocketError };
    }

    IcmpPacket6 icmp6_packet;
    memcpy(&icmp6_packet, received_packet, sizeof(icmp6_packet));

    const auto validation_result = validate_packet(icmp6_packet, sequence);
    if (validation_result != EchoReplyResult::Status::Success) {
        os_log_debug(logger, "Packet validation failed");
        return { validation_result };
    }

    return { EchoReplyResult::Status::Success,{} };
}

} // namespace

crd_ping_packet_result crd_ping_packet(const char* domain, int sequence)
{
    logger = os_log_create("cloudremotediagd", "ping");
    std::string error;
    std::optional<IcmpSocket> socket_opt = IcmpSocket::create(error);
    if (!socket_opt.has_value()) {
        os_log_debug(logger, "Failed to create an ICMP socket: %s", error.c_str());
        return { nullptr, 0, false };
    }

    return socket_opt->ping(domain, sequence);
}

crd_ping_packet_result crd_ping6_packet(const char* domain, int sequence)
{
    logger = os_log_create("cloudremotediagd", "ping6");
    std::string error;
    std::optional<IcmpSocket6> socket_opt = IcmpSocket6::create(error);
    if (!socket_opt.has_value()) {
        os_log_debug(logger, "Failed to create an ICMPv6 socket: %s", error.c_str());
        return { nullptr, 0, false };
    }

    return socket_opt->ping6(domain, sequence);
}
