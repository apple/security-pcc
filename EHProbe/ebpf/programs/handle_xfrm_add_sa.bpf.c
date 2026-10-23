// SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause
// handle_xfrm_add_sa.bpf.c - Detect and optionally kill callers of
// `XFRM_MSG_NEWSA` that trigger the Dirty Frag ESP variant.
//
// The ESP variant of Dirty Frag requires: (a) the attacker to have
// CAP_NET_ADMIN in some netns (obtained via `unshare(CLONE_NEWUSER |
// CLONE_NEWNET)`), and (b) an SA with `XFRM_STATE_ESN` set, because
// only the ESN path reaches `crypto_authenc_esn_decrypt()` which
// performs the in-place 4-byte STORE on the attacker-pinned page.
//
// The intersection is zero-FP on RHEL 9: legitimate IPsec daemons
// (libreswan `pluto`, strongSwan `charon`, OVN `ovn-controller`) all
// run in the init user namespace with real CAP_NET_ADMIN. No
// legitimate IPsec configuration runs from a non-init userns.
//
// This catches both attack variants the exploit can take:
//   - XFRMA_ALG_AEAD = "authencesn(...)"        (published exploit)
//   - XFRMA_ALG_AUTH + XFRMA_ALG_CRYPT + ESN    (split-attr form the
//                                                kernel internally
//                                                resolves to the same
//                                                authencesn sink)
//
// Enforcement: `bpf_send_signal(SIGKILL)`. The SA registration may
// complete, but the attacker cannot proceed to splice+send UDP-encap
// packets because the calling task is killed on syscall return.
#include <ehprobe_common.h>
#include <xfrm_events.h>

char LICENSE[] SEC("license") = "Dual BSD/GPL";

#define SIGKILL 9

SEC("kprobe/xfrm_add_sa")
int BPF_KPROBE(handle_xfrm_add_sa, struct sk_buff *skb,
               struct nlmsghdr *nlh, struct nlattr **attrs)
{
    u32 map_key = 0;
    struct ehprobe_env *env = bpf_map_lookup_elem(&ehprobe_env_map, &map_key);
    if (!env || !env->flag_xfrm_sa_new) {
        return 0;
    }
    // Snapshot the blocking mode once so the emit-time record matches
    // the enforce decision even under a concurrent userspace update.
    u64 block_mode = env->xfrm_sa_new_block_mode;

    struct task_struct *task = bpf_get_current_task_btf();
    if (!task) {
        return 0;
    }

    // Zero-FP gate part 1: non-init user namespace owning the netns.
    if (!current_netns_user_ns_is_non_init(task)) {
        return 0;
    }

    // Zero-FP gate part 2: XFRM_STATE_ESN flag set on the SA.
    // The full `struct xfrm_usersa_info` is ~200 bytes — far too big
    // for the BPF stack.  We read only the `flags` byte from the
    // netlink payload via CO-RE, so the struct offset auto-adjusts
    // across kernels.
    struct xfrm_usersa_info *info_ptr =
        (struct xfrm_usersa_info *)((void *)nlh + EHPROBE_NLMSG_HDRLEN);
    uint8_t sa_flags = BPF_CORE_READ(info_ptr, flags);
    if (!(sa_flags & EHPROBE_XFRM_STATE_ESN)) {
        return 0;
    }

    // Extract algo names for forensic telemetry.  Name buffers live in
    // a per-CPU scratch map to keep the BPF stack under 512 bytes.
    u32 scratch_key = 0;
    struct ehprobe_xfrm_sa_scratch *scratch =
        bpf_map_lookup_elem(&ehprobe_xfrm_sa_scratch_map, &scratch_key);
    if (!scratch) {
        return 0;
    }
    __builtin_memset(scratch, 0, sizeof(*scratch));
    uint32_t aead_len = 0, auth_len = 0, crypt_len = 0;

    // For each attribute: the `bpf_probe_read_kernel` reads the
    // pointer slot out of `attrs[id]`, which returns 0 (success) even
    // when the slot itself is NULL because the attribute wasn't in
    // the message.  A NULL check on `attr` is required before we can
    // safely dereference it in `read_xfrm_alg_name`.
    struct nlattr *attr;
    if (bpf_probe_read_kernel(&attr, sizeof(attr),
                              &attrs[EHPROBE_XFRMA_ALG_AEAD]) == 0 && attr) {
        aead_len = read_xfrm_alg_name(attr, scratch->aead_name,
                                      sizeof(scratch->aead_name));
    }
    // XFRMA_ALG_AUTH (xfrm_algo) and XFRMA_ALG_AUTH_TRUNC (xfrm_algo_auth)
    // both place alg_name[64] at offset 0 of their attribute data — we can
    // read either into the same buffer.  The published Dirty Frag ESP
    // exploit uses AUTH_TRUNC exclusively; legacy configurations may use
    // AUTH.  Prefer AUTH_TRUNC when both are present (it's the modern form).
    if (bpf_probe_read_kernel(&attr, sizeof(attr),
                              &attrs[EHPROBE_XFRMA_ALG_AUTH_TRUNC]) == 0 && attr) {
        auth_len = read_xfrm_alg_name(attr, scratch->auth_name,
                                      sizeof(scratch->auth_name));
    }
    if (auth_len == 0 &&
        bpf_probe_read_kernel(&attr, sizeof(attr),
                              &attrs[EHPROBE_XFRMA_ALG_AUTH]) == 0 && attr) {
        auth_len = read_xfrm_alg_name(attr, scratch->auth_name,
                                      sizeof(scratch->auth_name));
    }
    if (bpf_probe_read_kernel(&attr, sizeof(attr),
                              &attrs[EHPROBE_XFRMA_ALG_CRYPT]) == 0 && attr) {
        crypt_len = read_xfrm_alg_name(attr, scratch->crypt_name,
                                       sizeof(scratch->crypt_name));
    }

    uint64_t user_ns_inum = current_netns_user_ns_inum(task);

    (void)ehprobe_xfrm_sa_new(
        user_ns_inum,
        (uint32_t)sa_flags,
        aead_len  > 0 ? scratch->aead_name  : NULL, aead_len,
        auth_len  > 0 ? scratch->auth_name  : NULL, auth_len,
        crypt_len > 0 ? scratch->crypt_name : NULL, crypt_len,
        block_mode
    );

    if (block_mode == EHPROBE_BLOCKING_MODE_ENFORCE) {
        trace_log("EHPROBE_XFRM_ADD_SA: killing offender (pid=%d userns=%llu)",
                  bpf_get_current_pid_tgid() >> 32, user_ns_inum);
        bpf_send_signal(SIGKILL);
    }

    return 0;
}
