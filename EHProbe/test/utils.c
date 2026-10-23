#include "utils.h"
#include <stdio.h>
#include <time.h>
#include <sys/stat.h>
#include <openssl/evp.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>

// Global variables
bool debug_output = false;
volatile bool running = true;

// Unified list of system directories (without leading slash for containers)
const char *SYSTEM_DIRECTORIES[] = {
    "bin",
    "sbin",
    "usr/bin",
    "usr/sbin",
    "usr/lib",
    "usr/local/bin",
    "usr/local/sbin",
    "usr/libexec",
};

const int SYSTEM_DIRECTORIES_COUNT = sizeof(SYSTEM_DIRECTORIES) / sizeof(SYSTEM_DIRECTORIES[0]);

void print_timestamp(uint64_t timestamp_ns) {
    struct timespec ts;
    struct tm *tm;
    char time_str[32];
    
    time_t sec = timestamp_ns / 1000000000;
    uint64_t nsec = timestamp_ns % 1000000000;
    
    clock_gettime(CLOCK_MONOTONIC, &ts);
    time_t wall_sec = time(NULL) - ts.tv_sec + sec;
    
    tm = localtime(&wall_sec);
    strftime(time_str, sizeof(time_str), "%H:%M:%S", tm);
    
    printf("[%s.%06lu]", time_str, nsec / 1000);
}

void print_param_string(const ehprobe_param_t *param) {
    if (param->type == EHPROBE_PARAM_STRING && param->length > 0) {
        printf("%s", param->value.str);
    } else if (param->type == EHPROBE_PARAM_NONE) {
        printf("<none>");
    } else {
        printf("<invalid>");
    }
}

void print_param_bytebuf(const ehprobe_param_t *param) {
    if (param->type == EHPROBE_PARAM_BYTEBUF && param->length > 0 && param->value.bytebuf) {
        for (uint16_t i = 0; i < param->length && i < 32; i++) {
            printf("%02x", param->value.bytebuf[i]);
        }
        if (param->length > 32) {
            printf("...");
        }
    } else if (param->type == EHPROBE_PARAM_NONE) {
        printf("<none>");
    } else {
        printf("<invalid>");
    }
}

const char* get_signal_name(uint32_t sig) {
    switch(sig) {
        case 1: return "HUP";
        case 2: return "INT";
        case 3: return "QUIT";
        case 4: return "ILL";
        case 5: return "TRAP";
        case 6: return "ABRT";
        case 7: return "BUS";
        case 8: return "FPE";
        case 9: return "KILL";
        case 10: return "USR1";
        case 11: return "SEGV";
        case 12: return "USR2";
        case 13: return "PIPE";
        case 14: return "ALRM";
        case 15: return "TERM";
        case 17: return "CHLD";
        case 18: return "CONT";
        case 19: return "STOP";
        case 20: return "TSTP";
        case 21: return "TTIN";
        case 22: return "TTOU";
        default: return "UNKNOWN";
    }
}

int calculate_file_hash(const char *filepath, unsigned char *hash) {
    int fd = open(filepath, O_RDONLY);
    if (fd < 0) {
        return -1;
    }
    
    int result = calculate_file_hash_fd(fd, hash);
    close(fd);
    return result;
}

int calculate_file_hash_fd(int fd, unsigned char *hash) {
    EVP_MD_CTX *mdctx = EVP_MD_CTX_new();
    if (!mdctx) {
        return -1;
    }
    
    if (EVP_DigestInit_ex(mdctx, EVP_sha256(), NULL) != 1) {
        EVP_MD_CTX_free(mdctx);
        return -1;
    }
    
    unsigned char buffer[8192];
    ssize_t bytes;
    
    // Save current position and reset to beginning
    off_t saved_pos = lseek(fd, 0, SEEK_CUR);
    lseek(fd, 0, SEEK_SET);
    
    while ((bytes = read(fd, buffer, sizeof(buffer))) > 0) {
        if (EVP_DigestUpdate(mdctx, buffer, bytes) != 1) {
            EVP_MD_CTX_free(mdctx);
            lseek(fd, saved_pos, SEEK_SET);
            return -1;
        }
    }
    
    // Restore file position
    lseek(fd, saved_pos, SEEK_SET);
    
    if (bytes < 0) {
        EVP_MD_CTX_free(mdctx);
        return -1;
    }
    
    unsigned int hash_len;
    if (EVP_DigestFinal_ex(mdctx, hash, &hash_len) != 1) {
        EVP_MD_CTX_free(mdctx);
        return -1;
    }
    
    EVP_MD_CTX_free(mdctx);
    return 0;
}

int get_file_info(const char *filepath, uint64_t *ino, uint32_t *dev) {
    struct stat st;
    
    if (stat(filepath, &st) != 0) {
        return -1;
    }
    
    *ino = st.st_ino;
    *dev = st.st_dev;
    
    return 0;
}

int get_file_info_at(int dirfd, const char *filepath, uint64_t *ino, uint32_t *dev) {
    struct stat st;
    
    if (fstatat(dirfd, filepath, &st, 0) != 0) {
        return -1;
    }
    
    *ino = st.st_ino;
    *dev = st.st_dev;
    
    return 0;
}

bool is_executable_file(const char *filepath) {
    struct stat st;
    
    if (stat(filepath, &st) != 0) {
        return false;
    }
    
    return S_ISREG(st.st_mode) && (st.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH));
}

bool is_executable_file_at(int dirfd, const char *filepath) {
    struct stat st;
    
    if (fstatat(dirfd, filepath, &st, 0) != 0) {
        return false;
    }
    
    return S_ISREG(st.st_mode) && (st.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH));
}
