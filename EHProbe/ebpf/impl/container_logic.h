// SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause

#pragma once

#include "ehprobe_common.h"

struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 1);
    __type(key, u32);
    __type(value, struct container_entry);
} local_container_map __weak SEC(".maps");

static __always_inline int ehprobe_container_exec(struct file *file) {
    pid_t pid = bpf_get_current_pid_tgid() >> 32;
    pid_t tgid = (pid_t)bpf_get_current_pid_tgid();

    // Get current task
    struct task_struct *task = (struct task_struct *)bpf_get_current_task_btf();
    if (!task) {
        trace_log("EHPROBE_CONTAINER_EXEC: unable to get task");
        return -1;
    }

    // Get the parent task
    struct task_struct *parent = BPF_CORE_READ(task, real_parent);
    if (!parent) {
        trace_log("EHPROBE_CONTAINER_EXEC: unable to get task parent");
        return -1;
    }

    pid_t ppid = BPF_CORE_READ(parent, pid);

    trace_log("EHPROBE_CONTAINER_EXEC: hook entered, PID %d, PPID %d", pid, ppid);

    // Read current process command name
    struct container_runtime_binary current_comm = {};
    BPF_CORE_READ_STR_INTO(&current_comm.comm, task, comm);
    
    // Read parent process command name
    struct container_runtime_binary parent_comm = {};
    BPF_CORE_READ_STR_INTO(&parent_comm.comm, parent, comm);

    trace_log("EHPROBE_CONTAINER_EXEC: comm: %s, parent comm: %s", current_comm.comm, parent_comm.comm);

    // Get namespace information
    struct nsproxy *nsproxy = BPF_CORE_READ(task, nsproxy);
    struct nsproxy *parent_nsproxy = BPF_CORE_READ(parent, nsproxy);
    
    if (!nsproxy || !parent_nsproxy) {
        trace_log("EHPROBE_CONTAINER_EXEC: Failed to read nsproxy");
        return -1;
    }

    // Read all namespace pointers
    struct mnt_namespace *mnt_ns = BPF_CORE_READ(nsproxy, mnt_ns);
    struct pid_namespace *pid_ns = BPF_CORE_READ(nsproxy, pid_ns_for_children);
    struct net *net_ns = BPF_CORE_READ(nsproxy, net_ns);
    struct uts_namespace *uts_ns = BPF_CORE_READ(nsproxy, uts_ns);
    struct ipc_namespace *ipc_ns = BPF_CORE_READ(nsproxy, ipc_ns);
    
    struct mnt_namespace *parent_mnt_ns = BPF_CORE_READ(parent_nsproxy, mnt_ns);
    struct pid_namespace *parent_pid_ns = BPF_CORE_READ(parent_nsproxy, pid_ns_for_children);
    struct net *parent_net_ns = BPF_CORE_READ(parent_nsproxy, net_ns);

    if (!mnt_ns || !parent_mnt_ns || !pid_ns || !parent_pid_ns || !net_ns || !parent_net_ns) {
        trace_log("EHPROBE_CONTAINER_EXEC: Failed to read namespace pointers");
        return -1;
    }

    // Get namespace inums
    u64 mnt_ns_inum = BPF_CORE_READ(mnt_ns, ns.inum);
    u64 parent_mnt_ns_inum = BPF_CORE_READ(parent_mnt_ns, ns.inum);
    
    u64 pid_ns_inum = BPF_CORE_READ(pid_ns, ns.inum);
    u64 parent_pid_ns_inum = BPF_CORE_READ(parent_pid_ns, ns.inum);
    
    u64 net_ns_inum = BPF_CORE_READ(net_ns, ns.inum);
    u64 parent_net_ns_inum = BPF_CORE_READ(parent_net_ns, ns.inum);
    
    u64 cgroup_id = bpf_get_current_cgroup_id();

    // Check if we have new namespaces (indicating container creation)
    bool has_new_mnt_ns = (mnt_ns_inum != parent_mnt_ns_inum);
    bool has_new_pid_ns = (pid_ns_inum != parent_pid_ns_inum);
    bool has_new_net_ns = (net_ns_inum != parent_net_ns_inum);

    // A new container typically has at least mount and PID namespaces different
    if (!has_new_mnt_ns || !has_new_pid_ns && (has_new_mnt_ns || has_new_pid_ns || has_new_net_ns)) {
        trace_log("EHPROBE_CONTAINER_EXEC: Partial namespace isolation detected");
        return 0;
    }

    trace_log("EHPROBE_CONTAINER_EXEC: *** NEW CONTAINER DETECTED ***");
    trace_log("EHPROBE_CONTAINER_EXEC: Container PID: %d", pid);
    trace_log("EHPROBE_CONTAINER_EXEC: Runtime: %s", current_comm.comm);
    trace_log("EHPROBE_CONTAINER_EXEC: MNT NS: %llu, PID NS: %llu, NET NS: %llu", 
                mnt_ns_inum, pid_ns_inum, net_ns_inum);
    
    // Check if this process is PID 1 in its namespace
    struct pid *pid_struct = BPF_CORE_READ(task, thread_pid);
    int ns_pid = 0;
    uint32_t level = 0;
    if (pid_struct) {
        level = BPF_CORE_READ(pid_struct, level);
        if (level >= 0) {
            ns_pid = BPF_CORE_READ(pid_struct, numbers[level].nr);
            trace_log("EHPROBE_CONTAINER_EXEC: PID in namespace: %d, level: %d", ns_pid, level);
        }
    }
    
    // Check if this container already exists in our map
    struct container_entry *existing = bpf_map_lookup_elem(&containers_map, &pid_ns_inum);
    if (existing) {
        trace_log("EHPROBE_CONTAINER_EXEC: Container already exists in map (PID NS: %llu)", pid_ns_inum);
        return 0;
    }

    // Prepare container entry for the map
    u32 map_key = 0;
    struct container_entry *container = bpf_map_lookup_elem(&local_container_map, &map_key);
    if (!container) {
        trace_log("EHPROBE_CONTAINER_EXEC: Failed to get temp container buffer - allowing");
        return -1;
    }
    
    __builtin_memcpy(container->runtime_type, current_comm.comm, sizeof(current_comm.comm));

    container->id = pid_ns_inum;
    container->level = level;
    container->pid = pid;
    container->ppid = ppid;
    container->mnt_ns_inum = mnt_ns_inum;
    container->pid_ns_inum = pid_ns_inum;
    container->cgroup_id = cgroup_id;
    container->start_time_ns = bpf_ktime_get_ns();
    container->blocking_mode = EHPROBE_BLOCKING_MODE_OFF;
    
    // Store in containers map using PID namespace inode as key
    int ret = bpf_map_update_elem(&containers_map, &pid_ns_inum, container, BPF_NOEXIST);
    if (ret != 0) {
        trace_log("EHPROBE_CONTAINER_EXEC: Failed to store container in map, ret: %d", ret);
        return -1;
    }

    trace_log("EHPROBE_CONTAINER_EXEC: *** CONTAINER STORED IN MAP for PID %d ***", pid);
    trace_log("EHPROBE_CONTAINER_EXEC: Key (PID NS): %llu", pid_ns_inum);
    trace_log("EHPROBE_CONTAINER_EXEC: Cgroup ID: %llu", container->cgroup_id);
    trace_log("EHPROBE_CONTAINER_EXEC: Start time: %llu", bpf_ktime_get_ns());
    
    if (ns_pid == 1) {
        trace_log("EHPROBE_CONTAINER_EXEC: *** CONFIRMED: Container init process (PID 1) ***");
    }
    
    // Send event using ehprobe API
    // Note: You'll need to define EVENT_TYPE_CONTAINER_START in events.h
    struct event_context *evt_ctx = start_event(EVENT_TYPE_CONTAINER_START, 10);
    if (!evt_ctx) {
        trace_log("EHPROBE_CONTAINER_EXEC: ERROR - start_event failed");
        update_drop_stats(EVENT_TYPE_CONTAINER_START);
        return 0; // Continue even if event fails
    }

    // Parameter 0: container ID
    if (push_param_u64(evt_ctx, pid_ns_inum) < 0) {
        trace_log("EHPROBE_CONTAINER_EXEC: ERROR - push_param_u64 failed for container_id");
        goto error;
    }

    // Parameter 1: container level
    if (push_param_u32(evt_ctx, level) < 0) {
        trace_log("EHPROBE_CONTAINER_EXEC: ERROR - push_param_u32 failed for level");
        goto error;
    }

    // Parameter 2: container PID
    if (push_param_s64(evt_ctx, (int64_t)pid) < 0) {
        trace_log("EHPROBE_CONTAINER_EXEC: ERROR - push_param_s64 failed for pid");
        goto error;
    }

    // Parameter 3: ppid
    if (push_param_s64(evt_ctx, (int64_t)ppid) < 0) {
        trace_log("EHPROBE_CONTAINER_EXEC: ERROR - push_param_s64 failed for ppid");
        goto error;
    }

    // Parameter 4: pid_ns_inum
    if (push_param_u64(evt_ctx, pid_ns_inum) < 0) {
        trace_log("EHPROBE_CONTAINER_EXEC: ERROR - push_param_u64 failed for pid_ns_inum");
        goto error;
    }

    // Parameter 5: mnt_ns_inum
    if (push_param_u64(evt_ctx, mnt_ns_inum) < 0) {
        trace_log("EHPROBE_CONTAINER_EXEC: ERROR - push_param_u64 failed for mnt_ns_inum");
        goto error;
    }

    // Parameter 6: net_ns_inum
    if (push_param_u64(evt_ctx, net_ns_inum) < 0) {
        trace_log("EHPROBE_CONTAINER_EXEC: ERROR - push_param_u64 failed for net_ns_inum");
        goto error;
    }

    // Parameter 7: cgroup_id
    if (push_param_u64(evt_ctx, cgroup_id) < 0) {
        trace_log("EHPROBE_CONTAINER_EXEC: ERROR - push_param_u64 failed for cgroup_id");
        goto error;
    }

    // Parameter 8: runtime
    if (push_param_string(evt_ctx, container->runtime_type, sizeof(container->runtime_type), 1) < 0) { // KERNEL space
        trace_log("EHPROBE_CONTAINER_EXEC: ERROR - push_param_string failed for runtime");
        goto error;
    }

    // Parameter 9: blocking_mode
    uint32_t blocking_mode_val = EHPROBE_BLOCKING_MODE_OFF;
    // Get exec blocking mode from config map
    struct ehprobe_env *env = bpf_map_lookup_elem(&ehprobe_env_map, &map_key);
    if (env) {
        blocking_mode_val = (uint32_t)env->blocking_mode;
    }
    if (push_param_u32(evt_ctx, blocking_mode_val) < 0) {
        trace_log("EHPROBE_CONTAINER_EXEC: ERROR - push_param_u32 failed for blocking_mode");
        goto error;
    }

    trace_log("EHPROBE_CONTAINER_EXEC: submitting event");
    submit_event(evt_ctx);
    return 0;

error:
    trace_log("EHPROBE_CONTAINER_EXEC: ERROR - dropping event");
    release_event(evt_ctx);
    update_drop_stats(EVENT_TYPE_CONTAINER_START);
    return 0;
}

static __always_inline int check_container_termination(struct task_struct *task) {
    if (!task) {
        return 0;
    }

    pid_t pid = BPF_CORE_READ(task, pid);
    pid_t tgid = BPF_CORE_READ(task, tgid);

    trace_log("EHPROBE_CONTAINER_EXIT: Task free called for PID %d, TGID %d", pid, tgid);

    // Only process thread group leaders (main processes)
    if (pid != tgid) {
        return 0;
    }

    // Get namespace information
    struct nsproxy *nsproxy = BPF_CORE_READ(task, nsproxy);
    if (!nsproxy) {
        trace_log("EHPROBE_CONTAINER_EXIT: Failed to read nsproxy for PID %d", pid);
        return 0;
    }

    struct pid_namespace *pid_ns = BPF_CORE_READ(nsproxy, pid_ns_for_children);
    if (!pid_ns) {
        trace_log("EHPROBE_CONTAINER_EXIT: Failed to read PID namespace for PID %d", pid);
        return 0;
    }

    u64 pid_ns_inum = BPF_CORE_READ(pid_ns, ns.inum);

    struct mnt_namespace *mnt_ns = BPF_CORE_READ(nsproxy, mnt_ns);
    if (!mnt_ns) {
        trace_log("EHPROBE_CONTAINER_EXIT: Failed to read MNT namespace for PID %d", pid);
        return 0;
    }

    u64 mnt_ns_inum = BPF_CORE_READ(mnt_ns, ns.inum);

	u64 cgroup_id = bpf_get_current_cgroup_id();

    // get global env map
	u32 map_key = 0;
    struct ehprobe_env *env = bpf_map_lookup_elem(&ehprobe_env_map, &map_key);
    if (!env) {
        trace_log("EHPROBE_CONTAINER_EXIT: env not found");
        return 0;
    }

    // checking if running on the host
    if (env->host_pid_ns == pid_ns_inum) {
        trace_log("EHPROBE_CONTAINER_EXIT: PID %d, NS inum %llu - running on the host", pid, pid_ns_inum);
        return 0;
    }

    // Check if this PID namespace corresponds to a tracked container
    struct container_entry *container = bpf_map_lookup_elem(&containers_map, &pid_ns_inum);
    if (!container) {
        trace_log("EHPROBE_CONTAINER_EXIT: tracked container NOT FOUND for PID %d, NS inum %llu", pid, pid_ns_inum);
        return 0;
    }

    trace_log("EHPROBE_CONTAINER_EXIT: Found tracked container for PID %d, NS inum %llu", pid, pid_ns_inum);

    // Check if this is the container's init process (PID 1 in namespace)
    struct pid *pid_struct = BPF_CORE_READ(task, thread_pid);
    if (!pid_struct) {
        trace_log("EHPROBE_CONTAINER_EXIT: Failed to read pid struct for PID %d", pid);
        return 0;
    }

    int level = BPF_CORE_READ(pid_struct, level);
    if (level < 0) {
        trace_log("EHPROBE_CONTAINER_EXIT: Invalid PID level %d for PID %d", level, pid);
        return 0;
    }

    int ns_pid = BPF_CORE_READ(pid_struct, numbers[level].nr);
    
    trace_log("EHPROBE_CONTAINER_EXIT: PID %d has namespace PID %d, level %d", pid, ns_pid, level);

    // Only process container init processes (PID 1 in their namespace)
    if (ns_pid != 1) {
        trace_log("EHPROBE_CONTAINER_EXIT: PID %d is not container init (ns_pid=%d), ignoring", pid, ns_pid);
        return 0;
    }

    trace_log("EHPROBE_CONTAINER_EXIT: *** CONTAINER INIT PROCESS TERMINATING ***");
    trace_log("EHPROBE_CONTAINER_EXIT: Container PID: %d, PID NS: %llu", pid, pid_ns_inum);

    // Get exit information
    int exit_code = BPF_CORE_READ(task, exit_code);
    int exit_signal = BPF_CORE_READ(task, exit_signal);
    
    trace_log("EHPROBE_CONTAINER_EXIT: Exit code: %d, Exit signal: %d", exit_code, exit_signal);

    // Calculate container duration
    u64 stop_time_ns = bpf_ktime_get_ns();
    u64 duration_ns = stop_time_ns - container->start_time_ns;

    trace_log("EHPROBE_CONTAINER_EXIT: Container ran for %llu ns", duration_ns);

    // Validate container termination by checking key fields
    if (container->pid != pid || container->pid_ns_inum != pid_ns_inum) {
        trace_log("EHPROBE_CONTAINER_EXIT: Container validation failed - PID mismatch");
        trace_log("EHPROBE_CONTAINER_EXIT: Expected PID %llu, got %d", container->pid, pid);
        return 0;
    }

    trace_log("EHPROBE_CONTAINER_EXIT: *** CONFIRMED CONTAINER TERMINATION ***");
    trace_log("EHPROBE_CONTAINER_EXIT: Removing container from tracking map");
    
    // Remove container from tracking map
    int ret = bpf_map_delete_elem(&containers_map, &pid_ns_inum);
    if (ret == 0) {
        trace_log("EHPROBE_CONTAINER_EXIT: Successfully removed container from map");
    } else {
        trace_log("EHPROBE_CONTAINER_EXIT: Failed to remove container from map, ret: %d", ret);
    }

    // Log final container statistics
    trace_log("EHPROBE_CONTAINER_EXIT: === CONTAINER STOP SUMMARY ===");
    trace_log("EHPROBE_CONTAINER_EXIT: Runtime: %s", container->runtime_type);
    trace_log("EHPROBE_CONTAINER_EXIT: Duration: %llu ns", duration_ns);
    trace_log("EHPROBE_CONTAINER_EXIT: Exit code: %d", exit_code);
    
    // Determine exit reason
    if (exit_signal > 0) {
        trace_log("EHPROBE_CONTAINER_EXIT: Termination reason: Signal %d", exit_signal);
    } else if (exit_code == 0) {
        trace_log("EHPROBE_CONTAINER_EXIT: Termination reason: Clean exit");
    } else {
        trace_log("EHPROBE_CONTAINER_EXIT: Termination reason: Error exit (code %d)", exit_code);
    }

    // Send event using ehprobe API
    // Note: You'll need to define EVENT_TYPE_CONTAINER_STOP in events.h
    struct event_context *evt_ctx = start_event(EVENT_TYPE_CONTAINER_STOP, 6);
    if (!evt_ctx) {
        trace_log("EHPROBE_CONTAINER_EXIT: ERROR - start_event failed");
        update_drop_stats(EVENT_TYPE_CONTAINER_STOP);
        return 0; // Continue even if event fails
    }

    // Parameter 0: container ID
    if (push_param_u64(evt_ctx, pid_ns_inum) < 0) {
        trace_log("EHPROBE_CONTAINER_EXIT: ERROR - push_param_u64 failed for container_id");
        goto error;
    }

    // Parameter 1: container level
    if (push_param_u32(evt_ctx, (uint32_t)level) < 0) {
        trace_log("EHPROBE_CONTAINER_EXIT: ERROR - push_param_u32 failed for level");
        goto error;
    }

    // Parameter 2: exit_signal
    if (push_param_u32(evt_ctx, (uint32_t)exit_signal) < 0) {
        trace_log("EHPROBE_CONTAINER_EXIT: ERROR - push_param_u32 failed for exit_signal");
        goto error;
    }

    // Parameter 3: exit_code
    if (push_param_s64(evt_ctx, (int64_t)exit_code) < 0) {
        trace_log("EHPROBE_CONTAINER_EXIT: ERROR - push_param_s64 failed for exit_code");
        goto error;
    }

    // Parameter 4: runtime
    if (push_param_string(evt_ctx, container->runtime_type, sizeof(container->runtime_type), 1) < 0) { // KERNEL space
        trace_log("EHPROBE_CONTAINER_EXIT: ERROR - push_param_string failed for runtime");
        goto error;
    }

    // Parameter 5: blocking_mode
    uint32_t blocking_mode_val = EHPROBE_BLOCKING_MODE_OFF;
    if (env) {
        blocking_mode_val = (uint32_t)env->blocking_mode;
    }
    if (push_param_u32(evt_ctx, blocking_mode_val) < 0) {
        trace_log("EHPROBE_CONTAINER_EXIT: ERROR - push_param_u32 failed for blocking_mode");
        goto error;
    }

    trace_log("EHPROBE_CONTAINER_EXIT: submitting event");
    submit_event(evt_ctx);
    return 0;

error:
    trace_log("EHPROBE_CONTAINER_EXIT: ERROR - dropping event");
    release_event(evt_ctx);
    update_drop_stats(EVENT_TYPE_CONTAINER_STOP);
	return 0;
}

// returns container PID if called from container context, 0 otherwise
// *out_level is filled with container level
static __always_inline uint64_t get_container_id(struct task_struct *task, uint32_t *out_level) {
    if (!task) {
        return 0;
    }

    pid_t pid = bpf_get_current_pid_tgid() >> 32;

    // Get namespace information
    struct nsproxy *nsproxy = BPF_CORE_READ(task, nsproxy);
    if (!nsproxy) {
        trace_log("EHPROBE_GET_CONTAINER_ID: Failed to read nsproxy for PID %d", pid);
        return 0;
    }

    struct pid_namespace *pid_ns = BPF_CORE_READ(nsproxy, pid_ns_for_children);
    if (!pid_ns) {
        trace_log("EHPROBE_GET_CONTAINER_ID: Failed to read PID namespace for PID %d", pid);
        return 0;
    }

    u64 pid_ns_inum = BPF_CORE_READ(pid_ns, ns.inum);

    // get global env map
	u32 map_key = 0;
    struct ehprobe_env *env = bpf_map_lookup_elem(&ehprobe_env_map, &map_key);
    if (!env) {
        trace_log("EHPROBE_GET_CONTAINER_ID: env not found");
        return 0;
    }

    // checking if running on the host
    if (env->host_pid_ns == pid_ns_inum) {
        trace_log("EHPROBE_GET_CONTAINER_ID: PID %d, NS inum %llu - running on the host", pid, pid_ns_inum);
        return 0;
    }

    // Check if this PID namespace corresponds to a tracked container
    struct container_entry *container = bpf_map_lookup_elem(&containers_map, &pid_ns_inum);
    if (!container) {
        trace_log("EHPROBE_GET_CONTAINER_ID: tracked container NOT FOUND for PID %d, NS inum %llu", pid, pid_ns_inum);
        return 0;
    }

    trace_log("EHPROBE_GET_CONTAINER_ID: Found tracked container for PID %d, NS inum %llu", pid, pid_ns_inum);

    // Check if this is the container's init process (PID 1 in namespace)
    struct pid *pid_struct = BPF_CORE_READ(task, thread_pid);
    if (!pid_struct) {
        trace_log("EHPROBE_GET_CONTAINER_ID: Failed to read pid struct for PID %d", pid);
        return 0;
    }

    uint32_t level = BPF_CORE_READ(pid_struct, level);
    if (level < 0) {
        trace_log("EHPROBE_GET_CONTAINER_ID: Invalid PID level %d for PID %d", level, pid);
        return 0;
    }

    int ns_pid = BPF_CORE_READ(pid_struct, numbers[level].nr);
    
    trace_log("EHPROBE_GET_CONTAINER_ID: ID %llu, ns_pid %d, level %d", pid_ns_inum, ns_pid, level);

    if (out_level) {
        *out_level = level;
    }
    return pid_ns_inum;
}

// returns 1 if container is in blocking mode (audit or enforce), 0 otherwise
static __always_inline int is_container_blocking(uint64_t container_id) {
    struct container_entry *container = bpf_map_lookup_elem(&containers_map, &container_id);
    if (!container) {
        trace_log("EHPROBE_CONTAINER_BLOCKING: tracked container NOT FOUND, container ID %llu", container_id);
        return 0;
    }

    return container->blocking_mode != EHPROBE_BLOCKING_MODE_OFF;
}
