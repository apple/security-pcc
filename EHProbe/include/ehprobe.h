// ehprobe.h - API for ehprobe static library
#pragma once

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define CONTAINER_CMD_MAX_LEN 256
#define CONTAINER_RUNTIME_MAX_LEN 64

// Event types (matching your eBPF code)
typedef enum {
    EHPROBE_EVENT_EXEC = 1,
    EHPROBE_EVENT_EXIT = 2,
    EHPROBE_EVENT_BPRM_CHECK = 3,
    EHPROBE_EVENT_TASK_KILL = 4,
    EHPROBE_EVENT_FILE_OPEN = 5,
    EHPROBE_EVENT_PATH_CHMOD = 6,
    EHPROBE_EVENT_EXEC_SECURITY = 7,
    EHPROBE_EVENT_BLOCK_KILL = 8,
    EHPROBE_EVENT_NEW_FS_EXEC = 9,
    EHPROBE_EVENT_CONTAINER_START = 10,
    EHPROBE_EVENT_CONTAINER_STOP = 11,
    EHPROBE_EVENT_NET_TCP = 12,
    EHPROBE_EVENT_NET_UDP = 13,
    EHPROBE_EVENT_DNS = 14,
    EHPROBE_EVENT_DEVICE_OPEN = 15,
    EHPROBE_EVENT_FORK = 16,
    EHPROBE_EVENT_FILE_WRITE = 17,
    EHPROBE_EVENT_FILE_UNLINK = 18,
    EHPROBE_EVENT_SETUID = 19,
    EHPROBE_EVENT_SETGID = 20,
    EHPROBE_EVENT_NET_ICMP = 21,
    EHPROBE_EVENT_PACKET_DATA = 22,
    EHPROBE_EVENT_SCRIPT_SECURITY = 23,
    EHPROBE_EVENT_AF_ALG_BIND = 24,
    EHPROBE_EVENT_SCRIPT_FILE_CHECK = 25,
    EHPROBE_EVENT_MODULE_LOAD_REQUEST = 26,
    EHPROBE_EVENT_XFRM_SA_NEW = 27,
} ehprobe_event_type_t;

// Parameter types
typedef enum {
    EHPROBE_PARAM_NONE = 0,
    EHPROBE_PARAM_U32 = 1,
    EHPROBE_PARAM_U64 = 2,
    EHPROBE_PARAM_S32 = 3,
    EHPROBE_PARAM_S64 = 4,
    EHPROBE_PARAM_STRING = 5,
    EHPROBE_PARAM_BYTEBUF = 6,
} ehprobe_param_type_t;

// Parameter value union
typedef union {
    uint32_t u32;
    uint64_t u64;
    int32_t s32;
    int64_t s64;
    const char *str;
    const unsigned char *bytebuf;
} ehprobe_param_value_t;

// Parameter structure
typedef struct {
    ehprobe_param_type_t type;
    uint16_t length;
    ehprobe_param_value_t value;
} ehprobe_param_t;

// Event structure (for passing to handler)
typedef struct {
    uint64_t timestamp_ns;
    uint32_t pid;
    ehprobe_event_type_t event_type;
    uint16_t param_count;
    uint16_t total_size;
    const uint8_t *raw_data;  // Pointer to raw event data (valid only during callback)
} ehprobe_event_t;

// Log severity levels
typedef enum {
    EHPROBE_LOG_DEBUG = 0,
    EHPROBE_LOG_INFO = 1,
    EHPROBE_LOG_WARNING = 2,
    EHPROBE_LOG_ERROR = 3,
} ehprobe_log_level_t;

// Feature flags for configuration
typedef enum {
    EHPROBE_FEATURE_EXEC = (1 << 0),        // Enable exec/exit/fork events
    EHPROBE_FEATURE_FS = (1 << 1),          // Enable filesystem events (open, chmod)
    EHPROBE_FEATURE_NETWORK = (1 << 2),     // Enable network events
    EHPROBE_FEATURE_BLOCK_KILL = (1 << 3),  // Block kill attempts to this process
    EHPROBE_FEATURE_BLOCK_EXEC = (1 << 4),  // Enable exec blocking (requires blocking mode to be set)
    EHPROBE_FEATURE_DPI = (1 << 5),         // Enable deep packet inspection (captures payload for nDPI classification)
    EHPROBE_FEATURE_BLOCK_SCRIPT = (1 << 6), // Enable script blocking (interpreter-aware file_open blocking)
    EHPROBE_FEATURE_AF_ALG = (1 << 7),      // Enable AF_ALG socket bind observer (lsm/socket_bind); required for AF_ALG blocking (CVE-2026-31431)
    EHPROBE_FEATURE_MODULE_LOAD = (1 << 8), // Enable kernel module load observer (lsm/kernel_module_request + lsm/kernel_read_file); required to block rxrpc.ko (Dirty Frag)
    EHPROBE_FEATURE_XFRM_SA_NEW = (1 << 9), // Enable XFRM SA registration observer (kprobe xfrm_add_sa); required to block ESN-enabled SAs from non-init userns (Dirty Frag ESP)
} ehprobe_feature_flags_t;

// Exec blocking mode values
#define EHPROBE_BLOCKING_MODE_OFF      0    // No exec blocking
#define EHPROBE_BLOCKING_MODE_AUDIT    1    // Run allowlist checks and emit events, but allow all executions
#define EHPROBE_BLOCKING_MODE_ENFORCE  2    // Run allowlist checks, emit events, and block unauthorized executions

// Error codes (returned as negative values)
typedef enum {
    EHPROBE_SUCCESS = 0,
    EHPROBE_ERROR_NOMEM = -1001,
    EHPROBE_ERROR_INIT = -1002,
    EHPROBE_ERROR_BPF_LOAD = -1003,
    EHPROBE_ERROR_BPF_ATTACH = -1004,
    EHPROBE_ERROR_RINGBUF = -1005,
    EHPROBE_ERROR_INVALID_PARAM = -1006,
    EHPROBE_ERROR_NOT_INITIALIZED = -1007,
    EHPROBE_ERROR_ALREADY_RUNNING = -1008,
    EHPROBE_ERROR_NOT_RUNNING = -1009,
    EHPROBE_ERROR_EVENT_TOO_LARGE = -1010,
    EHPROBE_ERROR_INVALID_EVENT = -1011,
} ehprobe_error_t;

// Event handler callback type
// Called for each event received. The event pointer is only valid during the callback.
// Return 0 to continue processing, non-zero to stop polling
typedef int (*ehprobe_event_handler_t)(const ehprobe_event_t *event, void *user_context);

// Log handler callback type
// Called for logging messages at various severity levels
typedef void (*ehprobe_log_handler_t)(ehprobe_log_level_t level, const char *message);

// Configuration options
typedef struct {
    uint32_t features;                    // Bitmask of ehprobe_feature_flags_t
    uint32_t ring_buffer_size_kb;         // Ring buffer size in KB (default: 256)
    uint32_t poll_timeout_ms;             // Polling timeout in milliseconds (default: 100)
    bool enable_debug_output;             // Enable debug level logging
    ehprobe_event_handler_t event_handler; // Event handler callback (required)
    ehprobe_log_handler_t log_handler;     // Log handler callback (optional)
    void *user_context;                   // Custom user context pointer
} ehprobe_config_t;

/**
 * @brief External container structure for ehprobe APIs
 * This structure provides a clean interface for container data
 * and maps to the internal container_entry struct used by eBPF
 */
struct ehprobe_container {
    uint64_t id;                                // Container ID
    uint64_t level;                             // Container nesting level
    uint64_t pid;                               // The PID of the container's first process
    uint64_t parent_id;                         // The PID of the process that created the container (ppid)
    uint64_t mnt_ns_inum;                       // PID namespace identifier
    uint64_t pid_ns_inum;                       // Mount namespace identifier
    uint64_t cgroup_id;                         // Cgroup path/identifier
    char runtime_type[CONTAINER_RUNTIME_MAX_LEN];
    char entrypoint_cmd[CONTAINER_CMD_MAX_LEN]; // The command executed by the entrypoint
    uint64_t start_time_ns;                     // The nanosecond timestamp of the start event
    uint64_t blocking_mode;                     // 0=off, 1=audit, 2=enforce
};

// --- Core API Functions ---

/**
 * Initialize ehprobe with configuration
 * @param config Configuration options (must include event_handler)
 * @return 0 on success, negative error code on failure
 */
int ehprobe_init(const ehprobe_config_t *config);

/**
 * Clean up and destroy ehprobe instance
 */
void ehprobe_destroy(void);

/**
 * Start monitoring events
 * @return 0 on success, negative error code on failure
 */
int ehprobe_start(void);

/**
 * Stop monitoring events
 * @return 0 on success, negative error code on failure
 */
int ehprobe_stop(void);

/**
 * Check if monitoring is active
 * @return true if monitoring is active, false otherwise
 */
bool ehprobe_is_running(void);

/**
 * Set features on a running ehprobe
 * @return 0 on success, negative error code on failure
 */
int ehprobe_set_features(uint32_t features);

/**
 * Poll for events (blocking with timeout)
 * Calls the event handler for each event received
 * @param timeout_ms Timeout in milliseconds (-1 for infinite, 0 for non-blocking)
 * @return Number of events processed, 0 if timeout, negative error code on failure
 */
int ehprobe_poll(int timeout_ms);

// --- Event Processing Helpers ---

/**
 * Get parameter from event by index
 * @param event Event structure
 * @param index Parameter index (0-based)
 * @param param Output parameter structure
 * @return 0 on success, negative error code on failure
 */
int ehprobe_get_param(const ehprobe_event_t *event,
                      uint16_t index,
                      ehprobe_param_t *param);

/**
 * Get parameter type name as string
 * @param param_type Parameter type
 * @return String representation of parameter type
 */
const char *ehprobe_param_type_str(ehprobe_param_type_t param_type);

/**
 * Adds a binary to the execution allowlist BPF map.
 * This function expects the raw 32-byte SHA256 hash to be pre-calculated by the caller.
 * The format must be a raw byte array to match the output of the kernel's bpf_ima_file_hash helper.
 *
 * @param container_id Container ID (0 for host)
 * @param ino inode
 * @param dev device
 * @param binary_hash A pointer to the 32-byte raw SHA256 hash of the executable.
 *
 * @return 0 on success, or a negative error code on failure.
 */
int ehprobe_add_file_to_exec_allowlist(uint64_t container_id, uint64_t ino, uint32_t dev, const unsigned char* binary_hash);

/**
 * Removes a binary from the execution allowlist BPF map.
 *
 * @param container_id Container ID
 * @param ino inode
 * @param dev device
 * @return 0 on success, or a negative error code on failure.
 */
int ehprobe_remove_file_from_exec_allowlist(uint64_t container_id, uint64_t ino, uint32_t dev);

/**
 * Removes container entries from the execution allowlist BPF map.
 *
 * @param container_id Container ID
 * @return 0 on success, or a negative error code on failure.
 */
int ehprobe_remove_container_from_exec_allowlist(uint64_t container_id);

/**
 * Set exec blocking mode for the host
 *
 * @param mode Blocking mode: EHPROBE_BLOCKING_MODE_OFF, EHPROBE_BLOCKING_MODE_AUDIT, or EHPROBE_BLOCKING_MODE_ENFORCE
 * @return 0 on success, or a negative error code on failure.
 */
int ehprobe_set_blocking_mode(uint64_t mode);

/**
 * Set exec blocking mode for a specified container
 *
 * @param container_id Container ID
 * @param mode Blocking mode: EHPROBE_BLOCKING_MODE_OFF, EHPROBE_BLOCKING_MODE_AUDIT, or EHPROBE_BLOCKING_MODE_ENFORCE
 * @return 0 on success, or a negative error code on failure.
 */
int ehprobe_set_container_blocking_mode(uint64_t container_id, uint64_t mode);

/**
 * @brief Store a container entry in the eBPF containers map
 * 
 * @param container_id Container ID (used as key)
 * @param entry Pointer to container_entry struct with container data
 * @return 0 on success, or a negative error code on failure
 */
int ehprobe_container_store(uint64_t container_id, struct ehprobe_container* entry);

/**
 * @brief Query a container from the eBPF containers map
 * 
 * @param container_id Container ID (key)
 * @param entry Pointer to container_entry struct to store the result
 * @return 0 on success, -ENOENT if not found, or other negative error code on failure
 */
int ehprobe_container_query(uint64_t container_id, struct ehprobe_container* entry);

/**
 * @brief Remove a container from the eBPF containers map
 * 
 * @param container_id Container ID (key)
 * @return 0 on success, -ENOENT if not found, or other negative error code on failure
 */
int ehprobe_container_remove(uint64_t container_id);

/**
 * @brief Check if a container exists in the eBPF containers map
 * 
 * @param container_id Container ID (key)
 * @return true if container exists, false otherwise
 */
bool ehprobe_container_exists(uint64_t container_id);

/**
 * @brief Get all container IDs from the eBPF containers map
 * 
 * @param container_ids Array to store container IDs (must be pre-allocated)
 * @param max_containers Maximum number of containers to retrieve
 * @param count Pointer to store the actual number of containers found
 * @return 0 on success, or a negative error code on failure
 */
int ehprobe_container_get_all_ids(uint64_t* container_ids, int max_containers, int* count);

// ============================================================================
// File Path Filtering API
// ============================================================================

/**
 * Enable or disable file path filtering
 * When enabled, only file events matching configured paths will be emitted
 * @param enable true to enable filtering, false to disable (emit all events)
 * @return 0 on success, or a negative error code on failure
 */
int ehprobe_file_path_filter_enable(bool enable);

/**
 * Add a literal (exact match) path to the filter
 * File events for this exact path will be emitted when filtering is enabled
 * @param path The exact file path to match (max 255 chars)
 * @return 0 on success, or a negative error code on failure
 */
int ehprobe_file_path_add_literal(const char *path);

/**
 * Add a prefix path to the filter
 * File events for paths starting with this prefix will be emitted when filtering is enabled
 * Uses an LPM trie for O(path_bits) lookup; supports up to 256 prefix entries.
 * @param prefix The path prefix to match (max 255 chars, e.g., "/root/.ssh/")
 * @return 0 on success, -ENOSPC if the trie is full, or other negative error code on failure
 */
int ehprobe_file_path_add_prefix(const char *prefix);

/**
 * Remove a literal path from the filter
 * @param path The exact file path to remove
 * @return 0 on success, -ENOENT if not found, or other negative error code on failure
 */
int ehprobe_file_path_remove_literal(const char *path);

/**
 * Remove a prefix path from the filter
 * @param prefix The path prefix to remove
 * @return 0 on success, -ENOENT if not found, or other negative error code on failure
 */
int ehprobe_file_path_remove_prefix(const char *prefix);

/**
 * Clear all path filters (both literal and prefix)
 * Does not disable filtering - call ehprobe_file_path_filter_enable(false) for that
 * @return 0 on success, or a negative error code on failure
 */
int ehprobe_file_path_clear_all(void);

// ============================================================================
// Script Blocking API
// ============================================================================

/**
 * Adds a script file to the script allowlist BPF map.
 * Uses the same allowlist_key/allowlist_entry structures as exec allowlist.
 *
 * @param container_id Container ID (0 for host)
 * @param ino inode
 * @param dev device
 * @param script_hash A pointer to the 32-byte raw SHA256 hash of the script file.
 * @return 0 on success, or a negative error code on failure.
 */
int ehprobe_add_file_to_script_allowlist(uint64_t container_id, uint64_t ino, uint32_t dev, const unsigned char* script_hash);

/**
 * Removes a script file from the script allowlist BPF map.
 *
 * @param container_id Container ID
 * @param ino inode
 * @param dev device
 * @return 0 on success, or a negative error code on failure.
 */
int ehprobe_remove_file_from_script_allowlist(uint64_t container_id, uint64_t ino, uint32_t dev);

/**
 * Removes container entries from the script allowlist BPF map.
 *
 * @param container_id Container ID
 * @return 0 on success, or a negative error code on failure.
 */
int ehprobe_remove_container_from_script_allowlist(uint64_t container_id);

/**
 * Set script blocking mode in the eBPF env map
 *
 * @param mode Blocking mode: EHPROBE_BLOCKING_MODE_OFF, EHPROBE_BLOCKING_MODE_AUDIT, or EHPROBE_BLOCKING_MODE_ENFORCE
 * @return 0 on success, or a negative error code on failure.
 */
int ehprobe_set_script_blocking_mode(uint64_t mode);

/**
 * Set AF_ALG bind blocking mode in the eBPF env map.
 *
 * In enforce mode, AF_ALG bind(2) calls targeting crypto templates
 * known to be vulnerable (currently: any template beginning with
 * `authencesn` — CVE-2026-31431) are denied with -EAFNOSUPPORT.
 * Telemetry events fire in all three modes so detection is preserved
 * regardless of enforcement.
 *
 * @param mode Blocking mode: EHPROBE_BLOCKING_MODE_OFF, EHPROBE_BLOCKING_MODE_AUDIT, or EHPROBE_BLOCKING_MODE_ENFORCE
 * @return 0 on success, or a negative error code on failure.
 */
int ehprobe_set_af_alg_block_mode(uint64_t mode);

/**
 * Set kernel module load blocking mode in the eBPF env map.
 *
 * In enforce mode, attempts to load modules on the Dirty Frag blocklist
 * (currently: `rxrpc`) are denied with -EPERM. Covers both the kernel
 * autoload path (`request_module()`, e.g. triggered by `socket(AF_RXRPC)`)
 * and explicit `finit_module(fd)` calls. Known gap: `init_module(buf)`
 * (raw-buffer form, no backing file) is not covered — modern RHEL 9
 * userland uses `finit_module`.
 *
 * Telemetry events fire in all three modes.
 *
 * @param mode Blocking mode: EHPROBE_BLOCKING_MODE_OFF, EHPROBE_BLOCKING_MODE_AUDIT, or EHPROBE_BLOCKING_MODE_ENFORCE
 * @return 0 on success, or a negative error code on failure.
 */
int ehprobe_set_module_load_block_mode(uint64_t mode);

/**
 * Set XFRM SA registration blocking mode in the eBPF env map.
 *
 * In enforce mode, `XFRM_MSG_NEWSA` messages that (a) originate from a
 * process whose net_ns is owned by a non-init user namespace AND (b) set
 * the `XFRM_STATE_ESN` flag are blocked by killing the calling task
 * (SIGKILL). This catches both the `XFRMA_ALG_AEAD = "authencesn(...)"`
 * path (published Dirty Frag exploit) and the split-attribute
 * `XFRMA_ALG_AUTH + XFRMA_ALG_CRYPT + XFRM_STATE_ESN` path that the
 * kernel internally resolves to the same vulnerable `authencesn` sink.
 *
 * Legitimate IPsec stacks (libreswan, strongSwan, OVN) run in the init
 * userns and are unaffected regardless of mode.
 *
 * @param mode Blocking mode: EHPROBE_BLOCKING_MODE_OFF, EHPROBE_BLOCKING_MODE_AUDIT, or EHPROBE_BLOCKING_MODE_ENFORCE
 * @return 0 on success, or a negative error code on failure.
 */
int ehprobe_set_xfrm_sa_new_block_mode(uint64_t mode);

/**
 * Add an interpreter binary name to the tracking map.
 * When a process with this comm name execs, its PID is tracked for script blocking.
 *
 * @param comm The process comm name (e.g., "python3", max 15 chars + null)
 * @return 0 on success, or a negative error code on failure.
 */
int ehprobe_add_interpreter_binary(const char* comm);

//
// Helper wrapper functions
//

/**
 * unshare wrapper
 * @return 0 on success, or a negative error code on failure.
 */
int ehprobe_unshare_wrapper(int flags);

/**
 * setns wrapper
 * @return 0 on success, or a negative error code on failure.
 */
int ehprobe_setns_wrapper(int fd, int nstype);

#ifdef __cplusplus
}
#endif
