// SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause
// handle_af_alg_bind.bpf.c - Detect and optionally block AF_ALG socket binds
//
// Fires on every bind(2) that targets AF_ALG (family 38). The userspace
// crypto subsystem is almost never exercised by legitimate unprivileged
// code; binding to the "authencesn" AEAD template is the entry point for
// CVE-2026-31431 (Copy Fail). We emit events unconditionally and, in
// enforce mode, additionally deny the bind by returning `-EAFNOSUPPORT`
// when the bound template starts with "authencesn". EAFNOSUPPORT mimics
// the kernel's error for a family that isn't registered at all — lower
// profile than a generic `EPERM` and indistinguishable from "AF_ALG not
// built into this kernel" from the caller's perspective.
#include <ehprobe_common.h>
#include <crypto_events.h>

char LICENSE[] SEC("license") = "Dual BSD/GPL";

// Linux errno for "address family not supported by protocol".
// Not defined in vmlinux.h BTF; matches /usr/include/asm-generic/errno.h.
#define EHPROBE_EAFNOSUPPORT 97

SEC("lsm/socket_bind")
int BPF_PROG(handle_socket_bind, struct socket *sock, struct sockaddr *address, int addrlen)
{
    u32 map_key = 0;
    struct ehprobe_env *env = bpf_map_lookup_elem(&ehprobe_env_map, &map_key);
    if (!env || !env->flag_af_alg) {
        return 0;
    }

    // Cheap filter: read only the first 2 bytes (sa_family) and bail
    // immediately if this is not an AF_ALG bind. The vast majority of
    // binds are AF_INET/AF_INET6 and we want near-zero overhead there.
    uint16_t family = 0;
    if (bpf_probe_read_kernel(&family, sizeof(family), address) < 0) {
        return 0;
    }
    if (family != AF_ALG) {
        return 0;
    }

    // Reject short AF_ALG binds upfront so we never read past the
    // caller-supplied buffer.
    if (addrlen < (int)sizeof(struct ehprobe_sockaddr_alg)) {
        return 0;
    }

    // Single kernel read of the sockaddr_alg — used for both the
    // telemetry event and the block decision below.
    struct ehprobe_sockaddr_alg salg = {};
    if (bpf_probe_read_kernel(&salg, sizeof(salg), address) < 0) {
        return 0;
    }
    // Null-terminate defensively in case the kernel buffer wasn't.
    salg.salg_type[sizeof(salg.salg_type) - 1] = '\0';
    salg.salg_name[sizeof(salg.salg_name) - 1] = '\0';

    // Emit the event first — we want this recorded whether or not we
    // block, and regardless of the block mode, so enforce deployments
    // preserve the detection signal.
    (void)ehprobe_af_alg_bind(&salg, env->af_alg_block_mode);

    // Enforcement: deny the bind iff mode == enforce AND the template
    // is a known CVE-2026-31431 trigger. Audit mode observes only; off
    // is the default (no behavioral change vs. pre-feature baseline).
    if (env->af_alg_block_mode == EHPROBE_BLOCKING_MODE_ENFORCE
        && salg_name_is_authencesn(salg.salg_name)) {
        trace_log("EHPROBE_LSM_SOCKET_BIND: blocking authencesn bind (pid=%d)",
                  bpf_get_current_pid_tgid() >> 32);
        return -EHPROBE_EAFNOSUPPORT;
    }

    return 0;
}
