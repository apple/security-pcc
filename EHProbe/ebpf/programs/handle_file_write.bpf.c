// SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause
// handle_file_write.bpf.c - File write handler
// Uses kprobe on vfs_write for file write detection
#include <ehprobe_common.h>
#include <file_events.h>
#include <container_logic.h>

char LICENSE[] SEC("license") = "Dual BSD/GPL";

// Store vfs_write args on entry
// Using LRU_HASH to automatically evict stale entries if kretprobe doesn't fire
// (e.g., process killed during syscall). This prevents map exhaustion.
struct vfs_write_args {
    struct file *file;
};

struct {
    __uint(type, BPF_MAP_TYPE_LRU_HASH);
    __uint(max_entries, 4096);
    __type(key, u64);
    __type(value, struct vfs_write_args);
} vfs_write_args_map SEC(".maps");

SEC("kprobe/vfs_write")
int BPF_KPROBE(handle_kprobe_vfs_write, struct file *file)
{
    if (!file) {
        return 0;
    }

    // Check if FS events are enabled
    u32 map_key = 0;
    struct ehprobe_env *env = bpf_map_lookup_elem(&ehprobe_env_map, &map_key);
    if (!env || !env->flag_fs) {
        return 0;
    }

    u64 pid_tgid = bpf_get_current_pid_tgid();

    struct vfs_write_args args = {
        .file = file,
    };

    int ret = bpf_map_update_elem(&vfs_write_args_map, &pid_tgid, &args, BPF_ANY);
    if (ret < 0) {
        // Map full or other error - write event will be lost for this syscall
        trace_log("EHPROBE_FILE_WRITE: kprobe map update failed ret=%d", ret);
    }

    return 0;
}

SEC("kretprobe/vfs_write")
int BPF_KRETPROBE(handle_kretprobe_vfs_write, long ret)
{
    u64 pid_tgid = bpf_get_current_pid_tgid();

    struct vfs_write_args *args = bpf_map_lookup_elem(&vfs_write_args_map, &pid_tgid);
    if (!args) {
        return 0;
    }

    // Only proceed on success (ret > 0 means bytes written)
    if (ret <= 0) {
        goto cleanup;
    }

    // args existing in the map means flag_fs was true at kprobe entry - no re-check needed
    struct task_struct *task = bpf_get_current_task_btf();

    // Skip kernel threads
    u32 task_flags = BPF_CORE_READ(task, flags);
    if (task_flags & PF_KTHREAD) {
        goto cleanup;
    }

    // Get container information
    uint32_t container_level = 0;
    uint64_t container_id = get_container_id(task, &container_level);

    // Emit the file write event
    int err = ehprobe_file_write(task, args->file, container_id, container_level);
    if (err < 0) {
        trace_log("EHPROBE_FILE_WRITE: ehprobe_file_write failed ret=%d", err);
    }

cleanup:
    bpf_map_delete_elem(&vfs_write_args_map, &pid_tgid);
    return 0;
}
