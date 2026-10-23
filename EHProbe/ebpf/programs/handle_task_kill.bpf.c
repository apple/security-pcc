// SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause
// handle_task_kill.bpf.c - Task kill handler
#include <ehprobe_common.h>
#include <block_kill.h>

char LICENSE[] SEC("license") = "Dual BSD/GPL";

// LSM hook for task_kill
SEC("lsm/task_kill")
int BPF_PROG(handle_task_kill, struct task_struct *p, struct kernel_siginfo *info, 
             int sig, const struct cred *cred, int ret)
{
    if (ehprobe_should_block_kill(p, sig) == 1) {
        return -1;
    }
	return 0;
}
