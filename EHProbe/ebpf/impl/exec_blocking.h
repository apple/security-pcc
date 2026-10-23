// SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause
#pragma once

#include <ehprobe_common.h>
#include <container_logic.h>

#include <bpf/bpf_tracing.h>
#include <bpf/bpf_endian.h>


// Per-CPU map to store exec path
struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 1);
    __type(key, u32);
    __type(value, struct path_entry);
} local_exec_path_map __weak SEC(".maps");

static __always_inline uint32_t convert_dev(dev_t dev) {
    unsigned major = MAJOR(dev);
    unsigned minor = MINOR(dev);
    return (minor & 0xff) | (major << 8) | ((minor & ~0xff) << 12);
}

// return 1 is the hashes are the same, 0 otherwise
static __always_inline int compare_hashes(const unsigned char *hash1, const unsigned char *hash2) {
    for (int i = 0; i < SHA256_DIGEST_SIZE; i++) {
        if (hash1[i] != hash2[i]) {
            return 0;
        }
    }
    return 1;
}

// Check if hash matches for the given ino/dev file
// returns 1 to allow the path, 0 otherwise
// verify_hash: 1 = compare hashes (IMA available), 0 = inode+dev match is sufficient (IMA unavailable)
static __always_inline int is_file_allowed(uint64_t ino, uint32_t dev, const unsigned char *hash,
                                           uint64_t container_id, int verify_hash) {
    // Look up the inner map for this container
    void *inner_map = bpf_map_lookup_elem(&exec_allowlist_outer_map, &container_id);
    if (!inner_map) {
        trace_log("EHPROBE_EXEC_BLOCKING: No allowlist found for container %llu", container_id);
        return 0;
    }

    // Prepare the lookup key for the inner map
    struct allowlist_key lookup_key = {
        .ino = ino,
        .dev = dev,
        .pad = 0
    };

    // Look up the entry in the inner map with original key
    struct allowlist_entry *entry = bpf_map_lookup_elem(inner_map, &lookup_key);
    if (!entry) {
        trace_log("EHPROBE_EXEC_BLOCKING: ino=%lu/dev=%u not found in allowlist for container %llu",
                   ino, dev, container_id);
        return 0;
    }

    // If hash verification is not available (IMA not enabled), inode+dev match is sufficient
    if (!verify_hash) {
        trace_log("EHPROBE_EXEC_BLOCKING: IMA unavailable, allowing by inode+dev for ino=%lu/dev=%u", ino, dev);
        return 1;
    }

    // Compare the hashes
    if (compare_hashes(hash, entry->hash)) {
        trace_log("EHPROBE_EXEC_BLOCKING: Hash matches allowlist entry for ino=%lu/dev=%u", ino, dev);
        return 1;
    }

    trace_log("EHPROBE_EXEC_BLOCKING: Hash mismatch for ino=%lu/dev=%u", ino, dev);
    return 0;
}

// Check if path matches any allowed path for the given hash
// returns 0 to allow execution, 1 to block execution and -1 in case of an error
static __always_inline int ehprobe_exec_blocking(struct linux_binprm *bprm) {
    pid_t pid = bpf_get_current_pid_tgid() >> 32;
    trace_log("EHPROBE_EXEC_BLOCKING: Hook entered for pid %d", pid);

    uint32_t container_level = 0;
    uint64_t container_id = get_container_id(bpf_get_current_task_btf(), &container_level);
    if (container_id > 0) {
        if (!is_container_blocking(container_id)) {
            trace_log("EHPROBE_EXEC_BLOCKING: container is not in blocking mode - allowing");
            return 0;
        }
    }

    // Get inode and device information
    struct inode *inode = BPF_CORE_READ(bprm, file, f_inode);
    if (!inode) {
        trace_log("EHPROBE_EXEC_BLOCKING: Failed to get inode - allowing");
        return -1;
    }

    uint64_t ino = BPF_CORE_READ(inode, i_ino);
    dev_t kernel_dev = BPF_CORE_READ(inode, i_sb, s_dev);
    uint32_t dev = convert_dev(kernel_dev);  // Convert to userspace format
    trace_log("EHPROBE_EXEC_BLOCKING: inode=%lu, dev=%u", ino, dev);

    // Get the per-CPU temporary path storage
    u32 map_key = 0;
    struct path_entry *exec_path = bpf_map_lookup_elem(&local_exec_path_map, &map_key);
    if (!exec_path) {
        trace_log("EHPROBE_EXEC_BLOCKING: Failed to get temp path - allowing");
        return -1;
    }

    // get the file path of the binary being executed
    int ret = bpf_d_path(&bprm->file->f_path, exec_path->path, sizeof(exec_path->path));
    if (ret < 0) {
        trace_log("EHPROBE_EXEC_BLOCKING: bpf_d_path failed with error %d - allowing", ret);
        return -1;
    }

    trace_log("EHPROBE_EXEC_BLOCKING: Checking path %s, container ID: %llu", exec_path->path, container_id);

    // calculate the file hash - sleepable operation (requires lsm.s prefix)
    // Falls back to inode+dev-only allowlist check when IMA is unavailable.
    unsigned char hash[SHA256_DIGEST_SIZE];
    int verify_hash = 1;
    ret = bpf_ima_file_hash(bprm->file, hash, sizeof(hash));
    if (ret < 0) {
        trace_log("EHPROBE_EXEC_BLOCKING: bpf_ima_file_hash failed (%d) - using inode-only check", ret);
        __builtin_memset(hash, 0, sizeof(hash));
        verify_hash = 0;
    }

    // Casting hash for easier printing - now properly aligned
    unsigned long long *exec_hash_ptr = (unsigned long long *)hash;
    trace_log("EHPROBE_EXEC_BLOCKING: Hash Part1: %016llx%016llx", bpf_cpu_to_be64(exec_hash_ptr[0]), bpf_cpu_to_be64(exec_hash_ptr[1]));
    trace_log("EHPROBE_EXEC_BLOCKING: Hash Part2: %016llx%016llx", bpf_cpu_to_be64(exec_hash_ptr[2]), bpf_cpu_to_be64(exec_hash_ptr[3]));

    // Check if the hash is allowed for this ino/dev
    int allowed = is_file_allowed(ino, dev, hash, container_id, verify_hash);

    trace_log("EHPROBE_EXEC_BLOCKING: Execution %s for %s, container ID %llu",
        (allowed != 0) ? "allowed" : "denied", exec_path->path, container_id);

    // Send event using ehprobe API
    struct event_context *evt_ctx = start_event(EVENT_TYPE_EXEC_SECURITY, 7);
    if (!evt_ctx) {
        trace_log("EHPROBE_EXEC_BLOCKING: ERROR - start_event failed");
        update_drop_stats(EVENT_TYPE_EXEC_SECURITY);
        goto event_error;
    }

    // Parameter 0: path
    if (push_param_string(evt_ctx, exec_path->path, MAX_PATH, 1) < 0) { // KERNEL space
        trace_log("EHPROBE_EXEC_BLOCKING: ERROR - push_param_string failed for path");
        goto event_error;
    }

    // Parameter 1: hash
    if (push_param_bytebuf(evt_ctx, hash, SHA256_DIGEST_SIZE, 1) < 0) {
        trace_log("EHPROBE_EXEC_BLOCKING: ERROR - push_param_none failed for hash");
        goto event_error;
    }

    // Parameter 2: process PID
    if (push_param_s64(evt_ctx, (int64_t)pid) < 0) {
        trace_log("EHPROBE_EXEC_BLOCKING: ERROR - push_param_s64 failed for pid");
        goto event_error;
    }

    // Parameter 3: container ID
    if (push_param_u64(evt_ctx, container_id) < 0) {
        trace_log("EHPROBE_EXEC_BLOCKING: ERROR - push_param_u64 failed for container_id");
        goto event_error;
    }

    // Parameter 4: container level
    if (push_param_u32(evt_ctx, container_level) < 0) {
        trace_log("EHPROBE_EXEC_BLOCKING: ERROR - push_param_u32 failed for container_level");
        goto event_error;
    }

    // Parameter 5: allow
    if (push_param_u32(evt_ctx, (allowed != 0) ? 1 : 0) < 0) {
        trace_log("EHPROBE_EXEC_BLOCKING: ERROR - push_param_u32 failed for allow");
        goto event_error;
    }

    // Parameter 6: blocking_mode (off=0, audit=1, enforce=2)
    {
        uint32_t blocking_mode_val = EHPROBE_BLOCKING_MODE_OFF;
        if (container_id > 0) {
            struct container_entry *container = bpf_map_lookup_elem(&containers_map, &container_id);
            if (container) {
                blocking_mode_val = (uint32_t)container->blocking_mode;
            }
        } else {
            u32 env_key = 0;
            struct ehprobe_env *env = bpf_map_lookup_elem(&ehprobe_env_map, &env_key);
            if (env) {
                blocking_mode_val = (uint32_t)env->blocking_mode;
            }
        }
        if (push_param_u32(evt_ctx, blocking_mode_val) < 0) {
            trace_log("EHPROBE_EXEC_BLOCKING: ERROR - push_param_u32 failed for blocking_mode");
            goto event_error;
        }
    }

    trace_log("EHPROBE_EXEC_BLOCKING: submitting event");
    submit_event(evt_ctx);
    return allowed ? 0 : 1;

event_error:
    trace_log("EHPROBE_EXEC_BLOCKING: ERROR - dropping event");
    release_event(evt_ctx);
    update_drop_stats(EVENT_TYPE_EXEC_SECURITY);
    return 0;
}
