// SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause
// handle_inline_code_exec.bpf.c - Inline code and stdin detection
//
// Tail-called from handle_exec after interpreter PID tracking.
// Runs with its own 1M instruction budget so the 512-byte argv scan loop
// doesn't compete with handle_exec's budget.
// If inline code and stdin checks both pass, tail-calls to bare interpreter.
#include <ehprobe_common.h>
#include <script_blocking.h>

char LICENSE[] SEC("license") = "Dual BSD/GPL";

SEC("tp_btf/sched_process_exec")
int BPF_PROG(handle_inline_code_exec, struct task_struct *p, pid_t old_pid,
             struct linux_binprm *bprm) {
    u32 map_key = 0;
    struct ehprobe_env *env = bpf_map_lookup_elem(&ehprobe_env_map, &map_key);
    if (!env || env->script_blocking_mode == EHPROBE_BLOCKING_MODE_OFF) {
        return 0;
    }

    uint32_t mode = (uint32_t)env->script_blocking_mode;

    if (!ehprobe_check_inline_code_exec(bprm, mode)) {
        if (!ehprobe_check_stdin_exec(bprm, mode)) {
            bpf_tail_call(ctx, &bare_interp_progs, 0);
        }
    }

    return 0;
}
