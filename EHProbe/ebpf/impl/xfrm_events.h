// SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause
#pragma once

#include <ehprobe_common.h>
#include <container_logic.h>

// ========================================================================
// XFRM constants not exported via vmlinux.h BTF
// ========================================================================

// Netlink message padding: nlmsghdr is 16 bytes, 4-byte aligned → 16.
// See include/uapi/linux/netlink.h NLMSG_HDRLEN.
#define EHPROBE_NLMSG_HDRLEN 16

// nlattr header is 4 bytes, 4-byte aligned → 4.
// See include/uapi/linux/netlink.h NLA_HDRLEN.
#define EHPROBE_NLA_HDRLEN 4

// xfrm_usersa_info.flags bit for extended sequence numbers.
// See include/uapi/linux/xfrm.h XFRM_STATE_ESN.  ESN is the condition
// that reaches the vulnerable `crypto_authenc_esn_decrypt` STORE path
// — the kernel only instantiates `authencesn(...)` when this flag is
// set.
#define EHPROBE_XFRM_STATE_ESN 128

// Netlink attribute IDs — must match enum in vmlinux.h (re-declared
// here so programs that include this header don't need the full
// vmlinux enum in scope).
#define EHPROBE_XFRMA_ALG_AUTH       1
#define EHPROBE_XFRMA_ALG_CRYPT      2
#define EHPROBE_XFRMA_ALG_AEAD       18
#define EHPROBE_XFRMA_ALG_AUTH_TRUNC 20
// __XFRMA_MAX in current kernel is 35; we size our attrs read window
// conservatively to cover it without overreading the caller's array.
#define EHPROBE_XFRMA_MAX_IDX        35

// xfrm_algo / xfrm_algo_aead both start with a 64-byte alg_name field.
// We only ever read alg_name, so treat them uniformly.
#define EHPROBE_XFRM_ALG_NAME_LEN 64

// Per-CPU scratch for algorithm-name buffers. The three 64-byte
// strings can't live on the BPF stack (hits the 512-byte limit along
// with everything else the hook touches).
struct ehprobe_xfrm_sa_scratch {
    char aead_name[EHPROBE_XFRM_ALG_NAME_LEN];
    char auth_name[EHPROBE_XFRM_ALG_NAME_LEN];
    char crypt_name[EHPROBE_XFRM_ALG_NAME_LEN];
};
struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 1);
    __type(key, uint32_t);
    __type(value, struct ehprobe_xfrm_sa_scratch);
} ehprobe_xfrm_sa_scratch_map __weak SEC(".maps");

// ========================================================================
// Helpers
// ========================================================================

// Copy the algorithm name from an xfrm netlink attribute into `out`.
// `attr_ptr` is the kernel pointer to the `struct nlattr` header (as
// stored in attrs[XFRMA_ALG_*]). Returns number of bytes written
// (including null terminator), 0 if attr is NULL or read fails.
//
// `cap` is clamped to EHPROBE_XFRM_ALG_NAME_LEN so a caller that
// miscomputes the buffer size (or hits a future increase in the
// kernel's CRYPTO_MAX_ALG_NAME) cannot overrun `out`.
static __always_inline uint32_t read_xfrm_alg_name(struct nlattr *attr_ptr,
                                                   char *out,
                                                   uint32_t cap) {
    if (!attr_ptr || !out || cap == 0) {
        return 0;
    }
    if (cap > EHPROBE_XFRM_ALG_NAME_LEN) {
        cap = EHPROBE_XFRM_ALG_NAME_LEN;
    }
    // nla_data(attr) = (void*)attr + NLA_HDRLEN. First field of
    // xfrm_algo / xfrm_algo_aead is alg_name[64].
    void *data = (void *)attr_ptr + EHPROBE_NLA_HDRLEN;
    long n = bpf_probe_read_kernel_str(out, cap, data);
    if (n <= 0) {
        return 0;
    }
    return (uint32_t)n;
}

// Return non-zero if the current task's net_ns is owned by a non-init
// user namespace.  init_user_ns has level == 0; any user_ns created
// via `unshare(CLONE_NEWUSER)` has level >= 1 (its parent is init_ns).
// This is exactly the scenario the Dirty Frag ESP variant creates with
// `unshare(CLONE_NEWUSER | CLONE_NEWNET)`.
static __always_inline bool current_netns_user_ns_is_non_init(struct task_struct *task) {
    int level = BPF_CORE_READ(task, nsproxy, net_ns, user_ns, level);
    return level > 0;
}

// Return the inode number of the current task's net_ns->user_ns for
// forensic correlation.
static __always_inline uint64_t current_netns_user_ns_inum(struct task_struct *task) {
    return (uint64_t)BPF_CORE_READ(task, nsproxy, net_ns, user_ns, ns.inum);
}

// XFRM SA new-state event.  Emitted when a non-init-userns process
// registers an XFRM SA with XFRM_STATE_ESN — the exact preconditions
// of the Dirty Frag ESP variant.
//
// **Parameters pushed (10 total):**
//   [0] user_ns_inum    (u64)    - sender's net_ns->user_ns inode
//   [1] sa_flags        (u32)    - raw xfrm_usersa_info.flags byte (ESN bit = 0x80)
//   [2] aead_name       (string) - from XFRMA_ALG_AEAD, or "" if absent
//   [3] auth_name       (string) - from XFRMA_ALG_AUTH, or "" if absent
//   [4] crypt_name      (string) - from XFRMA_ALG_CRYPT, or "" if absent
//   [5] ppid            (s64)
//   [6] exe_path        (string)
//   [7] container_id    (u64)
//   [8] container_level (u32)
//   [9] blocking_mode   (u64)    - 0=off, 1=audit, 2=enforce
//
// Returns the value of `submit_event()` on success (0, or ringbuf
// error) and 0 (with drop stats incremented) when event construction
// fails partway.  Callers can log on non-zero return to surface
// telemetry-emit failures; enforcement decisions are never gated on
// this return value.
static __always_inline int ehprobe_xfrm_sa_new(
    uint64_t user_ns_inum,
    uint32_t sa_flags,
    const char *aead_name, uint32_t aead_len,
    const char *auth_name, uint32_t auth_len,
    const char *crypt_name, uint32_t crypt_len,
    uint64_t blocking_mode
) {
    struct task_struct *task = bpf_get_current_task_btf();

    uint32_t container_level = 0;
    uint64_t container_id = get_container_id(task, &container_level);

    struct event_context *evt_ctx = start_event(EVENT_TYPE_XFRM_SA_NEW, 10);
    if (!evt_ctx) {
        trace_log("EHPROBE_XFRM_SA_NEW: ERROR - start_event failed");
        update_drop_stats(EVENT_TYPE_XFRM_SA_NEW);
        return 0;
    }

    // [0] user_ns_inum
    if (push_param_u64(evt_ctx, user_ns_inum) < 0) {
        goto error;
    }

    // [1] sa_flags
    if (push_param_u32(evt_ctx, sa_flags) < 0) {
        goto error;
    }

    // [2..4] aead / auth / crypt names — each is either a string or
    // PARAM_TYPE_NONE depending on whether the attribute was present.
#define PUSH_OPT_STR(p, l) do { \
        if ((p) != NULL && (l) > 0) { \
            if (push_param_string(evt_ctx, (p), (l), 1) < 0) { goto error; } \
        } else { \
            if (push_param_none(evt_ctx) < 0) { goto error; } \
        } \
    } while (0)

    PUSH_OPT_STR(aead_name, aead_len);
    PUSH_OPT_STR(auth_name, auth_len);
    PUSH_OPT_STR(crypt_name, crypt_len);

#undef PUSH_OPT_STR

    // [5] ppid
    int64_t ppid = (int64_t)(uint32_t)BPF_CORE_READ(task, real_parent, tgid);
    if (push_param_s64(evt_ctx, ppid) < 0) {
        goto error;
    }

    // [6] exe_path
    struct file *exe_file = BPF_CORE_READ(task, mm, exe_file);
    if (exe_file != NULL) {
        uint32_t len = 0;
        char *p = reconstruct_file_path(&(exe_file->f_path), &len);
        if (p != NULL && len > 0 && len < PATH_BUFFER_SIZE) {
            if (push_param_string(evt_ctx, p, len, 1) < 0) {
                goto error;
            }
        } else {
            if (push_param_none(evt_ctx) < 0) {
                goto error;
            }
        }
    } else {
        if (push_param_none(evt_ctx) < 0) {
            goto error;
        }
    }

    // [7] container_id
    if (push_param_u64(evt_ctx, container_id) < 0) {
        goto error;
    }

    // [8] container_level
    if (push_param_u32(evt_ctx, container_level) < 0) {
        goto error;
    }

    // [9] blocking_mode
    if (push_param_u64(evt_ctx, blocking_mode) < 0) {
        goto error;
    }

    trace_log("EHPROBE_XFRM_SA_NEW: submitting event (flags=0x%x mode=%llu userns=%llu)",
              sa_flags, blocking_mode, user_ns_inum);
    return submit_event(evt_ctx);

error:
    trace_log("EHPROBE_XFRM_SA_NEW: ERROR - dropping event");
    release_event(evt_ctx);
    update_drop_stats(EVENT_TYPE_XFRM_SA_NEW);
    return 0;
}
