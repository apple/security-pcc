// SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause
// handle_exec.bpf.c - Process execution handler
#include <ehprobe_common.h>
#include <process_events.h>
#include <script_blocking.h>

char LICENSE[] SEC("license") = "Dual BSD/GPL";

// Process execution
SEC("tp_btf/sched_process_exec")
int BPF_PROG(handle_exec, struct task_struct *p, pid_t old_pid, struct linux_binprm *bprm) {
	struct task_struct *task = bpf_get_current_task_btf();
	uint32_t flags = 0;
	BPF_CORE_READ_INTO(&flags, task, flags);

	trace_log("EHPROBE_PROC_EXEC: hook entered");

	/* We are not interested in kernel threads. */
	if (flags & PF_KTHREAD) {
		return 0;
	}

	u32 map_key = 0;
    struct ehprobe_env *env = bpf_map_lookup_elem(&ehprobe_env_map, &map_key);
    if (env && env->flag_exec) {
		if (env->blocking_mode == EHPROBE_BLOCKING_MODE_OFF) {
			/* Check if a container was started */
	        /* ehprobe_container_exec() is called from handle_bprm_check when blocking_mode is not off */
    		ehprobe_container_exec(bprm->file);
		}
		/* Process exec event */
		ehprobe_process_exec(p, bprm);

		/* Track interpreter PIDs and enforce script restrictions */
		if (env->script_blocking_mode != EHPROBE_BLOCKING_MODE_OFF) {
			ehprobe_check_interpreter_exec();
			bpf_tail_call(ctx, &inline_code_progs, 0);
		}
    }

    return 0;
}
