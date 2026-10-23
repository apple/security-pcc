// ehprobe_internal.h - Internal definitions for ehprobe library
#pragma once

#include <stdint.h>
#include <stdbool.h>
#include <pthread.h>
#include <bpf/libbpf.h>
#include "ehprobe.h"
#include "ehprobe.skel.h"

// Maximum number of containers to discover during startup
#define MAX_DISCOVERED_CONTAINERS 256

// Maximum namespace nesting levels supported
#define MAX_NS_LEVELS 16

// Buffer size for getdents64
#define GETDENTS_BUFSIZE 4096

// Linux directory entry structure for getdents64
struct linux_dirent64 {
    uint64_t        d_ino;
    int64_t         d_off;
    unsigned short  d_reclen;
    unsigned char   d_type;
    char            d_name[];
};

// Global state for the single instance
struct ehprobe_state {
    struct ehprobe_bpf *skel;
    struct ring_buffer *rb;
    ehprobe_config_t config;
    uint32_t supported_features;  // Kernel capability mask from probe_supported_features()
    bool initialized;
    bool running;
    int events_processed;  // Counter for events in current poll
    int handler_return;    // Return value from event handler

    // Thread safety
    pthread_mutex_t state_mutex;
    bool mutex_initialized;

    // Program links - stored here for dynamic attach/detach
    struct {
        // Exec/Exit/Fork
        struct bpf_link *handle_exec;
        struct bpf_link *handle_exit;
        struct bpf_link *handle_fork;

        // Filesystem
        struct bpf_link *handle_file_open;
        struct bpf_link *handle_file_open_new_exec;
        struct bpf_link *handle_path_chmod;
        struct bpf_link *handle_kprobe_vfs_write;
        struct bpf_link *handle_kretprobe_vfs_write;
        struct bpf_link *handle_path_unlink;

        // Device
        struct bpf_link *handle_kprobe_chrdev_open;
        struct bpf_link *handle_kretprobe_chrdev_open;

        // Network
        struct bpf_link *handle_kprobe_socket;
        struct bpf_link *handle_kretprobe_socket;
        struct bpf_link *handle_kprobe_close;
        struct bpf_link *handle_kprobe_connect;
        struct bpf_link *handle_kretprobe_connect;
        struct bpf_link *handle_kprobe_accept4;
        struct bpf_link *handle_kretprobe_accept4;
        struct bpf_link *handle_kprobe_sendto;
        struct bpf_link *handle_kprobe_sendmsg;
        struct bpf_link *handle_kprobe_sendmmsg;
        struct bpf_link *handle_kprobe_recvfrom;
        struct bpf_link *handle_kretprobe_recvfrom;
        struct bpf_link *handle_kprobe_recvmsg;
        struct bpf_link *handle_kretprobe_recvmsg;
        struct bpf_link *handle_socket_bind;

        // Blocking
        struct bpf_link *handle_bprm_check;
        struct bpf_link *handle_task_kill;

        // Process identity
        struct bpf_link *handle_setuid;
        struct bpf_link *handle_setgid;

        // DPI (deep packet inspection) - TCP payload capture
        struct bpf_link *handle_kprobe_tcp_sendmsg;
        struct bpf_link *handle_kprobe_tcp_recvmsg;
        struct bpf_link *handle_kretprobe_tcp_recvmsg;

        // Script blocking - file_post_open for interpreter file checks
        struct bpf_link *handle_file_post_open;

        // Script blocking - argv scanning for script path extraction
        struct bpf_link *handle_script_path_exec;

        // Dirty Frag - kernel module load observer (autoload + finit_module)
        struct bpf_link *handle_kernel_module_request;
        struct bpf_link *handle_kernel_read_file;

        // Dirty Frag - XFRM SA registration observer (kprobe xfrm_add_sa)
        struct bpf_link *handle_xfrm_add_sa;
    } links;
};

// Global state - defined in ehprobe_lib.c
extern struct ehprobe_state g_ehprobe;

// ============================================================================
// Logging (ehprobe_log.c)
// ============================================================================

// Log a message through the configured log handler
void report_log(ehprobe_log_level_t level, const char *format, ...);

// Custom libbpf print function
int libbpf_print_fn(enum libbpf_print_level level, const char *format, va_list args);

// ============================================================================
// BPF Program Management (ehprobe_bpf.c)
// ============================================================================

// Probe kernel BTF for supported features — returns bitmask of EHPROBE_FEATURE_*
uint32_t probe_supported_features(void);

// Build the program table from the skeleton — must be called after __open().
void build_prog_table(struct ehprobe_bpf *skel);

// Disable autoload for BPF programs not needed by requested features.
// Must be called between ehprobe_bpf__open() and ehprobe_bpf__load().
int configure_autoload(struct ehprobe_bpf *skel, uint32_t features);

// Configure BPF programs based on features - attaches/detaches as needed
int configure_bpf_programs(uint32_t features);

// Detach all programs - used during cleanup
void detach_all_programs(void);

// Update env map flags based on features bitmask
int update_env_flags(uint32_t features);

// Initialize per-CPU buffers
int init_percpu_buffers(void);

// ============================================================================
// Container Discovery (ehprobe_container.c)
// ============================================================================

// Get the host's PID namespace inode number
int get_host_pid_namespace(uint64_t *host_pid_ns_inum);

// Discover all running containers by scanning /proc
int discover_existing_containers(uint64_t host_pid_ns_inum);

// ============================================================================
// Event Handling (ehprobe_event.c)
// ============================================================================

// Ring buffer callback - calls user's event handler directly
int ringbuf_event_callback(void *ctx, void *data, size_t data_sz);
