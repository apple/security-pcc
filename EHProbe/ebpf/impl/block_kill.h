// SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause
#pragma once

#include <ehprobe_common.h>

#define SI_QUEUE -1
#define SI_USER 0
#define SIGHUP 1
#define SIGINT 2
#define SIGQUIT 3
#define SIGILL 4
#define SIGTRAP 5
#define SIGABRT 6
#define SIGIOT 6
#define SIGBUS 7
#define SIGFPE 8
#define SIGKILL 9
#define SIGUSR1 10
#define SIGSEGV 11
#define SIGUSR2 12
#define SIGPIPE 13
#define SIGALRM 14
#define SIGTERM 15
#define SIGSTKFLT 16
#define SIGCHLD 17
#define SIGCONT 18
#define SIGSTOP 19
#define SIGTSTP 20
#define SIGTTIN 21
#define SIGTTOU 22
#define SIGURG 23
#define SIGXCPU 24
#define SIGXFSZ 25
#define SIGVTALRM 26
#define SIGPROF 27
#define SIGWINCH 28
#define SIGIO 29
#define SIGPOLL SIGIO
/*
#define SIGLOST		29
*/
#define SIGPWR 30
#define SIGSYS 31
#define SIGUNUSED 31
#define SIGRTMIN 32
#define __SIGRTMAX 64
#define _NSIG (__SIGRTMAX + 1)
#define SIGRTMAX _NSIG

// returns 1 if the signal is going to kill process, 0 otherwise
static __always_inline int is_kill_signal(int sig) {
    switch (sig) {
    // Kill signal
    case SIGKILL:
    // Core dump signals
    case SIGQUIT:
    case SIGILL:
    case SIGTRAP:
    case SIGABRT:
    case SIGBUS:
    case SIGFPE:
    case SIGSEGV:
    case SIGXCPU:
    case SIGXFSZ:
    case SIGSYS:
    // Termination signals
    case SIGHUP:
    case SIGINT:
    case SIGUSR1:
    case SIGUSR2:
    case SIGPIPE:
    case SIGALRM:
    case SIGTERM:
    case SIGVTALRM:
    case SIGPROF:
    case SIGPOLL:
        return 1;
    default:
        // Real-time signals
        if (sig >= SIGRTMIN && sig <= SIGRTMAX) {
            return 1;
        }
        return 0;
    }
}

// return 0 if the signal should be allowed, 1 otherwise, -1 in case of an error
static __always_inline int ehprobe_should_block_kill(struct task_struct *p, int sig) {
    // Checking config map
	u32 map_key = 0;
    struct ehprobe_env *env = bpf_map_lookup_elem(&ehprobe_env_map, &map_key);
    if (!env || !env->flag_block_kill) {
        // nothing to do
        return 0;
    }

    // Get the PID of the process receiving the signal (the target)
    pid_t target_pid = BPF_CORE_READ(p, pid);
    if (target_pid != env->block_kill_pid_target) {
        // nothing to do - not our process
        trace_log("EHPROBE_BLOCK_KILL: not our process, target_pid = %d, config pid = %d\n",
            target_pid, env->block_kill_pid_target);
        return 0;
    }
    
    // Get the PID of the process sending the signal (the source)
    pid_t source_pid = bpf_get_current_pid_tgid() >> 32;
    if (source_pid == env->block_kill_pid_except_source) {
        // know source pid - allow SIGKILL to proceed
        trace_log("EHPROBE_BLOCK_KILL: Allow signal to process from %d to %d\n", source_pid, target_pid);
        return 0;
    }

    if (is_kill_signal(sig) == 0) {
        // not a kill signal
        trace_log("EHPROBE_BLOCK_KILL: Not a kill signal (%d) from %d to %d\n", sig, source_pid, target_pid);
        return 0;
    }

    // block the operation
    trace_log("EHPROBE_BLOCK_KILL: Blocking signal: source pid %d, target pid %d, signal %d\n", source_pid, target_pid, sig);

    // Send event using ehprobe API
    // Note: You'll need to define EVENT_TYPE_BLOCK_KILL in events.h
    struct event_context *evt_ctx = start_event(EVENT_TYPE_BLOCK_KILL, 2);
    if (!evt_ctx) {
        trace_log("EHPROBE_BLOCK_KILL: ERROR - start_event failed");
        update_drop_stats(EVENT_TYPE_BLOCK_KILL);
        return 0;
    }

    // Parameter 0: source_pid
    if (push_param_s64(evt_ctx, (int64_t)source_pid) < 0) {
        trace_log("EHPROBE_BLOCK_KILL: ERROR - push_param_s64 failed for source_pid");
        release_event(evt_ctx);
        update_drop_stats(EVENT_TYPE_BLOCK_KILL);
        return 0;
    }

    // Parameter 1: sig
    if (push_param_u32(evt_ctx, (uint32_t)sig) < 0) {
        trace_log("EHPROBE_BLOCK_KILL: ERROR - push_param_u32 failed for sig");
        release_event(evt_ctx);
        update_drop_stats(EVENT_TYPE_BLOCK_KILL);
        return 0;
    }

    trace_log("EHPROBE_BLOCK_KILL: submitting event");
    submit_event(evt_ctx);
    return 1;
}
