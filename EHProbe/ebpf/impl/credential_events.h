// SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause
#pragma once

#include <ehprobe_common.h>
#include <container_logic.h>

// Parameters pushed by ehprobe_setuid (8 total):
//   [0] old_uid      (u32) - real UID before change
//   [1] new_uid      (u32) - real UID after change
//   [2] old_euid     (u32) - effective UID before change
//   [3] new_euid     (u32) - effective UID after change
//   [4] ppid         (s64) - parent PID
//   [5] exe_path     (string) - current executable path
//   [6] container_id (u64)
//   [7] container_level (u32)
static __always_inline int ehprobe_setuid(struct cred *new_cred, const struct cred *old_cred) {
    struct task_struct *task = bpf_get_current_task_btf();

    uint32_t container_level = 0;
    uint64_t container_id = get_container_id(task, &container_level);

    struct event_context *evt_ctx = start_event(EVENT_TYPE_SETUID, 8);
    if (!evt_ctx) {
        trace_log("EHPROBE_SETUID: ERROR - start_event failed");
        update_drop_stats(EVENT_TYPE_SETUID);
        return -1;
    }

    // Parameter 0: old_uid
    // Use BPF_CORE_READ_INTO instead of BPF_CORE_READ when reading through a
    // const-qualified pointer (e.g. `const struct cred *`). The bare macro
    // declares an internal const temporary without an initializer, which trips
    // clang's -Wdefault-const-init-var-unsafe. Same pattern applies below.
    uint32_t old_uid = 0;
    BPF_CORE_READ_INTO(&old_uid, old_cred, uid.val);
    if (push_param_u32(evt_ctx, old_uid) < 0) {
        trace_log("EHPROBE_SETUID: ERROR - push_param_u32 failed for old_uid");
        goto error;
    }

    // Parameter 1: new_uid
    uint32_t new_uid = BPF_CORE_READ(new_cred, uid.val);
    if (push_param_u32(evt_ctx, new_uid) < 0) {
        trace_log("EHPROBE_SETUID: ERROR - push_param_u32 failed for new_uid");
        goto error;
    }

    // Parameter 2: old_euid
    uint32_t old_euid = 0;
    BPF_CORE_READ_INTO(&old_euid, old_cred, euid.val);
    if (push_param_u32(evt_ctx, old_euid) < 0) {
        trace_log("EHPROBE_SETUID: ERROR - push_param_u32 failed for old_euid");
        goto error;
    }

    // Parameter 3: new_euid
    uint32_t new_euid = BPF_CORE_READ(new_cred, euid.val);
    if (push_param_u32(evt_ctx, new_euid) < 0) {
        trace_log("EHPROBE_SETUID: ERROR - push_param_u32 failed for new_euid");
        goto error;
    }

    // Parameter 4: ppid
    int64_t ppid = (int64_t)(uint32_t)BPF_CORE_READ(task, real_parent, tgid);
    if (push_param_s64(evt_ctx, ppid) < 0) {
        trace_log("EHPROBE_SETUID: ERROR - push_param_s64 failed for ppid");
        goto error;
    }

    // Parameter 5: exe_path
    struct file *exe_file = BPF_CORE_READ(task, mm, exe_file);
    if (exe_file != NULL) {
        uint32_t len = 0;
        char *p = reconstruct_file_path(&(exe_file->f_path), &len);
        if (p != NULL && len > 0 && len < PATH_BUFFER_SIZE) {
            if (push_param_string(evt_ctx, p, len, 1) < 0) {
                trace_log("EHPROBE_SETUID: ERROR - push_param_string failed for exe_path");
                goto error;
            }
        } else {
            if (push_param_none(evt_ctx) < 0) {
                trace_log("EHPROBE_SETUID: ERROR - push_param_none failed for exe_path");
                goto error;
            }
        }
    } else {
        if (push_param_none(evt_ctx) < 0) {
            trace_log("EHPROBE_SETUID: ERROR - push_param_none failed for exe_path (null)");
            goto error;
        }
    }

    // Parameter 6: container_id
    if (push_param_u64(evt_ctx, container_id) < 0) {
        trace_log("EHPROBE_SETUID: ERROR - push_param_u64 failed for container_id");
        goto error;
    }

    // Parameter 7: container_level
    if (push_param_u32(evt_ctx, container_level) < 0) {
        trace_log("EHPROBE_SETUID: ERROR - push_param_u32 failed for container_level");
        goto error;
    }

    trace_log("EHPROBE_SETUID: submitting event (old_uid=%u new_uid=%u new_euid=%u)",
              old_uid, new_uid, new_euid);
    return submit_event(evt_ctx);

error:
    trace_log("EHPROBE_SETUID: ERROR - dropping event");
    release_event(evt_ctx);
    update_drop_stats(EVENT_TYPE_SETUID);
    return -1;
}

// Parameters pushed by ehprobe_setgid (8 total):
//   [0] old_gid      (u32) - real GID before change
//   [1] new_gid      (u32) - real GID after change
//   [2] old_egid     (u32) - effective GID before change
//   [3] new_egid     (u32) - effective GID after change
//   [4] ppid         (s64) - parent PID
//   [5] exe_path     (string) - current executable path
//   [6] container_id (u64)
//   [7] container_level (u32)
static __always_inline int ehprobe_setgid(struct cred *new_cred, const struct cred *old_cred) {
    struct task_struct *task = bpf_get_current_task_btf();

    uint32_t container_level = 0;
    uint64_t container_id = get_container_id(task, &container_level);

    struct event_context *evt_ctx = start_event(EVENT_TYPE_SETGID, 8);
    if (!evt_ctx) {
        trace_log("EHPROBE_SETGID: ERROR - start_event failed");
        update_drop_stats(EVENT_TYPE_SETGID);
        return -1;
    }

    // Parameter 0: old_gid
    uint32_t old_gid = 0;
    BPF_CORE_READ_INTO(&old_gid, old_cred, gid.val);
    if (push_param_u32(evt_ctx, old_gid) < 0) {
        trace_log("EHPROBE_SETGID: ERROR - push_param_u32 failed for old_gid");
        goto error;
    }

    // Parameter 1: new_gid
    uint32_t new_gid = BPF_CORE_READ(new_cred, gid.val);
    if (push_param_u32(evt_ctx, new_gid) < 0) {
        trace_log("EHPROBE_SETGID: ERROR - push_param_u32 failed for new_gid");
        goto error;
    }

    // Parameter 2: old_egid
    uint32_t old_egid = 0;
    BPF_CORE_READ_INTO(&old_egid, old_cred, egid.val);
    if (push_param_u32(evt_ctx, old_egid) < 0) {
        trace_log("EHPROBE_SETGID: ERROR - push_param_u32 failed for old_egid");
        goto error;
    }

    // Parameter 3: new_egid
    uint32_t new_egid = BPF_CORE_READ(new_cred, egid.val);
    if (push_param_u32(evt_ctx, new_egid) < 0) {
        trace_log("EHPROBE_SETGID: ERROR - push_param_u32 failed for new_egid");
        goto error;
    }

    // Parameter 4: ppid
    int64_t ppid = (int64_t)(uint32_t)BPF_CORE_READ(task, real_parent, tgid);
    if (push_param_s64(evt_ctx, ppid) < 0) {
        trace_log("EHPROBE_SETGID: ERROR - push_param_s64 failed for ppid");
        goto error;
    }

    // Parameter 5: exe_path
    struct file *exe_file = BPF_CORE_READ(task, mm, exe_file);
    if (exe_file != NULL) {
        uint32_t len = 0;
        char *p = reconstruct_file_path(&(exe_file->f_path), &len);
        if (p != NULL && len > 0 && len < PATH_BUFFER_SIZE) {
            if (push_param_string(evt_ctx, p, len, 1) < 0) {
                trace_log("EHPROBE_SETGID: ERROR - push_param_string failed for exe_path");
                goto error;
            }
        } else {
            if (push_param_none(evt_ctx) < 0) {
                trace_log("EHPROBE_SETGID: ERROR - push_param_none failed for exe_path");
                goto error;
            }
        }
    } else {
        if (push_param_none(evt_ctx) < 0) {
            trace_log("EHPROBE_SETGID: ERROR - push_param_none failed for exe_path (null)");
            goto error;
        }
    }

    // Parameter 6: container_id
    if (push_param_u64(evt_ctx, container_id) < 0) {
        trace_log("EHPROBE_SETGID: ERROR - push_param_u64 failed for container_id");
        goto error;
    }

    // Parameter 7: container_level
    if (push_param_u32(evt_ctx, container_level) < 0) {
        trace_log("EHPROBE_SETGID: ERROR - push_param_u32 failed for container_level");
        goto error;
    }

    trace_log("EHPROBE_SETGID: submitting event (old_gid=%u new_gid=%u new_egid=%u)",
              old_gid, new_gid, new_egid);
    return submit_event(evt_ctx);

error:
    trace_log("EHPROBE_SETGID: ERROR - dropping event");
    release_event(evt_ctx);
    update_drop_stats(EVENT_TYPE_SETGID);
    return -1;
}
