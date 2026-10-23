// SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause
// handle_recvfrom.bpf.c - UDP receive handler
// Uses kprobe/kretprobe for compatibility across kernel BTF variations
#include <ehprobe_common.h>
#include <network_events.h>
#include <dpi_events.h>

char LICENSE[] SEC("license") = "Dual BSD/GPL";

struct recvfrom_args {
    int fd;
    void *ubuf;
    size_t size;
    struct sockaddr *addr;
};

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 4096);
    __type(key, u64);
    __type(value, struct recvfrom_args);
} recvfrom_args_map SEC(".maps");

SEC("kprobe/__sys_recvfrom")
int BPF_KPROBE(handle_kprobe_recvfrom,
               int fd,
               void *ubuf,
               size_t size,
               unsigned int flags,
               struct sockaddr *addr,
               int *addr_len)
{
    if (!addr) {
        return 0;
    }

    u32 map_key = 0;
    struct ehprobe_env *env = bpf_map_lookup_elem(&ehprobe_env_map, &map_key);
    if (!env || !env->flag_network) {
        return 0;
    }

    u64 pid_tgid = bpf_get_current_pid_tgid();

    struct recvfrom_args args = {
        .fd = fd,
        .ubuf = ubuf,
        .size = size,
        .addr = addr,
    };

    // Store info for further processing
    bpf_map_update_elem(&recvfrom_args_map, &pid_tgid, &args, BPF_ANY);

    return 0;
}

SEC("kretprobe/__sys_recvfrom")
int BPF_KRETPROBE(handle_kretprobe_recvfrom, long ret)
{
    u64 pid_tgid = bpf_get_current_pid_tgid();

    struct recvfrom_args *args = bpf_map_lookup_elem(&recvfrom_args_map, &pid_tgid);
    if (!args) {
        return 0;
    }

    if (ret < 0) {
        goto cleanup;
    }

    u32 map_key = 0;
    struct ehprobe_env *env = bpf_map_lookup_elem(&ehprobe_env_map, &map_key);
    if (!env || !env->flag_network) {
        goto cleanup;
    }

    struct sockaddr_in6 sa = {};
    if (bpf_probe_read_user(&sa, sizeof(sa), args->addr) < 0) {
        trace_log("EHPROBE_NET_RECVFROM: ERROR - failed to read sockaddr");
        goto cleanup;
    }

    u16 family = sa.sin6_family;
    if (family != AF_INET && family != AF_INET6) {
        goto cleanup;
    }

    struct task_struct *task = bpf_get_current_task_btf();
    u16 local_port = get_local_port_from_fd(task, args->fd);

    uint32_t container_level = 0;
    uint64_t container_id = get_container_id(task, &container_level);

    // Always emit NET_UDP event for all UDP traffic
    ehprobe_net_udp(task, &sa, family, local_port, NET_DIRECTION_INBOUND, 
                    container_id, container_level);

    u16 remote_port = get_remote_port_from_sockaddr(&sa, family);
    
    if (remote_port == DNS_PORT && args->ubuf && ret > 0) {
        // DNS response - capture payload
        trace_log("EHPROBE_NET_RECVFROM: DNS response detected, bytes=%ld", ret);
        
        int err = ehprobe_dns(task, &sa, family, (void *)args->ubuf, 
                              (u32)ret, DNS_DIRECTION_RESPONSE,
                              container_id, container_level);
        if (err < 0) {
            trace_log("EHPROBE_NET_RECVFROM: ehprobe_dns failed ret=%d", err);
        }
    }

    // DPI: capture payload for deep packet inspection if enabled
    if (env->flag_dpi && args->ubuf && ret > 0) {
        int dpi_err = ehprobe_packet_data(task, (family == AF_INET)
            ? (void *)&((struct sockaddr_in *)&sa)->sin_addr
            : (void *)&sa.sin6_addr,
            family, 17, remote_port, local_port,
            NET_DIRECTION_INBOUND, 0, (void *)args->ubuf, (uint32_t)ret,
            container_id, container_level);
        if (dpi_err < 0) {
            trace_log("EHPROBE_NET_RECVFROM: ehprobe_packet_data failed ret=%d", dpi_err);
        }
    }

cleanup:
    bpf_map_delete_elem(&recvfrom_args_map, &pid_tgid);
    return 0;
}
