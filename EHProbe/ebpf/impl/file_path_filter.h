// SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause
// file_path_filter.h - Path-based filtering for file events
#pragma once

#include <ehprobe_common.h>

// Check if a file path should emit an event based on configured filters
// Returns: 1 if event should be emitted, 0 if filtered out
//
// Filtering behavior (secure by default):
// - When filtering is DISABLED: emit all events (return 1)
// - When filtering is ENABLED: only emit events matching configured paths
//   - If no paths configured, filter out ALL events (return 0)
//   - Supports exact path matching via hash map (O(1) lookup)
//   - Supports prefix matching via LPM trie (O(path_bits) lookup, single call)
//
// Note: This header is included only by non-sleepable BPF programs.
// Sleepable programs (lsm.s/*) cannot use BPF_MAP_TYPE_LPM_TRIE.
static __always_inline int should_emit_file_event(const char *path, uint32_t path_len)
{
    // Get environment to check if filtering is enabled
    u32 env_key = 0;
    struct ehprobe_env *env = bpf_map_lookup_elem(&ehprobe_env_map, &env_key);
    if (!env || !env->flag_file_path_filter) {
        // Filtering not enabled - emit all events
        return 1;
    }

    // Path validation - when filtering is enabled, invalid paths are filtered out
    if (!path || path_len == 0 || path_len >= FILE_PATH_FILTER_MAX_LEN) {
        // Invalid path or path too long - filter out (secure by default)
        return 0;
    }

    // Build the LPM key once and reuse it for both map lookups.
    // Setting prefixlen = path_len * 8 means "match any registered prefix
    // that is a prefix of this full path."
    struct file_path_lpm_key lpm_key = {};
    lpm_key.prefixlen = path_len * 8;

    // Copy path into lpm_key.data using bpf_probe_read for safety.
    // This also serves as the key for the literal hash map (same bytes).
    if (bpf_probe_read_kernel_str(lpm_key.data, FILE_PATH_FILTER_MAX_LEN, path) < 0) {
        // Read failed - filter out (secure by default)
        return 0;
    }

    // Check 1: Exact path match in hash map (O(1) lookup).
    // Reuse lpm_key.data as the struct file_path_filter_key - same memory layout.
    struct file_path_filter_value *val =
        bpf_map_lookup_elem(&file_path_literal_map,
                            (struct file_path_filter_key *)lpm_key.data);
    if (val && val->active) {
        // Exact match found - emit event
        return 1;
    }

    // Check 2: Prefix match via LPM trie (O(path_bits), single kernel call).
    struct file_path_filter_value *lpm_val =
        bpf_map_lookup_elem(&file_path_prefix_lpm, &lpm_key);
    if (lpm_val && lpm_val->active) {
        return 1;
    }

    // No match found - filter out this event
    return 0;
}
