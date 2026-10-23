// SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause
// handle_sendto.bpf.c - Outbound UDP handler for sendto() and send()
// Uses kprobe for compatibility across kernel BTF variations
#include <ehprobe_common.h>
#include <network_events.h>
#include <dpi_events.h>

char LICENSE[] SEC("license") = "Dual BSD/GPL";

SEC("kprobe/__sys_sendto")
int BPF_KPROBE(handle_kprobe_sendto,
               int fd,
               void *buff,
               size_t len,
               unsigned int flags,
               struct sockaddr *addr,
               int addr_len)
{
    u32 map_key = 0;
    struct ehprobe_env *env = bpf_map_lookup_elem(&ehprobe_env_map, &map_key);
    if (!env || !env->flag_network) {
        return 0;
    }

    struct task_struct *task = bpf_get_current_task_btf();
    u32 pid = BPF_CORE_READ(task, tgid);

    // Check socket type - handle UDP and ICMP (raw/dgram ICMP sockets)
    u64 sock_key = ((u64)pid << 32) | (u32)fd;
    struct socket_info *info = bpf_map_lookup_elem(&socket_type_map, &sock_key);
    if (!info) {
        return 0;
    }

    bool is_icmp = (info->protocol == IPPROTO_ICMP || info->protocol == IPPROTO_ICMPV6);
    bool is_udp  = (info->type == SOCK_DGRAM && !is_icmp);

    if (!is_udp && !is_icmp) {
        return 0;
    }

    struct sockaddr_in6 sa = {};
    u16 family;

    if (!addr) {
        if (is_icmp) {
            // ICMP raw sockets without explicit destination - skip
            return 0;
        }
        // send() on connected socket - check if it's a DNS socket
        if (!info->is_dns_connected) {
            // Connected non-DNS socket - we don't have the address
            // (The connect() handler already emitted NET_UDP for this)
            return 0;
        }

        // Use the stored address from connect()
        __builtin_memcpy(&sa, info->dns_server, sizeof(sa));
        family = sa.sin6_family;
        trace_log("EHPROBE_NET_SENDTO: connected DNS socket pid=%d fd=%d", pid, fd);
    } else {
        if (bpf_probe_read_user(&sa, sizeof(sa), addr) < 0) {
            return 0;
        }
        family = sa.sin6_family;
    }

    if (family != AF_INET && family != AF_INET6) {
        return 0;
    }

    uint32_t container_level = 0;
    uint64_t container_id = get_container_id(task, &container_level);

    // Handle ICMP: read ICMP header from payload and emit NET_ICMP event
    if (is_icmp) {
        if (!buff) {
            return 0;
        }
        // ICMP header: type(1) + code(1) + checksum(2) + identifier(2) + sequence(2)
        struct {
            u8 type;
            u8 code;
            u16 cksum;
            u16 id;
            u16 seq;
        } icmp_hdr = {};
        if (bpf_probe_read_user(&icmp_hdr, sizeof(icmp_hdr), buff) < 0) {
            return 0;
        }
        ehprobe_net_icmp(task, &sa, family,
                         icmp_hdr.type, icmp_hdr.code,
                         bpf_ntohs(icmp_hdr.id), bpf_ntohs(icmp_hdr.seq),
                         container_id, container_level);
        return 0;
    }

    // Always emit NET_UDP event for all UDP traffic
    ehprobe_net_udp(task, &sa, family, 0, NET_DIRECTION_OUTBOUND, container_id, container_level);

    // Check if this is DNS traffic (port 53) - emit additional DNS event
    u16 remote_port = get_remote_port_from_sockaddr(&sa, family);
    if (remote_port == DNS_PORT) {
        trace_log("EHPROBE_NET_SENDTO: DNS query pid=%d len=%zu", pid, len);

        ehprobe_dns(task, &sa, family, buff, (u32)len, DNS_DIRECTION_QUERY,
                   container_id, container_level);
    }

    // DPI: capture payload for deep packet inspection if enabled
    if (env->flag_dpi && buff && len > 0) {
        u16 local_port = get_local_port_from_fd(task, fd);
        int dpi_err = ehprobe_packet_data(task, (family == AF_INET)
            ? (void *)&((struct sockaddr_in *)&sa)->sin_addr
            : (void *)&sa.sin6_addr,
            family, 17, remote_port, local_port,
            NET_DIRECTION_OUTBOUND, 0, buff, (uint32_t)len,
            container_id, container_level);
        if (dpi_err < 0) {
            trace_log("EHPROBE_NET_SENDTO: ehprobe_packet_data failed ret=%d", dpi_err);
        }
    }

    return 0;
}
