#include "allowlist.h"
#include "utils.h"
#include "ehprobe.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <limits.h>
#include <sys/stat.h>

int add_file_to_allowlist(const char *filepath, allowlist_stats_t *stats) {
    uint64_t ino;
    uint32_t dev;
    
    if (get_file_info(filepath, &ino, &dev) != 0) {
        if (debug_output) {
            fprintf(stderr, "Failed to get file info for '%s': %s\n", 
                    filepath, strerror(errno));
        }
        return -1;
    }
    
    unsigned char hash[32];
    if (calculate_file_hash(filepath, hash) != 0) {
        if (debug_output) {
            fprintf(stderr, "Failed to calculate hash for '%s': %s\n", 
                    filepath, strerror(errno));
        }
        return -1;
    }
    
    int ret = ehprobe_add_file_to_exec_allowlist(0, ino, dev, hash);
    if (ret != 0) {
        if (debug_output) {
            fprintf(stderr, "Failed to add '%s' to allowlist: %d\n", filepath, ret);
        }
        if (stats) stats->failed_to_add++;
        return ret;
    }
    
    if (stats) stats->added_to_allowlist++;
    
    if (debug_output) {
        printf("  Added: %s (inode=%lu, dev=%u)\n", filepath, ino, dev);
    }
    
    return 0;
}

int add_container_file_to_allowlist(uint64_t container_id, int rootfd, 
                                   const char *filepath, allowlist_stats_t *stats) {
    uint64_t ino;
    uint32_t dev;
    
    if (get_file_info_at(rootfd, filepath, &ino, &dev) != 0) {
        if (debug_output) {
            fprintf(stderr, "Failed to get file info for '%s' in container %lu: %s\n", 
                    filepath, container_id, strerror(errno));
        }
        return -1;
    }
    
    int fd = openat(rootfd, filepath, O_RDONLY);
    if (fd < 0) {
        if (debug_output) {
            fprintf(stderr, "Failed to open '%s' in container %lu: %s\n", 
                    filepath, container_id, strerror(errno));
        }
        return -1;
    }
    
    unsigned char hash[32];
    int hash_result = calculate_file_hash_fd(fd, hash);
    close(fd);
    
    if (hash_result != 0) {
        if (debug_output) {
            fprintf(stderr, "Failed to calculate hash for '%s' in container %lu\n", 
                    filepath, container_id);
        }
        return -1;
    }
    
    int ret = ehprobe_add_file_to_exec_allowlist(container_id, ino, dev, hash);
    if (ret != 0) {
        if (debug_output) {
            fprintf(stderr, "Failed to add '%s' to container %lu allowlist: %d\n", 
                    filepath, container_id, ret);
        }
        if (stats) stats->failed_to_add++;
        return ret;
    }
    
    if (stats) stats->added_to_allowlist++;
    
    if (debug_output) {
        printf("  Added to container %lu: %s (inode=%lu, dev=%u)\n", 
               container_id, filepath, ino, dev);
    }
    
    return 0;
}

void scan_directory(const char *dirpath, allowlist_stats_t *stats, int max_depth) {
    DIR *dir;
    struct dirent *entry;
    char filepath[PATH_MAX];
    
    if (max_depth <= 0) {
        return;
    }
    
    dir = opendir(dirpath);
    if (!dir) {
        if (debug_output && errno != ENOENT) {
            fprintf(stderr, "Cannot open directory '%s': %s\n", dirpath, strerror(errno));
        }
        return;
    }
    
    while ((entry = readdir(dir)) != NULL) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
            continue;
        }
        
        snprintf(filepath, sizeof(filepath), "%s/%s", dirpath, entry->d_name);
        
        if (stats) stats->total_files_scanned++;
        
        struct stat st;
        if (stat(filepath, &st) == 0) {
            if (S_ISDIR(st.st_mode)) {
                scan_directory(filepath, stats, max_depth - 1);
            } else if (is_executable_file(filepath)) {
                if (stats) stats->executables_found++;
                add_file_to_allowlist(filepath, stats);
            }
        }
    }
    
    closedir(dir);
}

void scan_container_directory(uint64_t container_id, int rootfd, 
                             const char *dirpath, allowlist_stats_t *stats, int max_depth) {
    DIR *dir;
    struct dirent *entry;
    char filepath[PATH_MAX];
    
    if (max_depth <= 0) {
        return;
    }
    
    int dirfd = openat(rootfd, dirpath, O_RDONLY | O_DIRECTORY);
    if (dirfd < 0) {
        if (debug_output && errno != ENOENT) {
            fprintf(stderr, "Cannot open container directory '%s': %s\n", dirpath, strerror(errno));
        }
        return;
    }
    
    dir = fdopendir(dirfd);
    if (!dir) {
        close(dirfd);
        if (debug_output) {
            fprintf(stderr, "Cannot open container directory '%s': %s\n", dirpath, strerror(errno));
        }
        return;
    }
    
    while ((entry = readdir(dir)) != NULL) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
            continue;
        }
        
        snprintf(filepath, sizeof(filepath), "%s/%s", dirpath, entry->d_name);
        
        if (stats) stats->total_files_scanned++;
        
        struct stat st;
        if (fstatat(rootfd, filepath, &st, 0) == 0) {
            if (S_ISDIR(st.st_mode)) {
                scan_container_directory(container_id, rootfd, filepath, stats, max_depth - 1);
            } else if (is_executable_file_at(rootfd, filepath)) {
                if (stats) stats->executables_found++;
                add_container_file_to_allowlist(container_id, rootfd, filepath, stats);
            }
        }
    }
    
    closedir(dir);
}

int build_host_allowlist(void) {
    allowlist_stats_t stats = {0};
    char full_path[PATH_MAX];
    
    printf("\nBuilding execution allowlist for host system...\n");
    
    for (int i = 0; i < SYSTEM_DIRECTORIES_COUNT; i++) {
        snprintf(full_path, sizeof(full_path), "/%s", SYSTEM_DIRECTORIES[i]);
        printf("Scanning directory: %s\n", full_path);
        scan_directory(full_path, &stats, 3);
    }
    
    printf("\nHost allowlist building complete:\n");
    printf("  Total files scanned: %d\n", stats.total_files_scanned);
    printf("  Executables found: %d\n", stats.executables_found);
    printf("  Added to allowlist: %d\n", stats.added_to_allowlist);
    if (stats.failed_to_add > 0) {
        printf("  Failed to add: %d\n", stats.failed_to_add);
    }
    
    return stats.added_to_allowlist;
}

int build_container_allowlist(uint64_t container_id, int64_t container_pid) {
    allowlist_stats_t stats = {0};
    char container_root[PATH_MAX];
    
    snprintf(container_root, sizeof(container_root), "/proc/%ld/root", container_pid);
    
    int rootfd = open(container_root, O_RDONLY | O_DIRECTORY);
    if (rootfd < 0) {
        fprintf(stderr, "Failed to open container %lu root at %s: %s\n", 
                container_id, container_root, strerror(errno));
        return -1;
    }
    
    printf("\nBuilding execution allowlist for container %lu (pid=%ld)...\n", 
           container_id, container_pid);
    
    for (int i = 0; i < SYSTEM_DIRECTORIES_COUNT; i++) {
        if (debug_output) {
            printf("Scanning container directory: /%s\n", SYSTEM_DIRECTORIES[i]);
        }
        scan_container_directory(container_id, rootfd, SYSTEM_DIRECTORIES[i], &stats, 3);
    }
    
    close(rootfd);
    
    printf("Container %lu allowlist complete: scanned=%d, found=%d, added=%d", 
           container_id, stats.total_files_scanned, stats.executables_found, 
           stats.added_to_allowlist);
    if (stats.failed_to_add > 0) {
        printf(", failed=%d", stats.failed_to_add);
    }
    printf("\n");
    
    return stats.added_to_allowlist;
}
