#pragma once

#include <stdint.h>
#include <stdbool.h>
#include "ehprobe.h"

// Global debug flag
extern bool debug_output;
extern volatile bool running;

// Standard system directories to scan for executables
extern const char *SYSTEM_DIRECTORIES[];
extern const int SYSTEM_DIRECTORIES_COUNT;

// Statistics for allowlist building
typedef struct {
    int total_files_scanned;
    int executables_found;
    int added_to_allowlist;
    int failed_to_add;
} allowlist_stats_t;

// Utility functions
void print_timestamp(uint64_t timestamp_ns);
void print_param_string(const ehprobe_param_t *param);
void print_param_bytebuf(const ehprobe_param_t *param);
const char* get_signal_name(uint32_t sig);
int calculate_file_hash(const char *filepath, unsigned char *hash);
int calculate_file_hash_fd(int fd, unsigned char *hash);

// File info functions
int get_file_info(const char *filepath, uint64_t *ino, uint32_t *dev);
int get_file_info_at(int dirfd, const char *filepath, uint64_t *ino, uint32_t *dev);
bool is_executable_file(const char *filepath);
bool is_executable_file_at(int dirfd, const char *filepath);
