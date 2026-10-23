// SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause
// handle_kernel_module_request.bpf.c - Detect and optionally block the
// kernel autoload path (`request_module()`) for Dirty Frag modules.
//
// Fires from `lsm/kernel_module_request` when the kernel wants to
// autoload a module on behalf of some caller. The Dirty Frag RxRPC
// variant depends on this path: `socket(AF_RXRPC, ...)` triggers
// `request_module("net-pf-XX-YY-rxrpc")`, and the module's presence is
// a prerequisite for the `rxkad_verify_packet_1` in-place decrypt
// primitive. On RHEL 9 (our only Linux target) rxrpc.ko lives in
// `kernel-modules-extra` and is not pulled in by any base package, so
// a block here is zero-FP.
//
// Pairs with `handle_kernel_read_file.bpf.c`, which covers the
// explicit `finit_module(fd)` load path. Together they catch all
// realistic module-load routes on RHEL 9 userland. `init_module(buf)`
// (raw-buffer form, no backing file) is a documented minor gap.
#include <ehprobe_common.h>
#include <module_events.h>

char LICENSE[] SEC("license") = "Dual BSD/GPL";

#define EHPROBE_EPERM 1

SEC("lsm/kernel_module_request")
int BPF_PROG(handle_kernel_module_request, char *kmod_name)
{
    u32 map_key = 0;
    struct ehprobe_env *env = bpf_map_lookup_elem(&ehprobe_env_map, &map_key);
    if (!env || !env->flag_module_load) {
        return 0;
    }
    // Snapshot the blocking mode once so the value recorded on the
    // event matches the value the enforce check uses.  Otherwise a
    // userspace update between the two reads would let us log "audit"
    // while actually denying the load (or vice versa).
    u64 block_mode = env->module_load_block_mode;

    // Copy the module name into a fixed-size local buffer so we can
    // do prefix matching + emit it as an event parameter without any
    // further kernel reads.
    char name[EHPROBE_MODULE_NAME_LEN] = {};
    long n = bpf_probe_read_kernel_str(name, sizeof(name), kmod_name);
    if (n <= 0) {
        return 0;
    }
    // Defensive null-termination — bpf_probe_read_kernel_str already
    // null-terminates, but clamp the last byte in case of truncation.
    name[EHPROBE_MODULE_NAME_LEN - 1] = '\0';

    // Only emit for modules on the Dirty Frag blocklist — module-load
    // traffic is high on RHEL (every boot, every netns creation, every
    // `modprobe` call) and unconditional emission would be far too
    // noisy. Extend `kmod_name_is_blocked()` to add new modules.
    if (!kmod_name_is_blocked(name)) {
        return 0;
    }

    int emit_ret = ehprobe_module_load_request(
        name, (uint32_t)n, NULL,
        EHPROBE_MODULE_HOOK_REQUEST,
        block_mode
    );
    if (emit_ret < 0) {
        // A blocked load without telemetry is worse than a quiet
        // allow; surface the failure so operators can correlate the
        // denied load with a dropped event.
        trace_log("EHPROBE_LSM_MODULE_REQUEST: failed to emit event for %s", name);
    }

    if (block_mode == EHPROBE_BLOCKING_MODE_ENFORCE) {
        trace_log("EHPROBE_LSM_MODULE_REQUEST: blocking %s load (pid=%d)",
                  name, bpf_get_current_pid_tgid() >> 32);
        return -EHPROBE_EPERM;
    }

    return 0;
}
