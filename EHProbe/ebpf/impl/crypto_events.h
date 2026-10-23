// SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause
#pragma once

#include <ehprobe_common.h>
#include <container_logic.h>

// AF_ALG socket family (Linux socket.h). Not defined in vmlinux.h BTF.
#ifndef AF_ALG
#define AF_ALG 38
#endif

// Layout of struct sockaddr_alg as passed to bind(2). Matches the
// in-kernel definition in include/uapi/linux/if_alg.h. We copy the
// incoming sockaddr into this local struct so we can read it with a
// fixed layout regardless of BTF naming differences across kernels.
struct ehprobe_sockaddr_alg {
    uint16_t salg_family;
    uint8_t  salg_type[14];
    uint32_t salg_feat;
    uint32_t salg_mask;
    uint8_t  salg_name[64];
};

// Byte-for-byte prefix check: is salg_name "authencesn…"?
// Inlined + verifier-friendly. authencesn is the sole vulnerable
// IPsec-ESN AEAD template triggering CVE-2026-31431, and no other
// kernel crypto template begins with this string, so an exact prefix
// match uniquely identifies the vulnerable bind.
static __always_inline bool salg_name_is_authencesn(const uint8_t name[64]) {
    return name[0] == 'a' && name[1] == 'u' && name[2] == 't'
        && name[3] == 'h' && name[4] == 'e' && name[5] == 'n'
        && name[6] == 'c' && name[7] == 'e' && name[8] == 's'
        && name[9] == 'n';
}

// AF_ALG bind event emission helper. Fires from the LSM socket_bind
// hook when an unprivileged process binds to a crypto algorithm via
// AF_ALG. The "authencesn" algorithm is the trigger for CVE-2026-31431
// (Copy Fail), but we emit for any AF_ALG bind so rego rules can
// decide which names are interesting.
//
// **Contract:** the caller is responsible for providing a fully-read
// `struct ehprobe_sockaddr_alg` (no further kernel reads happen here)
// and the current `blocking_mode` value so it can be recorded on the
// event for rego/forensic correlation.
//
// **Return value:** always 0 so this telemetry helper can never
// accidentally cause the LSM hook it's called from to deny the
// userspace operation. Failures are recorded via update_drop_stats
// and logged, not surfaced to the caller.
//
// Parameters pushed by ehprobe_af_alg_bind (7 total):
//   [0] salg_type      (string) - e.g. "aead", "skcipher", "hash"
//   [1] salg_name      (string) - e.g. "authencesn(hmac(sha256),cbc(aes))"
//   [2] ppid           (s64)    - parent PID
//   [3] exe_path       (string) - calling process executable
//   [4] container_id   (u64)
//   [5] container_level (u32)
//   [6] blocking_mode  (u64)    - 0=off, 1=audit, 2=enforce (snapshot at event time)
static __always_inline int ehprobe_af_alg_bind(
    const struct ehprobe_sockaddr_alg *salg,
    uint64_t blocking_mode
) {
    struct task_struct *task = bpf_get_current_task_btf();

    uint32_t container_level = 0;
    uint64_t container_id = get_container_id(task, &container_level);

    struct event_context *evt_ctx = start_event(EVENT_TYPE_AF_ALG_BIND, 7);
    if (!evt_ctx) {
        trace_log("EHPROBE_AF_ALG_BIND: ERROR - start_event failed");
        update_drop_stats(EVENT_TYPE_AF_ALG_BIND);
        return 0;
    }

    // Parameter 0: salg_type
    if (push_param_string(evt_ctx, (const char *)salg->salg_type,
                          sizeof(salg->salg_type), 1) < 0) {
        goto error;
    }

    // Parameter 1: salg_name
    if (push_param_string(evt_ctx, (const char *)salg->salg_name,
                          sizeof(salg->salg_name), 1) < 0) {
        goto error;
    }

    // Parameter 2: ppid
    int64_t ppid = (int64_t)(uint32_t)BPF_CORE_READ(task, real_parent, tgid);
    if (push_param_s64(evt_ctx, ppid) < 0) {
        goto error;
    }

    // Parameter 3: exe_path
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

    // Parameter 4: container_id
    if (push_param_u64(evt_ctx, container_id) < 0) {
        goto error;
    }

    // Parameter 5: container_level
    if (push_param_u32(evt_ctx, container_level) < 0) {
        goto error;
    }

    // Parameter 6: blocking_mode (snapshot at emission time)
    if (push_param_u64(evt_ctx, blocking_mode) < 0) {
        goto error;
    }

    trace_log("EHPROBE_AF_ALG_BIND: submitting event (type=%s name=%s mode=%llu)",
              salg->salg_type, salg->salg_name, blocking_mode);
    return submit_event(evt_ctx);

error:
    trace_log("EHPROBE_AF_ALG_BIND: ERROR - dropping event");
    release_event(evt_ctx);
    update_drop_stats(EVENT_TYPE_AF_ALG_BIND);
    return 0;
}
