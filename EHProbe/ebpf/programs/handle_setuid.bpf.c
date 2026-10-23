// SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause
// handle_setuid.bpf.c - Setuid handler
#include <ehprobe_common.h>
#include <credential_events.h>
#include <container_logic.h>

char LICENSE[] SEC("license") = "Dual BSD/GPL";

// LSM hook for task_fix_setuid - called when a process's UID credentials change
SEC("lsm/task_fix_setuid")
int BPF_PROG(handle_setuid, struct cred *new, const struct cred *old, int flags)
{
    u32 map_key = 0;
    struct ehprobe_env *env = bpf_map_lookup_elem(&ehprobe_env_map, &map_key);
    if (!env || !env->flag_exec) {
        return 0;
    }

    int result = ehprobe_setuid(new, old);
    if (result < 0) {
        trace_log("EHPROBE_LSM_SETUID: unable to emit event, error %d", result);
    }

    return 0;
}
