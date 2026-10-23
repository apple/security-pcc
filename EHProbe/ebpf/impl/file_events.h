// SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause
// file_events.h - File event emission helpers
#pragma once

#include <ehprobe_common.h>
#include <container_logic.h>
#include <file_path_filter.h>

// Helper to build cache key from file pointer
// Returns: 1 on success, 0 if inode is NULL (key should not be used)
static __always_inline int build_file_cache_key(
    struct file *filp,
    struct file_handle_cache_key *key
) {
    struct inode *inode = BPF_CORE_READ(filp, f_inode);
    if (!inode) {
        // f_inode is NULL (special file descriptor or corrupted state)
        // Return failure to prevent cache operations with invalid key
        return 0;
    }
    key->ino = BPF_CORE_READ(inode, i_ino);
    key->dev = BPF_CORE_READ(inode, i_sb, s_dev);
    key->pid = bpf_get_current_pid_tgid() >> 32;
    return 1;
}

// Helper to build cache key from dentry (for unlink, which has no struct file)
// Returns: 1 on success, 0 if inode is NULL
static __always_inline int build_dentry_cache_key(
    struct dentry *dentry,
    uint32_t pid,
    struct file_handle_cache_key *key
) {
    struct inode *inode = BPF_CORE_READ(dentry, d_inode);
    if (!inode) {
        return 0;
    }
    key->ino = BPF_CORE_READ(inode, i_ino);
    key->dev = BPF_CORE_READ(inode, i_sb, s_dev);
    key->pid = pid;
    return 1;
}

// Helper to check cache for filter decision
// Returns: 1 if cache hit with should_emit decision stored in *should_emit
//          0 if cache miss or invalid inode
static __always_inline int check_file_handle_cache(
    struct file *filp,
    int *should_emit
) {
    struct file_handle_cache_key key = {};
    if (!build_file_cache_key(filp, &key)) {
        return 0;  // Invalid inode, treat as cache miss
    }

    struct file_handle_cache_value *cached = bpf_map_lookup_elem(&file_handle_filter_cache, &key);
    if (!cached) {
        return 0;  // Cache miss
    }

    *should_emit = cached->should_emit;
    return 1;  // Cache hit
}

// Helper to update cache with filter decision
// Silently skips update if inode is NULL (no valid cache key)
static __always_inline void update_file_handle_cache(
    struct file *filp,
    int should_emit
) {
    struct file_handle_cache_key key = {};
    if (!build_file_cache_key(filp, &key)) {
        return;  // Invalid inode, skip cache update
    }

    struct file_handle_cache_value val = {};
    val.should_emit = should_emit ? 1 : 0;
    val.path_valid = 0;  // Not caching path to avoid verifier complexity

    bpf_map_update_elem(&file_handle_filter_cache, &key, &val, BPF_ANY);
}

// File open event emission helper
// Parameters:
// 0: file_path (string)
// 1: flags (s32)
// 2: ppid (s64)
// 3: uid (u32)
// 4: executable_path (string)
// 5: container_id (u64)
// 6: container_level (u32)
static __always_inline int ehprobe_file_open(
    struct task_struct *task,
    struct file *filp,
    int flags,
    uint64_t container_id,
    uint32_t container_level
) {
    // First, reconstruct the path to check if we should emit this event
    struct path *file_path = &filp->f_path;
    uint32_t path_len = 0;
    char *path_str = reconstruct_file_path(file_path, &path_len);

    // Skip events with empty or invalid paths - no actionable data
    if (!path_str || path_len == 0 || path_len >= PATH_BUFFER_SIZE) {
        // Cache the negative decision so writes don't have to reconstruct
        update_file_handle_cache(filp, 0);
        return 0;
    }

    // Check path filter before allocating event context (performance optimization)
    int should_emit = should_emit_file_event(path_str, path_len);

    // Cache the filter decision for subsequent write operations
    // This saves the expensive should_emit_file_event() check on writes
    update_file_handle_cache(filp, should_emit);

    if (!should_emit) {
        // Path filtered out - don't emit event
        return 0;
    }

    struct event_context *evt_ctx = start_event(EVENT_TYPE_FILE_OPEN, 7);
    if (!evt_ctx) {
        trace_log("EHPROBE_FILE_OPEN: ERROR - start_event failed");
        update_drop_stats(EVENT_TYPE_FILE_OPEN);
        return -1;
    }

    // Parameter 0: file_path - already reconstructed above (validated non-empty)
    if (push_param_string(evt_ctx, path_str, path_len, 1) < 0) {
        trace_log("EHPROBE_FILE_OPEN: ERROR - push_param_string failed for path");
        goto error;
    }

    // Parameter 1: flags
    if (push_param_s32(evt_ctx, flags) < 0) {
        trace_log("EHPROBE_FILE_OPEN: ERROR - push_param_s32 failed for flags");
        goto error;
    }

    // Parameter 2: ppid
    __s64 ppid = BPF_CORE_READ(task, real_parent, tgid);
    if (push_param_s64(evt_ctx, ppid) < 0) {
        trace_log("EHPROBE_FILE_OPEN: ERROR - push_param_s64 failed for ppid");
        goto error;
    }

    // Parameter 3: uid
    uint32_t uid = bpf_get_current_uid_gid() & 0xFFFFFFFF;
    if (push_param_u32(evt_ctx, uid) < 0) {
        trace_log("EHPROBE_FILE_OPEN: ERROR - push_param_u32 failed for uid");
        goto error;
    }

    // Parameter 4: executable_path
    struct file *exe_file = BPF_CORE_READ(task, mm, exe_file);
    if (exe_file != NULL) {
        uint32_t exe_len = 0;
        char *exe_path = reconstruct_file_path(&(exe_file->f_path), &exe_len);
        if (exe_path && exe_len > 0 && exe_len < PATH_BUFFER_SIZE) {
            if (push_param_string(evt_ctx, exe_path, exe_len, 1) < 0) {
                trace_log("EHPROBE_FILE_OPEN: ERROR - push_param_string failed for exe_path");
                goto error;
            }
        } else {
            if (push_param_none(evt_ctx) < 0) {
                goto error;
            }
        }
    } else {
        if (push_param_none(evt_ctx) < 0) {
            goto error;
        }
    }

    // Parameter 5: container_id
    if (push_param_u64(evt_ctx, container_id) < 0) {
        goto error;
    }

    // Parameter 6: container_level
    if (push_param_u32(evt_ctx, container_level) < 0) {
        goto error;
    }

    return submit_event(evt_ctx);

error:
    trace_log("EHPROBE_FILE_OPEN: ERROR - dropping event");
    release_event(evt_ctx);
    update_drop_stats(EVENT_TYPE_FILE_OPEN);
    return -1;
}

// File write event emission helper
// Parameters:
// 0: file_path (string)
// 1: ppid (s64)
// 2: uid (u32)
// 3: executable_path (string)
// 4: container_id (u64)
// 5: container_level (u32)
static __always_inline int ehprobe_file_write(
    struct task_struct *task,
    struct file *filp,
    uint64_t container_id,
    uint32_t container_level
) {
    // Check cache first to avoid expensive filter check
    // The cache stores the filter decision from file_open
    int should_emit = 0;
    if (check_file_handle_cache(filp, &should_emit)) {
        // Cache hit - use cached decision
        if (!should_emit) {
            return 0;  // Cached negative decision - skip this file
        }
        // Cache hit with should_emit=true - we still need to reconstruct path
        // but we skip the expensive should_emit_file_event() check
    }

    // Reconstruct the path (needed for event emission)
    struct path *file_path = &filp->f_path;
    uint32_t path_len = 0;
    char *path_str = reconstruct_file_path(file_path, &path_len);

    // Skip events with empty or invalid paths - no actionable data
    if (!path_str || path_len == 0 || path_len >= PATH_BUFFER_SIZE) {
        return 0;
    }

    // If we didn't have a cache hit, check the filter now
    if (!should_emit) {
        if (!should_emit_file_event(path_str, path_len)) {
            // Path filtered out - don't emit event
            return 0;
        }
    }

    struct event_context *evt_ctx = start_event(EVENT_TYPE_FILE_WRITE, 6);
    if (!evt_ctx) {
        trace_log("EHPROBE_FILE_WRITE: ERROR - start_event failed");
        update_drop_stats(EVENT_TYPE_FILE_WRITE);
        return -1;
    }

    // Parameter 0: file_path - already reconstructed above (validated non-empty)
    if (push_param_string(evt_ctx, path_str, path_len, 1) < 0) {
        goto error;
    }

    // Parameter 1: ppid
    __s64 ppid = BPF_CORE_READ(task, real_parent, tgid);
    if (push_param_s64(evt_ctx, ppid) < 0) {
        goto error;
    }

    // Parameter 2: uid
    uint32_t uid = bpf_get_current_uid_gid() & 0xFFFFFFFF;
    if (push_param_u32(evt_ctx, uid) < 0) {
        goto error;
    }

    // Parameter 3: executable_path
    struct file *exe_file = BPF_CORE_READ(task, mm, exe_file);
    if (exe_file != NULL) {
        uint32_t exe_len = 0;
        char *exe_path = reconstruct_file_path(&(exe_file->f_path), &exe_len);
        if (exe_path && exe_len > 0 && exe_len < PATH_BUFFER_SIZE) {
            if (push_param_string(evt_ctx, exe_path, exe_len, 1) < 0) {
                goto error;
            }
        } else {
            if (push_param_none(evt_ctx) < 0) {
                goto error;
            }
        }
    } else {
        if (push_param_none(evt_ctx) < 0) {
            goto error;
        }
    }

    // Parameter 4: container_id
    if (push_param_u64(evt_ctx, container_id) < 0) {
        goto error;
    }

    // Parameter 5: container_level
    if (push_param_u32(evt_ctx, container_level) < 0) {
        goto error;
    }

    return submit_event(evt_ctx);

error:
    release_event(evt_ctx);
    update_drop_stats(EVENT_TYPE_FILE_WRITE);
    return -1;
}

// File unlink event emission helper
// Parameters:
// 0: file_path (string)
// 1: ppid (s64)
// 2: uid (u32)
// 3: executable_path (string)
// 4: container_id (u64)
// 5: container_level (u32)
static __always_inline int ehprobe_file_unlink(
    struct task_struct *task,
    struct path *dir,
    struct dentry *dentry,
    uint64_t container_id,
    uint32_t container_level
) {
    // Check cache before path reconstruction - same key as write/open (inode+dev+pid).
    // A cache HIT saying should_emit=0 means file_open already decided this path is
    // filtered out; skip the expensive dentry walk entirely.
    uint32_t pid = bpf_get_current_pid_tgid() >> 32;
    int should_emit = -1; // -1 = no cache decision yet
    struct file_handle_cache_key unlink_cache_key = {};
    if (build_dentry_cache_key(dentry, pid, &unlink_cache_key)) {
        struct file_handle_cache_value *cached =
            bpf_map_lookup_elem(&file_handle_filter_cache, &unlink_cache_key);
        if (cached) {
            should_emit = cached->should_emit;
            if (!should_emit) {
                return 0; // Cached negative - skip path reconstruction
            }
        }
    }

    // For unlink, construct a struct path from dir and the dentry
    // This allows reconstruct_file_path to properly build the full path
    struct path file_path;
    file_path.mnt = BPF_CORE_READ(dir, mnt);
    file_path.dentry = dentry;

    uint32_t path_len = 0;
    char *path_str = reconstruct_file_path(&file_path, &path_len);

    // Skip events with empty or invalid paths
    if (!path_str || path_len == 0 || path_len >= PATH_BUFFER_SIZE) {
        return 0;
    }

    // Cache miss - run the filter check now that we have the path
    if (should_emit < 0) {
        should_emit = should_emit_file_event(path_str, path_len);
        if (!should_emit) {
            return 0;
        }
    }

    struct event_context *evt_ctx = start_event(EVENT_TYPE_FILE_UNLINK, 6);
    if (!evt_ctx) {
        trace_log("EHPROBE_FILE_UNLINK: ERROR - start_event failed");
        update_drop_stats(EVENT_TYPE_FILE_UNLINK);
        return -1;
    }

    // Parameter 0: full file path
    if (push_param_string(evt_ctx, path_str, path_len, 1) < 0) {
        goto error;
    }

    // Parameter 1: ppid
    __s64 ppid = BPF_CORE_READ(task, real_parent, tgid);
    if (push_param_s64(evt_ctx, ppid) < 0) {
        goto error;
    }

    // Parameter 2: uid
    uint32_t uid = bpf_get_current_uid_gid() & 0xFFFFFFFF;
    if (push_param_u32(evt_ctx, uid) < 0) {
        goto error;
    }

    // Parameter 3: executable_path
    struct file *exe_file = BPF_CORE_READ(task, mm, exe_file);
    if (exe_file != NULL) {
        uint32_t exe_len = 0;
        char *exe_path = reconstruct_file_path(&(exe_file->f_path), &exe_len);
        if (exe_path && exe_len > 0 && exe_len < PATH_BUFFER_SIZE) {
            if (push_param_string(evt_ctx, exe_path, exe_len, 1) < 0) {
                goto error;
            }
        } else {
            if (push_param_none(evt_ctx) < 0) {
                goto error;
            }
        }
    } else {
        if (push_param_none(evt_ctx) < 0) {
            goto error;
        }
    }

    // Parameter 4: container_id
    if (push_param_u64(evt_ctx, container_id) < 0) {
        goto error;
    }

    // Parameter 5: container_level
    if (push_param_u32(evt_ctx, container_level) < 0) {
        goto error;
    }

    return submit_event(evt_ctx);

error:
    release_event(evt_ctx);
    update_drop_stats(EVENT_TYPE_FILE_UNLINK);
    return -1;
}
