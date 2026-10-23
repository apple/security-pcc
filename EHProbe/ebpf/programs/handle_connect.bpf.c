// SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause
// handle_connect.bpf.c - Network connection handler (outbound)
// Uses kprobe/kretprobe for compatibility across kernel BTF variations
#include <ehprobe_common.h>
#include <network_events.h>

char LICENSE[] SEC("license") = "Dual BSD/GPL";

#define EINPROGRESS 115

struct connect_args {
    int fd;
    struct sockaddr *uservaddr;
};

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 4096);
    __type(key, u64);
    __type(value, struct connect_args);
} connect_args_map SEC(".maps");

SEC("kprobe/__sys_connect")
int BPF_KPROBE(handle_kprobe_connect,
               int fd,
               struct sockaddr *uservaddr,
               int addrlen)
{
    if (!uservaddr) {
        return 0;
    }

    u32 map_key = 0;
    struct ehprobe_env *env = bpf_map_lookup_elem(&ehprobe_env_map, &map_key);
    if (!env || !env->flag_network) {
        return 0;
    }

    u64 pid_tgid = bpf_get_current_pid_tgid();

    struct connect_args args = {
        .fd = fd,
        .uservaddr = uservaddr,
    };

    bpf_map_update_elem(&connect_args_map, &pid_tgid, &args, BPF_ANY);

    return 0;
}

SEC("kretprobe/__sys_connect")
int BPF_KRETPROBE(handle_kretprobe_connect, long ret)
{
    u64 pid_tgid = bpf_get_current_pid_tgid();

    struct connect_args *args = bpf_map_lookup_elem(&connect_args_map, &pid_tgid);
    if (!args) {
        return 0;
    }

    // Only proceed on success or EINPROGRESS (non-blocking)
    if (ret < 0 && ret != -EINPROGRESS) {
        goto cleanup;
    }

    u32 map_key = 0;
    struct ehprobe_env *env = bpf_map_lookup_elem(&ehprobe_env_map, &map_key);
    if (!env || !env->flag_network) {
        goto cleanup;
    }

    struct sockaddr_in6 sa = {};
    if (bpf_probe_read_user(&sa, sizeof(sa), args->uservaddr) < 0) {
        goto cleanup;
    }

    u16 family = sa.sin6_family;
    if (family != AF_INET && family != AF_INET6) {
        goto cleanup;
    }

    struct task_struct *task = bpf_get_current_task_btf();
    u32 pid = BPF_CORE_READ(task, tgid);

    // Look up socket type
    u64 sock_key = ((u64)pid << 32) | (u32)args->fd;
    struct socket_info *info = bpf_map_lookup_elem(&socket_type_map, &sock_key);
    
    // Default to TCP if not found (conservative)
    u16 sock_type = info ? info->type : SOCK_STREAM;

    uint32_t container_level = 0;
    uint64_t container_id = get_container_id(task, &container_level);

    int err;
    if (sock_type == SOCK_STREAM) {
        trace_log("EHPROBE_NET_CONNECT: TCP outbound pid=%d fd=%d", pid, args->fd);
        err = ehprobe_net_tcp(task, args->fd, &sa, family, 0, NET_DIRECTION_OUTBOUND, container_id, container_level);
        if (err < 0) {
            trace_log("EHPROBE_NET_CONNECT: ehprobe_net_tcp failed ret=%d", err);
        }
    } else if (sock_type == SOCK_DGRAM) {
        // Check if this is a DNS connection (port 53)
        u16 remote_port = get_remote_port_from_sockaddr(&sa, family);
        
        if (remote_port == DNS_PORT && info) {
            // Update socket_info to mark as DNS-connected and store server address
            struct socket_info updated_info = *info;
            updated_info.is_dns_connected = 1;
            __builtin_memcpy(updated_info.dns_server, &sa, sizeof(updated_info.dns_server));
            bpf_map_update_elem(&socket_type_map, &sock_key, &updated_info, BPF_ANY);

            // Don't emit NET_UDP here - will be emitted when actual DNS query is sent
            // This avoids duplicate events since sendmsg/sendto/sendmmsg will emit NET_UDP
            trace_log("EHPROBE_NET_CONNECT: DNS socket marked pid=%d fd=%d", pid, args->fd);
            goto cleanup;
        }
        
        trace_log("EHPROBE_NET_CONNECT: UDP pid=%d fd=%d port=%u", pid, args->fd, remote_port);
        err = ehprobe_net_udp(task, &sa, family, 0, NET_DIRECTION_OUTBOUND, container_id, container_level);
        if (err < 0) {
            trace_log("EHPROBE_NET_CONNECT: ehprobe_net_udp failed ret=%d", err);
        }
    } else {
        trace_log("EHPROBE_NET_CONNECT: unknown socket type (%d), pid=%d fd=%d", sock_type, pid, args->fd);
    }

cleanup:
    bpf_map_delete_elem(&connect_args_map, &pid_tgid);
    return 0;
}
