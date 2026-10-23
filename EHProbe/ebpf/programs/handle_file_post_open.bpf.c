// SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause
// handle_file_post_open.bpf.c - Script blocking via file_post_open (sleepable)
//
// For .py/.pyc files: checks allowlist in-kernel, blocks if unauthorized.
// For extensionless files opened by tracked interpreters: emits an internal
// EVENT_TYPE_SCRIPT_FILE_CHECK event with the resolved file path and raw
// argv script_path/startup_path. Swift userspace resolves relative paths,
// compares, and kills the process if unauthorized. This avoids complex path
// resolution in BPF.
#include <ehprobe_common.h>
#include <script_blocking.h>

char LICENSE[] SEC("license") = "Dual BSD/GPL";

// Emit an internal SCRIPT_FILE_CHECK event for userspace path resolution.
// Parameters: file_path (resolved), pid, script_path (raw), blocking_mode
static __always_inline void emit_script_file_check(
    struct path_entry *script_path, int path_len, u32 tgid,
    struct interpreter_pid_entry *entry, uint32_t blocking_mode) {

    struct event_context *evt_ctx = start_event(EVENT_TYPE_SCRIPT_FILE_CHECK, 4);
    if (!evt_ctx) {
        update_drop_stats(EVENT_TYPE_SCRIPT_FILE_CHECK);
        return;
    }

    // Parameter 0: resolved file path (from bpf_d_path)
    if (push_param_string(evt_ctx, script_path->path, MAX_PATH, 1) < 0) {
        goto error;
    }

    // Parameter 1: PID
    if (push_param_s64(evt_ctx, (int64_t)tgid) < 0) {
        goto error;
    }

    // Parameter 2: raw script_path from argv
    if (push_param_string(evt_ctx, entry->script_path, INTERPRETER_SCRIPT_PATH_LEN, 1) < 0) {
        goto error;
    }

    // Parameter 3: blocking mode
    if (push_param_u32(evt_ctx, blocking_mode) < 0) {
        goto error;
    }

    submit_event(evt_ctx);
    return;

error:
    release_event(evt_ctx);
    update_drop_stats(EVENT_TYPE_SCRIPT_FILE_CHECK);
}

SEC("lsm.s/file_post_open")
int BPF_PROG(handle_file_post_open, struct file *file, int mask)
{
    u32 map_key = 0;
    struct ehprobe_env *env = bpf_map_lookup_elem(&ehprobe_env_map, &map_key);
    if (!env || !env->flag_block_script) {
        return 0;
    }
    if (env->script_blocking_mode == EHPROBE_BLOCKING_MODE_OFF) {
        return 0;
    }

    u32 tgid = bpf_get_current_pid_tgid() >> 32;
    struct interpreter_pid_entry *entry = bpf_map_lookup_elem(&interpreter_pids, &tgid);
    if (!entry) {
        return 0;
    }

    // Get per-CPU path storage
    struct path_entry *script_path = bpf_map_lookup_elem(&local_script_path_map, &map_key);
    if (!script_path) {
        return 0;
    }

    // Resolve file path with bpf_d_path (reliable, sleepable)
    int path_len = bpf_d_path(&file->f_path, script_path->path, sizeof(script_path->path));
    if (path_len < 0) {
        return 0;
    }
    if (path_len >= (int)sizeof(script_path->path)) {
        path_len = (int)sizeof(script_path->path) - 1;
    }

    // .py/.pyc files: check allowlist in-kernel, block if unauthorized
    if (is_python_script(script_path->path, path_len)) {
        int decision = ehprobe_script_allowlist_check(file, script_path, path_len, tgid);
        if (decision > 0 && env->script_blocking_mode == EHPROBE_BLOCKING_MODE_ENFORCE) {
            return -1;
        }
        return 0;
    }

    // Non-.py/.pyc file opened by a tracked interpreter.
    // Emit internal event for userspace to resolve paths and decide.
    // Always emit for tracked interpreters — userspace checks both script_path
    // and PYTHONSTARTUP (read from /proc/<pid>/environ).
    emit_script_file_check(script_path, path_len, tgid, entry,
                           (uint32_t)env->script_blocking_mode);

    return 0;
}
