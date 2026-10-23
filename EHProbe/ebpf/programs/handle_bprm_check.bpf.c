// SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause
// handle_bprm_check.bpf.c - Binary permission check handler
#include <ehprobe_common.h>
#include <exec_blocking.h>
#include <container_logic.h>

char LICENSE[] SEC("license") = "Dual BSD/GPL";

// LSM hook for bprm_check_security (sleepable)
SEC("lsm.s/bprm_check_security")
int BPF_PROG(handle_bprm_check, struct linux_binprm *bprm, int ret) {
	struct task_struct *task = bpf_get_current_task_btf();
	uint32_t flags = 0;
	BPF_CORE_READ_INTO(&flags, task, flags);

	/* We are not interested in kernel threads. */
	if (flags & PF_KTHREAD) {
		return 0;
	}

	u32 map_key = 0;
	struct ehprobe_env *env = bpf_map_lookup_elem(&ehprobe_env_map, &map_key);
	if (!env) {
		return 0;
	}

	/* Exec blocking */
	if (env->blocking_mode != EHPROBE_BLOCKING_MODE_OFF) {
		if (ehprobe_container_exec(bprm->file) != 0) {
			trace_log("EHPROBE_EXEC_BLOCKING: container processing error");
			/* fall through to script blocking */
		} else {
			int decision = ehprobe_exec_blocking(bprm);
			if (decision < 0) {
				trace_log("EHPROBE_EXEC_BLOCKING: exec blocking decision error");
			} else {
				trace_log("EHPROBE_EXEC_BLOCKING: decision=%s",
					(decision == 0) ? "allow" : "deny");
				if (decision > 0 && env->blocking_mode == EHPROBE_BLOCKING_MODE_ENFORCE) {
					return -1;
				}
			}
		}
	}

	return 0;
}
