// SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause
// handle_file_open_new_exec.bpf.c - File open new executable detection (sleepable)
// This sleepable LSM hook handles O_CREAT detection and IMA hash computation.
// File path filtering and event emission is in handle_file_open.bpf.c (non-sleepable).
#include <ehprobe_common.h>
#include <new_fs_exec.h>

char LICENSE[] SEC("license") = "Dual BSD/GPL";

// LSM hook for file_open (sleepable) - O_CREAT + IMA hash detection only.
// Must be sleepable because bpf_ima_file_hash() may sleep.
SEC("lsm.s/file_open")
int BPF_PROG(handle_file_open_new_exec, struct file *file, int ret)
{
    // Check if FS events are enabled
    u32 map_key = 0;
    struct ehprobe_env *env = bpf_map_lookup_elem(&ehprobe_env_map, &map_key);
    if (!env || !env->flag_fs) {
        return 0;
    }

    unsigned int flags = BPF_CORE_READ(file, f_flags);

    // Check for O_CREAT - delegate to new_fs_exec for executable detection
    if (flags & O_CREAT) {
        int result = ehprobe_check_new_fs_exec(
            file,
            NULL,
            BPF_CORE_READ(file, f_inode, i_mode),
            NEW_FS_EXEC_OPERATION_CREATE);
        if (result < 0) {
            trace_log("EHPROBE_LSM_FILE_OPEN_NEW_EXEC: unable to check file, error %d", result);
        }
    }

    return 0;
}
