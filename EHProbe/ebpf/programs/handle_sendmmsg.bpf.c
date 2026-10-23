// SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause
// handle_sendmmsg.bpf.c - Multiple outbound UDP messages handler
// Uses kprobe for compatibility across kernel BTF variations
#include <ehprobe_common.h>
#include <network_events.h>

char LICENSE[] SEC("license") = "Dual BSD/GPL";

// Helper to process a single message from sendmmsg
static __always_inline int process_mmsg_entry(
    struct task_struct *task,
    struct sockaddr_in6 *sa,
    u16 family,
    struct mmsghdr *msgvec,
    unsigned int idx,
    unsigned int vlen,
    uint64_t container_id,
    uint32_t container_level
) {
    if (idx >= vlen) {
        return 0;
    }

    struct mmsghdr mmsg = {};
    if (bpf_probe_read_user(&mmsg, sizeof(mmsg), &msgvec[idx]) < 0) {
        trace_log("EHPROBE_NET_SENDMMSG: failed to read mmsghdr[%u]", idx);
        return 0;
    }

    // Read the iovec to get the payload
    if (mmsg.msg_hdr.msg_iov && mmsg.msg_hdr.msg_iovlen > 0) {
        struct iovec iov = {};
        if (bpf_probe_read_user(&iov, sizeof(iov), mmsg.msg_hdr.msg_iov) < 0) {
            trace_log("EHPROBE_NET_SENDMMSG: failed to read iovec[%u]", idx);
            return 0;
        }

        void *buf = iov.iov_base;
        size_t len = iov.iov_len;

        trace_log("EHPROBE_NET_SENDMMSG: msg[%u] len=%zu", idx, len);

        // Emit DNS query event
        ehprobe_dns(task, sa, family, buf, (u32)len, DNS_DIRECTION_QUERY,
                   container_id, container_level);
    }

    return 0;
}

SEC("kprobe/__sys_sendmmsg")
int BPF_KPROBE(handle_kprobe_sendmmsg,
               int fd,
               struct mmsghdr *mmsg,
               unsigned int vlen,
               unsigned int flags)
{
    u32 map_key = 0;
    struct ehprobe_env *env = bpf_map_lookup_elem(&ehprobe_env_map, &map_key);
    if (!env || !env->flag_network) {
        return 0;
    }

    struct task_struct *task = bpf_get_current_task_btf();
    u32 pid = BPF_CORE_READ(task, tgid);

    // Check socket type - only handle UDP
    u64 sock_key = ((u64)pid << 32) | (u32)fd;
    struct socket_info *info = bpf_map_lookup_elem(&socket_type_map, &sock_key);
    if (!info || info->type != SOCK_DGRAM) {
        return 0;
    }

    // Check if this is a DNS-connected socket
    if (!info->is_dns_connected) {
        return 0;
    }

    // Get the stored DNS server address
    struct sockaddr_in6 sa = {};
    __builtin_memcpy(&sa, info->dns_server, sizeof(sa));
    u16 family = sa.sin6_family;

    if (family != AF_INET && family != AF_INET6) {
        return 0;
    }

    uint32_t container_level = 0;
    uint64_t container_id = get_container_id(task, &container_level);

    // Emit NET_UDP event for the DNS server connection
    ehprobe_net_udp(task, &sa, family, 0, NET_DIRECTION_OUTBOUND, container_id, container_level);

    trace_log("EHPROBE_NET_SENDMMSG: DNS queries pid=%d fd=%d vlen=%u", pid, fd, vlen);

    // Process up to 4 messages (DNS typically sends 2: A and AAAA)
    // Manually unrolled to satisfy BPF verifier
    process_mmsg_entry(task, &sa, family, mmsg, 0, vlen, container_id, container_level);
    process_mmsg_entry(task, &sa, family, mmsg, 1, vlen, container_id, container_level);
    process_mmsg_entry(task, &sa, family, mmsg, 2, vlen, container_id, container_level);
    process_mmsg_entry(task, &sa, family, mmsg, 3, vlen, container_id, container_level);

    return 0;
}
