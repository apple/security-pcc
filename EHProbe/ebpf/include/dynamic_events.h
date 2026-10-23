// SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause
// dynamic_events.h
#pragma once

#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_core_read.h>
#include "events.h"
#include "helpers.h"

// macros needed to keep eBPF verifier happy
#define MAX_EVENT_OFFSET (MAX_EVENT_SIZE - 8)
#define BOUND(x) ((x) < MAX_EVENT_OFFSET ? (x) : MAX_EVENT_OFFSET)
#define BOUND_CUSTOM(x, l) ((x) < (MAX_EVENT_SIZE - (l)) ? (x) : (MAX_EVENT_SIZE - (l)))

// Per-CPU map for event contexts
struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 1);
    __type(key, uint32_t);
    __type(value, struct event_context);
} event_context_map __weak SEC(".maps");

// Start building a new event
static __always_inline struct event_context* start_event(uint16_t event_id, uint16_t param_count)
{
    uint32_t key = 0;
    struct event_context *ctx;
    
    ctx = bpf_map_lookup_elem(&event_context_map, &key);
    if (!ctx) {
        return NULL;
    }
    
    if (ctx->in_use != 0) {
        return NULL;
    }
    ctx->in_use = 1;
    
    // Compiler barrier to ensure in_use is written before we proceed
    // This prevents compiler from reordering the in_use write
    asm volatile("" ::: "memory");
    
    // Now safe to initialize the buffer
    uint16_t start_data_offset = sizeof(struct ehevent_header) + param_count * sizeof(struct param_header);
    
    struct ehevent_header* hdr = (struct ehevent_header*)ctx->buffer;
    hdr->timestamp_ns = bpf_ktime_get_ns();
    hdr->pid = bpf_get_current_pid_tgid() >> 32;
    hdr->event_id = event_id;
    hdr->total_size = start_data_offset;
    hdr->param_count = param_count;
    
    ctx->cursor = start_data_offset;
    ctx->param_index = 0;

    return ctx;
}

// Helper to add parameter to buffer
static __always_inline int push_header(struct event_context* ctx, enum param_type type, uint16_t length)
{    
    if (!ctx) {
        return -1;
    }

    struct ehevent_header* hdr = (struct ehevent_header*)ctx->buffer;
    if (ctx->param_index >= hdr->param_count) {
        // Too many parameters
        return -1;
    }

    // Pushing param header
    struct param_header phdr;
    phdr.type = type;
    phdr.offset = ctx->cursor;
    phdr.length = length;

    uint32_t phdr_offset = sizeof(struct ehevent_header) + ctx->param_index * sizeof(struct param_header);

    uint32_t offset = phdr_offset & (MAX_PARAM_LENGTH - 1);
    int ret = bpf_probe_read_kernel(&ctx->buffer[offset], sizeof(phdr), &phdr);
    if (ret < 0) {
        return ret;
    }

    ctx->cursor += length;
    ctx->param_index++;
    hdr->total_size += length;

    return 0;
}

// Push empty/skipped parameter
static __always_inline int push_param_none(struct event_context *ctx)
{
    if (!ctx) {
        return -1;
    }
    return push_header(ctx, PARAM_TYPE_NONE, 0);
}

// Push u32 parameter
static __always_inline int push_param_u32(struct event_context *ctx, uint32_t value)
{
    if (!ctx) {
        return -1;
    }
    
    uint32_t cursor = ctx->cursor & (MAX_PARAM_LENGTH - 1);
    (*(uint32_t*)(&(ctx->buffer[cursor]))) = value;

    int ret = push_header(ctx, PARAM_TYPE_U32, sizeof(value));
    if (ret < 0) {
        return ret;
    }

    return 0;
}

// Push u64 parameter
static __always_inline int push_param_u64(struct event_context *ctx, uint64_t value)
{
    if (!ctx) {
        return -1;
    }

    uint32_t cursor = ctx->cursor & (MAX_PARAM_LENGTH - 1);
    (*(uint64_t*)(&(ctx->buffer[cursor]))) = value;

    int ret = push_header(ctx, PARAM_TYPE_U64, sizeof(value));
    if (ret < 0) {
        return ret;
    }

    return 0;
}

// Push s32 parameter
static __always_inline int push_param_s32(struct event_context *ctx, __s32 value)
{
    if (!ctx) {
        return -1;
    }

    uint32_t cursor = ctx->cursor & (MAX_PARAM_LENGTH - 1);
    (*(__s32*)(&(ctx->buffer[cursor]))) = value;

    int ret = push_header(ctx, PARAM_TYPE_S32, sizeof(value));
    if (ret < 0) {
        return ret;
    }

    return 0;
}

// Push s64 parameter
static __always_inline int push_param_s64(struct event_context *ctx, __s64 value)
{
    if (!ctx) {
        return -1;
    }

    uint32_t cursor = ctx->cursor & (MAX_PARAM_LENGTH - 1);
    (*(__s64*)(&(ctx->buffer[cursor]))) = value;

    int ret = push_header(ctx, PARAM_TYPE_S64, sizeof(value));
    if (ret < 0) {
        return ret;
    }

    return 0;
}

// Push string parameter - returns string length on success, or a negative error otherwise
static __always_inline int push_param_string(struct event_context *ctx, const char *value, uint32_t length, int kernel_mem_flag)
{
    if (!ctx || !value) {
        return -1;
    }

    uint32_t checked_length = ((length == (uint32_t)0 || length == MAX_PARAM_LENGTH) ? MAX_PARAM_LENGTH : length & (MAX_PARAM_LENGTH - 1));
    uint32_t cursor = ctx->cursor & (MAX_PARAM_LENGTH - 1);

    // Write value if present
    int read_length = 0;
    if (value) {
        if (kernel_mem_flag) {
            read_length = bpf_probe_read_kernel_str(&ctx->buffer[cursor], checked_length, value);
            if (read_length < 0) {
                return read_length;
            }

        }
        else {
            read_length = bpf_probe_read_user_str(&ctx->buffer[cursor], checked_length, value);
            if (read_length < 0) {
                return read_length;
            }
        }
    }

    int ret = push_header(ctx, PARAM_TYPE_STRING, read_length);
    if (ret < 0) {
        return ret;
    }

    return read_length;
}

// Push bytebuf parameter
static __always_inline int push_param_bytebuf(struct event_context *ctx, const unsigned char *data, uint16_t length, int kernel_mem_flag)
{
    if (!ctx || !data) {
        return -1;
    }

    uint32_t checked_length = ((length == (uint32_t)0 || length == MAX_PARAM_LENGTH) ? MAX_PARAM_LENGTH : length & (MAX_PARAM_LENGTH - 1));
    uint32_t cursor = ctx->cursor & (MAX_PARAM_LENGTH - 1);

    int ret = 0;
    if (data) {
        if (kernel_mem_flag) {
            ret = bpf_probe_read_kernel(&ctx->buffer[cursor], checked_length & (MAX_PARAM_LENGTH - 1), data);
            if (ret < 0) {
                return ret;
            }

        }
        else {
            ret = bpf_probe_read_user(&ctx->buffer[cursor], checked_length & (MAX_PARAM_LENGTH - 1), data);
            if (ret < 0) {
                return ret;
            }
        }
    }

    ret = push_header(ctx, PARAM_TYPE_BYTEBUF, checked_length);
    if (ret < 0) {
        return ret;
    }

    return 0;
}

static __always_inline void release_event(struct event_context *ctx)
{
    if (!ctx) {
        return;
    }
    ctx->in_use = 0;
}

// Submit event using bpf_ringbuf_output
static __always_inline int submit_event_to_rb(struct event_context *ctx, void *rb_map)
{
    uint64_t flags = BPF_RB_FORCE_WAKEUP;
    
    if (!ctx || !rb_map) {
        return -1;
    }

    struct ehevent_header* hdr = (struct ehevent_header*)ctx->buffer;
    if (ctx->param_index != hdr->param_count) {
        // Not every parameter pushed
        return -1;
    }
    
    // Ensure total_size is valid
    if (ctx->cursor > MAX_EVENT_SIZE) {
        return -1;
    }
    
    // bpf_ringbuf_output sends exactly ctx->cursor bytes to userspace
    int ret = bpf_ringbuf_output(rb_map, ctx->buffer, BOUND(ctx->cursor), flags);

    release_event(ctx);
    return ret;
}
