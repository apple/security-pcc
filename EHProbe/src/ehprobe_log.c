// ehprobe_log.c - Logging implementation
#include <stdio.h>
#include <string.h>
#include <stdarg.h>
#include <bpf/libbpf.h>
#include "ehprobe_internal.h"

// Log message buffers
static char g_log_message[512 * 1024];
static char g_libbpf_message[512 * 1024];

void report_log(ehprobe_log_level_t level, const char *format, ...) {
    // Skip debug messages if debug output is not enabled
    if (level == EHPROBE_LOG_DEBUG && !g_ehprobe.config.enable_debug_output) {
        return;
    }
    
    if (!g_ehprobe.config.log_handler) {
        return;
    }
    
    va_list args;
    va_start(args, format);
    vsnprintf(g_log_message, sizeof(g_log_message), format, args);
    va_end(args);
    
    g_ehprobe.config.log_handler(level, g_log_message);
}

int libbpf_print_fn(enum libbpf_print_level level, const char *format, va_list args) {
    if (!g_ehprobe.config.log_handler) {
        return 0;
    }
    
    vsnprintf(g_libbpf_message, sizeof(g_libbpf_message), format, args);
    
    // Remove trailing newline if present
    size_t len = strlen(g_libbpf_message);
    if (len > 0 && g_libbpf_message[len - 1] == '\n') {
        g_libbpf_message[len - 1] = '\0';
    }
    
    // Map libbpf log levels to our log levels
    ehprobe_log_level_t log_level;
    switch (level) {
    case LIBBPF_DEBUG:
        log_level = EHPROBE_LOG_DEBUG;
        break;
    case LIBBPF_INFO:
        log_level = EHPROBE_LOG_INFO;
        break;
    case LIBBPF_WARN:
        log_level = EHPROBE_LOG_WARNING;
        break;
    default:
        log_level = EHPROBE_LOG_INFO;
        break;
    }
    
    report_log(log_level, "[libbpf] %s", g_libbpf_message);
    return 0;
}
