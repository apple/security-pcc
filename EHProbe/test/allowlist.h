#pragma once

#include <stdint.h>
#include "utils.h"

int add_file_to_allowlist(const char *filepath, allowlist_stats_t *stats);
int add_container_file_to_allowlist(uint64_t container_id, int rootfd, 
                                   const char *filepath, allowlist_stats_t *stats);

void scan_directory(const char *dirpath, allowlist_stats_t *stats, int max_depth);
void scan_container_directory(uint64_t container_id, int rootfd, 
                             const char *dirpath, allowlist_stats_t *stats, int max_depth);

int build_host_allowlist(void);
int build_container_allowlist(uint64_t container_id, int64_t container_pid);
