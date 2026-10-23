// SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause
#pragma once

#include <ehprobe_common.h>
#include <container_logic.h>

/* Proc name */
#define MAX_PROC_EXE 4096
#define PERCPU_PATH_BUF_SIZE 4096

#define STATUS_EXIT(status) ((status) >> 8)
#define STATUS_SIGNAL(status) ((status) & 0x7f)
#define STATUS_COREDUMP(status) (((status) & 0x80) != 0)

// Define per-CPU buffer for path construction
struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 1);
    __type(key, uint32_t);
    __type(value, char[PERCPU_PATH_BUF_SIZE]);
} local_path_map __weak SEC(".maps");

// TODO: refactor
/**
 * @brief Encode device number with `MAJOR` and `MINOR` MACRO.
 *
 * Please note: **Used only inside this file**.
 *
 * @param dev device number extracted directly from the kernel.
 * @return encoded device number.
 */
static __always_inline dev_t encode_dev(dev_t dev) {
	unsigned int major = MAJOR(dev);
	unsigned int minor = MINOR(dev);

	return (minor & 0xff) | (major << 8) | ((minor & ~0xff) << 12);
}

static __always_inline uint32_t get_tty(struct task_struct *task) {
	struct signal_struct *signal = BPF_CORE_READ(task, signal);
	if (!signal) {
		return 0;
	}

	struct tty_struct *tty = BPF_CORE_READ(signal, tty);
	if (!tty) {
		return 0;
	}

	struct tty_driver *driver = BPF_CORE_READ(tty, driver);
	if (!driver) {
		return 0;
	}

	int index = BPF_CORE_READ(tty, index);
	int major = BPF_CORE_READ(driver, major);
	int minor_start = BPF_CORE_READ(driver, minor_start);
	return encode_dev(MKDEV(major, minor_start) + index);
}

static __always_inline int ehprobe_process_exec(struct task_struct *p, struct linux_binprm *bprm) {
    struct task_struct *task = bpf_get_current_task_btf();

    uint32_t container_level = 0;
    uint64_t container_id = get_container_id(task, &container_level);
    if (container_id > 0) {
        trace_log("EHPROBE_PROCESS_EXEC: container ID: %lu, container_level: %d", container_id, container_level);
    }

    // Start event with 13 parameters
    struct event_context *evt_ctx = start_event(EVENT_TYPE_EXEC, 13);
    if (!evt_ctx) {
        trace_log("EHPROBE_PROCESS_EXEC: ERROR - start_event failed");
        update_drop_stats(EVENT_TYPE_EXEC);
        return -1;
    }

    // Parameter 0: exe_file
    struct file *exe_file = BPF_CORE_READ(task, mm, exe_file);
    if (exe_file != NULL) {
		uint32_t len = 0;
		char* p = reconstruct_file_path(&(exe_file->f_path), &len);
		if (p == NULL) {
			trace_log("EHPROBE_PROCESS_EXEC: ERROR - reconstruct_file_path failed for exe_file, p == NULL");
            goto error;
		}
		if (len == 0 || len >= PATH_BUFFER_SIZE) {
			trace_log("EHPROBE_PROCESS_EXEC: ERROR - reconstruct_file_path failed for exe_file, len %d", len);
            goto error;
		}
		if (push_param_string(evt_ctx, p, len, 1) < 0) {
			trace_log("EHPROBE_PROCESS_EXEC: ERROR - push_param_string failed for exe_file");
			goto error;
		}
    } else {
        if (push_param_none(evt_ctx) < 0) {
            trace_log("EHPROBE_PROCESS_EXEC: ERROR - push_param_none failed for exe_file (null)");
            goto error;
        }
    }

    unsigned long arg_start_pointer = 0;
    unsigned long arg_end_pointer = 0;
    uint16_t exe_arg_len = 0;

    BPF_CORE_READ_INTO(&arg_start_pointer, task, mm, arg_start);
    BPF_CORE_READ_INTO(&arg_end_pointer, task, mm, arg_end);

    // Parameter 1: exe
    if (arg_start_pointer != 0) {
        exe_arg_len = push_param_string(evt_ctx, (const char *)arg_start_pointer, MAX_PROC_EXE, 0);
        if (exe_arg_len < 0) { // USER space
            trace_log("EHPROBE_PROCESS_EXEC: ERROR - push_param_string failed for exe");
            goto error;
        }
    } else {
        if (push_param_none(evt_ctx) < 0) {
            trace_log("EHPROBE_PROCESS_EXEC: ERROR - push_param_none failed for exe");
            goto error;
        }
    }

    // Parameter 2: args
    unsigned long total_args_len = 0;
    if (arg_start_pointer != 0) {
        total_args_len = arg_end_pointer - arg_start_pointer - exe_arg_len;
    }
    if (total_args_len != 0) {
        if (push_param_bytebuf(evt_ctx, (const unsigned char *)(arg_start_pointer + exe_arg_len), total_args_len, 0) < 0) {
            trace_log("EHPROBE_PROCESS_EXEC: ERROR - push_param_bytebuf failed for args");
            goto error;
        }
    }
    else {
        if (push_param_none(evt_ctx) < 0) {
            trace_log("EHPROBE_PROCESS_EXEC: ERROR - push_param_none failed for args");
            goto error;
        }
    }

    // Parameter 3: pid
    int64_t pid = (int64_t)BPF_CORE_READ(task, tgid);
    if (push_param_s64(evt_ctx, pid) < 0) {
        trace_log("EHPROBE_PROCESS_EXEC: ERROR - push_param_s64 failed for pid");
        goto error;
    }

    // Parameter 4: pgid
    int64_t pgid = (int64_t)BPF_CORE_READ(task, real_parent, pid);
    if (push_param_s64(evt_ctx, pgid) < 0) {
        trace_log("EHPROBE_PROCESS_EXEC: ERROR - push_param_s64 failed for pgid");
        goto error;
    }

    // Parameter 5: comm
    if (push_param_string(evt_ctx, (const char *)task->comm, TASK_COMM_LEN, 1) < 0) { // KERNEL space
        trace_log("EHPROBE_PROCESS_EXEC: ERROR - push_param_string failed for comm");
        goto error;
    }

    // Parameter 6: cwd
	uint32_t len = 0;
	struct path path;
	BPF_CORE_READ_INTO(&path, task, fs, pwd);
	char* pwd_path = reconstruct_file_path(&path, &len);
	if (pwd_path != NULL) {
		if (len == 0 || len >= PATH_BUFFER_SIZE) {
	        trace_log("EHPROBE_PROCESS_EXEC: ERROR - reconstruct_file_path failed for pwd, len %d", len);
			goto error;
		}
		if (push_param_string(evt_ctx, pwd_path, len, 1) < 0) {
	        trace_log("EHPROBE_PROCESS_EXEC: ERROR - push_param_string failed for pwd");
			goto error;
		}
	}
	else {
		if (push_param_none(evt_ctx) < 0) {
			trace_log("EHPROBE_PROCESS_EXEC: ERROR - push_param_none failed for pwd");
			goto error;
		}
	}

    // Parameter 7: tty
    uint32_t tty = get_tty(task);
    if (push_param_u32(evt_ctx, tty) < 0) {
        trace_log("EHPROBE_PROCESS_EXEC: ERROR - push_param_u32 failed for tty");
        goto error;
    }

    // Parameter 8: euid
    // Use BPF_CORE_READ_INTO when reading through `task->cred` (a const pointer);
    // BPF_CORE_READ would declare a const temporary without an initializer and
    // trip clang's -Wdefault-const-init-var-unsafe.
    uint32_t euid = 0;
    BPF_CORE_READ_INTO(&euid, task, cred, euid.val);
    if (push_param_u32(evt_ctx, euid) < 0) {
        trace_log("EHPROBE_PROCESS_EXEC: ERROR - push_param_u32 failed for euid");
        goto error;
    }

    // Parameter 9: egid
    uint32_t egid = 0;
    BPF_CORE_READ_INTO(&egid, task, cred, egid.val);
    if (push_param_u32(evt_ctx, egid) < 0) {
        trace_log("EHPROBE_PROCESS_EXEC: ERROR - push_param_u32 failed for egid");
        goto error;
    }

    struct task_struct *parent_task = BPF_CORE_READ(task, real_parent);
    struct file *parent_exe_file = BPF_CORE_READ(parent_task, mm, exe_file);

    // Parameter 10: parent_exe_file
    if (parent_exe_file != NULL) {
		uint32_t len = 0;
		char* p = reconstruct_file_path(&(parent_exe_file->f_path), &len);
		if (p == NULL) {
			trace_log("EHPROBE_PROCESS_EXEC: ERROR - reconstruct_file_path failed for parent's trusted_exepath, p == NULL");
            goto error;
		}
		if (len == 0 || len >= PATH_BUFFER_SIZE) {
			trace_log("EHPROBE_PROCESS_EXEC: ERROR - reconstruct_file_path failed for parent's trusted_exepath, len %d", len);
            goto error;
		}
		if (push_param_string(evt_ctx, p, len, 1) < 0) {
			trace_log("EHPROBE_PROCESS_EXEC: ERROR - push_param_string failed for parent's trusted_exepath");
			goto error;
		}
    } else {
        if (push_param_none(evt_ctx) < 0) {
            trace_log("EHPROBE_PROCESS_EXEC: ERROR - push_param_none failed for parent's trusted_exepath (null)");
            goto error;
        }
    }

    // Parameter 11: container ID
    if (push_param_u64(evt_ctx, container_id) < 0) {
        trace_log("EHPROBE_PROCESS_EXEC: ERROR - push_param_u64 failed for container_id");
        goto error;
    }

    // Parameter 12: container level
    if (push_param_u32(evt_ctx, container_level) < 0) {
        trace_log("EHPROBE_PROCESS_EXEC: ERROR - push_param_u32 failed for container_level");
        goto error;
    }

    trace_log("EHPROBE_PROCESS_EXEC: submitting event");
    return submit_event(evt_ctx);

error:
    trace_log("EHPROBE_PROCESS_EXEC: ERROR - dropping event");
    release_event(evt_ctx);
    update_drop_stats(EVENT_TYPE_EXEC);
    return -1;
}

static __always_inline int ehprobe_process_exit(struct task_struct *task) {
    if (!task) {
        return 0;
    }

    uint32_t container_level = 0;
    uint64_t container_id = get_container_id(task, &container_level);
    if (container_id > 0) {
        trace_log("EHPROBE_PROCESS_EXIT: container ID: %lu, container_level: %d", container_id, container_level);
    }

    // Start event with 7 parameters (matching the original implementation)
    struct event_context *evt_ctx = start_event(EVENT_TYPE_EXIT, 7);
    if (!evt_ctx) {
        trace_log("EHPROBE_PROCESS_EXIT: ERROR - start_event failed");
        update_drop_stats(EVENT_TYPE_EXIT);
        return -1;
    }

    // Parameter 0: pid
    int64_t pid = (int64_t)BPF_CORE_READ(task, tgid);
    if (push_param_s64(evt_ctx, pid) < 0) {
        trace_log("EHPROBE_PROCESS_EXIT: ERROR - push_param_s64 failed for pid");
        goto error;
    }

    // Parameter 1: status
    int32_t exit_code = 0;
    BPF_CORE_READ_INTO(&exit_code, task, exit_code);
    if (push_param_s64(evt_ctx, (int64_t)exit_code) < 0) {
        trace_log("EHPROBE_PROCESS_EXIT: ERROR - push_param_s64 failed for exit_code");
        goto error;
    }

    // Parameter 2: ret
    uint8_t ret = STATUS_EXIT(exit_code);
    if (push_param_s64(evt_ctx, (int64_t)ret) < 0) {
        trace_log("EHPROBE_PROCESS_EXIT: ERROR - push_param_s64 failed for ret");
        goto error;
    }

    // Parameter 3: sig
    uint8_t sig = STATUS_SIGNAL(exit_code);
    if (sig == 0x7f) {
        // process stopped
        sig = 0;
    }
    if (push_param_u32(evt_ctx, (uint32_t)sig) < 0) {
        trace_log("EHPROBE_PROCESS_EXIT: ERROR - push_param_u32 failed for sig");
        goto error;
    }

    // Parameter 4: core
    uint8_t core = STATUS_COREDUMP(exit_code);
    if (push_param_u32(evt_ctx, (uint32_t)core) < 0) {
        trace_log("EHPROBE_PROCESS_EXIT: ERROR - push_param_u32 failed for core");
        goto error;
    }

    // Parameter 5: container ID
    if (push_param_u64(evt_ctx, container_id) < 0) {
        trace_log("EHPROBE_PROCESS_EXIT: ERROR - push_param_u64 failed for container_id");
        goto error;
    }

    // Parameter 6: container level
    if (push_param_u32(evt_ctx, container_level) < 0) {
        trace_log("EHPROBE_PROCESS_EXIT: ERROR - push_param_u32 failed for container_level");
        goto error;
    }

    trace_log("EHPROBE_PROCESS_EXIT: submitting event");
    return submit_event(evt_ctx);

error:
    trace_log("EHPROBE_PROCESS_EXIT: ERROR - dropping event");
    release_event(evt_ctx);
    update_drop_stats(EVENT_TYPE_EXIT);
    return -1;
}

static __always_inline int ehprobe_process_fork(struct task_struct *parent, struct task_struct *child) {
    struct task_struct *task = bpf_get_current_task_btf();

    if (!parent || !child) {
        return 0;
    }

    uint32_t container_level = 0;
    uint64_t container_id = get_container_id(parent, &container_level);
    if (container_id > 0) {
        trace_log("EHPROBE_PROCESS_FORK: container ID: %lu, container_level: %d", container_id, container_level);
    }

    // Start event with 6 parameters
    struct event_context *evt_ctx = start_event(EVENT_TYPE_FORK, 6);
    if (!evt_ctx) {
        trace_log("EHPROBE_PROCESS_FORK: ERROR - start_event failed");
        update_drop_stats(EVENT_TYPE_FORK);
        return -1;
    }

    // Parameter 0: child_pid (S64)
    int64_t child_pid = (int64_t)BPF_CORE_READ(child, tgid);
    if (push_param_s64(evt_ctx, child_pid) < 0) {
        trace_log("EHPROBE_PROCESS_FORK: ERROR - push_param_s64 failed for child_pid");
        goto error;
    }

    // Parameter 1: parent_pid (S64)
    int64_t parent_pid = (int64_t)BPF_CORE_READ(parent, tgid);
    if (push_param_s64(evt_ctx, parent_pid) < 0) {
        trace_log("EHPROBE_PROCESS_FORK: ERROR - push_param_s64 failed for parent_pid");
        goto error;
    }

    // Parameter 2: comm (STRING)
    if (push_param_string(evt_ctx, (const char *)task->comm, TASK_COMM_LEN, 1) < 0) { // KERNEL space
        trace_log("EHPROBE_PROCESS_EXEC: ERROR - push_param_string failed for comm");
        goto error;
    }

    // Parameter 3: parent_exe (STRING or NONE)
    struct file *parent_exe_file = BPF_CORE_READ(parent, mm, exe_file);
    if (parent_exe_file != NULL) {
        uint32_t len = 0;
        char* p = reconstruct_file_path(&(parent_exe_file->f_path), &len);
        if (p == NULL) {
            trace_log("EHPROBE_PROCESS_FORK: ERROR - reconstruct_file_path failed for parent_exe_file, p == NULL");
            goto error;
        }
        if (len == 0 || len >= PATH_BUFFER_SIZE) {
            trace_log("EHPROBE_PROCESS_FORK: ERROR - reconstruct_file_path failed for parent_exe_file, len %d", len);
            goto error;
        }
        if (push_param_string(evt_ctx, p, len, 1) < 0) {
            trace_log("EHPROBE_PROCESS_FORK: ERROR - push_param_string failed for parent_exe_file");
            goto error;
        }
    } else {
        if (push_param_none(evt_ctx) < 0) {
            trace_log("EHPROBE_PROCESS_FORK: ERROR - push_param_none failed for parent_exe_file (null)");
            goto error;
        }
    }

    // Parameter 4: container_id (U64)
    if (push_param_u64(evt_ctx, container_id) < 0) {
        trace_log("EHPROBE_PROCESS_FORK: ERROR - push_param_u64 failed for container_id");
        goto error;
    }

    // Parameter 5: container_level (U32)
    if (push_param_u32(evt_ctx, container_level) < 0) {
        trace_log("EHPROBE_PROCESS_FORK: ERROR - push_param_u32 failed for container_level");
        goto error;
    }

    trace_log("EHPROBE_PROCESS_FORK: submitting event");
    return submit_event(evt_ctx);

error:
    trace_log("EHPROBE_PROCESS_FORK: ERROR - dropping event");
    release_event(evt_ctx);
    update_drop_stats(EVENT_TYPE_FORK);
    return -1;
}
