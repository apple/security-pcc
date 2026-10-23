// SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause
// dpi_events.h — DPI packet data capture helpers
#pragma once

// EEXIST is not available in BPF programs (no errno.h)
#ifndef EEXIST
#define EEXIST 17
#endif

#include <ehprobe_common.h>
#include <container_logic.h>

// Struct and map definitions are in data.h and maps.h respectively.
// DPI_PAYLOAD_CAPTURE_MAX, struct dpi_payload_buf → data.h
// dpi_flow_tracker, dpi_payload_map → maps.h

// Check if a DPI flow has exceeded the byte capture budget.
// Returns 1 if we should capture (under budget), 0 if we should skip.
static __always_inline int dpi_flow_should_capture(
    uint32_t pid, uint8_t protocol, uint8_t family,
    void *remote_addr, uint16_t remote_port, uint16_t local_port,
    uint32_t payload_len
) {
    struct dpi_flow_key key = {};
    key.pid = pid;
    key.protocol = protocol;
    key.family = family;
    key.remote_port = remote_port;
    key.local_port = local_port;

    if (family == AF_INET) {
        bpf_probe_read_kernel(&key.remote_addr4, 4, remote_addr);
    } else if (family == AF_INET6) {
        bpf_probe_read_kernel(&key.remote_addr6, 16, remote_addr);
    } else {
        return 0;
    }

    // Try to insert a new entry. BPF_NOEXIST makes this a no-op if another
    // CPU already created the entry, so we always fall through to lookup+increment.
    struct dpi_flow_value new_val = { .bytes_captured = 0 };
    int insert_err = bpf_map_update_elem(&dpi_flow_tracker, &key, &new_val, BPF_NOEXIST);
    if (insert_err != 0 && insert_err != -EEXIST) {
        // Map full or other failure — don't capture.
        return 0;
    }

    struct dpi_flow_value *val = bpf_map_lookup_elem(&dpi_flow_tracker, &key);
    if (!val) {
        return 0;
    }
    // Atomically add payload_len first, then check — avoids TOCTOU race
    // where multiple CPUs pass the check before any add occurs.
    uint32_t prev = __sync_fetch_and_add(&val->bytes_captured, payload_len);
    if (prev >= DPI_MAX_BYTES_PER_FLOW) {
        return 0;
    }
    return 1;
}

// Emit a PACKET_DATA event for DPI processing.
// Parameters: pid, comm, family, protocol, remote_addr, remote_port,
//             local_port, direction, ifindex, payload, payload_len, container_id, container_level
static __always_inline int ehprobe_packet_data(
    struct task_struct *task,
    void *remote_addr,
    uint8_t family,
    uint8_t protocol,
    uint16_t remote_port,
    uint16_t local_port,
    uint8_t direction,
    uint32_t ifindex,
    void *payload_ptr,
    uint32_t payload_len,
    uint64_t container_id,
    uint32_t container_level
) {
    uint32_t pid = BPF_CORE_READ(task, tgid);

    trace_log("EHPROBE_DPI: packet_data called pid=%d proto=%d port=%d", pid, protocol, remote_port);

    if (!dpi_flow_should_capture(pid, protocol, family,
                                  remote_addr, remote_port, local_port,
                                  payload_len)) {
        return 0;
    }

    // Use per-CPU map buffer for payload to avoid BPF 512-byte stack limit
    uint32_t buf_key = 0;
    struct dpi_payload_buf *pbuf = bpf_map_lookup_elem(&dpi_payload_map, &buf_key);
    if (!pbuf) {
        return -1;
    }

    struct event_context *evt_ctx = start_event(EVENT_TYPE_PACKET_DATA, 13);
    if (!evt_ctx) {
        update_drop_stats(EVENT_TYPE_PACKET_DATA);
        return -1;
    }

    if (push_param_s64(evt_ctx, (int64_t)pid) < 0) {
        goto error;
    }

    char comm[TASK_COMM_LEN];
    BPF_CORE_READ_STR_INTO(&comm, task, comm);
    if (push_param_string(evt_ctx, comm, TASK_COMM_LEN, 1) < 0) {
        goto error;
    }

    if (push_param_u32(evt_ctx, (uint32_t)family) < 0) {
        goto error;
    }

    if (push_param_u32(evt_ctx, (uint32_t)protocol) < 0) {
        goto error;
    }

    if (family == AF_INET) {
        if (push_param_bytebuf(evt_ctx, (const unsigned char *)remote_addr, 4, 1) < 0) {
            goto error;
        }
    } else if (family == AF_INET6) {
        if (push_param_bytebuf(evt_ctx, (const unsigned char *)remote_addr, 16, 1) < 0) {
            goto error;
        }
    } else {
        goto error;
    }

    if (push_param_u32(evt_ctx, (uint32_t)remote_port) < 0) {
        goto error;
    }

    if (push_param_u32(evt_ctx, (uint32_t)local_port) < 0) {
        goto error;
    }

    if (push_param_u32(evt_ctx, (uint32_t)direction) < 0) {
        goto error;
    }

    if (push_param_u32(evt_ctx, ifindex) < 0) {
        goto error;
    }

    // Capture payload into per-CPU buffer
    // IMPORTANT: push_param_bytebuf treats length==0 as MAX_PARAM_LENGTH (BPF
    // verifier workaround), which corrupts the event buffer.  Always push at
    // least 1 byte so checked_length stays small.
    // Only zero the first byte (used when no payload is captured).
    // bpf_probe_read_user overwrites the buffer for actual captures.
    pbuf->data[0] = 0;
    uint32_t capture_len = 0;
    if (payload_ptr != NULL && payload_len > 0) {
        capture_len = payload_len;
        if (capture_len > DPI_PAYLOAD_CAPTURE_MAX) {
            capture_len = DPI_PAYLOAD_CAPTURE_MAX;
        }
        // Read only the bytes we need — avoid leaking adjacent user memory.
        // The BPF verifier needs a provably-bounded size argument.
        // capture_len is already clamped to [1, DPI_PAYLOAD_CAPTURE_MAX] above.
        // The & mask provides the verifier proof that it fits in the buffer.
        // (DPI_PAYLOAD_CAPTURE_MAX is enforced as power-of-2 via _Static_assert in data.h)
        uint32_t read_len = capture_len & (DPI_PAYLOAD_CAPTURE_MAX - 1);
        if (read_len == 0) {
            read_len = DPI_PAYLOAD_CAPTURE_MAX;  // capture_len was exactly MAX
        }
        long read_ret = bpf_probe_read_user(pbuf->data, read_len, payload_ptr);
        if (read_ret < 0) {
            capture_len = 0;
        }
    }

    // Push at least 1 byte to avoid push_param_bytebuf 0→4096 length bug
    uint32_t push_len = capture_len > 0 ? capture_len : 1;
    if (push_param_bytebuf(evt_ctx, pbuf->data, push_len, 1) < 0) {
        goto error;
    }

    if (push_param_u32(evt_ctx, payload_len) < 0) {
        goto error;
    }

    if (push_param_u64(evt_ctx, container_id) < 0) {
        goto error;
    }

    if (push_param_u32(evt_ctx, container_level) < 0) {
        goto error;
    }

    return submit_event(evt_ctx);

error:
    release_event(evt_ctx);
    update_drop_stats(EVENT_TYPE_PACKET_DATA);
    return -1;
}
