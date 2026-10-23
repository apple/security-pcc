// SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause
#pragma once

#include <ehprobe_common.h>
#include <container_logic.h>

#define AF_INET     2
#define AF_INET6    10
#define bpf_ntohs(x) __builtin_bswap16(x)

#define NET_DIRECTION_OUTBOUND  1
#define NET_DIRECTION_INBOUND   2

// ICMP type constants
#define ICMP_TYPE_ECHO_REPLY   0
#define ICMP_TYPE_ECHO_REQUEST 8

// DNS constants
#define DNS_PORT 53
#define DNS_MAX_PAYLOAD 128  // Reduced to help verifier - captures most DNS queries
#define DNS_HEADER_SIZE 12

#define DNS_DIRECTION_QUERY    1
#define DNS_DIRECTION_RESPONSE 2

// DNS pending receive info (for recvfrom/recvmsg exit handlers)
struct dns_pending_recv {
    u64 buf_ptr;           // Pointer to receive buffer
    u64 sockaddr_ptr;      // Pointer to sockaddr (source address)
    u32 buf_len;           // Buffer length
    u16 local_port;        // Local port
    u16 pad;
};

// Helper to get remote port from sockaddr
static __always_inline u16 get_remote_port_from_sockaddr(struct sockaddr_in6 *sa, u16 family) {
    if (family == AF_INET) {
        struct sockaddr_in *sa4 = (struct sockaddr_in *)sa;
        return bpf_ntohs(sa4->sin_port);
    } else {
        return bpf_ntohs(sa->sin6_port);
    }
}

// Helper to get local port from socket via fd
// Returns 0 if unable to determine (which is valid for unbound sockets)
static __always_inline u16 get_local_port_from_fd(struct task_struct *task, int fd) {
    // Get the files struct
    struct files_struct *files = BPF_CORE_READ(task, files);
    if (!files) {
        return 0;
    }

    // Get the fdtable
    struct fdtable *fdt = BPF_CORE_READ(files, fdt);
    if (!fdt) {
        return 0;
    }

    // Get the file pointer array
    struct file **fd_array = BPF_CORE_READ(fdt, fd);
    if (!fd_array) {
        return 0;
    }

    // Bounds check - get max_fds
    unsigned int max_fds = BPF_CORE_READ(fdt, max_fds);
    if (fd < 0 || (unsigned int)fd >= max_fds) {
        return 0;
    }

    // Get the file struct for this fd
    struct file *file = NULL;
    if (bpf_probe_read_kernel(&file, sizeof(file), &fd_array[fd]) < 0 || !file) {
        return 0;
    }

    // Get private_data which points to struct socket for socket files
    void *private_data = BPF_CORE_READ(file, private_data);
    if (!private_data) {
        return 0;
    }

    // Cast to socket and get sock
    struct socket *socket = (struct socket *)private_data;
    struct sock *sk = BPF_CORE_READ(socket, sk);
    if (!sk) {
        return 0;
    }

    // Read the local port (in network byte order in __sk_common.skc_num)
    // skc_num is already in host byte order
    u16 local_port = BPF_CORE_READ(sk, __sk_common.skc_num);
    
    return local_port;
}

// DNS event emission helper
static __always_inline int ehprobe_dns(
    struct task_struct *task,
    struct sockaddr_in6 *sa,
    u16 family,
    void *payload_ptr,
    u32 payload_len,
    u8 direction,
    uint64_t container_id,
    uint32_t container_level
) {
    u32 pid = BPF_CORE_READ(task, tgid);

    // Start event with 11 parameters
    struct event_context *evt_ctx = start_event(EVENT_TYPE_DNS, 11);
    if (!evt_ctx) {
        trace_log("EHPROBE_DNS: ERROR - start_event failed");
        update_drop_stats(EVENT_TYPE_DNS);
        return -1;
    }

    // Parameter 0: pid
    if (push_param_s64(evt_ctx, (int64_t)pid) < 0) {
        trace_log("EHPROBE_DNS: ERROR - push_param_s64 failed for pid");
        goto error;
    }

    // Parameter 1: comm
    if (push_param_string(evt_ctx, (const char *)task->comm, TASK_COMM_LEN, 1) < 0) {
        trace_log("EHPROBE_DNS: ERROR - push_param_string failed for comm");
        goto error;
    }

    // Parameter 2: uid
    // Use BPF_CORE_READ_INTO when reading through `task->cred` (a const pointer);
    // BPF_CORE_READ would declare a const temporary without an initializer and
    // trip clang's -Wdefault-const-init-var-unsafe. Same pattern below.
    uint32_t uid = 0;
    BPF_CORE_READ_INTO(&uid, task, cred, uid.val);
    if (push_param_u32(evt_ctx, uid) < 0) {
        trace_log("EHPROBE_DNS: ERROR - push_param_u32 failed for uid");
        goto error;
    }

    // Parameter 3: direction (query=1, response=2)
    if (push_param_u32(evt_ctx, (uint32_t)direction) < 0) {
        trace_log("EHPROBE_DNS: ERROR - push_param_u32 failed for direction");
        goto error;
    }

    // Parameter 4: dns_server_addr (remote address for query, source for response)
    if (family == AF_INET) {
        struct sockaddr_in *sa4 = (struct sockaddr_in *)sa;
        if (push_param_bytebuf(evt_ctx, (const unsigned char *)&sa4->sin_addr, 4, 1) < 0) {
            trace_log("EHPROBE_DNS: ERROR - push_param_bytebuf failed for addr v4");
            goto error;
        }
    } else {
        if (push_param_bytebuf(evt_ctx, (const unsigned char *)&sa->sin6_addr, 16, 1) < 0) {
            trace_log("EHPROBE_DNS: ERROR - push_param_bytebuf failed for addr v6");
            goto error;
        }
    }

    // Parameter 5: dns_server_port
    u16 port = get_remote_port_from_sockaddr(sa, family);
    if (push_param_u32(evt_ctx, (uint32_t)port) < 0) {
        trace_log("EHPROBE_DNS: ERROR - push_param_u32 failed for port");
        goto error;
    }

    // Parameter 6: family
    if (push_param_u32(evt_ctx, (uint32_t)family) < 0) {
        trace_log("EHPROBE_DNS: ERROR - push_param_u32 failed for family");
        goto error;
    }

    // Parameter 7: dns_payload (raw DNS packet, up to DNS_MAX_PAYLOAD bytes)
    unsigned char dns_buf[DNS_MAX_PAYLOAD];
    __builtin_memset(dns_buf, 0, sizeof(dns_buf));
    
    u16 capture_len = 0;
    if (payload_ptr != NULL && payload_len > 0) {
        // Cap at DNS_MAX_PAYLOAD
        capture_len = (u16)payload_len;
        if (capture_len > DNS_MAX_PAYLOAD) {
            capture_len = DNS_MAX_PAYLOAD;
        }
        
        // Read the payload with fixed size to satisfy verifier
        // We read DNS_MAX_PAYLOAD bytes but only use capture_len
        long read_ret = bpf_probe_read_user(dns_buf, DNS_MAX_PAYLOAD, payload_ptr);
        if (read_ret < 0) {
            trace_log("EHPROBE_DNS: WARNING - failed to read payload, ret=%ld", read_ret);
            capture_len = 0;
        }
    }
    
    // Push the captured payload with the actual capture length
    if (push_param_bytebuf(evt_ctx, dns_buf, capture_len, 1) < 0) {
        trace_log("EHPROBE_DNS: ERROR - push_param_bytebuf failed for payload");
        goto error;
    }

    // Parameter 8: payload_len (original length, may be larger than captured)
    if (push_param_u32(evt_ctx, payload_len) < 0) {
        trace_log("EHPROBE_DNS: ERROR - push_param_u32 failed for payload_len");
        goto error;
    }

    // Parameter 9: container_id
    if (push_param_u64(evt_ctx, container_id) < 0) {
        trace_log("EHPROBE_DNS: ERROR - push_param_u64 failed for container_id");
        goto error;
    }

    // Parameter 10: container_level
    if (push_param_u32(evt_ctx, container_level) < 0) {
        trace_log("EHPROBE_DNS: ERROR - push_param_u32 failed for container_level");
        goto error;
    }

    trace_log("EHPROBE_DNS: submitting event, direction=%u, port=%u, payload_len=%u",
              direction, port, payload_len);
    return submit_event(evt_ctx);

error:
    trace_log("EHPROBE_DNS: ERROR - dropping event");
    release_event(evt_ctx);
    update_drop_stats(EVENT_TYPE_DNS);
    return -1;
}

static __always_inline int ehprobe_net_tcp(
    struct task_struct *task,
    int fd,
    struct sockaddr_in6 *sa,
    u16 family,
    u16 local_port,
    u8 direction,
    uint64_t container_id,
    uint32_t container_level
) {
    // Start event with 11 parameters (added local_port)
    struct event_context *evt_ctx = start_event(EVENT_TYPE_NET_TCP, 11);
    if (!evt_ctx) {
        trace_log("EHPROBE_NET_TCP: ERROR - start_event failed");
        update_drop_stats(EVENT_TYPE_NET_TCP);
        return -1;
    }

    // Parameter 0: pid
    int64_t pid = (int64_t)BPF_CORE_READ(task, tgid);
    if (push_param_s64(evt_ctx, pid) < 0) {
        trace_log("EHPROBE_NET_TCP: ERROR - push_param_s64 failed for pid");
        goto error;
    }

    // Parameter 1: comm
    if (push_param_string(evt_ctx, (const char *)task->comm, TASK_COMM_LEN, 1) < 0) {
        trace_log("EHPROBE_NET_TCP: ERROR - push_param_string failed for comm");
        goto error;
    }

    // Parameter 2: fd
    if (push_param_s64(evt_ctx, (int64_t)fd) < 0) {
        trace_log("EHPROBE_NET_TCP: ERROR - push_param_s64 failed for fd");
        goto error;
    }

    // Parameter 3: family (AF_INET=2, AF_INET6=10)
    if (push_param_u32(evt_ctx, (uint32_t)family) < 0) {
        trace_log("EHPROBE_NET_TCP: ERROR - push_param_u32 failed for family");
        goto error;
    }

    // Parameter 4: remote_addr (4 bytes for IPv4, 16 bytes for IPv6)
    if (family == AF_INET) {
        struct sockaddr_in *sa4 = (struct sockaddr_in *)sa;
        if (push_param_bytebuf(evt_ctx, (const unsigned char *)&sa4->sin_addr, 4, 1) < 0) {
            trace_log("EHPROBE_NET_TCP: ERROR - push_param_bytebuf failed for remote_addr v4");
            goto error;
        }
    } else {
        if (push_param_bytebuf(evt_ctx, (const unsigned char *)&sa->sin6_addr, 16, 1) < 0) {
            trace_log("EHPROBE_NET_TCP: ERROR - push_param_bytebuf failed for remote_addr v6");
            goto error;
        }
    }

    // Parameter 5: remote_port
    u16 remote_port = (family == AF_INET)
        ? ((struct sockaddr_in *)sa)->sin_port
        : sa->sin6_port;
    if (push_param_u32(evt_ctx, (uint32_t)bpf_ntohs(remote_port)) < 0) {
        trace_log("EHPROBE_NET_TCP: ERROR - push_param_u32 failed for remote_port");
        goto error;
    }

    // Parameter 6: local_port
    if (push_param_u32(evt_ctx, (uint32_t)local_port) < 0) {
        trace_log("EHPROBE_NET_TCP: ERROR - push_param_u32 failed for local_port");
        goto error;
    }

    // Parameter 7: direction (1=outbound, 2=inbound)
    if (push_param_u32(evt_ctx, (uint32_t)direction) < 0) {
        trace_log("EHPROBE_NET_TCP: ERROR - push_param_u32 failed for direction");
        goto error;
    }

    // Parameter 8: uid
    uint32_t uid = 0;
    BPF_CORE_READ_INTO(&uid, task, cred, uid.val);
    if (push_param_u32(evt_ctx, uid) < 0) {
        trace_log("EHPROBE_NET_TCP: ERROR - push_param_u32 failed for uid");
        goto error;
    }

    // Parameter 9: container_id
    if (push_param_u64(evt_ctx, container_id) < 0) {
        trace_log("EHPROBE_NET_TCP: ERROR - push_param_u64 failed for container_id");
        goto error;
    }

    // Parameter 10: container_level
    if (push_param_u32(evt_ctx, container_level) < 0) {
        trace_log("EHPROBE_NET_TCP: ERROR - push_param_u32 failed for container_level");
        goto error;
    }

    trace_log("EHPROBE_NET_TCP: submitting event, pid=%lld, remote_port=%u, local_port=%u", 
              pid, bpf_ntohs(remote_port), local_port);
    return submit_event(evt_ctx);

error:
    trace_log("EHPROBE_NET_TCP: ERROR - dropping event");
    release_event(evt_ctx);
    update_drop_stats(EVENT_TYPE_NET_TCP);
    return -1;
}

static __always_inline int ehprobe_net_udp(
    struct task_struct *task,
    struct sockaddr_in6 *sa,
    u16 family,
    u16 local_port,
    u8 initiator,
    uint64_t container_id,
    uint32_t container_level
) {
    u32 pid = BPF_CORE_READ(task, tgid);
    u16 port;
    
    // Build cache key
    struct udp_session_key key = {};
    key.pid = pid;
    key.family = family;
    
    if (family == AF_INET) {
        struct sockaddr_in *sa4 = (struct sockaddr_in *)sa;
        key.addr4 = sa4->sin_addr.s_addr;
        port = bpf_ntohs(sa4->sin_port);
    } else {
        __builtin_memcpy(key.addr6, &sa->sin6_addr, 16);
        port = bpf_ntohs(sa->sin6_port);
    }
    key.port = port;
    
    // Check if session exists in cache
    struct udp_session_value *existing = bpf_map_lookup_elem(&udp_session_cache, &key);
    if (existing) {
        // Session already tracked, skip event
        return 0;
    }
    
    // New session - add to cache
    struct udp_session_value new_value = {};
    new_value.first_seen_ns = bpf_ktime_get_ns();
    new_value.initiator = initiator;
    
    bpf_map_update_elem(&udp_session_cache, &key, &new_value, BPF_ANY);
    
    // Start event with 10 parameters
    struct event_context *evt_ctx = start_event(EVENT_TYPE_NET_UDP, 10);
    if (!evt_ctx) {
        trace_log("EHPROBE_NET_UDP: ERROR - start_event failed");
        update_drop_stats(EVENT_TYPE_NET_UDP);
        return -1;
    }

    // Parameter 0: pid
    if (push_param_s64(evt_ctx, (int64_t)pid) < 0) {
        trace_log("EHPROBE_NET_UDP: ERROR - push_param_s64 failed for pid");
        goto error;
    }

    // Parameter 1: comm
    if (push_param_string(evt_ctx, (const char *)task->comm, TASK_COMM_LEN, 1) < 0) {
        trace_log("EHPROBE_NET_UDP: ERROR - push_param_string failed for comm");
        goto error;
    }

    // Parameter 2: family (AF_INET=2, AF_INET6=10)
    if (push_param_u32(evt_ctx, (uint32_t)family) < 0) {
        trace_log("EHPROBE_NET_UDP: ERROR - push_param_u32 failed for family");
        goto error;
    }

    // Parameter 3: remote_addr (4 bytes for IPv4, 16 bytes for IPv6)
    if (family == AF_INET) {
        struct sockaddr_in *sa4 = (struct sockaddr_in *)sa;
        if (push_param_bytebuf(evt_ctx, (const unsigned char *)&sa4->sin_addr, 4, 1) < 0) {
            trace_log("EHPROBE_NET_UDP: ERROR - push_param_bytebuf failed for remote_addr v4");
            goto error;
        }
    } else {
        if (push_param_bytebuf(evt_ctx, (const unsigned char *)&sa->sin6_addr, 16, 1) < 0) {
            trace_log("EHPROBE_NET_UDP: ERROR - push_param_bytebuf failed for remote_addr v6");
            goto error;
        }
    }

    // Parameter 4: remote_port
    if (push_param_u32(evt_ctx, (uint32_t)port) < 0) {
        trace_log("EHPROBE_NET_UDP: ERROR - push_param_u32 failed for remote_port");
        goto error;
    }

    // Parameter 5: local_port
    if (push_param_u32(evt_ctx, (uint32_t)local_port) < 0) {
        trace_log("EHPROBE_NET_UDP: ERROR - push_param_u32 failed for local_port");
        goto error;
    }

    // Parameter 6: initiator (1=outbound, 2=inbound)
    if (push_param_u32(evt_ctx, (uint32_t)initiator) < 0) {
        trace_log("EHPROBE_NET_UDP: ERROR - push_param_u32 failed for initiator");
        goto error;
    }

    // Parameter 7: uid
    uint32_t uid = 0;
    BPF_CORE_READ_INTO(&uid, task, cred, uid.val);
    if (push_param_u32(evt_ctx, uid) < 0) {
        trace_log("EHPROBE_NET_UDP: ERROR - push_param_u32 failed for uid");
        goto error;
    }

    // Parameter 8: container_id
    if (push_param_u64(evt_ctx, container_id) < 0) {
        trace_log("EHPROBE_NET_UDP: ERROR - push_param_u64 failed for container_id");
        goto error;
    }

    // Parameter 9: container_level
    if (push_param_u32(evt_ctx, container_level) < 0) {
        trace_log("EHPROBE_NET_UDP: ERROR - push_param_u32 failed for container_level");
        goto error;
    }

    trace_log("EHPROBE_NET_UDP: submitting event, pid=%u, port=%u, local_port=%u",
        pid, bpf_ntohs(port), local_port);
    return submit_event(evt_ctx);

error:
    trace_log("EHPROBE_NET_UDP: ERROR - dropping event");
    release_event(evt_ctx);
    update_drop_stats(EVENT_TYPE_NET_UDP);
    return -1;
}

static __always_inline int ehprobe_net_icmp(
    struct task_struct *task,
    struct sockaddr_in6 *sa,
    u16 family,
    u8 icmp_type,
    u8 icmp_code,
    u16 identifier,
    u16 sequence,
    uint64_t container_id,
    uint32_t container_level
) {
    u32 pid = BPF_CORE_READ(task, tgid);

    // Start event with 11 parameters:
    // pid, comm, uid, icmp_type, icmp_code, identifier, sequence, family, remote_addr, container_id, container_level
    struct event_context *evt_ctx = start_event(EVENT_TYPE_NET_ICMP, 11);
    if (!evt_ctx) {
        trace_log("EHPROBE_NET_ICMP: ERROR - start_event failed");
        update_drop_stats(EVENT_TYPE_NET_ICMP);
        return -1;
    }

    // Parameter 0: pid
    if (push_param_s64(evt_ctx, (int64_t)pid) < 0) {
        trace_log("EHPROBE_NET_ICMP: ERROR - push_param_s64 failed for pid");
        goto error;
    }

    // Parameter 1: comm
    if (push_param_string(evt_ctx, (const char *)task->comm, TASK_COMM_LEN, 1) < 0) {
        trace_log("EHPROBE_NET_ICMP: ERROR - push_param_string failed for comm");
        goto error;
    }

    // Parameter 2: uid
    uint32_t uid = 0;
    BPF_CORE_READ_INTO(&uid, task, cred, uid.val);
    if (push_param_u32(evt_ctx, uid) < 0) {
        trace_log("EHPROBE_NET_ICMP: ERROR - push_param_u32 failed for uid");
        goto error;
    }

    // Parameter 3: icmp_type
    if (push_param_u32(evt_ctx, (uint32_t)icmp_type) < 0) {
        trace_log("EHPROBE_NET_ICMP: ERROR - push_param_u32 failed for icmp_type");
        goto error;
    }

    // Parameter 4: icmp_code
    if (push_param_u32(evt_ctx, (uint32_t)icmp_code) < 0) {
        trace_log("EHPROBE_NET_ICMP: ERROR - push_param_u32 failed for icmp_code");
        goto error;
    }

    // Parameter 5: identifier
    if (push_param_u32(evt_ctx, (uint32_t)identifier) < 0) {
        trace_log("EHPROBE_NET_ICMP: ERROR - push_param_u32 failed for identifier");
        goto error;
    }

    // Parameter 6: sequence
    if (push_param_u32(evt_ctx, (uint32_t)sequence) < 0) {
        trace_log("EHPROBE_NET_ICMP: ERROR - push_param_u32 failed for sequence");
        goto error;
    }

    // Parameter 7: family
    if (push_param_u32(evt_ctx, (uint32_t)family) < 0) {
        trace_log("EHPROBE_NET_ICMP: ERROR - push_param_u32 failed for family");
        goto error;
    }

    // Parameter 8: remote_addr (4 bytes for IPv4, 16 bytes for IPv6)
    if (family == AF_INET) {
        struct sockaddr_in *sa4 = (struct sockaddr_in *)sa;
        if (push_param_bytebuf(evt_ctx, (const unsigned char *)&sa4->sin_addr, 4, 1) < 0) {
            trace_log("EHPROBE_NET_ICMP: ERROR - push_param_bytebuf failed for remote_addr v4");
            goto error;
        }
    } else {
        if (push_param_bytebuf(evt_ctx, (const unsigned char *)&sa->sin6_addr, 16, 1) < 0) {
            trace_log("EHPROBE_NET_ICMP: ERROR - push_param_bytebuf failed for remote_addr v6");
            goto error;
        }
    }

    // Parameter 9: container_id
    if (push_param_u64(evt_ctx, container_id) < 0) {
        trace_log("EHPROBE_NET_ICMP: ERROR - push_param_u64 failed for container_id");
        goto error;
    }

    // Parameter 10: container_level
    if (push_param_u32(evt_ctx, container_level) < 0) {
        trace_log("EHPROBE_NET_ICMP: ERROR - push_param_u32 failed for container_level");
        goto error;
    }

    trace_log("EHPROBE_NET_ICMP: submitting event, pid=%u, type=%u, code=%u",
              pid, icmp_type, icmp_code);
    return submit_event(evt_ctx);

error:
    trace_log("EHPROBE_NET_ICMP: ERROR - dropping event");
    release_event(evt_ctx);
    update_drop_stats(EVENT_TYPE_NET_ICMP);
    return -1;
}
