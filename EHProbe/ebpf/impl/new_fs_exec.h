// SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause
#pragma once

#include <ehprobe_common.h>
#include <container_logic.h>

#include <bpf/bpf_tracing.h>
#include <bpf/bpf_endian.h>

#define S_IXUSR 00100
#define S_IXGRP 00010
#define S_IXOTH 00001

// This function is called with either file, either path parameter.
// file parameter is needed if hash is to be calculated on the spot.
// Otherwise, path is used.
static __always_inline int ehprobe_check_new_fs_exec(struct file *file, struct path *path, umode_t mode, enum new_fs_exec_operation op) {
    if (!file && !path) {
        return 0; // Should not happen
    }

    // Get the file's flags to check if it's being breated
    if (!(mode & (S_IXUSR | S_IXGRP | S_IXOTH))) {
        return 0; // Not executable, ignore
    }

    unsigned char hash[SHA256_DIGEST_SIZE];
    bool hash_available = false;
    if (file) {
        // calculate the file hash - sleepable operation (requires lsm.s prefix)
        int ret = bpf_ima_file_hash(file, hash, sizeof(hash));
        if (ret < 0) {
            trace_log("EHPROBE_NEW_FS_EXEC: bpf_ima_file_hash failed for with error %d", ret);
            // Continue without hash
        } else {
            hash_available = true;
            unsigned long long *hash_ptr = (unsigned long long *)hash;
            trace_log("EHPROBE_NEW_FS_EXEC: Hash Part1: %016llx%016llx", bpf_cpu_to_be64(hash_ptr[0]), bpf_cpu_to_be64(hash_ptr[1]));
            trace_log("EHPROBE_NEW_FS_EXEC: Hash Part2: %016llx%016llx", bpf_cpu_to_be64(hash_ptr[2]), bpf_cpu_to_be64(hash_ptr[3]));
        }
    }

    // Get current task
    struct task_struct *task = (struct task_struct *)bpf_get_current_task_btf();
    if (!task) {
        trace_log("EHPROBE_NEW_FS_EXEC: Failed to get current task");
        return -1;
    }

    uint32_t container_level = 0;
    uint64_t container_id = get_container_id(task, &container_level);
    if (container_id > 0) {
        trace_log("EHPROBE_NEW_FS_EXEC: container ID: %lu, container_level: %d", container_id, container_level);
    }

    struct pid *pid_struct = BPF_CORE_READ(task, thread_pid);
    if (pid_struct) {
		uint32_t level = BPF_CORE_READ(pid_struct, level);
		struct pid_namespace *pid_namespace_struct = BPF_CORE_READ(pid_struct, numbers[level].ns);
        if (pid_namespace_struct) {
            int pidns_level = BPF_CORE_READ(pid_namespace_struct, level);
            trace_log("EHPROBE_NEW_FS_EXEC: pidns_level: %d", pidns_level);
        }
    }

    // Get current process information
    u64 pid_tgid = bpf_get_current_pid_tgid();
    u32 pid = pid_tgid >> 32;

    // Send event using ehprobe API
    // Note: You'll need to define EVENT_TYPE_NEW_FS_EXEC in events.h
    struct event_context *evt_ctx = start_event(EVENT_TYPE_NEW_FS_EXEC, 7);
    if (!evt_ctx) {
        trace_log("EHPROBE_NEW_FS_EXEC: ERROR - start_event failed");
        update_drop_stats(EVENT_TYPE_NEW_FS_EXEC);
        return -1;
    }

    // Parameter 0: path
    if (file) {
        uint32_t len = 0;
        char* p = reconstruct_file_path(&(file->f_path), &len);
        if (p == NULL) {
            trace_log("EHPROBE_NEW_FS_EXEC: ERROR - reconstruct_file_path failed for file, p == NULL");
            goto error;
        }
        if (len == 0 || len >= PATH_BUFFER_SIZE) {
            trace_log("EHPROBE_NEW_FS_EXEC: ERROR - reconstruct_file_path failed for file, len %d", len);
            goto error;
        }
        if (push_param_string(evt_ctx, p, len, 1) < 0) {
            trace_log("EHPROBE_NEW_FS_EXEC: ERROR - push_param_string failed for file");
            goto error;
        }
    }
    else if (path) {
        uint32_t len = 0;
        char* p = reconstruct_file_path(path, &len);
        if (p == NULL) {
            trace_log("EHPROBE_NEW_FS_EXEC: ERROR - reconstruct_file_path failed for path, p == NULL");
            goto error;
        }
        if (len == 0 || len >= PATH_BUFFER_SIZE) {
            trace_log("EHPROBE_NEW_FS_EXEC: ERROR - reconstruct_file_path failed for path, len %d", len);
            goto error;
        }
        if (push_param_string(evt_ctx, p, len, 1) < 0) {
            trace_log("EHPROBE_NEW_FS_EXEC: ERROR - push_param_string failed for path");
            goto error;
        }
    }
    else {
        if (push_param_none(evt_ctx) < 0) {
            trace_log("EHPROBE_NEW_FS_EXEC: ERROR - push_param_none failed for path");
            goto error;
        }
    }

    // Parameter 1: hash
    if (hash_available) {
        if (push_param_bytebuf(evt_ctx, hash, SHA256_DIGEST_SIZE, 1) < 0) {
            trace_log("EHPROBE_NEW_FS_EXEC: ERROR - push_param_none failed for hash");
            goto error;
        }
    } else {
        if (push_param_none(evt_ctx) < 0) {
            trace_log("EHPROBE_NEW_FS_EXEC: ERROR - push_param_none failed for hash (not available)");
            goto error;
        }
    }

    // Parameter 2: process PID
    if (push_param_s64(evt_ctx, (int64_t)pid) < 0) {
        trace_log("EHPROBE_NEW_FS_EXEC: ERROR - push_param_s64 failed for pid");
        goto error;
    }

    // Parameter 3: process path
    struct file *exe_file = BPF_CORE_READ(task, mm, exe_file);
    if (exe_file != NULL) {
		uint32_t len = 0;
		char* p = reconstruct_file_path(&(exe_file->f_path), &len);
		if (p == NULL) {
			trace_log("EHPROBE_NEW_FS_EXEC: ERROR - reconstruct_file_path failed for process path, p == NULL");
            goto error;
		}
		if (len == 0 || len >= PATH_BUFFER_SIZE) {
			trace_log("EHPROBE_NEW_FS_EXEC: ERROR - reconstruct_file_path failed for process path, len %d", len);
            goto error;
		}
		if (push_param_string(evt_ctx, p, len, 1) < 0) {
			trace_log("EHPROBE_NEW_FS_EXEC: ERROR - push_param_string failed for process path");
			goto error;
		}
    } else {
        if (push_param_none(evt_ctx) < 0) {
            trace_log("EHPROBE_NEW_FS_EXEC: ERROR - push_param_none failed for process path (null)");
            goto error;
        }
    }

    // Parameter 4: operation
    if (push_param_u32(evt_ctx, (uint32_t)op) < 0) {
        trace_log("EHPROBE_NEW_FS_EXEC: ERROR - push_param_u32 failed for operation");
        goto error;
    }

    // Parameter 5: container ID
    if (push_param_u64(evt_ctx, container_id) < 0) {
        trace_log("EHPROBE_NEW_FS_EXEC: ERROR - push_param_u64 failed for container_id");
        goto error;
    }

    // Parameter 6: container level
    if (push_param_u32(evt_ctx, container_level) < 0) {
        trace_log("EHPROBE_NEW_FS_EXEC: ERROR - push_param_u32 failed for container_level");
        goto error;
    }

    trace_log("EHPROBE_NEW_FS_EXEC: submitting event");
    submit_event(evt_ctx);
    return 0;

error:
    trace_log("EHPROBE_NEW_FS_EXEC: ERROR - dropping event");
    release_event(evt_ctx);
    update_drop_stats(EVENT_TYPE_NEW_FS_EXEC);
    return -1;
}
