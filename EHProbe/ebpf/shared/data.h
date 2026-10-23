// SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause
// data.h
#pragma once

#ifndef MAX_PATH
#define MAX_PATH 4096
#endif

// SHA256 hash size
#define SHA256_DIGEST_SIZE 32

#define CONTAINER_CMD_MAX_LEN 256
#define CONTAINER_RUNTIME_MAX_LEN 64

#define TASK_COMM_LEN 16

// Exec blocking mode values for ehprobe_env.blocking_mode
#define EHPROBE_BLOCKING_MODE_OFF      0    // No exec blocking
#define EHPROBE_BLOCKING_MODE_AUDIT    1    // Run allowlist checks and emit events, but allow all executions
#define EHPROBE_BLOCKING_MODE_ENFORCE  2    // Run allowlist checks, emit events, and block unauthorized executions

struct ehprobe_env {
    uint64_t flag_exec;
    uint64_t flag_fs;
    uint64_t flag_network;
    uint64_t flag_block_kill;
    uint64_t blocking_mode;                        // 0=off, 1=audit, 2=enforce (replaces flag_block_exec + blocking_enabled)
    uint64_t flag_file_path_filter;                // 1 if file path filtering is enabled
    uint64_t block_kill_pid_target;            // Target PID to protect from kill signals (except from block_kill_pid_except_source)
    uint64_t block_kill_pid_except_source;     // The only PID that is allowed to kill the target protected PID
    uint64_t host_pid_ns;                      // PID namespace inode for the host (always the root/init namespace)
    uint64_t monitor_pid_ns;                   // PID namespace inode of the monitoring process (equals host_pid_ns if on host, differs if in container)
    uint64_t running_in_container;             // 1 if ehprobe is running inside a container, 0 if on host
    uint64_t flag_dpi;                         // 1 if deep packet inspection is enabled (captures payload for nDPI)
    uint64_t flag_block_script;                // 1 if script blocking is enabled
    uint64_t script_blocking_mode;             // 0=off, 1=audit, 2=enforce
    uint64_t flag_af_alg;                     // 1 if AF_ALG socket bind observer (lsm/socket_bind) is attached
    uint64_t af_alg_block_mode;               // 0=off, 1=audit, 2=enforce — controls whether AF_ALG binds to known-vulnerable crypto templates (e.g. authencesn / CVE-2026-31431) are denied
    uint64_t flag_module_load;                // 1 if kernel module load observer (lsm/kernel_module_request + lsm/kernel_read_file) is attached
    uint64_t module_load_block_mode;          // 0=off, 1=audit, 2=enforce — Dirty Frag RxRPC mitigation (blocks rxrpc.ko load)
    uint64_t flag_xfrm_sa_new;                // 1 if XFRM SA registration observer (kprobe xfrm_add_sa) is attached
    uint64_t xfrm_sa_new_block_mode;          // 0=off, 1=audit, 2=enforce — Dirty Frag ESP mitigation (kills non-init-userns XFRM_STATE_ESN SAs)
};

// Maximum bytes to scan from argv for inline code flag detection (e.g., "-c")
// and script path extraction. Must be a power of 2 for BPF verifier bitmask clamping.
#define INLINE_CODE_SCAN_SIZE 512

// Per-CPU buffer for scanning argv data for inline code flags
struct inline_code_scan_buf {
    char data[INLINE_CODE_SCAN_SIZE];
};

// Allowlist inner map key
struct allowlist_key {
    uint64_t ino;
    uint32_t dev;
    uint32_t pad;   // eBPF map key size has to be 64-bit aligned
};

// Allowlist map entry
struct allowlist_entry {
    unsigned char hash[SHA256_DIGEST_SIZE];
};

// Single path entry
struct path_entry {
    char path[MAX_PATH];
};

// Container map entry
struct container_entry {
    uint64_t id;
    uint64_t level;
    char runtime_type[CONTAINER_RUNTIME_MAX_LEN];
	char entrypoint_cmd[CONTAINER_CMD_MAX_LEN]; // The command executed by the entrypoint.
	uint64_t pid;                               // The PID of the container's first process.
	uint64_t ppid;                              // The PID of the process that created the container.
    uint64_t mnt_ns_inum;
    uint64_t pid_ns_inum;
    uint64_t cgroup_id;
	uint64_t start_time_ns;                     // The nanosecond timestamp of the start event.
    uint64_t blocking_mode;                     // 0=off, 1=audit, 2=enforce
};

// Key for the 'container_runtimes_map'.
// Used to check if a process name is a known container runtime.
struct container_runtime_binary {
	char comm[TASK_COMM_LEN];
};

// Key for the 'interpreter_binaries' map.
// Used to check if a process name is a known interpreter (e.g., python3).
struct interpreter_binary_key {
    char comm[TASK_COMM_LEN];
};

// Maximum length for the first-argument script path stored per tracked interpreter.
// Paths exceeding this limit are killed in enforce mode (truncated paths bypass
// the SCRIPT_FILE_CHECK comparison). Must be a power of 2 for bitmask clamping.
#define INTERPRETER_SCRIPT_PATH_LEN 256

// Value for the 'interpreter_pids' map.
// Tracks interpreter processes and the first-argument script path from argv.
// The script_path is sent to userspace via SCRIPT_FILE_CHECK events for
// path resolution and blocking decisions on extensionless scripts.
struct interpreter_pid_entry {
    char script_path[INTERPRETER_SCRIPT_PATH_LEN]; // First non-option argv arg (null-terminated, empty if none)
};

// UDP session cache key
struct udp_session_key {
    uint32_t pid;
    uint16_t family;
    uint16_t port;
    union {
        uint32_t addr4;
        uint8_t addr6[16];
    };
} __attribute__((packed));

// UDP session cache value
struct udp_session_value {
    uint64_t first_seen_ns;
    uint64_t initiator;
};

// Pending recvfrom state (to get sockaddr on sys_exit)
struct udp_recvfrom_pending {
    uint64_t sockaddr_ptr;
    int fd;
    uint16_t family;
    uint16_t local_port;
};

// Socket type tracking
#define SOCK_STREAM 1
#define SOCK_DGRAM  2
#define SOCK_RAW    3

// ICMP protocol constants
#define IPPROTO_ICMP   1
#define IPPROTO_ICMPV6 58

struct socket_info {
    uint16_t type;                           // SOCK_STREAM, SOCK_DGRAM, or SOCK_RAW
    uint16_t family;                         // AF_INET or AF_INET6
    uint16_t protocol;                       // 0=unspecified, IPPROTO_ICMP=1, IPPROTO_ICMPV6=58
    uint16_t pad;
    uint32_t is_dns_connected;                // 1 if connected to port 53
    uint8_t dns_server[28];                  // sizeof(struct sockaddr_in6) - raw storage
};

enum new_fs_exec_operation {
    NEW_FS_EXEC_OPERATION_CREATE = 1,
    NEW_FS_EXEC_OPERATION_CHMOD = 2,
};

enum udp_initiator_operation {
    UDP_INITIATOR_OUTBOUND = 1,  // sendto/sendmsg
    UDP_INITIATOR_INBOUND = 2,  // recvfrom/recvmsg
};

// ============================================================================
// File Path Filtering
// ============================================================================

// ============================================================================
// DPI Flow Tracking
// ============================================================================

// Maximum bytes to capture per flow for DPI classification.
// Replaces the old per-packet counter: SSH reads byte-by-byte (20+ reads
// for a 20-byte banner), exhausting a 10-packet budget.  An 8KB byte budget
// accommodates both SSH (~2.5KB) and TLS (~4.5KB) handshakes comfortably.
#define DPI_MAX_BYTES_PER_FLOW 8192

// Maximum payload bytes to capture per packet for DPI.
// 2048 bytes covers TLS ClientHello with post-quantum key shares (ML-KEM,
// which adds ~1KB to the ClientHello) and full ServerHello + Certificate
// messages. Must be a power of 2 for BPF verifier mask.
#define DPI_PAYLOAD_CAPTURE_MAX 2048

// Alias for backward compatibility
#define DPI_MAX_PAYLOAD_LEN DPI_PAYLOAD_CAPTURE_MAX

// Maximum number of tracked DPI flows
#define DPI_FLOW_TRACKER_MAX_ENTRIES 4096

// Key for dpi_flow_tracker map — identifies a unique network flow
struct dpi_flow_key {
    uint32_t pid;
    uint8_t protocol;       // 6=TCP, 17=UDP
    uint8_t family;         // AF_INET=2, AF_INET6=10
    uint16_t remote_port;
    uint16_t local_port;
    uint16_t pad;
    union {
        uint32_t remote_addr4;
        uint8_t remote_addr6[16];
    };
} __attribute__((packed));

// Value for dpi_flow_tracker map
struct dpi_flow_value {
    uint32_t bytes_captured;
};

// Per-CPU buffer for DPI payload capture (avoids BPF stack overflow)
// DPI_PAYLOAD_CAPTURE_MAX is defined above (DPI Flow Tracking section)

// Compile-time check: must be power of 2 for BPF verifier bitmask
_Static_assert((DPI_PAYLOAD_CAPTURE_MAX & (DPI_PAYLOAD_CAPTURE_MAX - 1)) == 0,
               "DPI_PAYLOAD_CAPTURE_MAX must be a power of 2");

struct dpi_payload_buf {
    unsigned char data[DPI_PAYLOAD_CAPTURE_MAX];
};

// Args stashed across kprobe/kretprobe for TCP data capture
struct tcp_data_args {
    void *sock;        // struct sock * from kprobe entry
    void *msg;         // struct msghdr * (for iov payload access)
    uint32_t size;     // Requested size from syscall arg
};

// ============================================================================

// Maximum path length for filtering (shorter than MAX_PATH for BPF map efficiency)
#define FILE_PATH_FILTER_MAX_LEN 256

// Maximum number of literal paths in hash map
#define FILE_PATH_LITERAL_MAX_ENTRIES 1024

// Maximum number of prefix paths in LPM trie
#define FILE_PATH_PREFIX_LPM_MAX_ENTRIES 256

// Key for file_path_literal_map (fixed-size for hash map)
struct file_path_filter_key {
    char path[FILE_PATH_FILTER_MAX_LEN];
};

// Value for file_path_literal_map and file_path_prefix_lpm (indicates path is active)
struct file_path_filter_value {
    uint8_t active;
};

// Key for the LPM trie prefix map.
// prefixlen is in bits; data holds the path bytes.
struct file_path_lpm_key {
    __u32 prefixlen;
    __u8  data[FILE_PATH_FILTER_MAX_LEN];
};

// ============================================================================
// File Handle Filter Cache
// ============================================================================

// Key for file_handle_filter_cache - uniquely identifies an open file
struct file_handle_cache_key {
    uint64_t ino;     // Inode number
    uint32_t dev;     // Device number
    uint32_t pid;     // Process ID (to handle same inode opened by different processes)
};

// Value for file_handle_filter_cache - cached filter decision
// We only cache the should_emit decision, not the path, to avoid BPF verifier
// complexity with variable-length string handling. Path reconstruction still
// happens on writes, but the expensive filter check is skipped.
struct file_handle_cache_value {
    uint8_t should_emit;    // 1 = emit events, 0 = filter out
    uint8_t path_valid;     // Reserved for future use (always 0)
    uint16_t path_len;      // Reserved for future use (always 0)
    // Note: path field removed to simplify BPF verifier constraints
};
