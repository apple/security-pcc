// SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause
// handle_exit.bpf.c - Process exit handler
#include <ehprobe_common.h>
#include <process_events.h>
#include <script_blocking.h>

char LICENSE[] SEC("license") = "Dual BSD/GPL";

// Process exit
SEC("tp_btf/sched_process_exit")
int BPF_PROG(handle_exit, struct task_struct *task) {
	u32 map_key = 0;
    struct ehprobe_env *env = bpf_map_lookup_elem(&ehprobe_env_map, &map_key);
    if (env && env->flag_exec) {
		uint32_t flags = 0;
		BPF_CORE_READ_INTO(&flags, task, flags);

		/* We are not interested in kernel threads. */
		if (flags & PF_KTHREAD) {
			return 0;
		}

		// Get pid and tgid
		pid_t pid = bpf_get_current_pid_tgid() >> 32;  // tgid (process ID)
		pid_t tid = bpf_get_current_pid_tgid() & 0xFFFFFFFF;  // pid (thread ID)
		if (pid != tid) {
			// thread termination - not interested
			return 0;
		}

		ehprobe_process_exit(task);
		// check if a container is terminated
		check_container_termination(task);

		// Clean up interpreter tracking for script blocking
		if (env->flag_block_script) {
			ehprobe_cleanup_interpreter_exit();
		}
    }

    return 0;
}
