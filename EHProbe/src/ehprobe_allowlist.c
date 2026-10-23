// ehprobe_allowlist.c - Allowlist management implementation
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <bpf/libbpf.h>
#include <bpf/bpf.h>
#include "ehprobe_internal.h"
#include "data.h"

int ehprobe_add_file_to_exec_allowlist(uint64_t container_id, uint64_t ino, uint32_t dev, const unsigned char* binary_hash) {
    int err;
    int inner_fd = -1;

    int outer_fd = bpf_map__fd(g_ehprobe.skel->maps.exec_allowlist_outer_map);
    if (outer_fd < 0) {
        report_log(EHPROBE_LOG_ERROR, "Failed to get exec_allowlist_outer_map FD, error: %s (%d)",
            strerror(errno), errno);
        return -errno;
    }

    uint32_t inner_map_id = 0;
    err = bpf_map_lookup_elem(outer_fd, &container_id, &inner_map_id);
    if (err) {
        if (errno != ENOENT) {
            report_log(EHPROBE_LOG_ERROR, "Failed to lookup inner map for container %lu: %s",
                container_id, strerror(errno));
            return -errno;
        }
        
        int template_fd = bpf_map__fd(g_ehprobe.skel->maps.exec_allowlist_inner_map);
        if (template_fd < 0) {
            report_log(EHPROBE_LOG_ERROR, "Failed to get inner map template FD: %s (%d)",
                strerror(errno), errno);
            return -errno;
        }

        struct bpf_map_info template_info = {};
        uint32_t template_info_len = sizeof(template_info);
        err = bpf_map_get_info_by_fd(template_fd, &template_info, &template_info_len);
        if (err) {
            report_log(EHPROBE_LOG_ERROR, "Failed to get inner map template info: %s (%d)",
                strerror(errno), errno);
            return -errno;
        }

        report_log(EHPROBE_LOG_DEBUG, 
            "Template: type=%u, key=%u, val=%u, max=%u, flags=0x%x, btf_id=%u, btf_key=%u, btf_val=%u",
            template_info.type, template_info.key_size, template_info.value_size, 
            template_info.max_entries, template_info.map_flags,
            template_info.btf_id, template_info.btf_key_type_id, template_info.btf_value_type_id);

        int btf_fd = -1;
        if (template_info.btf_id != 0) {
            btf_fd = bpf_object__btf_fd(g_ehprobe.skel->obj);
            report_log(EHPROBE_LOG_DEBUG, "Using BTF fd=%d from skeleton object", btf_fd);
        }

        LIBBPF_OPTS(bpf_map_create_opts, opts,
            .map_flags = template_info.map_flags,
            .btf_fd = (btf_fd >= 0) ? (__u32)btf_fd : 0,
            .btf_key_type_id = template_info.btf_key_type_id,
            .btf_value_type_id = template_info.btf_value_type_id,
        );

        inner_fd = bpf_map_create(BPF_MAP_TYPE_HASH,
                                  NULL,
                                  template_info.key_size,
                                  template_info.value_size,
                                  template_info.max_entries,
                                  &opts);
        if (inner_fd < 0) {
            int saved_errno = errno;
            report_log(EHPROBE_LOG_ERROR, 
                "Failed to create inner map for container %lu: %s (errno=%d). "
                "Tried: key=%u, val=%u, max=%u, flags=0x%x, btf_fd=%d, btf_key=%u, btf_val=%u",
                container_id, strerror(saved_errno), saved_errno,
                template_info.key_size, template_info.value_size, template_info.max_entries,
                template_info.map_flags, btf_fd, 
                template_info.btf_key_type_id, template_info.btf_value_type_id);
            return -saved_errno;
        }

        report_log(EHPROBE_LOG_DEBUG, "Created inner map fd=%d", inner_fd);

        err = bpf_map_update_elem(outer_fd, &container_id, &inner_fd, BPF_ANY);
        if (err) {
            int saved_errno = errno;
            close(inner_fd);
            report_log(EHPROBE_LOG_ERROR, "Failed to add inner map for container %lu: %s (errno=%d)",
                container_id, strerror(saved_errno), saved_errno);
            return -saved_errno;
        }
        
        report_log(EHPROBE_LOG_DEBUG, "Added inner map to outer map for container %lu", container_id);
    } else {
        inner_fd = bpf_map_get_fd_by_id(inner_map_id);
        if (inner_fd < 0) {
            report_log(EHPROBE_LOG_ERROR, "Failed to get inner map FD from ID %u for container %lu: %s", 
                inner_map_id, container_id, strerror(errno));
            return -errno;
        }
    }

    struct allowlist_key key = {
        .ino = ino,
        .dev = dev,
        .pad = 0
    };
    struct allowlist_entry entry = {0};
    memcpy(entry.hash, binary_hash, SHA256_DIGEST_SIZE);

    err = bpf_map_update_elem(inner_fd, &key, &entry, BPF_ANY);
    int saved_errno = errno;
    close(inner_fd);
    
    if (err) {
        report_log(EHPROBE_LOG_ERROR, "Failed to add allowlist entry for container %lu, ino %lu, dev %u: %s", 
            container_id, ino, dev, strerror(saved_errno));
        return -saved_errno;
    }

    return 0;
}

int ehprobe_remove_file_from_exec_allowlist(uint64_t container_id, uint64_t ino, uint32_t dev) {
    int outer_fd = bpf_map__fd(g_ehprobe.skel->maps.exec_allowlist_outer_map);
    if (outer_fd < 0) {
        report_log(EHPROBE_LOG_ERROR, "Failed to get exec_allowlist_outer_map FD, error: %s (%d)",
            strerror(errno), errno);
        return -errno;
    }

    uint32_t inner_map_id = 0;
    int err = bpf_map_lookup_elem(outer_fd, &container_id, &inner_map_id);
    if (err) {
        if (errno == ENOENT) {
            return -ENOENT;
        }
        report_log(EHPROBE_LOG_ERROR, "Failed to lookup inner map for container %lu: %s",
            container_id, strerror(errno));
        return -errno;
    }

    int inner_fd = bpf_map_get_fd_by_id(inner_map_id);
    if (inner_fd < 0) {
        report_log(EHPROBE_LOG_ERROR, "Failed to get inner map FD from ID %u for container %lu: %s", 
            inner_map_id, container_id, strerror(errno));
        return -errno;
    }

    struct allowlist_key key = {
        .ino = ino,
        .dev = dev,
        .pad = 0
    };

    err = bpf_map_delete_elem(inner_fd, &key);
    int saved_errno = errno;
    close(inner_fd);
    
    if (err) {
        if (saved_errno == ENOENT) {
            return -ENOENT;
        }
        report_log(EHPROBE_LOG_ERROR, "Failed to remove allowlist entry for container %lu, ino %lu, dev %u: %s", 
            container_id, ino, dev, strerror(saved_errno));
        return -saved_errno;
    }

    return 0;
}

int ehprobe_remove_container_from_exec_allowlist(uint64_t container_id) {
    int outer_fd = bpf_map__fd(g_ehprobe.skel->maps.exec_allowlist_outer_map);
    if (outer_fd < 0) {
        report_log(EHPROBE_LOG_ERROR, "Failed to get exec_allowlist_outer_map FD, error: %s (%d)",
            strerror(errno), errno);
        return -errno;
    }

    // Just delete the outer map entry — the kernel manages inner map lifetime
    // via refcounting. When the outer entry is removed, the inner map's refcount
    // drops and it is freed automatically.
    int err = bpf_map_delete_elem(outer_fd, &container_id);
    if (err) {
        if (errno == ENOENT) {
            return -ENOENT;
        }
        report_log(EHPROBE_LOG_ERROR, "Failed to remove container %lu from allowlist: %s",
            container_id, strerror(errno));
        return -errno;
    }

    return 0;
}

// ============================================================================
// Script Allowlist Functions
// ============================================================================

int ehprobe_add_file_to_script_allowlist(uint64_t container_id, uint64_t ino, uint32_t dev, const unsigned char* script_hash) {
    int err;
    int inner_fd = -1;

    int outer_fd = bpf_map__fd(g_ehprobe.skel->maps.script_allowlist_outer_map);
    if (outer_fd < 0) {
        report_log(EHPROBE_LOG_ERROR, "Failed to get script_allowlist_outer_map FD, error: %s (%d)",
            strerror(errno), errno);
        return -errno;
    }

    uint32_t inner_map_id = 0;
    err = bpf_map_lookup_elem(outer_fd, &container_id, &inner_map_id);
    if (err) {
        if (errno != ENOENT) {
            report_log(EHPROBE_LOG_ERROR, "Failed to lookup script inner map for container %lu: %s",
                container_id, strerror(errno));
            return -errno;
        }

        int template_fd = bpf_map__fd(g_ehprobe.skel->maps.script_allowlist_inner_map);
        if (template_fd < 0) {
            report_log(EHPROBE_LOG_ERROR, "Failed to get script inner map template FD: %s (%d)",
                strerror(errno), errno);
            return -errno;
        }

        struct bpf_map_info template_info = {};
        uint32_t template_info_len = sizeof(template_info);
        err = bpf_map_get_info_by_fd(template_fd, &template_info, &template_info_len);
        if (err) {
            report_log(EHPROBE_LOG_ERROR, "Failed to get script inner map template info: %s (%d)",
                strerror(errno), errno);
            return -errno;
        }

        int btf_fd = -1;
        if (template_info.btf_id != 0) {
            btf_fd = bpf_object__btf_fd(g_ehprobe.skel->obj);
        }

        LIBBPF_OPTS(bpf_map_create_opts, opts,
            .map_flags = template_info.map_flags,
            .btf_fd = (btf_fd >= 0) ? (__u32)btf_fd : 0,
            .btf_key_type_id = template_info.btf_key_type_id,
            .btf_value_type_id = template_info.btf_value_type_id,
        );

        inner_fd = bpf_map_create(BPF_MAP_TYPE_HASH,
                                  NULL,
                                  template_info.key_size,
                                  template_info.value_size,
                                  template_info.max_entries,
                                  &opts);
        if (inner_fd < 0) {
            int saved_errno = errno;
            report_log(EHPROBE_LOG_ERROR,
                "Failed to create script inner map for container %lu: %s (errno=%d)",
                container_id, strerror(saved_errno), saved_errno);
            return -saved_errno;
        }

        err = bpf_map_update_elem(outer_fd, &container_id, &inner_fd, BPF_ANY);
        if (err) {
            int saved_errno = errno;
            close(inner_fd);
            report_log(EHPROBE_LOG_ERROR, "Failed to add script inner map for container %lu: %s (errno=%d)",
                container_id, strerror(saved_errno), saved_errno);
            return -saved_errno;
        }

        report_log(EHPROBE_LOG_DEBUG, "Created script allowlist inner map fd=%d for container %lu", inner_fd, container_id);
    } else {
        inner_fd = bpf_map_get_fd_by_id(inner_map_id);
        if (inner_fd < 0) {
            report_log(EHPROBE_LOG_ERROR, "Failed to get script inner map FD from ID %u for container %lu: %s",
                inner_map_id, container_id, strerror(errno));
            return -errno;
        }
    }

    struct allowlist_key key = {
        .ino = ino,
        .dev = dev,
        .pad = 0
    };
    struct allowlist_entry entry = {0};
    memcpy(entry.hash, script_hash, SHA256_DIGEST_SIZE);

    err = bpf_map_update_elem(inner_fd, &key, &entry, BPF_ANY);
    int saved_errno = errno;
    close(inner_fd);

    if (err) {
        report_log(EHPROBE_LOG_ERROR, "Failed to add script allowlist entry for container %lu, ino %lu, dev %u: %s",
            container_id, ino, dev, strerror(saved_errno));
        return -saved_errno;
    }

    return 0;
}

int ehprobe_remove_file_from_script_allowlist(uint64_t container_id, uint64_t ino, uint32_t dev) {
    int outer_fd = bpf_map__fd(g_ehprobe.skel->maps.script_allowlist_outer_map);
    if (outer_fd < 0) {
        report_log(EHPROBE_LOG_ERROR, "Failed to get script_allowlist_outer_map FD, error: %s (%d)",
            strerror(errno), errno);
        return -errno;
    }

    uint32_t inner_map_id = 0;
    int err = bpf_map_lookup_elem(outer_fd, &container_id, &inner_map_id);
    if (err) {
        if (errno == ENOENT) {
            return -ENOENT;
        }
        report_log(EHPROBE_LOG_ERROR, "Failed to lookup script inner map for container %lu: %s",
            container_id, strerror(errno));
        return -errno;
    }

    int inner_fd = bpf_map_get_fd_by_id(inner_map_id);
    if (inner_fd < 0) {
        report_log(EHPROBE_LOG_ERROR, "Failed to get script inner map FD from ID %u for container %lu: %s",
            inner_map_id, container_id, strerror(errno));
        return -errno;
    }

    struct allowlist_key key = {
        .ino = ino,
        .dev = dev,
        .pad = 0
    };

    err = bpf_map_delete_elem(inner_fd, &key);
    int saved_errno = errno;
    close(inner_fd);

    if (err) {
        if (saved_errno == ENOENT) {
            return -ENOENT;
        }
        report_log(EHPROBE_LOG_ERROR, "Failed to remove script allowlist entry for container %lu, ino %lu, dev %u: %s",
            container_id, ino, dev, strerror(saved_errno));
        return -saved_errno;
    }

    return 0;
}

int ehprobe_remove_container_from_script_allowlist(uint64_t container_id) {
    int outer_fd = bpf_map__fd(g_ehprobe.skel->maps.script_allowlist_outer_map);
    if (outer_fd < 0) {
        report_log(EHPROBE_LOG_ERROR, "Failed to get script_allowlist_outer_map FD, error: %s (%d)",
            strerror(errno), errno);
        return -errno;
    }

    int inner_map_id;
    int err = bpf_map_lookup_elem(outer_fd, &container_id, &inner_map_id);
    if (err == 0) {
        int inner_fd = bpf_map_get_fd_by_id(inner_map_id);
        if (inner_fd >= 0) {
            close(inner_fd);
        }
    }

    err = bpf_map_delete_elem(outer_fd, &container_id);
    if (err) {
        if (errno == ENOENT) {
            return -ENOENT;
        }
        report_log(EHPROBE_LOG_ERROR, "Failed to remove container %lu from script allowlist: %s",
            container_id, strerror(errno));
        return -errno;
    }

    return 0;
}

int ehprobe_add_interpreter_binary(const char* comm) {
    if (!comm) {
        return -EINVAL;
    }

    int map_fd = bpf_map__fd(g_ehprobe.skel->maps.interpreter_binaries);
    if (map_fd < 0) {
        report_log(EHPROBE_LOG_ERROR, "Failed to get interpreter_binaries map FD: %s (%d)",
            strerror(errno), errno);
        return -errno;
    }

    struct interpreter_binary_key key = {};
    strncpy(key.comm, comm, sizeof(key.comm) - 1);
    key.comm[sizeof(key.comm) - 1] = '\0';

    uint8_t val = 1;
    int err = bpf_map_update_elem(map_fd, &key, &val, BPF_ANY);
    if (err) {
        report_log(EHPROBE_LOG_ERROR, "Failed to add interpreter binary '%s': %s",
            comm, strerror(errno));
        return -errno;
    }

    report_log(EHPROBE_LOG_INFO, "Added interpreter binary: %s", comm);
    return 0;
}
