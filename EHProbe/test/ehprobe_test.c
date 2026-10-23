#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>
#include "ehprobe.h"
#include "utils.h"
#include "event_handlers.h"
#include "allowlist.h"
#include "container_tracker.h"

static void sig_handler(int sig) {
    running = false;
}

static void print_usage(const char *prog_name) {
    printf("Usage: %s [OPTIONS]\n", prog_name);
    printf("Options:\n");
    printf("  -e, --exec          Enable exec/exit/fork event monitoring\n");
    printf("  -f, --fs            Enable filesystem event monitoring\n");
    printf("  -n, --network       Enable network event monitoring\n");
    printf("  -k, --block-kill    Block kill attempts to this process\n");
    printf("  -x, --block-exec    Block unauthorized executables\n");
    printf("  -d, --debug         Enable debug output\n");
    printf("  -b SIZE             Ring buffer size in KB (default: 256)\n");
    printf("  -t TIMEOUT          Poll timeout in ms (default: 100)\n");
    printf("  -h, --help          Show this help message\n");
}

int main(int argc, char **argv) {
    ehprobe_config_t config = {
        .features = 0,
        .ring_buffer_size_kb = 256,
        .poll_timeout_ms = 100,
        .enable_debug_output = false,
        .event_handler = event_handler,
        .log_handler = log_handler,
        .user_context = NULL
    };
    
    // Parse command line arguments
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-e") == 0 || strcmp(argv[i], "--exec") == 0) {
            config.features |= EHPROBE_FEATURE_EXEC;
        } else if (strcmp(argv[i], "-f") == 0 || strcmp(argv[i], "--fs") == 0) {
            config.features |= EHPROBE_FEATURE_FS;
        } else if (strcmp(argv[i], "-n") == 0 || strcmp(argv[i], "--network") == 0) {
            config.features |= EHPROBE_FEATURE_NETWORK;
        } else if (strcmp(argv[i], "-k") == 0 || strcmp(argv[i], "--block-kill") == 0) {
            config.features |= EHPROBE_FEATURE_BLOCK_KILL;
        } else if (strcmp(argv[i], "-x") == 0 || strcmp(argv[i], "--block-exec") == 0) {
            config.features |= EHPROBE_FEATURE_BLOCK_EXEC;
        } else if (strcmp(argv[i], "-d") == 0 || strcmp(argv[i], "--debug") == 0) {
            config.enable_debug_output = true;
            debug_output = true;
        } else if (strcmp(argv[i], "-b") == 0 && i + 1 < argc) {
            config.ring_buffer_size_kb = atoi(argv[++i]);
        } else if (strcmp(argv[i], "-t") == 0 && i + 1 < argc) {
            config.poll_timeout_ms = atoi(argv[++i]);
        } else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
            print_usage(argv[0]);
            return 0;
        } else {
            fprintf(stderr, "Unknown option: %s\n", argv[i]);
            print_usage(argv[0]);
            return 1;
        }
    }
    
    // Default to all monitoring features if none specified
    if ((config.features & (EHPROBE_FEATURE_EXEC | EHPROBE_FEATURE_FS | EHPROBE_FEATURE_NETWORK)) == 0) {
        config.features |= EHPROBE_FEATURE_EXEC | EHPROBE_FEATURE_FS | EHPROBE_FEATURE_NETWORK;
    }
    
    signal(SIGINT, sig_handler);
    signal(SIGTERM, sig_handler);
    
    printf("Initializing ehprobe with features: 0x%x\n", config.features);
    
    int ret = ehprobe_init(&config);
    if (ret < 0) {
        fprintf(stderr, "Failed to initialize ehprobe: %d\n", ret);
        return 1;
    }
    
    // If BLOCK_EXEC feature is enabled, set up the host allowlist
    if (config.features & EHPROBE_FEATURE_BLOCK_EXEC) {
        int num_added = build_host_allowlist();
        
        if (num_added == 0) {
            fprintf(stderr, "Warning: No executables were added to the host allowlist!\n");
            fprintf(stderr, "Execution blocking may prevent all programs from running.\n");
        }
        
        printf("\nEnabling execution blocking (enforce mode) for host...\n");
        ret = ehprobe_set_blocking_mode(EHPROBE_BLOCKING_MODE_ENFORCE);
        if (ret != 0) {
            fprintf(stderr, "Failed to set blocking mode: %d\n", ret);
        } else {
            printf("Host execution blocking enabled - only allowlisted binaries can run\n");
        }
    }
    
    ret = ehprobe_start();
    if (ret < 0) {
        fprintf(stderr, "Failed to start monitoring: %d\n", ret);
        ehprobe_destroy();
        return 1;
    }
    
    printf("\nUniversal Event Monitor Started\n");
    printf("Monitoring events:\n");
    if (config.features & EHPROBE_FEATURE_EXEC) {
        printf("  - Process exec/exit/fork\n");
    }
    if (config.features & EHPROBE_FEATURE_FS) {
        printf("  - Filesystem operations (including device access)\n");
    }
    if (config.features & EHPROBE_FEATURE_NETWORK) {
        printf("  - Network connections\n");
    }
    if (config.features & EHPROBE_FEATURE_BLOCK_KILL) {
        printf("  - Blocking kill attempts to PID %d\n", getpid());
    }
    if (config.features & EHPROBE_FEATURE_BLOCK_EXEC) {
        printf("  - Blocking unauthorized executables (auto-scan enabled)\n");
        printf("  - Scanning directories: ");
        for (int i = 0; i < SYSTEM_DIRECTORIES_COUNT; i++) {
            printf("/%s ", SYSTEM_DIRECTORIES[i]);
        }
        printf("\n");
    }
    if (debug_output) {
        printf("  - Debug logging enabled\n");
    }
    printf("\nPress Ctrl-C to stop...\n\n");
    
    // Main event loop
    while (running) {
        ret = ehprobe_poll(config.poll_timeout_ms);
        if (ret < 0) {
            if (ret != -1 || running) {
                fprintf(stderr, "Poll returned error: %d\n", ret);
            }
            break;
        }
    }
    
    printf("\nStopping monitor...\n");
    
    cleanup_all_containers();
    
    if (config.features & EHPROBE_FEATURE_BLOCK_EXEC) {
        printf("Disabling host execution blocking...\n");
        ehprobe_set_blocking_mode(EHPROBE_BLOCKING_MODE_OFF);
    }
    
    ehprobe_stop();
    ehprobe_destroy();
    
    return 0;
}
