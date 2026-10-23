// SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause
// handle_accept.bpf.c - TCP inbound connection handler (accept/accept4)
// Uses kprobe/kretprobe for compatibility across kernel BTF variations
#include <ehprobe_common.h>
#include <network_events.h>

char LICENSE[] SEC("license") = "Dual BSD/GPL";

struct accept_args {
    int fd;
    struct sockaddr *upeer_sockaddr;
};

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 4096);
    __type(key, u64);
    __type(value, struct accept_args);
} accept_args_map SEC(".maps");

SEC("kprobe/__sys_accept4")
int BPF_KPROBE(handle_kprobe_accept4,
               int fd,
               struct sockaddr *upeer_sockaddr,
               int *upeer_addrlen,
               int flags)
{
    if (!upeer_sockaddr) {
        return 0;
    }

    u32 map_key = 0;
    struct ehprobe_env *env = bpf_map_lookup_elem(&ehprobe_env_map, &map_key);
    if (!env || !env->flag_network) {
        return 0;
    }

    u64 pid_tgid = bpf_get_current_pid_tgid();

    struct accept_args args = {
        .fd = fd,
        .upeer_sockaddr = upeer_sockaddr,
    };

    bpf_map_update_elem(&accept_args_map, &pid_tgid, &args, BPF_ANY);

    return 0;
}

SEC("kretprobe/__sys_accept4")
int BPF_KRETPROBE(handle_kretprobe_accept4, long ret)
{
    u64 pid_tgid = bpf_get_current_pid_tgid();

    struct accept_args *args = bpf_map_lookup_elem(&accept_args_map, &pid_tgid);
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
    if (bpf_probe_read_user(&sa, sizeof(sa), args->upeer_sockaddr) < 0) {
        goto cleanup;
    }

    u16 family = sa.sin6_family;
    if (family != AF_INET && family != AF_INET6) {
        goto cleanup;
    }

    struct task_struct *task = bpf_get_current_task_btf();
    
    int new_fd = (int)ret;
    u16 local_port = get_local_port_from_fd(task, args->fd);

    uint32_t container_level = 0;
    uint64_t container_id = get_container_id(task, &container_level);

    trace_log("EHPROBE_NET_TCP: inbound pid=%d fd=%d local_port=%u", 
              (u32)(pid_tgid >> 32), new_fd, local_port);
    
    int err = ehprobe_net_tcp(task, new_fd, &sa, family, local_port,
                              NET_DIRECTION_INBOUND, container_id, container_level);
    if (err < 0) {
        trace_log("EHPROBE_NET_TCP: ehprobe_net_tcp (inbound) failed ret=%d", err);
    }

cleanup:
    bpf_map_delete_elem(&accept_args_map, &pid_tgid);
    return 0;
}
