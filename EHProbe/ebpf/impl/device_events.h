// SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause
#pragma once

#include <ehprobe_common.h>
#include <container_logic.h>

// Helper to classify device based on major number
static __always_inline const char* get_device_class(unsigned int major)
{
    switch (major) {
        case 226: return "gpu";           // /dev/dri/*
        case 13:  return "input";         // /dev/input/*
        case 116: return "sound";         // /dev/snd/*
        case 81:  return "video";         // /dev/video*
        case 189: return "usb";           // /dev/bus/usb/*
        case 251: return "hid";           // /dev/hidraw*
        case 10:  return "misc";          // /dev/tpm*, /dev/uinput, etc.
        case 180: return "usb-gadget";
        case 166: return "acpi";          // /dev/acpi/*
        case 1:   return "mem";           // /dev/mem, /dev/kmem, /dev/null, etc.
        case 5:   return "tty";           // /dev/tty, /dev/console, /dev/ptmx
        case 4:   return "tty-serial";    // /dev/ttyS*, /dev/tty*
        case 89:  return "i2c";           // /dev/i2c-*
        case 254: return "rtc";           // /dev/rtc*
        default:  return "unknown";
    }
}

// Device open event emission helper
static __always_inline int ehprobe_device_open(
    struct task_struct *task,
    struct inode *inode,
    struct file *filp,
    uint64_t container_id,
    uint32_t container_level
) {
    u32 pid = BPF_CORE_READ(task, tgid);

    // Extract device information from inode
    dev_t dev = BPF_CORE_READ(inode, i_rdev);
    unsigned int major = MAJOR(dev);
    unsigned int minor = MINOR(dev);

    trace_log("EHPROBE_DEVICE_OPEN: major=%d minor=%d class=%s",
              major, minor, get_device_class(major));

    // Start event with 7 parameters:
    // 0: device_path (string)
    // 1: device_major (u32)
    // 2: device_minor (u32)
    // 3: device_class (string)
    // 4: executable_path (string)
    // 5: container_id (u64)
    // 6: container_level (u32)
    struct event_context *evt_ctx = start_event(EVENT_TYPE_DEVICE_OPEN, 7);
    if (!evt_ctx) {
        trace_log("EHPROBE_DEVICE_OPEN: ERROR - start_event failed");
        update_drop_stats(EVENT_TYPE_DEVICE_OPEN);
        return -1;
    }

    // Parameter 0: device_path - reconstruct from file path
    struct path *file_path = &filp->f_path;
    uint32_t path_len = 0;
    char *device_path = reconstruct_file_path(file_path, &path_len);

    if (device_path && path_len > 0 && path_len < PATH_BUFFER_SIZE) {
        if (push_param_string(evt_ctx, device_path, path_len, 1) < 0) {
            trace_log("EHPROBE_DEVICE_OPEN: ERROR - push_param_string failed for device_path");
            goto error;
        }
    } else {
        if (push_param_none(evt_ctx) < 0) {
            trace_log("EHPROBE_DEVICE_OPEN: ERROR - push_param_none failed for device_path");
            goto error;
        }
    }

    // Parameter 1: device_major
    if (push_param_u32(evt_ctx, major) < 0) {
        trace_log("EHPROBE_DEVICE_OPEN: ERROR - push_param_u32 failed for major");
        goto error;
    }

    // Parameter 2: device_minor
    if (push_param_u32(evt_ctx, minor) < 0) {
        trace_log("EHPROBE_DEVICE_OPEN: ERROR - push_param_u32 failed for minor");
        goto error;
    }

    // Parameter 3: device_class
    const char *device_class = get_device_class(major);
    int class_len = 0;

    // Calculate string length manually (bounded)
    #pragma unroll
    for (int i = 0; i < 32; i++) {
        if (device_class[i] == '\0') {
            class_len = i + 1;
            break;
        }
    }

    if (class_len > 0) {
        if (push_param_string(evt_ctx, device_class, class_len, 1) < 0) {
            trace_log("EHPROBE_DEVICE_OPEN: ERROR - push_param_string failed for device_class");
            goto error;
        }
    } else {
        if (push_param_none(evt_ctx) < 0) {
            trace_log("EHPROBE_DEVICE_OPEN: ERROR - push_param_none failed for device_class");
            goto error;
        }
    }

    // Parameter 4: executable_path
    struct file *exe_file = BPF_CORE_READ(task, mm, exe_file);
    if (exe_file != NULL) {
        uint32_t exe_len = 0;
        char *exe_path = reconstruct_file_path(&(exe_file->f_path), &exe_len);
        if (exe_path && exe_len > 0 && exe_len < PATH_BUFFER_SIZE) {
            if (push_param_string(evt_ctx, exe_path, exe_len, 1) < 0) {
                trace_log("EHPROBE_DEVICE_OPEN: ERROR - push_param_string failed for exe_path");
                goto error;
            }
        } else {
            if (push_param_none(evt_ctx) < 0) {
                trace_log("EHPROBE_DEVICE_OPEN: ERROR - push_param_none failed for exe_path (invalid)");
                goto error;
            }
        }
    } else {
        if (push_param_none(evt_ctx) < 0) {
            trace_log("EHPROBE_DEVICE_OPEN: ERROR - push_param_none failed for exe_path (null)");
            goto error;
        }
    }

    // Parameter 5: container_id
    if (push_param_u64(evt_ctx, container_id) < 0) {
        trace_log("EHPROBE_DEVICE_OPEN: ERROR - push_param_u64 failed for container_id");
        goto error;
    }

    // Parameter 6: container_level
    if (push_param_u32(evt_ctx, container_level) < 0) {
        trace_log("EHPROBE_DEVICE_OPEN: ERROR - push_param_u32 failed for container_level");
        goto error;
    }

    trace_log("EHPROBE_DEVICE_OPEN: submitting event, major=%d, minor=%d, class=%s",
              major, minor, device_class);
    return submit_event(evt_ctx);

error:
    trace_log("EHPROBE_DEVICE_OPEN: ERROR - dropping event");
    release_event(evt_ctx);
    update_drop_stats(EVENT_TYPE_DEVICE_OPEN);
    return -1;
}
