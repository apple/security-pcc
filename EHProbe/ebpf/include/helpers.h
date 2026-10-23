// SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause
// helpers.h
#pragma once

#include <ehprobe_common.h>

#define trace_log(format, ...) ({ static char lfmt[] = format "\0"; bpf_trace_printk(lfmt, sizeof(lfmt), ##__VA_ARGS__); })

// Path reconstruction constants
#define MAX_PATH_DEPTH                  16
#define PATH_BUFFER_SIZE                8192
#define PATH_BUILD_START_OFFSET         4096
#define BOUND_INDEX(x)                  ((x) & (PATH_BUILD_START_OFFSET - 1))

// Per-CPU buffer for path construction
struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 1);
    __type(key, uint32_t);
    __type(value, char[PATH_BUFFER_SIZE]);
} percpu_path_buffer __weak SEC(".maps");

// Internal helper that does the actual path reconstruction
static __always_inline char* reconstruct_file_path(struct path *file_path, uint32_t *out_path_length) {
    char path_separator = '/';
    char string_terminator = '\0';

    if (!file_path) {
        return NULL;
    }
        
    uint32_t map_key = 0;
    char *path_workspace = bpf_map_lookup_elem(&percpu_path_buffer, &map_key);
    if (!path_workspace) {
        return NULL;
    }

    struct path current_path = {};
    bpf_core_read(&current_path, sizeof(struct path), file_path);
    
    struct dentry *current_dentry = current_path.dentry;
    struct vfsmount *current_mount = current_path.mnt;
    struct mount *mount_struct = container_of(current_mount, struct mount, mnt);
    struct mount *parent_mount = BPF_CORE_READ(mount_struct, mnt_parent);
    
    struct dentry *mount_root = BPF_CORE_READ(current_mount, mnt_root);

    uint32_t write_position = PATH_BUILD_START_OFFSET;

    struct dentry *parent_dentry = NULL;
    struct qstr name_string = {};
    int actual_name_length = 0;
    uint32_t segment_offset = 0;

#pragma unroll
    for(int depth = 0; depth < MAX_PATH_DEPTH; depth++) {
        parent_dentry = BPF_CORE_READ(current_dentry, d_parent);
        name_string = BPF_CORE_READ(current_dentry, d_name);

        if (current_dentry == parent_dentry && current_dentry != mount_root) {
            // reached root but not mount root
            trace_log("reconstruct_file_path: reached root, name_string = %s, workspace: %s",
                    name_string.name, &(path_workspace[BOUND_INDEX(write_position)]));
            break;
        }

        if (current_dentry == mount_root) {
            if (mount_struct != parent_mount) {
                // Cross mount boundary (matches kernel __prepend_path logic):
                // 1. Step to the dentry where this mount is attached in the parent
                current_dentry = BPF_CORE_READ(mount_struct, mnt_mountpoint);
                // 2. Advance to parent mount struct
                mount_struct = parent_mount;
                current_mount = &parent_mount->mnt;
                // 3. Update parent_mount and mount_root for the next boundary check
                parent_mount = BPF_CORE_READ(mount_struct, mnt_parent);
                mount_root = BPF_CORE_READ(mount_struct, mnt.mnt_root);
                continue;
            } else {
                // Reached filesystem root — full traversal complete
                break;
            }
        }

        // Calculate offset (extra char for null terminator)
        segment_offset = write_position - (name_string.len + 1);
        
        actual_name_length = bpf_probe_read_kernel_str(
                &(path_workspace[BOUND_INDEX(segment_offset)]),
                BOUND_INDEX(name_string.len + 1),
                (void *)name_string.name);
        if (actual_name_length <= 1) {
            break;
        }

        // Replace the null terminator with a separator
        write_position -= 1;
        bpf_probe_read_kernel(&(path_workspace[BOUND_INDEX(write_position)]), 1, &path_separator);
        write_position -= (actual_name_length - 1);

        // Move to parent dentry
        current_dentry = parent_dentry;
    }

    char *result_path = NULL;
    uint32_t path_length = 0;

    // files with no filesystem path
    if (write_position == PATH_BUILD_START_OFFSET) {
        trace_log("reconstruct_file_path: no filesystem path");
        name_string = BPF_CORE_READ(current_dentry, d_name);
        path_length = bpf_probe_read_kernel_str(&(path_workspace[0]), BOUND_INDEX(name_string.len + 1), (void *)name_string.name);
        if (path_length > 0) {
            path_length--; // Reduce by 1 null terminator
            result_path = path_workspace;
        } else {
            if (out_path_length) {
                // error - return empty string
                *out_path_length = 0;
            }
            return path_workspace;
        }
    } else {
        write_position -= 1;
        bpf_probe_read_kernel(&(path_workspace[BOUND_INDEX(write_position)]), 1, &path_separator);
        bpf_probe_read_kernel(&(path_workspace[BOUND_INDEX(PATH_BUILD_START_OFFSET - 1)]), 1, &string_terminator);

        result_path = &(path_workspace[BOUND_INDEX(write_position)]);
        path_length = PATH_BUILD_START_OFFSET - BOUND_INDEX(write_position);
    }

    if (out_path_length) {
        *out_path_length = path_length;
    }
    
    trace_log("reconstruct_file_path: returning length %d: %s",
        *out_path_length, result_path);
    return result_path;
}

static __always_inline int reconstruct_file_path_into(struct path *file_path, char *buf, uint32_t sz) {
    if (!buf || sz == 0) {
        return -1;
    }

    uint32_t path_length = 0;
    char *result_path = reconstruct_file_path(file_path, &path_length);
    
    if (!result_path) {
        return -1;
    }

    // Copy to output buffer
    int copy_len = path_length;
    if (copy_len >= sz) {
        copy_len = sz - 1;
    }
    
    if (copy_len > 0) {
        bpf_probe_read_kernel(buf, copy_len, result_path);
    }
    buf[copy_len] = '\0';

    return copy_len;
}
