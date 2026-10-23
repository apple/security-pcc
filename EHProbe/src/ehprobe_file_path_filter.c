// ehprobe_file_path_filter.c - File path filtering implementation
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <bpf/libbpf.h>
#include <bpf/bpf.h>
#include "ehprobe_internal.h"
#include "data.h"

// Enable or disable file path filtering
int ehprobe_file_path_filter_enable(bool enable) {
    if (!g_ehprobe.initialized) {
        return EHPROBE_ERROR_NOT_INITIALIZED;
    }

    int map_fd = bpf_map__fd(g_ehprobe.skel->maps.ehprobe_env_map);
    if (map_fd < 0) {
        report_log(EHPROBE_LOG_ERROR, "Failed to get env map FD: %s", strerror(errno));
        return -errno;
    }

    uint32_t map_key = 0;
    struct ehprobe_env env = {0};
    int ret = bpf_map_lookup_elem(map_fd, &map_key, &env);
    if (ret < 0) {
        report_log(EHPROBE_LOG_ERROR, "Failed to lookup env map: %s", strerror(errno));
        return -errno;
    }

    env.flag_file_path_filter = enable ? 1 : 0;

    ret = bpf_map_update_elem(map_fd, &map_key, &env, BPF_ANY);
    if (ret < 0) {
        report_log(EHPROBE_LOG_ERROR, "Failed to update env map: %s", strerror(errno));
        return -errno;
    }

    report_log(EHPROBE_LOG_DEBUG, "File path filtering %s", enable ? "enabled" : "disabled");
    return 0;
}

// Add a literal (exact match) path to the filter
int ehprobe_file_path_add_literal(const char *path) {
    if (!g_ehprobe.initialized) {
        return EHPROBE_ERROR_NOT_INITIALIZED;
    }

    if (!path) {
        return EHPROBE_ERROR_INVALID_PARAM;
    }

    size_t path_len = strlen(path);
    if (path_len == 0 || path_len >= FILE_PATH_FILTER_MAX_LEN) {
        report_log(EHPROBE_LOG_ERROR, "Path length %zu invalid (max %d)",
                   path_len, FILE_PATH_FILTER_MAX_LEN - 1);
        return EHPROBE_ERROR_INVALID_PARAM;
    }

    int map_fd = bpf_map__fd(g_ehprobe.skel->maps.file_path_literal_map);
    if (map_fd < 0) {
        report_log(EHPROBE_LOG_ERROR, "Failed to get file_path_literal_map FD: %s", strerror(errno));
        return -errno;
    }

    struct file_path_filter_key key = {0};
    strncpy(key.path, path, FILE_PATH_FILTER_MAX_LEN - 1);

    struct file_path_filter_value value = {
        .active = 1
    };

    int ret = bpf_map_update_elem(map_fd, &key, &value, BPF_ANY);
    if (ret < 0) {
        report_log(EHPROBE_LOG_ERROR, "Failed to add literal path '%s': %s", path, strerror(errno));
        return -errno;
    }

    report_log(EHPROBE_LOG_DEBUG, "Added literal path filter: %s", path);
    return 0;
}

// Add a prefix path to the LPM trie filter
int ehprobe_file_path_add_prefix(const char *prefix) {
    if (!g_ehprobe.initialized) {
        return EHPROBE_ERROR_NOT_INITIALIZED;
    }

    if (!prefix) {
        return EHPROBE_ERROR_INVALID_PARAM;
    }

    size_t prefix_len = strnlen(prefix, FILE_PATH_FILTER_MAX_LEN);
    if (prefix_len == 0 || prefix_len >= FILE_PATH_FILTER_MAX_LEN) {
        report_log(EHPROBE_LOG_ERROR, "Prefix length %zu invalid (max %d)",
                   prefix_len, FILE_PATH_FILTER_MAX_LEN - 1);
        return EHPROBE_ERROR_INVALID_PARAM;
    }

    int map_fd = bpf_map__fd(g_ehprobe.skel->maps.file_path_prefix_lpm);
    if (map_fd < 0) {
        report_log(EHPROBE_LOG_ERROR, "Failed to get file_path_prefix_lpm FD: %s", strerror(errno));
        return -errno;
    }

    struct file_path_lpm_key key = {0};
    key.prefixlen = (uint32_t)(prefix_len * 8);
    strncpy((char *)key.data, prefix, FILE_PATH_FILTER_MAX_LEN - 1);

    struct file_path_filter_value value = { .active = 1 };

    int ret = bpf_map_update_elem(map_fd, &key, &value, BPF_ANY);
    if (ret < 0) {
        report_log(EHPROBE_LOG_ERROR, "Failed to add prefix '%s': %s", prefix, strerror(errno));
        return -errno;
    }

    report_log(EHPROBE_LOG_DEBUG, "Added prefix path filter: %s", prefix);
    return 0;
}

// Remove a literal path from the filter
int ehprobe_file_path_remove_literal(const char *path) {
    if (!g_ehprobe.initialized) {
        return EHPROBE_ERROR_NOT_INITIALIZED;
    }

    if (!path) {
        return EHPROBE_ERROR_INVALID_PARAM;
    }

    size_t path_len = strlen(path);
    if (path_len == 0 || path_len >= FILE_PATH_FILTER_MAX_LEN) {
        return EHPROBE_ERROR_INVALID_PARAM;
    }

    int map_fd = bpf_map__fd(g_ehprobe.skel->maps.file_path_literal_map);
    if (map_fd < 0) {
        report_log(EHPROBE_LOG_ERROR, "Failed to get file_path_literal_map FD: %s", strerror(errno));
        return -errno;
    }

    struct file_path_filter_key key = {0};
    strncpy(key.path, path, FILE_PATH_FILTER_MAX_LEN - 1);

    int ret = bpf_map_delete_elem(map_fd, &key);
    if (ret < 0) {
        if (errno == ENOENT) {
            return -ENOENT;
        }
        report_log(EHPROBE_LOG_ERROR, "Failed to remove literal path '%s': %s", path, strerror(errno));
        return -errno;
    }

    report_log(EHPROBE_LOG_DEBUG, "Removed literal path filter: %s", path);
    return 0;
}

// Remove a prefix path from the LPM trie filter
int ehprobe_file_path_remove_prefix(const char *prefix) {
    if (!g_ehprobe.initialized) {
        return EHPROBE_ERROR_NOT_INITIALIZED;
    }

    if (!prefix) {
        return EHPROBE_ERROR_INVALID_PARAM;
    }

    size_t prefix_len = strnlen(prefix, FILE_PATH_FILTER_MAX_LEN);
    if (prefix_len == 0 || prefix_len >= FILE_PATH_FILTER_MAX_LEN) {
        return EHPROBE_ERROR_INVALID_PARAM;
    }

    int map_fd = bpf_map__fd(g_ehprobe.skel->maps.file_path_prefix_lpm);
    if (map_fd < 0) {
        report_log(EHPROBE_LOG_ERROR, "Failed to get file_path_prefix_lpm FD: %s", strerror(errno));
        return -errno;
    }

    struct file_path_lpm_key key = {0};
    key.prefixlen = (uint32_t)(prefix_len * 8);
    strncpy((char *)key.data, prefix, FILE_PATH_FILTER_MAX_LEN - 1);

    int ret = bpf_map_delete_elem(map_fd, &key);
    if (ret < 0) {
        if (errno == ENOENT) {
            return -ENOENT;
        }
        report_log(EHPROBE_LOG_ERROR, "Failed to remove prefix '%s': %s", prefix, strerror(errno));
        return -errno;
    }

    report_log(EHPROBE_LOG_DEBUG, "Removed prefix path filter: %s", prefix);
    return 0;
}

// Clear all path filters
int ehprobe_file_path_clear_all(void) {
    if (!g_ehprobe.initialized) {
        return EHPROBE_ERROR_NOT_INITIALIZED;
    }

    int literal_map_fd = bpf_map__fd(g_ehprobe.skel->maps.file_path_literal_map);
    if (literal_map_fd < 0) {
        report_log(EHPROBE_LOG_ERROR, "Failed to get file_path_literal_map FD: %s", strerror(errno));
        return -errno;
    }

    int prefix_map_fd = bpf_map__fd(g_ehprobe.skel->maps.file_path_prefix_lpm);
    if (prefix_map_fd < 0) {
        report_log(EHPROBE_LOG_ERROR, "Failed to get file_path_prefix_lpm FD: %s", strerror(errno));
        return -errno;
    }

    // Clear literal paths by always getting and deleting the first key
    // Using NULL as prev_key always returns the first key in the map
    struct file_path_filter_key lit_key = {0};
    int cleared_literals = 0;

    while (bpf_map_get_next_key(literal_map_fd, NULL, &lit_key) == 0) {
        int del_ret = bpf_map_delete_elem(literal_map_fd, &lit_key);
        if (del_ret < 0) {
            report_log(EHPROBE_LOG_ERROR, "Failed to delete literal path entry: %s", strerror(errno));
            break;
        }
        cleared_literals++;
    }

    // Clear prefix LPM trie entries using get-next-key iteration
    struct file_path_lpm_key lpm_key = {0};
    struct file_path_lpm_key lpm_next_key = {0};
    int cleared_prefixes = 0;

    while (bpf_map_get_next_key(prefix_map_fd, NULL, &lpm_next_key) == 0) {
        lpm_key = lpm_next_key;
        int del_ret = bpf_map_delete_elem(prefix_map_fd, &lpm_key);
        if (del_ret < 0) {
            report_log(EHPROBE_LOG_ERROR, "Failed to delete prefix path entry: %s", strerror(errno));
            break;
        }
        cleared_prefixes++;
    }

    report_log(EHPROBE_LOG_DEBUG, "Cleared all path filters: %d literals, %d prefixes",
               cleared_literals, cleared_prefixes);
    return 0;
}
