// SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause
#pragma once

#include <ehprobe_common.h>
#include <container_logic.h>

// Maximum length of a kernel module name — matches kernel MODULE_NAME_LEN.
// Not in vmlinux.h BTF; see include/linux/module.h.
#define EHPROBE_MODULE_NAME_LEN 56

// Which LSM hook observed the load attempt.
// Included on the event so userspace + rego can distinguish the autoload
// path (triggered by e.g. `socket(AF_RXRPC)`) from an explicit load
// (`finit_module(fd)`).
#define EHPROBE_MODULE_HOOK_REQUEST 1   // lsm/kernel_module_request — autoload
#define EHPROBE_MODULE_HOOK_READ    2   // lsm/kernel_read_file(READING_MODULE) — finit_module

// ========================================================================
// Blocklist — single source of truth
// ========================================================================
//
// To deny another Dirty Frag-class kernel module, add exactly one line
// `X("<name>")` to the X-macro below.  Both the bare-name matcher
// (`lsm/kernel_module_request`, compares against "<name>") and the
// file-basename matcher (`lsm/kernel_read_file`, compares against
// "<name>.ko", "<name>.ko.xz", "<name>.ko.zst") pick up the new entry
// automatically — no other code changes needed.
//
// Each entry should be accompanied by a short `//` comment describing
// which CVE / bug class the module is being denied for, so the
// provenance of the blocklist is preserved as entries accumulate.
#define EHPROBE_MODULE_BLOCKLIST(X) \
    /* Dirty Frag (2026) — RxRPC Page-Cache Write variant.             */ \
    /* RHEL 9's base `kernel-modules` package does not ship rxrpc.ko   */ \
    /* and no in-distro service requires it.                           */ \
    X("rxrpc")

// Kernel autoload aliases for blocklisted modules.  The kernel's
// `request_module()` path is invoked from subsystem bootstrap code
// (e.g. `sock_create` → `request_module("net-pf-%d", family)`), which
// passes an alias string, NOT the bare module name.  Without these
// aliases here, the `lsm/kernel_module_request` hook cannot match the
// autoload path that the published exploits actually take — the
// `lsm/kernel_read_file` hook would still catch the resulting
// `finit_module` load, but blocking one syscall earlier is cleaner.
//
// Each entry is bare-name-only (not expanded into `.ko` file forms).
#define EHPROBE_MODULE_BLOCKLIST_ALIASES(X) \
    /* PF_RXRPC = 33 (include/linux/socket.h). The rxrpc module        */ \
    /* declares `MODULE_ALIAS_NETPROTO(PF_RXRPC)` which expands to     */ \
    /* `MODULE_ALIAS("net-pf-33")`, and `socket(AF_RXRPC, ...)`        */ \
    /* triggers `request_module("net-pf-33")`.                         */ \
    X("net-pf-33")

// Maximum byte length (including NUL) of any entry in either array.
// Bump if a future blocklist entry overflows.
#define EHPROBE_BLOCKLIST_NAMELEN 16

#define EHPROBE_BLOCKLIST_ENTRY_BARE(name)    name,
#define EHPROBE_BLOCKLIST_ENTRY_KO(name)      name ".ko",
#define EHPROBE_BLOCKLIST_ENTRY_KO_XZ(name)   name ".ko.xz",
#define EHPROBE_BLOCKLIST_ENTRY_KO_ZST(name)  name ".ko.zst",
#define EHPROBE_BLOCKLIST_ENTRY_KO_GZ(name)   name ".ko.gz",

// Bare-name form — used by lsm/kernel_module_request, which sees
// whatever string the in-kernel caller passed to `request_module`
// (either the module name directly or a subsystem alias).
static const char ehprobe_blocklist_bare[][EHPROBE_BLOCKLIST_NAMELEN] = {
    EHPROBE_MODULE_BLOCKLIST(EHPROBE_BLOCKLIST_ENTRY_BARE)
    EHPROBE_MODULE_BLOCKLIST_ALIASES(EHPROBE_BLOCKLIST_ENTRY_BARE)
};
#define EHPROBE_BLOCKLIST_BARE_COUNT \
    (sizeof(ehprobe_blocklist_bare) / sizeof(ehprobe_blocklist_bare[0]))

// File-basename form (all compression variants RHEL 9 + older RHEL /
// Debian-family packagings use) — fed to `lsm/kernel_read_file` for
// the `finit_module(fd)` path.
static const char ehprobe_blocklist_files[][EHPROBE_BLOCKLIST_NAMELEN] = {
    EHPROBE_MODULE_BLOCKLIST(EHPROBE_BLOCKLIST_ENTRY_KO)
    EHPROBE_MODULE_BLOCKLIST(EHPROBE_BLOCKLIST_ENTRY_KO_XZ)
    EHPROBE_MODULE_BLOCKLIST(EHPROBE_BLOCKLIST_ENTRY_KO_ZST)
    EHPROBE_MODULE_BLOCKLIST(EHPROBE_BLOCKLIST_ENTRY_KO_GZ)
};
#define EHPROBE_BLOCKLIST_FILES_COUNT \
    (sizeof(ehprobe_blocklist_files) / sizeof(ehprobe_blocklist_files[0]))

// Byte-wise null-terminated string equality, bounded.  Both buffers
// must be accessible for at least EHPROBE_BLOCKLIST_NAMELEN bytes.
static __always_inline bool ehprobe_blocklist_name_eq(const char *a, const char *b) {
    #pragma unroll
    for (uint32_t i = 0; i < EHPROBE_BLOCKLIST_NAMELEN; i++) {
        char ac = a[i];
        char bc = b[i];
        if (ac != bc) {
            return false;
        }
        if (ac == '\0') {
            return true;
        }
    }
    return true;
}

// Does `name` (bare module name, e.g. "rxrpc") match the blocklist?
// `name` buffer must be at least EHPROBE_BLOCKLIST_NAMELEN bytes.
static __always_inline bool kmod_name_is_blocked(const char name[EHPROBE_MODULE_NAME_LEN]) {
    #pragma unroll
    for (uint32_t i = 0; i < EHPROBE_BLOCKLIST_BARE_COUNT; i++) {
        if (ehprobe_blocklist_name_eq(name, ehprobe_blocklist_bare[i])) {
            return true;
        }
    }
    return false;
}

// Does `basename` (file basename, e.g. "rxrpc.ko.xz") match the
// blocklist?  `basename` buffer must be at least
// EHPROBE_BLOCKLIST_NAMELEN bytes.
static __always_inline bool kmod_basename_is_blocked(const char *basename) {
    #pragma unroll
    for (uint32_t i = 0; i < EHPROBE_BLOCKLIST_FILES_COUNT; i++) {
        if (ehprobe_blocklist_name_eq(basename, ehprobe_blocklist_files[i])) {
            return true;
        }
    }
    return false;
}

// Module-load event emission helper.
//
// **Parameters pushed (7 total):**
//   [0] kmod_name       (string) - module name (autoload) or file basename (finit)
//   [1] file_path       (string) - /lib/modules/.../rxrpc.ko.xz, or "" for autoload
//   [2] hook_tag        (u32)    - EHPROBE_MODULE_HOOK_*
//   [3] ppid            (s64)
//   [4] exe_path        (string) - calling process executable
//   [5] container_id    (u64)
//   [6] container_level (u32)
//   [7] blocking_mode   (u64)    - snapshot at emission time
//
// Returns the value of `submit_event()` on success (0, or ringbuf
// error) and 0 (with drop stats incremented) when event construction
// fails partway.  Callers can log on non-zero return to surface
// telemetry-emit failures; enforcement decisions are never gated on
// this return value.
static __always_inline int ehprobe_module_load_request(
    const char *kmod_name_ptr,
    uint32_t kmod_name_len,
    struct file *file,
    uint32_t hook_tag,
    uint64_t blocking_mode
) {
    struct task_struct *task = bpf_get_current_task_btf();

    uint32_t container_level = 0;
    uint64_t container_id = get_container_id(task, &container_level);

    struct event_context *evt_ctx = start_event(EVENT_TYPE_MODULE_LOAD_REQUEST, 8);
    if (!evt_ctx) {
        trace_log("EHPROBE_MODULE_LOAD: ERROR - start_event failed");
        update_drop_stats(EVENT_TYPE_MODULE_LOAD_REQUEST);
        return 0;
    }

    // [0] kmod_name (string). kmod_name_ptr may point to kernel memory.
    if (kmod_name_ptr != NULL && kmod_name_len > 0) {
        if (push_param_string(evt_ctx, kmod_name_ptr, kmod_name_len, 1) < 0) {
            goto error;
        }
    } else {
        if (push_param_none(evt_ctx) < 0) {
            goto error;
        }
    }

    // [1] file_path (string) — only present for READING_MODULE
    if (file != NULL) {
        uint32_t len = 0;
        char *p = reconstruct_file_path(&(file->f_path), &len);
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

    // [2] hook_tag
    if (push_param_u32(evt_ctx, hook_tag) < 0) {
        goto error;
    }

    // [3] ppid
    int64_t ppid = (int64_t)(uint32_t)BPF_CORE_READ(task, real_parent, tgid);
    if (push_param_s64(evt_ctx, ppid) < 0) {
        goto error;
    }

    // [4] exe_path
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

    // [5] container_id
    if (push_param_u64(evt_ctx, container_id) < 0) {
        goto error;
    }

    // [6] container_level
    if (push_param_u32(evt_ctx, container_level) < 0) {
        goto error;
    }

    // [7] blocking_mode
    if (push_param_u64(evt_ctx, blocking_mode) < 0) {
        goto error;
    }

    trace_log("EHPROBE_MODULE_LOAD: submitting event (hook=%u mode=%llu)",
              hook_tag, blocking_mode);
    return submit_event(evt_ctx);

error:
    trace_log("EHPROBE_MODULE_LOAD: ERROR - dropping event");
    release_event(evt_ctx);
    update_drop_stats(EVENT_TYPE_MODULE_LOAD_REQUEST);
    return 0;
}
