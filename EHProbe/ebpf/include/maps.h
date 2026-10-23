// SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause
// maps.h
#pragma once

#include <bpf/bpf_helpers.h>

/* Global environment map - single entry
 * Used by: handle_accept.bpf.c, handle_bprm_check.bpf.c, handle_connect.bpf.c,
 *          handle_exec.bpf.c, handle_exit.bpf.c, handle_recvfrom.bpf.c,
 *          handle_recvmsg.bpf.c, handle_sendmsg.bpf.c, handle_sendmmsg.bpf.c,
 *          handle_sendto.bpf.c
 */
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 1);
    __type(key, uint32_t);
    __type(value, struct ehprobe_env);
} ehprobe_env_map __weak SEC(".maps");

/* Inner map template for inode/dev -> SHA256 hash mapping
 * Used by: exec_blocking.h (referenced by handle_bprm_check.bpf.c)
 */
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 32768);
    __type(key, struct allowlist_key);
    __type(value, struct allowlist_entry);
} exec_allowlist_inner_map __weak SEC(".maps");

/* Outer map for container_id -> inner map mapping
 * Used by: exec_blocking.h (referenced by handle_bprm_check.bpf.c)
 */
struct {
    __uint(type, BPF_MAP_TYPE_HASH_OF_MAPS);
    __uint(max_entries, 1024);
    __type(key, u64);
    __type(value, uint32_t);  // inner map fd
    __array(values, exec_allowlist_inner_map);
} exec_allowlist_outer_map __weak SEC(".maps");

/*
 * Main database of active, confirmed containers.
 * KEY: The inode number of the container's PID namespace. This is a
 *      unique and stable identifier for the container's lifetime.
 * VALUE: Rich context about the running container.
 * Used by: container_logic.h (referenced by handle_bprm_check.bpf.c, handle_exec.bpf.c),
 *          handle_exit.bpf.c (via check_container_termination)
 */
struct {
	__uint(type, BPF_MAP_TYPE_HASH);
	__uint(max_entries, 1024);
	__type(key, u64);
	__type(value, struct container_entry);
} containers_map __weak SEC(".maps");

/* UDP session LRU cache - 16384 entries
 * Used by: network_events.h (for UDP session tracking)
 */
struct {
    __uint(type, BPF_MAP_TYPE_LRU_HASH);
    __uint(max_entries, 16384);
    __type(key, struct udp_session_key);
    __type(value, struct udp_session_value);
} udp_session_cache __weak SEC(".maps");

/* UDP recvfrom pending operations map
 * Used by: handle_recvfrom.bpf.c, handle_recvmsg.bpf.c
 */
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 4096);
    __type(key, u64);  // pid_tgid
    __type(value, struct udp_recvfrom_pending);
} udp_recvfrom_pending_map __weak SEC(".maps");

/* Socket type tracking map
 * Used by: handle_socket.bpf.c (create/close), handle_connect.bpf.c,
 *          handle_sendmsg.bpf.c, handle_sendmmsg.bpf.c, handle_sendto.bpf.c
 */
struct {
    __uint(type, BPF_MAP_TYPE_LRU_HASH);
    __uint(max_entries, 16384);
    __type(key, u64);  // (pid << 32) | fd
    __type(value, struct socket_info);
} socket_type_map __weak SEC(".maps");

/* File path literal filter map - O(1) lookup for exact path matches
 * Used by: file_path_filter.h (referenced by file open/write/unlink handlers)
 */
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, FILE_PATH_LITERAL_MAX_ENTRIES);
    __type(key, struct file_path_filter_key);
    __type(value, struct file_path_filter_value);
} file_path_literal_map __weak SEC(".maps");

/* File path prefix filter map - LPM trie for O(path_bits) prefix matching.
 * Non-sleepable programs (lsm/file_open, kprobe/vfs_write, lsm/path_unlink)
 * can access this map; sleepable programs cannot use LPM_TRIE.
 * Used by: file_path_filter.h (referenced by file open/write/unlink handlers)
 */
struct {
    __uint(type, BPF_MAP_TYPE_LPM_TRIE);
    __uint(max_entries, FILE_PATH_PREFIX_LPM_MAX_ENTRIES);
    __uint(map_flags, BPF_F_NO_PREALLOC);
    __type(key, struct file_path_lpm_key);
    __type(value, struct file_path_filter_value);
} file_path_prefix_lpm __weak SEC(".maps");

/* File handle filter cache - LRU cache for filter decisions per open file
 * Caches the should_emit decision and path string from file_open to avoid
 * re-running expensive path reconstruction and filter checks on every write.
 * KEY: (inode, device, pid) - uniquely identifies an open file handle
 * VALUE: should_emit flag and cached path string
 * Used by: file_events.h (ehprobe_file_open caches, ehprobe_file_write checks)
 */
struct {
    __uint(type, BPF_MAP_TYPE_LRU_HASH);
    __uint(max_entries, 8192);
    __type(key, struct file_handle_cache_key);
    __type(value, struct file_handle_cache_value);
} file_handle_filter_cache __weak SEC(".maps");

/* DPI flow tracker - LRU cache to limit payload bytes captured per flow
 * Tracks the total bytes captured per flow for DPI classification.
 * After DPI_MAX_BYTES_PER_FLOW bytes, further payload captures are skipped.
 * Used by: dpi_events.h (referenced by TCP/UDP data capture handlers)
 */
struct {
    __uint(type, BPF_MAP_TYPE_LRU_HASH);
    __uint(max_entries, DPI_FLOW_TRACKER_MAX_ENTRIES);
    __type(key, struct dpi_flow_key);
    __type(value, struct dpi_flow_value);
} dpi_flow_tracker __weak SEC(".maps");

/* DPI payload per-CPU buffer - avoids BPF 512-byte stack limit for payload capture
 * Used by: dpi_events.h (ehprobe_packet_data helper)
 */
struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 1);
    __type(key, uint32_t);
    __type(value, struct dpi_payload_buf);
} dpi_payload_map __weak SEC(".maps");

/* TCP sendmsg args map - stashes args across kprobe/kretprobe
 * Uses LRU_HASH so entries auto-evict if the kretprobe never fires
 * (e.g., process killed by signal between kprobe and kretprobe).
 * Used by: handle_tcp_sendmsg.bpf.c
 */
struct {
    __uint(type, BPF_MAP_TYPE_LRU_HASH);
    __uint(max_entries, 4096);
    __type(key, u64);  // pid_tgid
    __type(value, struct tcp_data_args);
} tcp_sendmsg_args_map __weak SEC(".maps");

/* TCP recvmsg args map - stashes args across kprobe/kretprobe
 * Uses LRU_HASH so entries auto-evict if the kretprobe never fires
 * (e.g., process killed by signal between kprobe and kretprobe).
 * Used by: handle_tcp_recvmsg.bpf.c
 */
struct {
    __uint(type, BPF_MAP_TYPE_LRU_HASH);
    __uint(max_entries, 4096);
    __type(key, u64);  // pid_tgid
    __type(value, struct tcp_data_args);
} tcp_recvmsg_args_map __weak SEC(".maps");

/* ============================================================================
 * Script Blocking Maps
 * ============================================================================ */

/* Tracked interpreter PIDs - LRU so stale entries self-heal if exit is missed
 * KEY: tgid (process group ID)
 * VALUE: interpreter_pid_entry (script path from first argv argument)
 * Used by: script_blocking.h (handle_exec, handle_fork, handle_exit, handle_file_open_new_exec)
 */
struct {
    __uint(type, BPF_MAP_TYPE_LRU_HASH);
    __uint(max_entries, 4096);
    __type(key, u32);
    __type(value, struct interpreter_pid_entry);
} interpreter_pids __weak SEC(".maps");

/* Known interpreter binary names - populated from userspace
 * KEY: interpreter_binary_key (comm name, e.g., "python3")
 * VALUE: 1 (presence indicates the comm is a known interpreter)
 * Used by: script_blocking.h (handle_exec, handle_bprm_check)
 */
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 32);
    __type(key, struct interpreter_binary_key);
    __type(value, uint8_t);
} interpreter_binaries __weak SEC(".maps");

/* Inner map template for script allowlist: inode/dev -> SHA256 hash mapping
 * Used by: script_blocking.h (handle_file_open_new_exec)
 */
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 32768);
    __type(key, struct allowlist_key);
    __type(value, struct allowlist_entry);
} script_allowlist_inner_map __weak SEC(".maps");

/* Outer map for container_id -> script allowlist inner map mapping
 * Used by: script_blocking.h (handle_file_open_new_exec)
 */
struct {
    __uint(type, BPF_MAP_TYPE_HASH_OF_MAPS);
    __uint(max_entries, 1024);
    __type(key, u64);
    __type(value, uint32_t);  // inner map fd
    __array(values, script_allowlist_inner_map);
} script_allowlist_outer_map __weak SEC(".maps");

