// SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause
// handle_bare_interp_exec.bpf.c - Bare interpreter detection
//
// Tail-called from handle_exec after inline code and stdin checks both pass.
// Runs with its own 1M instruction budget so the argv scan loop doesn't
// compete with handle_exec's budget.
#include <ehprobe_common.h>
#include <script_blocking.h>

char LICENSE[] SEC("license") = "Dual BSD/GPL";

SEC("tp_btf/sched_process_exec")
int BPF_PROG(handle_bare_interp_exec, struct task_struct *p, pid_t old_pid,
             struct linux_binprm *bprm) {
    u32 map_key = 0;
    struct ehprobe_env *env = bpf_map_lookup_elem(&ehprobe_env_map, &map_key);
    if (!env || env->script_blocking_mode == EHPROBE_BLOCKING_MODE_OFF) {
        return 0;
    }

    return ehprobe_check_bare_interpreter_exec(bprm,
        (uint32_t)env->script_blocking_mode);
}
