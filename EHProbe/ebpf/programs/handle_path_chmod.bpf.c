// SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause
// handle_path_chmod.bpf.c - Path chmod handler
#include <ehprobe_common.h>
#include <new_fs_exec.h>

char LICENSE[] SEC("license") = "Dual BSD/GPL";

// LSM hook for path_chmod
SEC("lsm/path_chmod")
int BPF_PROG(handle_path_chmod, struct path *path, umode_t mode, int ret)
{
    int result = ehprobe_check_new_fs_exec(NULL, path, mode, NEW_FS_EXEC_OPERATION_CHMOD);
    if (result < 0) {
        trace_log("EHPROBE_LSM_PATH_CHMOD: unable to check file, error %d", result);
    }

    return 0;
}
