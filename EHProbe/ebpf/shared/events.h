// SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause
// events.h
#pragma once

// Event types enum
enum event_type {
    EVENT_TYPE_EXEC = 1,
    EVENT_TYPE_EXIT = 2,
    EVENT_TYPE_BPRM_CHECK = 3,
    EVENT_TYPE_TASK_KILL = 4,
    EVENT_TYPE_FILE_OPEN = 5,
    EVENT_TYPE_PATH_CHMOD = 6,
    EVENT_TYPE_EXEC_SECURITY = 7,
    EVENT_TYPE_BLOCK_KILL = 8,
    EVENT_TYPE_NEW_FS_EXEC = 9,
    EVENT_TYPE_CONTAINER_START = 10,
    EVENT_TYPE_CONTAINER_STOP = 11,
    EVENT_TYPE_NET_TCP = 12,
    EVENT_TYPE_NET_UDP = 13,
    EVENT_TYPE_DNS = 14,
    EVENT_TYPE_DEVICE_OPEN = 15,
    EVENT_TYPE_FORK = 16,
    EVENT_TYPE_FILE_WRITE = 17,
    EVENT_TYPE_FILE_UNLINK = 18,
    EVENT_TYPE_SETUID = 19,
    EVENT_TYPE_SETGID = 20,
    EVENT_TYPE_NET_ICMP = 21,
    EVENT_TYPE_PACKET_DATA = 22,
    EVENT_TYPE_SCRIPT_SECURITY = 23,
    EVENT_TYPE_AF_ALG_BIND = 24,
    EVENT_TYPE_SCRIPT_FILE_CHECK = 25, // Internal: interpreter opened a file, needs userspace path resolution
    EVENT_TYPE_MODULE_LOAD_REQUEST = 26, // Kernel module load attempt (autoload / finit_module) — Dirty Frag RxRPC mitigation
    EVENT_TYPE_XFRM_SA_NEW = 27,         // XFRM SA registration from non-init userns with ESN — Dirty Frag ESP mitigation
    EVENT_TYPE_MAX
};

// Parameter types for TLV encoding
enum param_type {
    PARAM_TYPE_NONE = 0,    // Empty/skipped parameter
    PARAM_TYPE_U32 = 1,
    PARAM_TYPE_U64 = 2,
    PARAM_TYPE_S32 = 3,
    PARAM_TYPE_S64 = 4,
    PARAM_TYPE_STRING = 5,
    PARAM_TYPE_BYTEBUF = 6,
};

// Event header for dynamic events
struct ehevent_header {
    uint64_t timestamp_ns;
    uint32_t pid;
    uint16_t event_id;     // User-defined event ID
    uint16_t param_count;  // Number of parameters
    uint16_t total_size;   // Total size including header and all params
} __attribute__((packed));

// parameter header
struct param_header {
    uint8_t type;      // param_type enum
    uint16_t offset;   // param data offset
    uint16_t length;   // length of value (0 for NONE type)
} __attribute__((packed));

// Maximum sizes
#define MAX_EVENT_SIZE 8192
// Buffer size is twice MAX_EVENT_SIZE to keep verifier happy
#define MAX_EVENT_BUFFER_SIZE 16384
#define MAX_PARAM_LENGTH ((uint32_t)4096)

// Event context for building dynamic events
struct event_context {
    uint32_t in_use;                   // 1 if buffer is in use, 0 if free
    uint32_t cursor;                   // Current position in buffer
    uint16_t param_index;              // Current param
    uint8_t buffer[MAX_EVENT_BUFFER_SIZE];    // Buffer for parameters
};
