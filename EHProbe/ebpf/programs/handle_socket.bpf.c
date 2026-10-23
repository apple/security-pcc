// SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause
// handle_socket.bpf.c - Track socket creation and cleanup
// Uses kprobe/kretprobe for compatibility across kernel BTF variations
#include <ehprobe_common.h>
#include <network_events.h>

char LICENSE[] SEC("license") = "Dual BSD/GPL";

// Store socket() args on entry
struct socket_args {
    int family;
    int type;
    int protocol;
};

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 4096);
    __type(key, u64);
    __type(value, struct socket_args);
} socket_args_map SEC(".maps");

SEC("kprobe/__sys_socket")
int BPF_KPROBE(handle_kprobe_socket,
               int family,
               int type,
               int protocol)
{
    // Only track IPv4/IPv6 TCP/UDP/ICMP
    if (family != AF_INET && family != AF_INET6) {
        return 0;
    }

    // Mask out flags like SOCK_NONBLOCK, SOCK_CLOEXEC
    int base_type = type & 0xF;
    bool is_tcp_udp = (base_type == SOCK_STREAM || base_type == SOCK_DGRAM);
    bool is_icmp_raw = (base_type == SOCK_RAW &&
                        (protocol == IPPROTO_ICMP || protocol == IPPROTO_ICMPV6));
    if (!is_tcp_udp && !is_icmp_raw) {
        return 0;
    }

    u64 pid_tgid = bpf_get_current_pid_tgid();

    struct socket_args args = {
        .family = family,
        .type = base_type,
        .protocol = protocol,
    };

    bpf_map_update_elem(&socket_args_map, &pid_tgid, &args, BPF_ANY);

    return 0;
}

SEC("kretprobe/__sys_socket")
int BPF_KRETPROBE(handle_kretprobe_socket, long ret)
{
    u64 pid_tgid = bpf_get_current_pid_tgid();

    struct socket_args *args = bpf_map_lookup_elem(&socket_args_map, &pid_tgid);
    if (!args) {
        return 0;
    }

    int fd = (int)ret;
    if (fd < 0) {
        goto cleanup;
    }

    u32 pid = pid_tgid >> 32;
    u64 sock_key = ((u64)pid << 32) | (u32)fd;

    struct socket_info info = {
        .type = args->type,
        .family = args->family,
        .protocol = (uint16_t)args->protocol,
    };

    bpf_map_update_elem(&socket_type_map, &sock_key, &info, BPF_ANY);

    trace_log("EHPROBE_NET_SOCKET: added socket to map: type=%d, family=%d, protocol=%d",
              info.type, info.family, info.protocol);

cleanup:
    bpf_map_delete_elem(&socket_args_map, &pid_tgid);
    return 0;
}

SEC("kprobe/close_fd")
int BPF_KPROBE(handle_kprobe_close, unsigned int fd)
{
    u32 pid = bpf_get_current_pid_tgid() >> 32;

    u64 sock_key = ((u64)pid << 32) | (u32)fd;
    bpf_map_delete_elem(&socket_type_map, &sock_key);

    return 0;
}
