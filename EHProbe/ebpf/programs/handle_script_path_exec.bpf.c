// SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause
// handle_script_path_exec.bpf.c - Extract script path from interpreter argv
//
// Uses BPF tail calls to split the work into three stages, each with its own
// verifier instruction budget. Each stage has exactly one loop.
//
// Stage 0 (handle_script_path_exec): Check interpreter, read argv, skip argv[0]
// Stage 1 (script_path_find_arg):    Walk args to find first non-flag argument
// Stage 2 (script_path_copy):        Copy script path and update interpreter_pids
//
// State is passed between stages via the script_path_state per-CPU map.
#include <ehprobe_common.h>
#include <script_blocking.h>

char LICENSE[] SEC("license") = "Dual BSD/GPL";

// Maximum bytes to scan from argv. Uses the full inline_code_scan_buf (512).
// Each tail call stage has its own verifier budget, so the full size is safe.
#define ARGV_SCAN_LIMIT INLINE_CODE_SCAN_SIZE

// Per-CPU state passed between tail call stages
struct script_path_state {
    u32 tgid;
    int arg_after_argv0;  // Set by stage 0, used by stage 1
    int script_start;     // Set by stage 1, used by stage 2
    int limit;            // Actual bytes read (shared by all stages)
};

struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 1);
    __type(key, u32);
    __type(value, struct script_path_state);
} script_path_state_map __weak SEC(".maps");

// Prog array for tail calls between stages
struct {
    __uint(type, BPF_MAP_TYPE_PROG_ARRAY);
    __uint(max_entries, 2);
    __type(key, u32);
    __type(value, u32);
} script_path_progs __weak SEC(".maps");

// Stage 2: Copy the script path from the scan buffer into interpreter_pids.
// Reads script_start from state, finds the null terminator, copies the path.
SEC("tp_btf/sched_process_exec")
int BPF_PROG(script_path_copy, struct task_struct *p, pid_t old_pid,
             struct linux_binprm *bprm) {
    u32 map_key = 0;
    struct script_path_state *state = bpf_map_lookup_elem(&script_path_state_map, &map_key);
    if (!state || state->script_start == 0) {
        return 0;
    }

    struct inline_code_scan_buf *buf = bpf_map_lookup_elem(&inline_code_scan_map, &map_key);
    if (!buf) {
        return 0;
    }

    int script_start = state->script_start;
    int limit = state->limit;
    u32 tgid = state->tgid;

    // Clamp values from state map so the verifier can prove buffer access is safe
    if (script_start <= 0 || script_start >= ARGV_SCAN_LIMIT) {
        return 0;
    }
    if (limit <= script_start || limit >= ARGV_SCAN_LIMIT) {
        return 0;
    }
    script_start &= (ARGV_SCAN_LIMIT - 1);
    limit &= (ARGV_SCAN_LIMIT - 1);

    // Find end of script path (next null terminator)
    int script_end = limit;
    for (int i = script_start; i < ARGV_SCAN_LIMIT - 1; i++) {
        if (i >= limit) {
            break;
        }
        if (buf->data[i] == '\0') {
            script_end = i;
            break;
        }
    }

    int copy_len = script_end - script_start;
    if (copy_len <= 0) {
        return 0;
    }
    if (copy_len >= INTERPRETER_SCRIPT_PATH_LEN) {
        // Script path exceeds storage — extensionless scripts with truncated paths
        // bypass the SCRIPT_FILE_CHECK comparison (truncated != full path).
        // In enforce mode, kill the process. Legitimate scripts don't have 256+ char paths.
        struct ehprobe_env *env = bpf_map_lookup_elem(&ehprobe_env_map, &map_key);
        if (env && env->script_blocking_mode == EHPROBE_BLOCKING_MODE_ENFORCE) {
            trace_log("SB_SCRIPT_PATH: pid=%u path truncated (%d bytes), killing", tgid, copy_len);
            bpf_send_signal(9);
        }
        copy_len = INTERPRETER_SCRIPT_PATH_LEN - 1;
    }
    copy_len &= (INTERPRETER_SCRIPT_PATH_LEN - 1);

    // Use per-CPU temp buffer instead of stack (entry is 512 bytes, exceeds BPF stack limit)
    u32 entry_key = 0;
    struct interpreter_pid_entry *entry = bpf_map_lookup_elem(&local_interpreter_entry_map, &entry_key);
    if (!entry) {
        return 0;
    }
    __builtin_memset(entry, 0, sizeof(*entry));
    bpf_probe_read_kernel(entry->script_path, copy_len, &buf->data[script_start]);
    entry->script_path[copy_len] = '\0';

    trace_log("SB_SCRIPT_PATH: pid=%u script_path=%s", tgid, entry->script_path);
    bpf_map_update_elem(&interpreter_pids, &tgid, entry, BPF_ANY);
    return 0;
}

// Stage 1: Walk arguments after argv[0] to find the first non-flag argument.
// Skips flags (-u, -B, etc.) and value-consuming flags (-W val, -X val).
SEC("tp_btf/sched_process_exec")
int BPF_PROG(script_path_find_arg, struct task_struct *p, pid_t old_pid,
             struct linux_binprm *bprm) {
    u32 map_key = 0;
    struct script_path_state *state = bpf_map_lookup_elem(&script_path_state_map, &map_key);
    if (!state || state->arg_after_argv0 == 0) {
        return 0;
    }

    struct inline_code_scan_buf *buf = bpf_map_lookup_elem(&inline_code_scan_map, &map_key);
    if (!buf) {
        return 0;
    }

    int arg_after_argv0 = state->arg_after_argv0;
    int limit = state->limit;

    // Clamp values from state map for verifier
    if (arg_after_argv0 <= 0 || arg_after_argv0 >= ARGV_SCAN_LIMIT) {
        return 0;
    }
    if (limit <= arg_after_argv0 || limit >= ARGV_SCAN_LIMIT) {
        return 0;
    }
    arg_after_argv0 &= (ARGV_SCAN_LIMIT - 1);
    limit &= (ARGV_SCAN_LIMIT - 1);

    // Walk arguments to find first non-flag argument.
    // Uses a state machine that tracks position within each arg to detect
    // -W and -X flags without lookahead (which causes verifier issues).
    // States: 0=between args (after null), 1=saw first char of arg, 2=mid-arg
    int script_start = 0;
    int skip_next = 0;
    int pos_in_arg = 0;  // 0=at null/start, 1=first char seen, 2+=rest
    int cur_is_flag = 0;
    int cur_consumes_next = 0;

    for (int i = arg_after_argv0; i < ARGV_SCAN_LIMIT - 1; i++) {
        if (i >= limit) {
            break;
        }

        char c = buf->data[i];

        if (c == '\0') {
            // End of argument — apply skip_next from previous flag
            if (cur_is_flag && cur_consumes_next) {
                skip_next = 1;
            }
            pos_in_arg = 0;
            cur_is_flag = 0;
            cur_consumes_next = 0;
            continue;
        }

        if (pos_in_arg == 0) {
            // First character of a new argument
            pos_in_arg = 1;

            if (skip_next) {
                skip_next = 0;
                continue;
            }

            if (c == '-') {
                cur_is_flag = 1;
                continue;
            }

            // Non-flag argument found
            script_start = i;
            break;
        }

        if (pos_in_arg == 1 && cur_is_flag) {
            // Second character of a flag — check for -W or -X
            if (c == 'W' || c == 'X') {
                cur_consumes_next = 1;
            }
            pos_in_arg = 2;
            continue;
        }

        pos_in_arg = 2;
    }

    if (script_start == 0) {
        return 0;
    }

    // Store result and tail call to stage 2
    state->script_start = script_start;
    bpf_tail_call(ctx, &script_path_progs, 1);
    return 0;  // Fallback if tail call fails
}

// Stage 0 (entry): Check if interpreter is tracked, read argv, skip argv[0].
SEC("tp_btf/sched_process_exec")
int BPF_PROG(handle_script_path_exec, struct task_struct *p, pid_t old_pid,
             struct linux_binprm *bprm) {
    struct task_struct *task = bpf_get_current_task_btf();
    uint32_t flags = 0;
    BPF_CORE_READ_INTO(&flags, task, flags);

    if (flags & PF_KTHREAD) {
        return 0;
    }

    u32 map_key = 0;
    struct ehprobe_env *env = bpf_map_lookup_elem(&ehprobe_env_map, &map_key);
    if (!env || !env->flag_block_script) {
        return 0;
    }

    u32 tgid = bpf_get_current_pid_tgid() >> 32;
    struct interpreter_pid_entry *existing = bpf_map_lookup_elem(&interpreter_pids, &tgid);
    if (!existing) {
        return 0;
    }

    unsigned long arg_start = 0, arg_end = 0;
    BPF_CORE_READ_INTO(&arg_start, task, mm, arg_start);
    BPF_CORE_READ_INTO(&arg_end, task, mm, arg_end);

    if (arg_start == 0 || arg_end <= arg_start) {
        return 0;
    }

    struct inline_code_scan_buf *buf = bpf_map_lookup_elem(&inline_code_scan_map, &map_key);
    if (!buf) {
        return 0;
    }

    unsigned long scan_len = arg_end - arg_start;
    if (scan_len >= ARGV_SCAN_LIMIT) {
        scan_len = ARGV_SCAN_LIMIT - 1;
    }
    scan_len &= (ARGV_SCAN_LIMIT - 1);
    if (scan_len == 0) {
        return 0;
    }

    __builtin_memset(buf->data, 0, ARGV_SCAN_LIMIT);
    if (bpf_probe_read_user(buf->data, scan_len, (void *)arg_start) < 0) {
        return 0;
    }

    int limit = (int)scan_len;

    // Loop 1: Skip argv[0] — find first null terminator
    int arg_after_argv0 = 0;
    for (int i = 0; i < ARGV_SCAN_LIMIT - 1; i++) {
        if (i >= limit) {
            break;
        }
        if (buf->data[i] == '\0') {
            arg_after_argv0 = i + 1;
            break;
        }
    }

    if (arg_after_argv0 == 0 || arg_after_argv0 >= limit) {
        return 0;
    }

    // Store state and tail call to stage 1
    struct script_path_state *state = bpf_map_lookup_elem(&script_path_state_map, &map_key);
    if (!state) {
        return 0;
    }
    state->tgid = tgid;
    state->arg_after_argv0 = arg_after_argv0;
    state->script_start = 0;
    state->limit = limit;

    bpf_tail_call(ctx, &script_path_progs, 0);
    return 0;  // Fallback if tail call fails
}
