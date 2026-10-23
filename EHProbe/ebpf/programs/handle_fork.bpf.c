// SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause
// handle_fork.bpf.c - Process fork handler
#include <ehprobe_common.h>
#include <process_events.h>
#include <container_logic.h>
#include <script_blocking.h>

char LICENSE[] SEC("license") = "Dual BSD/GPL";

// Process fork
SEC("tp_btf/sched_process_fork")
int BPF_PROG(handle_fork_tp, struct task_struct *parent, struct task_struct *child) {
	uint32_t flags = 0;
	BPF_CORE_READ_INTO(&flags, parent, flags);

	trace_log("EHPROBE_PROC_FORK: hook entered");

	/* We are not interested in kernel threads. */
	if (flags & PF_KTHREAD) {
		return 0;
	}

	/* Filter out thread creation - only report actual process forks */
	int32_t parent_tgid = BPF_CORE_READ(parent, tgid);
	int32_t child_tgid = BPF_CORE_READ(child, tgid);

	if (parent_tgid == child_tgid) {
		/* This is thread creation within the same process, not a fork */
		trace_log("EHPROBE_PROC_FORK: skipping thread creation (parent_tgid=%d, child_tgid=%d)",
		          parent_tgid, child_tgid);
		return 0;
	}

	trace_log("EHPROBE_PROC_FORK: actual fork detected (parent_tgid=%d, child_tgid=%d)",
	          parent_tgid, child_tgid);

	u32 map_key = 0;
	struct ehprobe_env *env = bpf_map_lookup_elem(&ehprobe_env_map, &map_key);
	if (env && env->flag_exec) {
		/* Process fork event */
		ehprobe_process_fork(parent, child);

		/* Propagate interpreter tracking for script blocking */
		if (env->flag_block_script) {
			ehprobe_propagate_interpreter_fork(parent_tgid, child_tgid);
		}
	}

	return 0;
}
