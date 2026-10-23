// SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause
// ehprobe_common.h - Common definitions for all eBPF programs
#pragma once

#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>
#include <bpf/bpf_core_read.h>
#include "data.h"
#include "maps.h"
#include "events.h"
#include "dynamic_events.h"
#include "helpers.h"

#define PF_KTHREAD 0x00200000
#define O_CREAT 00000100  /* not fcntl */

#define MINORBITS 20
#define MINORMASK ((1U << MINORBITS) - 1)
#define MAJOR(dev) ((unsigned int)((dev) >> MINORBITS))
#define MINOR(dev) ((unsigned int)((dev) & MINORMASK))
#define MKDEV(ma, mi) (((ma) << MINORBITS) | (mi))

// Single ring buffer for all events (shared across all programs)
struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 256 * 1024);
} rb __weak SEC(".maps");

// Stats map for monitoring dropped events (shared across all programs)
struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, EVENT_TYPE_MAX);
    __type(key, uint32_t);
    __type(value, uint64_t);
} event_stats __weak SEC(".maps");

// Wrapper for submit_event that passes our ring buffer
static __always_inline int submit_event(struct event_context *ctx)
{
    return submit_event_to_rb(ctx, &rb);
}

// Helper to update drop stats
static __always_inline void update_drop_stats(uint16_t event_id)
{
    uint64_t *stats;
    uint32_t key = event_id;
    
    stats = bpf_map_lookup_elem(&event_stats, &key);
    if (stats) {
        __sync_fetch_and_add(stats, 1);
    } else {
        uint64_t initial = 1;
        bpf_map_update_elem(&event_stats, &key, &initial, BPF_ANY);
    }
}
