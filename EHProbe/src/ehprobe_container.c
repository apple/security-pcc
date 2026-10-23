// ehprobe_container.c - Container management implementation
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <bpf/bpf.h>
#include "ehprobe_internal.h"
#include "data.h"

// ============================================================================
// Internal Helper Functions
// ============================================================================

/**
 * Parse NSpid from /proc/[pid]/status to get PID at each namespace level
 */
static int get_nspid_levels(pid_t pid, pid_t *ns_pids, int max_levels, int *num_levels) {
    char path[256];
    char buf[4096];
    int fd;
    ssize_t bytes_read;
    int count = 0;
    
    snprintf(path, sizeof(path), "/proc/%d/status", pid);
    fd = open(path, O_RDONLY);
    if (fd < 0) {
        return -errno;
    }
    
    bytes_read = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    
    if (bytes_read <= 0) {
        return -EIO;
    }
    buf[bytes_read] = '\0';
    
    // Find NSpid line
    char *line = strstr(buf, "\nNSpid:");
    if (!line) {
        if (strncmp(buf, "NSpid:", 6) == 0) {
            line = buf;
        } else {
            return -ENOENT;
        }
    } else {
        line++;
    }
    
    // Skip "NSpid:" prefix
    line += 6;
    
    // Parse PIDs
    while (*line && *line != '\n' && count < max_levels) {
        while (*line == ' ' || *line == '\t') {
            line++;
        }
        
        if (*line == '\n' || *line == '\0') {
            break;
        }
        
        pid_t val = 0;
        while (*line >= '0' && *line <= '9') {
            val = val * 10 + (*line - '0');
            line++;
        }
        
        if (val > 0) {
            ns_pids[count++] = val;
        }
    }
    
    *num_levels = count;
    return count > 0 ? 0 : -ENOENT;
}

/**
 * Get the cgroup ID for a process.
 */
static int get_process_cgroup_id(pid_t pid, uint64_t *cgroup_id) {
    char path[256];
    char buf[512];
    char cgroup_path_buf[256];
    char full_path[512];
    int fd;
    ssize_t bytes_read;
    struct stat cgroup_stat;
    
    snprintf(path, sizeof(path), "/proc/%d/cgroup", pid);
    fd = open(path, O_RDONLY);
    if (fd < 0) {
        return -errno;
    }
    
    bytes_read = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    
    if (bytes_read <= 0) {
        return -EIO;
    }
    buf[bytes_read] = '\0';
    
    // Find cgroup v2 line (starts with "0::")
    char *line = buf;
    while (line && *line) {
        if (strncmp(line, "0::", 3) == 0) {
            char *cgroup_path = line + 3;
            
            char *eol = strchr(cgroup_path, '\n');
            size_t path_len = eol ? (size_t)(eol - cgroup_path) : strlen(cgroup_path);
            
            if (path_len >= sizeof(cgroup_path_buf)) {
                path_len = sizeof(cgroup_path_buf) - 1;
            }
            memcpy(cgroup_path_buf, cgroup_path, path_len);
            cgroup_path_buf[path_len] = '\0';
            
            int written = snprintf(full_path, sizeof(full_path), "/sys/fs/cgroup%s", cgroup_path_buf);
            if (written < 0 || (size_t)written >= sizeof(full_path)) {
                report_log(EHPROBE_LOG_DEBUG, "Cgroup path truncated for pid %d", pid);
            }
            
            if (stat(full_path, &cgroup_stat) == 0) {
                *cgroup_id = (uint64_t)cgroup_stat.st_ino;
                return 0;
            }
            break;
        }
        
        line = strchr(line, '\n');
        if (line) line++;
    }
    
    return -ENOENT;
}

/**
 * Helper function to convert ehprobe_container to internal container_entry
 */
static void ehprobe_to_container_entry(const struct ehprobe_container* probe_container, struct container_entry* entry) {
    entry->id = probe_container->id;
    entry->level = probe_container->level;
    entry->pid = probe_container->pid;
    entry->ppid = probe_container->parent_id;
    entry->mnt_ns_inum = probe_container->mnt_ns_inum;
    entry->pid_ns_inum = probe_container->pid_ns_inum;
    entry->cgroup_id = probe_container->cgroup_id;
    entry->start_time_ns = probe_container->start_time_ns;
    entry->blocking_mode = probe_container->blocking_mode;
    strncpy(entry->runtime_type, probe_container->runtime_type, CONTAINER_RUNTIME_MAX_LEN - 1);
    entry->runtime_type[CONTAINER_RUNTIME_MAX_LEN - 1] = '\0';
    
    strncpy(entry->entrypoint_cmd, probe_container->entrypoint_cmd, CONTAINER_CMD_MAX_LEN - 1);
    entry->entrypoint_cmd[CONTAINER_CMD_MAX_LEN - 1] = '\0';
}

/**
 * Helper function to convert internal container_entry to ehprobe_container
 */
static void container_entry_to_ehprobe(const struct container_entry* entry, struct ehprobe_container* probe_container) {
    probe_container->id = entry->id;
    probe_container->level = entry->level;
    probe_container->pid = entry->pid;
    probe_container->parent_id = entry->ppid;
    probe_container->mnt_ns_inum = entry->mnt_ns_inum;
    probe_container->pid_ns_inum = entry->pid_ns_inum;
    probe_container->cgroup_id = entry->cgroup_id;
    probe_container->start_time_ns = entry->start_time_ns;
    probe_container->blocking_mode = entry->blocking_mode;

    strncpy(probe_container->runtime_type, entry->runtime_type, CONTAINER_RUNTIME_MAX_LEN - 1);
    probe_container->runtime_type[CONTAINER_RUNTIME_MAX_LEN - 1] = '\0';

    strncpy(probe_container->entrypoint_cmd, entry->entrypoint_cmd, CONTAINER_CMD_MAX_LEN - 1);
    probe_container->entrypoint_cmd[CONTAINER_CMD_MAX_LEN - 1] = '\0';
}

// ============================================================================
// Container Discovery Functions
// ============================================================================

int get_host_pid_namespace(uint64_t *host_pid_ns_inum) {
    int proc_fd;
    char buf[GETDENTS_BUFSIZE];
    struct linux_dirent64 *d;
    int nread;
    char path[256];
    struct stat ns_stat;
    pid_t ns_pids[MAX_NS_LEVELS];
    int num_levels;
    int ret = -ENOENT;
    
    if (!host_pid_ns_inum) {
        return -EINVAL;
    }
    
    proc_fd = open("/proc", O_RDONLY | O_DIRECTORY);
    if (proc_fd < 0) {
        report_log(EHPROBE_LOG_ERROR, "Failed to open /proc: %s", strerror(errno));
        return -errno;
    }
    
    while ((nread = syscall(SYS_getdents64, proc_fd, buf, sizeof(buf))) > 0) {
        for (int bpos = 0; bpos < nread; ) {
            d = (struct linux_dirent64 *)(buf + bpos);
            bpos += d->d_reclen;
            
            if (d->d_name[0] < '0' || d->d_name[0] > '9') {
                continue;
            }
            
            pid_t pid = atoi(d->d_name);
            if (pid <= 0) continue;
            
            if (get_nspid_levels(pid, ns_pids, MAX_NS_LEVELS, &num_levels) != 0) {
                continue;
            }
            
            if (num_levels == 1) {
                snprintf(path, sizeof(path), "/proc/%d/ns/pid", pid);
                if (stat(path, &ns_stat) == 0) {
                    *host_pid_ns_inum = (uint64_t)ns_stat.st_ino;
                    report_log(EHPROBE_LOG_DEBUG, 
                        "Found host PID namespace %lu from process %d (level 0)",
                        *host_pid_ns_inum, pid);
                    ret = 0;
                    goto done;
                }
            }
        }
    }
    
    if (nread < 0) {
        ret = -errno;
        report_log(EHPROBE_LOG_ERROR, "getdents64 failed: %s", strerror(errno));
    } else if (ret != 0) {
        report_log(EHPROBE_LOG_ERROR, "Failed to find any level-0 process for host namespace detection");
    }
    
done:
    close(proc_fd);
    return ret;
}

/**
 * Internal structure for tracking discovered containers during enumeration
 */
struct discovered_container_info {
    uint64_t pid_ns_inum;
    uint64_t mnt_ns_inum;
    uint64_t cgroup_id;
    pid_t init_pid;
    uint32_t level;
};

int discover_existing_containers(uint64_t host_pid_ns_inum) {
    int proc_fd;
    char buf[GETDENTS_BUFSIZE];
    struct linux_dirent64 *d;
    int nread;
    char path[256];
    struct stat pid_ns_stat, mnt_ns_stat, cgroup_ns_stat;
    pid_t ns_pids[MAX_NS_LEVELS];
    int num_levels;
    
    // Get host cgroup namespace for comparison
    uint64_t host_cgroup_ns_inum = 0;
    if (stat("/proc/1/ns/cgroup", &cgroup_ns_stat) == 0) {
        host_cgroup_ns_inum = (uint64_t)cgroup_ns_stat.st_ino;
    } else {
        report_log(EHPROBE_LOG_WARNING, 
            "Could not read host cgroup namespace, container detection may include infrastructure processes");
    }
    
    // Track discovered containers
    struct discovered_container_info containers[MAX_DISCOVERED_CONTAINERS];
    int container_count = 0;
    
    // Track which namespaces we've already processed
    uint64_t seen_namespaces[MAX_DISCOVERED_CONTAINERS];
    int seen_count = 0;
    
    proc_fd = open("/proc", O_RDONLY | O_DIRECTORY);
    if (proc_fd < 0) {
        report_log(EHPROBE_LOG_ERROR, "Failed to open /proc for container discovery: %s", 
            strerror(errno));
        return -errno;
    }
    
    report_log(EHPROBE_LOG_DEBUG, 
        "Starting container discovery scan (host_pid_ns=%lu, host_cgroup_ns=%lu)...", 
        host_pid_ns_inum, host_cgroup_ns_inum);
    
    while ((nread = syscall(SYS_getdents64, proc_fd, buf, sizeof(buf))) > 0 
           && container_count < MAX_DISCOVERED_CONTAINERS) {
        
        for (int bpos = 0; bpos < nread && container_count < MAX_DISCOVERED_CONTAINERS; ) {
            d = (struct linux_dirent64 *)(buf + bpos);
            bpos += d->d_reclen;
            
            if (d->d_name[0] < '0' || d->d_name[0] > '9') {
                continue;
            }
            
            pid_t pid = atoi(d->d_name);
            if (pid <= 0) continue;
            
            snprintf(path, sizeof(path), "/proc/%d/ns/pid", pid);
            if (stat(path, &pid_ns_stat) != 0) {
                continue;
            }
            
            uint64_t pid_ns_inum = (uint64_t)pid_ns_stat.st_ino;
            
            if (pid_ns_inum == host_pid_ns_inum) {
                continue;
            }
            
            int already_seen = 0;
            for (int i = 0; i < seen_count; i++) {
                if (seen_namespaces[i] == pid_ns_inum) {
                    already_seen = 1;
                    break;
                }
            }
            if (already_seen) {
                continue;
            }
            
            if (seen_count < MAX_DISCOVERED_CONTAINERS) {
                seen_namespaces[seen_count++] = pid_ns_inum;
            }
            
            snprintf(path, sizeof(path), "/proc/%d/ns/cgroup", pid);
            if (stat(path, &cgroup_ns_stat) == 0) {
                uint64_t proc_cgroup_ns_inum = (uint64_t)cgroup_ns_stat.st_ino;
                if (host_cgroup_ns_inum != 0 && proc_cgroup_ns_inum == host_cgroup_ns_inum) {
                    report_log(EHPROBE_LOG_DEBUG, 
                        "Process %d: skipping - cgroup namespace matches host (infrastructure process)",
                        pid);
                    continue;
                }
            }
            
            if (get_nspid_levels(pid, ns_pids, MAX_NS_LEVELS, &num_levels) != 0) {
                continue;
            }
            
            if (num_levels < 2) {
                continue;
            }
            
            uint32_t level = (uint32_t)(num_levels - 1);
            pid_t innermost_pid = ns_pids[level];
            
            if (innermost_pid != 1) {
                continue;
            }
            
            report_log(EHPROBE_LOG_INFO, 
                "Found container init: host_pid=%d, pid_ns=%lu, level=%u",
                pid, pid_ns_inum, level);
            
            uint64_t mnt_ns_inum = 0;
            snprintf(path, sizeof(path), "/proc/%d/ns/mnt", pid);
            if (stat(path, &mnt_ns_stat) == 0) {
                mnt_ns_inum = (uint64_t)mnt_ns_stat.st_ino;
            }
            
            uint64_t cgroup_id = 0;
            get_process_cgroup_id(pid, &cgroup_id);
            
            containers[container_count].pid_ns_inum = pid_ns_inum;
            containers[container_count].mnt_ns_inum = mnt_ns_inum;
            containers[container_count].cgroup_id = cgroup_id;
            containers[container_count].init_pid = pid;
            containers[container_count].level = level;
            container_count++;
        }
    }
    
    close(proc_fd);
    
    if (nread < 0) {
        report_log(EHPROBE_LOG_ERROR, "getdents64 failed during container discovery: %s", 
            strerror(errno));
        return -errno;
    }
    
    report_log(EHPROBE_LOG_INFO, "Container discovery complete: found %d pre-existing containers", 
        container_count);
    
    // Register all discovered containers in the eBPF map
    int registered = 0;
    int failed = 0;
    
    for (int i = 0; i < container_count; i++) {
        struct ehprobe_container probe_container = {0};
        
        probe_container.id = containers[i].pid_ns_inum;
        probe_container.level = containers[i].level;
        probe_container.pid = (uint64_t)containers[i].init_pid;
        probe_container.parent_id = 0;
        probe_container.mnt_ns_inum = containers[i].mnt_ns_inum;
        probe_container.pid_ns_inum = containers[i].pid_ns_inum;
        probe_container.cgroup_id = containers[i].cgroup_id;
        probe_container.start_time_ns = 0;
        probe_container.blocking_mode = EHPROBE_BLOCKING_MODE_OFF;
        probe_container.runtime_type[0] = '\0';
        probe_container.entrypoint_cmd[0] = '\0';
        
        int ret = ehprobe_container_store(containers[i].pid_ns_inum, &probe_container);
        if (ret == 0) {
            registered++;
            report_log(EHPROBE_LOG_DEBUG, 
                "Registered pre-existing container: id=%lu, init_pid=%d, level=%u",
                containers[i].pid_ns_inum, 
                containers[i].init_pid, 
                containers[i].level);
        } else {
            failed++;
            report_log(EHPROBE_LOG_WARNING,
                "Failed to register container pid_ns=%lu: %s",
                containers[i].pid_ns_inum, strerror(-ret));
        }
    }
    
    report_log(EHPROBE_LOG_INFO, 
        "Container registration complete: %d registered, %d failed",
        registered, failed);
    
    return 0;
}

// ============================================================================
// Public Container API
// ============================================================================

int ehprobe_container_store(uint64_t container_id, struct ehprobe_container* probe_container) {
    struct container_entry entry;
    int err;

    int map_fd = bpf_map__fd(g_ehprobe.skel->maps.containers_map);
    if (map_fd < 0) {
        report_log(EHPROBE_LOG_ERROR, "Failed to get containers map FD, error: %s (%d)",
            strerror(errno), errno);
        return -errno;
    }

    ehprobe_to_container_entry(probe_container, &entry);

    err = bpf_map_update_elem(map_fd, &container_id, &entry, BPF_ANY);
    if (err) {
        report_log(EHPROBE_LOG_ERROR, "Failed to store container %lu: %s",
            container_id, strerror(errno));
        return -errno;
    }

    return 0;
}

int ehprobe_container_query(uint64_t container_id, struct ehprobe_container* probe_container) {
    struct container_entry entry;
    int err;

    int map_fd = bpf_map__fd(g_ehprobe.skel->maps.containers_map);
    if (map_fd < 0) {
        report_log(EHPROBE_LOG_ERROR, "Failed to get containers map FD, error: %s (%d)",
            strerror(errno), errno);
        return -errno;
    }

    err = bpf_map_lookup_elem(map_fd, &container_id, &entry);
    if (err) {
        if (errno == ENOENT) {
            return -ENOENT;
        }
        report_log(EHPROBE_LOG_ERROR, "Failed to query container %lu: %s",
            container_id, strerror(errno));
        return -errno;
    }

    container_entry_to_ehprobe(&entry, probe_container);

    return 0;
}

int ehprobe_container_remove(uint64_t container_id) {
    int err;

    int map_fd = bpf_map__fd(g_ehprobe.skel->maps.containers_map);
    if (map_fd < 0) {
        report_log(EHPROBE_LOG_ERROR, "Failed to get containers map FD, error: %s (%d)",
            strerror(errno), errno);
        return -errno;
    }

    err = bpf_map_delete_elem(map_fd, &container_id);
    if (err) {
        if (errno == ENOENT) {
            return -ENOENT;
        }
        report_log(EHPROBE_LOG_ERROR, "Failed to remove container %lu: %s",
            container_id, strerror(errno));
        return -errno;
    }

    return 0;
}

bool ehprobe_container_exists(uint64_t container_id) {
    struct container_entry dummy_entry;
    int err;

    int map_fd = bpf_map__fd(g_ehprobe.skel->maps.containers_map);
    if (map_fd < 0) {
        return false;
    }

    err = bpf_map_lookup_elem(map_fd, &container_id, &dummy_entry);
    return (err == 0);
}

int ehprobe_container_get_all_ids(uint64_t* container_ids, int max_containers, int* count) {
    uint64_t key, next_key;
    struct container_entry dummy_entry;
    int err;
    int found = 0;

    int map_fd = bpf_map__fd(g_ehprobe.skel->maps.containers_map);
    if (map_fd < 0) {
        report_log(EHPROBE_LOG_ERROR, "Failed to get containers map FD, error: %s (%d)", 
            strerror(errno), errno);
        return -errno;
    }

    key = 0;
    while (found < max_containers) {
        err = bpf_map_get_next_key(map_fd, &key, &next_key);
        if (err) {
            if (errno == ENOENT) {
                break;
            }
            report_log(EHPROBE_LOG_ERROR, "Failed to get next key: %s", strerror(errno));
            return -errno;
        }

        err = bpf_map_lookup_elem(map_fd, &next_key, &dummy_entry);
        if (err == 0) {
            container_ids[found] = next_key;
            found++;
        }

        key = next_key;
    }

    *count = found;
    return 0;
}

int ehprobe_set_container_blocking_mode(uint64_t container_id, uint64_t mode) {
    if (mode != EHPROBE_BLOCKING_MODE_OFF &&
        mode != EHPROBE_BLOCKING_MODE_AUDIT &&
        mode != EHPROBE_BLOCKING_MODE_ENFORCE) {
        report_log(EHPROBE_LOG_ERROR, "Invalid blocking mode value: %lu", mode);
        return -EINVAL;
    }

    struct container_entry entry;

    int map_fd = bpf_map__fd(g_ehprobe.skel->maps.containers_map);
    if (map_fd < 0) {
        report_log(EHPROBE_LOG_ERROR, "Failed to get containers map FD, error: %s (%d)",
            strerror(errno), errno);
        return -errno;
    }

    int ret = bpf_map_lookup_elem(map_fd, &container_id, &entry);
    if (ret != 0) {
        report_log(EHPROBE_LOG_ERROR, "Failed to get container entry, error: %s (%d)",
            strerror(errno), errno);
        return -errno;
    }

    entry.blocking_mode = mode;

    ret = bpf_map_update_elem(map_fd, &container_id, &entry, BPF_ANY);
    if (ret != 0) {
        report_log(EHPROBE_LOG_ERROR, "Failed to update container map: %s", strerror(errno));
        return -errno;
    }
    return 0;
}
