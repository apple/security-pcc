// SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause
#pragma once

#include <ehprobe_common.h>
#include <container_logic.h>
#include <exec_blocking.h>

#include <bpf/bpf_tracing.h>
#include <bpf/bpf_endian.h>

// Per-CPU map to store script path (reuses path_entry from data.h)
struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 1);
    __type(key, u32);
    __type(value, struct path_entry);
} local_script_path_map __weak SEC(".maps");

// Per-CPU buffer for scanning argv data during inline code detection
struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 1);
    __type(key, u32);
    __type(value, struct inline_code_scan_buf);
} inline_code_scan_map __weak SEC(".maps");

// Small per-CPU buffer for the bare interpreter argv scan.
// 64 bytes covers all practical bare interpreter args (e.g., "python3\0-i\0-q\0-Wdefault\0" = ~28 bytes).
// If total argv exceeds 64 bytes, the invocation is not bare (has a script path or long args).
// This scan runs in a tail-called program with its own 1M instruction budget.
#define BARE_INTERP_SCAN_SIZE 64
struct bare_interp_scan_buf {
    char data[BARE_INTERP_SCAN_SIZE];
};
struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 1);
    __type(key, u32);
    __type(value, struct bare_interp_scan_buf);
} bare_interp_scan_map __weak SEC(".maps");

// Prog array for inline code detection tail call from handle_exec.
// handle_exec tail-calls into handle_inline_code_exec (key 0) which
// runs inline code, stdin, and bare interpreter checks with its own budget.
struct {
    __uint(type, BPF_MAP_TYPE_PROG_ARRAY);
    __uint(max_entries, 1);
    __type(key, u32);
    __type(value, u32);
} inline_code_progs __weak SEC(".maps");

// Prog array for bare interpreter tail call.
// handle_inline_code_exec tail-calls into handle_bare_interp_exec (key 0)
// after inline code and stdin checks both pass.
struct {
    __uint(type, BPF_MAP_TYPE_PROG_ARRAY);
    __uint(max_entries, 1);
    __type(key, u32);
    __type(value, u32);
} bare_interp_progs __weak SEC(".maps");

// Maximum bytes to scan from argv for script path extraction.
// Used by handle_script_path_exec.bpf.c (separate BPF program with its own
// instruction budget).
#define SCRIPT_PATH_SCAN_SIZE INLINE_CODE_SCAN_SIZE

// Per-CPU temporary storage for interpreter_pid_entry (too large for BPF stack at 512 bytes)
struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 1);
    __type(key, u32);
    __type(value, struct interpreter_pid_entry);
} local_interpreter_entry_map __weak SEC(".maps");

// Check if the current process's comm matches a known interpreter.
// If so, add the tgid to the interpreter_pids tracking map with an empty entry.
// The script path is extracted separately by handle_script_path_exec.bpf.c
// (a separate BPF program on the same tracepoint with its own instruction budget).
// Called from handle_exec.bpf.c after process exec.
static __always_inline void ehprobe_check_interpreter_exec(void) {
    struct task_struct *task = bpf_get_current_task_btf();
    char comm[TASK_COMM_LEN] = {};
    BPF_CORE_READ_INTO(&comm, task, comm);

    struct interpreter_binary_key key = {};
    __builtin_memcpy(key.comm, comm, TASK_COMM_LEN);

    uint8_t *found = bpf_map_lookup_elem(&interpreter_binaries, &key);
    trace_log("SB_EXEC: comm=%s found=%d", comm, found ? 1 : 0);
    if (found) {
        u32 tgid = bpf_get_current_pid_tgid() >> 32;
        u32 map_key = 0;
        struct interpreter_pid_entry *entry = bpf_map_lookup_elem(&local_interpreter_entry_map, &map_key);
        if (entry) {
            __builtin_memset(entry, 0, sizeof(*entry));
            bpf_map_update_elem(&interpreter_pids, &tgid, entry, BPF_ANY);
        }
    }
}

// Propagate interpreter tracking from parent to child on fork.
// Called from handle_fork.bpf.c.
static __always_inline void ehprobe_propagate_interpreter_fork(u32 parent_tgid, u32 child_tgid) {
    struct interpreter_pid_entry *parent_entry = bpf_map_lookup_elem(&interpreter_pids, &parent_tgid);
    if (parent_entry) {
        bpf_map_update_elem(&interpreter_pids, &child_tgid, parent_entry, BPF_ANY);
        trace_log("EHPROBE_SCRIPT_BLOCKING: Propagated interpreter tracking from PID %u to child PID %u",
                  parent_tgid, child_tgid);
    }
}

// Remove a PID from the interpreter tracking map on process exit.
// Called from handle_exit.bpf.c.
static __always_inline void ehprobe_cleanup_interpreter_exit(void) {
    u32 tgid = bpf_get_current_pid_tgid() >> 32;
    bpf_map_delete_elem(&interpreter_pids, &tgid);
}

// Check if a file path ends with ".py" or ".pyc".
// path_len is the raw bpf_d_path return (includes null terminator).
// path is in a map value buffer. Returns 1 if match, 0 otherwise.
static __always_inline int is_python_script(const char *path, int path_len) {
    // path_len from bpf_d_path includes the null terminator.
    // String length = path_len - 1. Need at least ".py\0" = 4 bytes.
    if (path_len < 4) {
        return 0;
    }

    // Read the last 5 bytes of the path into a stack buffer to avoid
    // verifier issues with variable-offset map value access.
    // offset = path_len - 5 (or path_len - 4 for .py check)
    char tail[8] = {};
    int offset = path_len - 5;
    if (offset < 0) {
        offset = 0;
    }
    // Clamp offset for the verifier
    offset &= 4095;

    bpf_probe_read_kernel(tail, 5, path + offset);

    // For a path like "/tmp/test.py\0" with path_len=13:
    //   offset = 13-5 = 8, tail = "t.py\0"
    //   We check tail[1]=='.' tail[2]=='p' tail[3]=='y' tail[4]=='\0'
    // For ".pyc\0" with path_len=? :
    //   offset = path_len-5, tail = ".pyc\0"
    //   We check tail[0]=='.' tail[1]=='p' tail[2]=='y' tail[3]=='c' tail[4]=='\0'

    // Check for ".py\0" at end
    if (tail[1] == '.' && tail[2] == 'p' && tail[3] == 'y' && tail[4] == '\0') {
        return 1;
    }

    // Check for ".pyc\0" at end
    if (tail[0] == '.' && tail[1] == 'p' && tail[2] == 'y' && tail[3] == 'c' && tail[4] == '\0') {
        return 1;
    }

    return 0;
}

// Check if the current exec is an interpreter invoked with inline code.
// Detects both standalone "-c" and combined flags containing 'c' (e.g., -uc, -Bc, -suc).
// Must be called from tp_btf/sched_process_exec where current->mm is the NEW mm,
// so argv is readable via task->mm->arg_start using bpf_probe_read_user.
//
// Scans the first INLINE_CODE_SCAN_SIZE bytes of argv with a state machine:
//   1. Skips argv[0] (interpreter path)
//   2. For each arg starting with '-', scans chars for 'c'
//   3. Stops at first non-flag arg (positional = flags are done)
//   4. Handles -W/-X value-consuming flags: chars after W/X in the same
//      arg are the option value, not flags (e.g., -Wdefault is not -c)
//   5. Handles -m module flag: chars after m are the module name, not flags
//      (e.g., -mc = module "c", not inline code)
//
// CPython processes combined flags left-to-right and stops at -c, so
// -uc = unbuffered + inline code, but -Wc = warning filter "c" (not -c),
// and -mc = module "c" (not -c).
//
// If inline code is detected:
//   - Emits a EVENT_TYPE_SCRIPT_SECURITY event
//   - In enforce mode, sends SIGKILL (process dies before any user-space code runs)
//   - In audit mode, logs but allows execution
//
// Returns: 1 if inline code detected, 0 otherwise
static __always_inline int ehprobe_check_inline_code_exec(struct linux_binprm *bprm,
                                                           uint32_t script_blocking_mode) {
    struct task_struct *task = bpf_get_current_task_btf();

    // Check if comm matches a known interpreter
    char comm[TASK_COMM_LEN] = {};
    BPF_CORE_READ_INTO(&comm, task, comm);

    struct interpreter_binary_key ikey = {};
    __builtin_memcpy(ikey.comm, comm, TASK_COMM_LEN);

    if (!bpf_map_lookup_elem(&interpreter_binaries, &ikey)) {
        return 0;  // Not an interpreter
    }

    // Read arg_start and arg_end from the new mm
    unsigned long arg_start = 0, arg_end = 0;
    BPF_CORE_READ_INTO(&arg_start, task, mm, arg_start);
    BPF_CORE_READ_INTO(&arg_end, task, mm, arg_end);

    if (arg_start == 0 || arg_end <= arg_start) {
        return 0;
    }

    // Get per-CPU scan buffer
    u32 map_key = 0;
    struct inline_code_scan_buf *buf = bpf_map_lookup_elem(&inline_code_scan_map, &map_key);
    if (!buf) {
        return 0;
    }

    // Scan the full 512-byte argv buffer for -c flag detection. Python flags
    // always precede positional args, so -c appears early in argv. This runs
    // in a tail-called program (handle_inline_code_exec) with its own 1M
    // instruction budget, allowing the full buffer to be scanned.
#define INLINE_CODE_FLAG_SCAN INLINE_CODE_SCAN_SIZE

    unsigned long scan_len = arg_end - arg_start;
    if (scan_len >= INLINE_CODE_FLAG_SCAN) {
        scan_len = INLINE_CODE_FLAG_SCAN - 1;
    }
    // Clamp for verifier (must be <= buffer size)
    scan_len &= (INLINE_CODE_FLAG_SCAN - 1);
    if (scan_len == 0) {
        return 0;
    }

    if (bpf_probe_read_user(buf->data, scan_len, (void *)arg_start) < 0) {
        trace_log("SB_INLINE: bpf_probe_read_user failed for argv");
        return 0;
    }
    // Null-terminate after the read data so the scan doesn't read stale bytes.
    buf->data[scan_len & (INLINE_CODE_FLAG_SCAN - 1)] = '\0';

    // Scan for 'c' in any flag argument (handles combined flags like -uc, -Bc, -suc).
    // argv is null-separated: "python3\0-uc\0code...\0"
    // Walk args after argv[0]. For each arg starting with '-', scan chars for 'c'.
    // -W and -X consume remaining chars as value, so 'c' after W/X is not inline code.
    // -m consumes remaining chars as module name, so 'c' after m is not inline code.
    // When -W/-X is the last char in an arg (next byte is null), the value is the
    // next arg — skip_next skips it. Same pattern as ehprobe_check_bare_interpreter_exec.
    // -m does NOT set skip_next — the module name arg is a positional that triggers
    // the break, preventing the scanner from misinterpreting module arguments as flags.
    // Stop at first non-flag arg (positional args mean flag parsing is done).
    int found = 0;
    int limit = (int)scan_len;
    int past_argv0 = 0;   // 0=still in argv[0], 1=past it
    int in_flag = 0;       // 1=current arg is a flag (starts with -)
    int at_arg_start = 0;  // 1=next non-null char is start of new arg
    int skip_next = 0;     // 1=next arg is consumed value for -W/-X

    for (int i = 0; i < INLINE_CODE_FLAG_SCAN - 1; i++) {
        if (i >= limit) {
            break;
        }

        char c = buf->data[i];

        // Fast path: skip argv[0] without touching flag state.
        // Isolating this reduces verifier state during argv[0] scanning.
        if (!past_argv0) {
            if (c == '\0') {
                past_argv0 = 1;
                at_arg_start = 1;
            }
            continue;
        }

        if (c == '\0') {
            in_flag = 0;
            at_arg_start = 1;
            continue;
        }

        if (at_arg_start) {
            at_arg_start = 0;
            if (skip_next) {
                skip_next = 0;
                continue;  // Skip this arg — it's the value for -W/-X
            }
            if (c == '-') {
                in_flag = 1;
                continue;  // Skip the '-' itself
            }
            // Non-flag arg after argv[0] — flags are done, stop scanning
            break;
        }

        if (!in_flag) {
            continue;  // Inside W/X value or skipping to next null
        }

        // Inside flag characters after '-'
        if (c == 'c') {
            found = 1;
            break;
        }
        // -W and -X: remaining chars in this arg are the option value.
        // If W/X is the last char before null, the value is the next arg.
        if (c == 'W' || c == 'X') {
            in_flag = 0;
            if (buf->data[(i + 1) & (INLINE_CODE_FLAG_SCAN - 1)] == '\0') {
                skip_next = 1;
            }
        } else if (c == 'm') {
            // -m: remaining chars are the module name (e.g., -mc = module "c").
            // No skip_next — the module name arg is a positional that triggers
            // the break, preventing us from scanning module arguments.
            in_flag = 0;
        }
    }

#undef INLINE_CODE_FLAG_SCAN

    if (!found) {
        return 0;
    }

    u32 tgid = bpf_get_current_pid_tgid() >> 32;
    trace_log("SB_INLINE: detected -c flag for interpreter %s (pid=%u, mode=%u)",
              comm, tgid, script_blocking_mode);

    // Get container context
    uint32_t container_level = 0;
    uint64_t container_id = get_container_id(task, &container_level);

    // Emit EVENT_TYPE_SCRIPT_SECURITY event with is_inline_code=1
    struct event_context *evt_ctx = start_event(EVENT_TYPE_SCRIPT_SECURITY, 10);
    if (!evt_ctx) {
        update_drop_stats(EVENT_TYPE_SCRIPT_SECURITY);
        goto emit_done;
    }

    // Parameter 0: script path — use the interpreter path (bprm->filename)
    if (push_param_string(evt_ctx, (const char *)BPF_CORE_READ(bprm, filename), MAX_PATH, 1) < 0) {
        goto emit_error;
    }

    // Parameter 1: hash — empty for inline code (no file to hash)
    unsigned char empty_hash[SHA256_DIGEST_SIZE] = {};
    if (push_param_bytebuf(evt_ctx, empty_hash, SHA256_DIGEST_SIZE, 1) < 0) {
        goto emit_error;
    }

    // Parameter 2: pid
    if (push_param_s64(evt_ctx, (int64_t)tgid) < 0) {
        goto emit_error;
    }

    // Parameter 3: container_id
    if (push_param_u64(evt_ctx, container_id) < 0) {
        goto emit_error;
    }

    // Parameter 4: container_level
    if (push_param_u32(evt_ctx, container_level) < 0) {
        goto emit_error;
    }

    // Parameter 5: allow (0=denied — inline code is never allowed)
    if (push_param_u32(evt_ctx, 0) < 0) {
        goto emit_error;
    }

    // Parameter 6: blocking_mode
    if (push_param_u32(evt_ctx, script_blocking_mode) < 0) {
        goto emit_error;
    }

    // Parameter 7: is_inline_code (1=yes)
    if (push_param_u32(evt_ctx, 1) < 0) {
        goto emit_error;
    }

    // Parameter 8: is_piped_stdin (0=no)
    if (push_param_u32(evt_ctx, 0) < 0) {
        goto emit_error;
    }

    // Parameter 9: is_no_args (0=no)
    if (push_param_u32(evt_ctx, 0) < 0) {
        goto emit_error;
    }

    submit_event(evt_ctx);
    goto emit_done;

emit_error:
    release_event(evt_ctx);
    update_drop_stats(EVENT_TYPE_SCRIPT_SECURITY);

emit_done:
    // In enforce mode, kill the process before it executes any user-space code.
    // bpf_send_signal is synchronous here (IRQs enabled in tracepoint context),
    // so TIF_SIGPENDING is set immediately. The process is killed during
    // kernel-to-userspace transition, before the first user instruction.
    if (script_blocking_mode == EHPROBE_BLOCKING_MODE_ENFORCE) {
        bpf_send_signal(9);  // SIGKILL
        trace_log("SB_INLINE: sent SIGKILL to pid=%u", tgid);
    }

    return 1;
}

// Check if the current exec is an interpreter with piped/redirected stdin.
// Inspects fd 0 of the current task: if it's a pipe (S_ISFIFO) or regular file
// (S_ISREG), the process received code via stdin (e.g., `echo 'code' | python3`
// or `python3 < script.py`). TTY stdin (interactive) is ignored.
//
// Must be called from tp_btf/sched_process_exec after ehprobe_check_interpreter_exec()
// so the interpreter is already tracked.
//
// Returns: 1 if piped/redirected stdin detected, 0 otherwise
static __always_inline int ehprobe_check_stdin_exec(struct linux_binprm *bprm,
                                                     uint32_t script_blocking_mode) {
    struct task_struct *task = bpf_get_current_task_btf();

    // Check if comm matches a known interpreter
    char comm[TASK_COMM_LEN] = {};
    BPF_CORE_READ_INTO(&comm, task, comm);

    struct interpreter_binary_key ikey = {};
    __builtin_memcpy(ikey.comm, comm, TASK_COMM_LEN);

    if (!bpf_map_lookup_elem(&interpreter_binaries, &ikey)) {
        return 0;  // Not an interpreter
    }

    // Read fd 0 (stdin) from the task's file descriptor table
    struct files_struct *files = BPF_CORE_READ(task, files);
    if (!files) {
        return 0;
    }

    struct fdtable *fdt = BPF_CORE_READ(files, fdt);
    if (!fdt) {
        return 0;
    }

    struct file **fd_array = BPF_CORE_READ(fdt, fd);
    if (!fd_array) {
        return 0;
    }

    unsigned int max_fds = BPF_CORE_READ(fdt, max_fds);
    if (max_fds == 0) {
        return 0;
    }

    struct file *stdin_file = NULL;
    if (bpf_probe_read_kernel(&stdin_file, sizeof(stdin_file), &fd_array[0]) < 0 || !stdin_file) {
        return 0;
    }

    // Read the inode mode of stdin's file
    struct inode *inode = BPF_CORE_READ(stdin_file, f_inode);
    if (!inode) {
        return 0;
    }

    unsigned short i_mode = BPF_CORE_READ(inode, i_mode);

    // S_IFIFO = 0010000 (pipe), S_IFREG = 0100000 (regular file)
    // S_IFMT  = 0170000 (mask)
    unsigned short file_type = i_mode & 0170000;
    int is_pipe = (file_type == 0010000);   // S_IFIFO
    int is_regular = (file_type == 0100000); // S_IFREG

    if (!is_pipe && !is_regular) {
        return 0;  // stdin is a TTY or other device — normal interactive use
    }

    u32 tgid = bpf_get_current_pid_tgid() >> 32;
    trace_log("SB_STDIN: detected piped/redirected stdin for interpreter: mode=%u, pipe=%d, reg=%d",
              script_blocking_mode, is_pipe, is_regular);

    // Get container context
    uint32_t container_level = 0;
    uint64_t container_id = get_container_id(task, &container_level);

    // Emit EVENT_TYPE_SCRIPT_SECURITY event with is_inline_code=0, is_piped_stdin=1
    struct event_context *evt_ctx = start_event(EVENT_TYPE_SCRIPT_SECURITY, 10);
    if (!evt_ctx) {
        update_drop_stats(EVENT_TYPE_SCRIPT_SECURITY);
        goto emit_done;
    }

    // Parameter 0: script path — use the interpreter path (bprm->filename)
    if (push_param_string(evt_ctx, (const char *)BPF_CORE_READ(bprm, filename), MAX_PATH, 1) < 0) {
        goto emit_error;
    }

    // Parameter 1: hash — empty (no file to hash for piped stdin)
    unsigned char empty_hash[SHA256_DIGEST_SIZE] = {};
    if (push_param_bytebuf(evt_ctx, empty_hash, SHA256_DIGEST_SIZE, 1) < 0) {
        goto emit_error;
    }

    // Parameter 2: pid
    if (push_param_s64(evt_ctx, (int64_t)tgid) < 0) {
        goto emit_error;
    }

    // Parameter 3: container_id
    if (push_param_u64(evt_ctx, container_id) < 0) {
        goto emit_error;
    }

    // Parameter 4: container_level
    if (push_param_u32(evt_ctx, container_level) < 0) {
        goto emit_error;
    }

    // Parameter 5: allow (0=denied — piped stdin is never allowed)
    if (push_param_u32(evt_ctx, 0) < 0) {
        goto emit_error;
    }

    // Parameter 6: blocking_mode
    if (push_param_u32(evt_ctx, script_blocking_mode) < 0) {
        goto emit_error;
    }

    // Parameter 7: is_inline_code (0=no)
    if (push_param_u32(evt_ctx, 0) < 0) {
        goto emit_error;
    }

    // Parameter 8: is_piped_stdin (1=yes)
    if (push_param_u32(evt_ctx, 1) < 0) {
        goto emit_error;
    }

    // Parameter 9: is_no_args (0=no)
    if (push_param_u32(evt_ctx, 0) < 0) {
        goto emit_error;
    }

    submit_event(evt_ctx);
    goto emit_done;

emit_error:
    release_event(evt_ctx);
    update_drop_stats(EVENT_TYPE_SCRIPT_SECURITY);

emit_done:
    // In enforce mode, kill the process before it executes any user-space code.
    if (script_blocking_mode == EHPROBE_BLOCKING_MODE_ENFORCE) {
        bpf_send_signal(9);  // SIGKILL
        trace_log("SB_STDIN: sent SIGKILL to pid=%u", tgid);
    }

    return 1;
}

// Check if the current exec is a bare interpreter invocation (no script, no module,
// no inline code, TTY stdin). Detects interactive REPL sessions that could execute
// arbitrary code. The caller must verify (via argv scan results) that no script path,
// -m module, or -h/-V exit flag was present before calling this function.
//
// Must be called AFTER ehprobe_check_inline_code_exec and ehprobe_check_stdin_exec.
//
// Returns: 1 if bare interpreter detected, 0 otherwise
static __always_inline int ehprobe_check_bare_interpreter_exec(struct linux_binprm *bprm,
                                                                uint32_t script_blocking_mode) {
    struct task_struct *task = bpf_get_current_task_btf();

    char comm[TASK_COMM_LEN] = {};
    BPF_CORE_READ_INTO(&comm, task, comm);

    struct interpreter_binary_key ikey = {};
    __builtin_memcpy(ikey.comm, comm, TASK_COMM_LEN);

    if (!bpf_map_lookup_elem(&interpreter_binaries, &ikey)) {
        return 0;
    }

    // Mini argv scan: check if this invocation has a script path, -c, -m, or exit flag.
    // Uses a small 64-byte buffer (63 iterations) to stay within verifier budget.
    // Bare interpreter argv is always short (e.g., "python3 -i -q" ≈ 15 bytes).
    unsigned long arg_start = 0, arg_end = 0;
    BPF_CORE_READ_INTO(&arg_start, task, mm, arg_start);
    BPF_CORE_READ_INTO(&arg_end, task, mm, arg_end);

    if (arg_start != 0 && arg_end > arg_start) {
        unsigned long total_argv_len = arg_end - arg_start;
        if (total_argv_len >= BARE_INTERP_SCAN_SIZE) {
            return 0;
        }

        u32 bkey = 0;
        struct bare_interp_scan_buf *sbuf = bpf_map_lookup_elem(&bare_interp_scan_map, &bkey);
        if (!sbuf) {
            return 0;
        }

        unsigned long slen = total_argv_len;
        slen &= (BARE_INTERP_SCAN_SIZE - 1);

        if (slen > 0 && bpf_probe_read_user(sbuf->data, slen, (void *)arg_start) >= 0) {
            sbuf->data[slen & (BARE_INTERP_SCAN_SIZE - 1)] = '\0';

            int past_a0 = 0, in_fl = 0, at_start = 0, skip_next = 0;
            int has_action = 0;

            for (int i = 0; i < BARE_INTERP_SCAN_SIZE - 1; i++) {
                if (i >= (int)slen) {
                    break;
                }
                char c = sbuf->data[i];

                if (c == '\0') {
                    if (!past_a0) {
                        past_a0 = 1;
                    }
                    in_fl = 0;
                    at_start = 1;
                    continue;
                }

                if (!past_a0) {
                    continue;
                }

                if (at_start) {
                    at_start = 0;
                    if (skip_next) {
                        skip_next = 0;
                        continue;
                    }
                    if (c == '-') {
                        if (sbuf->data[(i + 1) & (BARE_INTERP_SCAN_SIZE - 1)] == '-') {
                            has_action = 1;
                            break;
                        }
                        in_fl = 1;
                        continue;
                    }
                    has_action = 1;
                    break;
                }

                if (!in_fl) {
                    continue;
                }

                if (c == 'c' || c == 'm' || c == 'h' || c == 'V') {
                    has_action = 1;
                    break;
                }
                if (c == 'W' || c == 'X') {
                    in_fl = 0;
                    if (sbuf->data[(i + 1) & (BARE_INTERP_SCAN_SIZE - 1)] == '\0') {
                        skip_next = 1;
                    }
                }
            }

            if (has_action) {
                return 0;
            }
        }
    }

    // Verify stdin is a TTY (character device). Pipe/file stdin is already
    // handled by ehprobe_check_stdin_exec.
    struct files_struct *files = BPF_CORE_READ(task, files);
    if (!files) {
        return 0;
    }

    struct fdtable *fdt = BPF_CORE_READ(files, fdt);
    if (!fdt) {
        return 0;
    }

    struct file **fd_array = BPF_CORE_READ(fdt, fd);
    if (!fd_array) {
        return 0;
    }

    unsigned int max_fds = BPF_CORE_READ(fdt, max_fds);
    if (max_fds == 0) {
        return 0;
    }

    struct file *stdin_file = NULL;
    if (bpf_probe_read_kernel(&stdin_file, sizeof(stdin_file), &fd_array[0]) < 0 || !stdin_file) {
        return 0;
    }

    struct inode *inode = BPF_CORE_READ(stdin_file, f_inode);
    if (!inode) {
        return 0;
    }

    unsigned short i_mode = BPF_CORE_READ(inode, i_mode);
    unsigned short file_type = i_mode & 0170000;

    // S_IFCHR = 0020000 (character device — TTY/PTY)
    if (file_type != 0020000) {
        return 0;
    }

    u32 tgid = bpf_get_current_pid_tgid() >> 32;
    trace_log("SB_BARE: bare interpreter %s pid=%u mode=%u", comm, tgid, script_blocking_mode);

    uint32_t container_level = 0;
    uint64_t container_id = get_container_id(task, &container_level);

    struct event_context *evt_ctx = start_event(EVENT_TYPE_SCRIPT_SECURITY, 10);
    if (!evt_ctx) {
        update_drop_stats(EVENT_TYPE_SCRIPT_SECURITY);
        goto emit_done;
    }

    if (push_param_string(evt_ctx, (const char *)BPF_CORE_READ(bprm, filename), MAX_PATH, 1) < 0) {
        goto emit_error;
    }

    unsigned char empty_hash[SHA256_DIGEST_SIZE] = {};
    if (push_param_bytebuf(evt_ctx, empty_hash, SHA256_DIGEST_SIZE, 1) < 0) {
        goto emit_error;
    }

    if (push_param_s64(evt_ctx, (int64_t)tgid) < 0) {
        goto emit_error;
    }

    if (push_param_u64(evt_ctx, container_id) < 0) {
        goto emit_error;
    }

    if (push_param_u32(evt_ctx, container_level) < 0) {
        goto emit_error;
    }

    // Parameter 5: allow (0=denied)
    if (push_param_u32(evt_ctx, 0) < 0) {
        goto emit_error;
    }

    if (push_param_u32(evt_ctx, script_blocking_mode) < 0) {
        goto emit_error;
    }

    // Parameter 7: is_inline_code (0=no)
    if (push_param_u32(evt_ctx, 0) < 0) {
        goto emit_error;
    }

    // Parameter 8: is_piped_stdin (0=no)
    if (push_param_u32(evt_ctx, 0) < 0) {
        goto emit_error;
    }

    // Parameter 9: is_no_args (1=yes)
    if (push_param_u32(evt_ctx, 1) < 0) {
        goto emit_error;
    }

    submit_event(evt_ctx);
    goto emit_done;

emit_error:
    release_event(evt_ctx);
    update_drop_stats(EVENT_TYPE_SCRIPT_SECURITY);

emit_done:
    if (script_blocking_mode == EHPROBE_BLOCKING_MODE_ENFORCE) {
        bpf_send_signal(9);  // SIGKILL
        trace_log("SB_BARE: sent SIGKILL to pid=%u", tgid);
    }

    return 1;
}

// Perform allowlist check, event emission, and return blocking decision.
// Called from script_blocking_allowlist_check (tail call stage 3) after
// a path match has been confirmed. Returns 1 to block, 0 to allow.
static __always_inline int ehprobe_script_allowlist_check(
    struct file *file, struct path_entry *script_path, int path_len, u32 tgid) {

    // Get inode and device information
    struct inode *inode = BPF_CORE_READ(file, f_inode);
    if (!inode) {
        trace_log("EHPROBE_SCRIPT_BLOCKING: Failed to get inode - allowing");
        return 0;
    }

    uint64_t ino = BPF_CORE_READ(inode, i_ino);
    dev_t kernel_dev = BPF_CORE_READ(inode, i_sb, s_dev);
    uint32_t dev = convert_dev(kernel_dev);

    // Compute SHA256 hash (sleepable operation).
    // Falls back to inode+dev-only allowlist check when IMA is unavailable.
    unsigned char hash[SHA256_DIGEST_SIZE];
    int verify_hash = 1;
    int ret = bpf_ima_file_hash(file, hash, sizeof(hash));
    if (ret < 0) {
        trace_log("EHPROBE_SCRIPT_BLOCKING: hash failed (%d) - using inode-only check", ret);
        __builtin_memset(hash, 0, sizeof(hash));
        verify_hash = 0;
    }

    // Get container context
    uint32_t container_level = 0;
    uint64_t container_id = get_container_id(bpf_get_current_task_btf(), &container_level);

    // Check allowlist
    int allowed = 0;
    {
        void *inner_map = bpf_map_lookup_elem(&script_allowlist_outer_map, &container_id);
        if (inner_map) {
            struct allowlist_key lookup_key = {
                .ino = ino,
                .dev = dev,
                .pad = 0
            };
            struct allowlist_entry *al_entry = bpf_map_lookup_elem(inner_map, &lookup_key);
            if (al_entry) {
                // Entry exists in allowlist. Verify hash if IMA is available,
                // otherwise inode+dev match is sufficient.
                if (!verify_hash || compare_hashes(hash, al_entry->hash)) {
                    allowed = 1;
                }
            }
        }
    }

    // Get blocking mode
    uint32_t blocking_mode_val = EHPROBE_BLOCKING_MODE_OFF;
    {
        u32 env_key = 0;
        struct ehprobe_env *env = bpf_map_lookup_elem(&ehprobe_env_map, &env_key);
        if (env) {
            blocking_mode_val = (uint32_t)env->script_blocking_mode;
        }
    }

    trace_log("EHPROBE_SCRIPT_BLOCKING: %s for %s",
              allowed ? "allowed" : "denied", script_path->path);

    // Emit EVENT_TYPE_SCRIPT_SECURITY event
    struct event_context *evt_ctx = start_event(EVENT_TYPE_SCRIPT_SECURITY, 10);
    if (!evt_ctx) {
        update_drop_stats(EVENT_TYPE_SCRIPT_SECURITY);
        goto event_error;
    }

    if (push_param_string(evt_ctx, script_path->path, MAX_PATH, 1) < 0) {
        goto event_error;
    }
    if (push_param_bytebuf(evt_ctx, hash, SHA256_DIGEST_SIZE, 1) < 0) {
        goto event_error;
    }
    if (push_param_s64(evt_ctx, (int64_t)tgid) < 0) {
        goto event_error;
    }
    if (push_param_u64(evt_ctx, container_id) < 0) {
        goto event_error;
    }
    if (push_param_u32(evt_ctx, container_level) < 0) {
        goto event_error;
    }
    if (push_param_u32(evt_ctx, allowed ? 1 : 0) < 0) {
        goto event_error;
    }
    if (push_param_u32(evt_ctx, blocking_mode_val) < 0) {
        goto event_error;
    }
    if (push_param_u32(evt_ctx, 0) < 0) {  // is_inline_code
        goto event_error;
    }
    if (push_param_u32(evt_ctx, 0) < 0) {  // is_piped_stdin
        goto event_error;
    }
    if (push_param_u32(evt_ctx, 0) < 0) {  // is_no_args
        goto event_error;
    }

    submit_event(evt_ctx);
    return (!allowed && blocking_mode_val == EHPROBE_BLOCKING_MODE_ENFORCE) ? 1 : 0;

event_error:
    release_event(evt_ctx);
    update_drop_stats(EVENT_TYPE_SCRIPT_SECURITY);
    return 0;
}
