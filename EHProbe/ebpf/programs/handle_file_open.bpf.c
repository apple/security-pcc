// SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause
// handle_file_open.bpf.c - File open event emission (non-sleepable)
// This non-sleepable LSM hook handles file path filtering and event emission.
// The O_CREAT + IMA hash check is in handle_file_open_new_exec.bpf.c (sleepable).
#include <ehprobe_common.h>
#include <file_events.h>
#include <container_logic.h>

char LICENSE[] SEC("license") = "Dual BSD/GPL";

// LSM hook for file_open (non-sleepable)
// Non-sleepable context allows use of LPM_TRIE maps for prefix matching.
SEC("lsm/file_open")
int BPF_PROG(handle_file_open, struct file *file, int ret)
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

    unsigned int flags = BPF_CORE_READ(file, f_flags);

    // Get container information
    uint32_t container_level = 0;
    uint64_t container_id = get_container_id(task, &container_level);

    int err = ehprobe_file_open(task, file, flags, container_id, container_level);
    if (err < 0) {
        trace_log("EHPROBE_LSM_FILE_OPEN: ehprobe_file_open failed ret=%d", err);
    }

    return 0;
}
