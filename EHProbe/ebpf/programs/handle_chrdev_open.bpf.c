// SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause
// handle_chrdev_open.bpf.c - Character device open handler
// Uses kprobe/kretprobe for compatibility across kernel versions
#include <ehprobe_common.h>
#include <device_events.h>

char LICENSE[] SEC("license") = "Dual BSD/GPL";

// Store chrdev_open args on entry
struct chrdev_open_args {
    struct inode *inode;
    struct file *filp;
};

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 4096);
    __type(key, u64);
    __type(value, struct chrdev_open_args);
} chrdev_open_args_map SEC(".maps");

SEC("kprobe/chrdev_open")
int BPF_KPROBE(handle_kprobe_chrdev_open,
               struct inode *inode,
               struct file *filp)
{
    if (!inode || !filp) {
        return 0;
    }

    // Check if device events are enabled (using FS feature flag)
    u32 map_key = 0;
    struct ehprobe_env *env = bpf_map_lookup_elem(&ehprobe_env_map, &map_key);
    if (!env || !env->flag_fs) {
        return 0;
    }

    u64 pid_tgid = bpf_get_current_pid_tgid();

    struct chrdev_open_args args = {
        .inode = inode,
        .filp = filp,
    };

    bpf_map_update_elem(&chrdev_open_args_map, &pid_tgid, &args, BPF_ANY);

    return 0;
}

SEC("kretprobe/chrdev_open")
int BPF_KRETPROBE(handle_kretprobe_chrdev_open, long ret)
{
    u64 pid_tgid = bpf_get_current_pid_tgid();

    struct chrdev_open_args *args = bpf_map_lookup_elem(&chrdev_open_args_map, &pid_tgid);
    if (!args) {
        return 0;
    }

    // Only proceed on success
    if (ret < 0) {
        goto cleanup;
    }

    // Check feature flag again
    u32 map_key = 0;
    struct ehprobe_env *env = bpf_map_lookup_elem(&ehprobe_env_map, &map_key);
    if (!env || !env->flag_fs) {
        goto cleanup;
    }

    struct task_struct *task = bpf_get_current_task_btf();

    // Get container information
    uint32_t container_level = 0;
    uint64_t container_id = get_container_id(task, &container_level);

    // Call the event emission helper
    int err = ehprobe_device_open(task, args->inode, args->filp, container_id, container_level);
    if (err < 0) {
        trace_log("EHPROBE_CHRDEV_OPEN: ehprobe_device_open failed ret=%d", err);
    }

cleanup:
    bpf_map_delete_elem(&chrdev_open_args_map, &pid_tgid);
    return 0;
}
