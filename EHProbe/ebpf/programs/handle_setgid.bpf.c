// SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause
// handle_setgid.bpf.c - Setgid handler
#include <ehprobe_common.h>
#include <credential_events.h>
#include <container_logic.h>

char LICENSE[] SEC("license") = "Dual BSD/GPL";

// LSM hook for task_fix_setgid - called when a process's GID credentials change
SEC("lsm/task_fix_setgid")
int BPF_PROG(handle_setgid, struct cred *new, const struct cred *old, int flags)
{
    u32 map_key = 0;
    struct ehprobe_env *env = bpf_map_lookup_elem(&ehprobe_env_map, &map_key);
    if (!env || !env->flag_exec) {
        return 0;
    }

    int result = ehprobe_setgid(new, old);
    if (result < 0) {
        trace_log("EHPROBE_LSM_SETGID: unable to emit event, error %d", result);
    }

    return 0;
}
