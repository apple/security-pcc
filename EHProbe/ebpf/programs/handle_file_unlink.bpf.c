// SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause
// handle_file_unlink.bpf.c - File unlink (delete) handler
// Uses LSM hook for path_unlink
#include <ehprobe_common.h>
#include <file_events.h>
#include <container_logic.h>

char LICENSE[] SEC("license") = "Dual BSD/GPL";

// LSM hook for path_unlink - called when a file is being deleted
SEC("lsm/path_unlink")
int BPF_PROG(handle_path_unlink, struct path *dir, struct dentry *dentry, int ret)
{
    // Check if FS events are enabled
    u32 map_key = 0;
    struct ehprobe_env *env = bpf_map_lookup_elem(&ehprobe_env_map, &map_key);
    if (!env || !env->flag_fs) {
        return 0;
    }

    struct task_struct *task = bpf_get_current_task_btf();

    // Skip kernel threads
    u32 task_flags = BPF_CORE_READ(task, flags);
    if (task_flags & PF_KTHREAD) {
        return 0;
    }

    // Get container information
    uint32_t container_level = 0;
    uint64_t container_id = get_container_id(task, &container_level);

    int err = ehprobe_file_unlink(task, dir, dentry, container_id, container_level);
    if (err < 0) {
        trace_log("EHPROBE_FILE_UNLINK: ehprobe_file_unlink failed ret=%d", err);
    }

    return 0;
}
