// SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause
// handle_tcp_sendmsg.bpf.c - TCP send payload capture for DPI classification
#include <ehprobe_common.h>
#include <network_events.h>
#include <dpi_events.h>

char LICENSE[] SEC("license") = "Dual BSD/GPL";

// iov_iter type constants from kernel BTF (linux/uio.h)
#define ITER_UBUF  0
#define ITER_IOVEC 1

// CO-RE flavor for pre-6.4 kernels, where struct iov_iter had a direct
// 'iov' field (not inside the unnamed union that introduced '__iov' in 6.4).
// Using a ___ flavor lets us reference the old field name at compile time
// even when the build-time vmlinux.h only describes the newer layout.
struct iov_iter___pre64 {
    const struct iovec *iov;
} __attribute__((preserve_access_index));

SEC("kprobe/tcp_sendmsg")
int BPF_KPROBE(handle_kprobe_tcp_sendmsg,
               struct sock *sk,
               struct msghdr *msg,
               size_t size)
{
    u32 map_key = 0;
    struct ehprobe_env *env = bpf_map_lookup_elem(&ehprobe_env_map, &map_key);
    if (!env || !env->flag_dpi) {
        return 0;
    }

    if (!sk || !msg || size == 0) {
        return 0;
    }

    struct task_struct *task = bpf_get_current_task_btf();

    u16 family = BPF_CORE_READ(sk, __sk_common.skc_family);
    if (family != AF_INET && family != AF_INET6) {
        return 0;
    }

    u16 remote_port = bpf_ntohs(BPF_CORE_READ(sk, __sk_common.skc_dport));
    u16 local_port = BPF_CORE_READ(sk, __sk_common.skc_num);

    uint32_t container_level = 0;
    uint64_t container_id = get_container_id(task, &container_level);

    // Read payload from msghdr iov_iter.
    // On kernel 6.x, simple read/write uses ITER_UBUF (single buffer) instead
    // of ITER_IOVEC (scatter/gather).  Handle both cases.
    // NOTE: payload_ptr is a user-space pointer. ehprobe_packet_data() uses
    // bpf_probe_read_user() to safely copy the payload from user memory.
    void *payload_ptr = NULL;
    uint32_t payload_len = 0;

    u8 iter_type = BPF_CORE_READ(msg, msg_iter.iter_type);
    // ITER_UBUF and __ubuf_iovec were added in Linux 6.0. Guard the field
    // access with bpf_core_field_exists() so the CO-RE relocation is dead-
    // code-eliminated on older kernels (e.g. RHEL 9.x on 5.14).
    if (bpf_core_field_exists(msg->msg_iter.__ubuf_iovec) && iter_type == ITER_UBUF) {
        // Single user buffer — read from __ubuf_iovec
        struct iovec ubuf_iov = {};
        bpf_probe_read_kernel(&ubuf_iov, sizeof(ubuf_iov),
                              &msg->msg_iter.__ubuf_iovec);
        if (ubuf_iov.iov_base && ubuf_iov.iov_len > 0) {
            payload_ptr = ubuf_iov.iov_base;
            payload_len = (uint32_t)ubuf_iov.iov_len;
        }
    } else if (iter_type == ITER_IOVEC) {
        // Scatter/gather — read first iovec from iov array.
        // In Linux 6.4 the field was renamed from iov to __iov (moved into a
        // union). Guard with bpf_core_field_exists() so the correct name is
        // used on the target kernel.
        const struct iovec *iov = NULL;
        if (bpf_core_field_exists(msg->msg_iter.__iov)) {
            iov = BPF_CORE_READ(msg, msg_iter.__iov);
        } else {
            struct iov_iter___pre64 *old_iter =
                (struct iov_iter___pre64 *)&msg->msg_iter;
            iov = BPF_CORE_READ(old_iter, iov);
        }
        if (iov) {
            struct iovec first_iov = {};
            bpf_probe_read_kernel(&first_iov, sizeof(first_iov), iov);
            if (first_iov.iov_base && first_iov.iov_len > 0) {
                payload_ptr = first_iov.iov_base;
                payload_len = (uint32_t)first_iov.iov_len;
            }
        }
    }
    // Other iter types (ITER_BVEC, ITER_KVEC, etc.) are not supported — skip

    // Read interface index from the socket.
    // sk_rx_dst_ifindex tracks the inbound route and may be 0 for outbound;
    // sk_bound_dev_if is set when the socket is bound to a specific device.
    // Use whichever is non-zero.
    int ifindex = BPF_CORE_READ(sk, sk_rx_dst_ifindex);
    if (ifindex == 0) {
        ifindex = BPF_CORE_READ(sk, __sk_common.skc_bound_dev_if);
    }

    if (family == AF_INET) {
        u32 daddr = BPF_CORE_READ(sk, __sk_common.skc_daddr);
        int dpi_err = ehprobe_packet_data(task, &daddr, family, 6,
                           remote_port, local_port,
                           NET_DIRECTION_OUTBOUND, (uint32_t)ifindex,
                           payload_ptr, payload_len,
                           container_id, container_level);
        if (dpi_err < 0) {
            trace_log("EHPROBE_NET_TCP_SENDMSG: ehprobe_packet_data failed ret=%d", dpi_err);
        }
    } else {
        struct in6_addr daddr6 = BPF_CORE_READ(sk, __sk_common.skc_v6_daddr);
        int dpi_err = ehprobe_packet_data(task, &daddr6, family, 6,
                           remote_port, local_port,
                           NET_DIRECTION_OUTBOUND, (uint32_t)ifindex,
                           payload_ptr, payload_len,
                           container_id, container_level);
        if (dpi_err < 0) {
            trace_log("EHPROBE_NET_TCP_SENDMSG: ehprobe_packet_data failed ret=%d", dpi_err);
        }
    }

    return 0;
}
