#include "event_handlers.h"
#include "utils.h"
#include "allowlist.h"
#include "container_tracker.h"
#include <stdio.h>
#include <time.h>
#include <pwd.h>
#include <grp.h>
#include <arpa/inet.h>

void log_handler(ehprobe_log_level_t level, const char *message) {
    const char *level_str;
    FILE *output = stderr;
    
    switch (level) {
    case EHPROBE_LOG_DEBUG:
        level_str = "DEBUG";
        break;
    case EHPROBE_LOG_INFO:
        level_str = "INFO";
        break;
    case EHPROBE_LOG_WARNING:
        level_str = "WARN";
        break;
    case EHPROBE_LOG_ERROR:
        level_str = "ERROR";
        break;
    default:
        level_str = "UNKNOWN";
        break;
    }
    
    time_t now = time(NULL);
    struct tm *tm = localtime(&now);
    char time_str[32];
    strftime(time_str, sizeof(time_str), "%H:%M:%S", tm);
    
    fprintf(output, "[%s] [%s] %s\n", time_str, level_str, message);
}

static void handle_exec_event(const ehprobe_event_t *event) {
    ehprobe_param_t param;
    
    print_timestamp(event->timestamp_ns);
    printf(" EXEC: pid=%d", event->pid);
    
    // Parameter 1: trusted_exepath (NONE for now)
    if (ehprobe_get_param(event, 0, &param) == 0) {
        if (param.type != EHPROBE_PARAM_NONE) {
            printf(" trusted_exepath=");
            print_param_string(&param);
        }
    }
    
    // Parameter 2: exe (STRING)
    if (ehprobe_get_param(event, 1, &param) == 0 && param.type == EHPROBE_PARAM_STRING) {
        printf(" exe=");
        print_param_string(&param);
    }
    
    // Parameter 3: args (NONE for now)
    // Skip - complex type
    
    // Parameter 4: pid (S64)
    if (ehprobe_get_param(event, 3, &param) == 0 && param.type == EHPROBE_PARAM_S64) {
        printf(" tid=%ld", param.value.s64);
    }
    
    // Parameter 5: pgid (S64)
    if (ehprobe_get_param(event, 4, &param) == 0 && param.type == EHPROBE_PARAM_S64) {
        printf(" pgid=%ld", param.value.s64);
    }
    
    // Parameter 6: comm (STRING)
    if (ehprobe_get_param(event, 5, &param) == 0 && param.type == EHPROBE_PARAM_STRING) {
        printf(" comm=");
        print_param_string(&param);
    }
    
    // Parameter 7: cwd (NONE for now)
    if (ehprobe_get_param(event, 6, &param) == 0 && param.type == EHPROBE_PARAM_STRING) {
        printf(" pwd=");
        print_param_string(&param);
    }
    
    // Parameter 8: cgroups (NONE for now)
    // Skip - complex type
    
    // Parameter 9: tty (U32)
    if (ehprobe_get_param(event, 8, &param) == 0 && param.type == EHPROBE_PARAM_U32) {
        printf(" tty=%u", param.value.u32);
    }
    
    // Parameter 10: euid (U32)
    if (ehprobe_get_param(event, 9, &param) == 0 && param.type == EHPROBE_PARAM_U32) {
        struct passwd *pwd = getpwuid(param.value.u32);
        printf(" euid=%u(%s)", param.value.u32, pwd ? pwd->pw_name : "?");
    }
    
    // Parameter 11: egid (U32)
    if (ehprobe_get_param(event, 10, &param) == 0 && param.type == EHPROBE_PARAM_U32) {
        struct group *grp = getgrgid(param.value.u32);
        printf(" egid=%u(%s)", param.value.u32, grp ? grp->gr_name : "?");
    }
    
    // Parameter 12: parent_trusted_exepath (NONE for now)
    // Skip - complex type
    
    // Parameter 13: container_id (U64)
    if (ehprobe_get_param(event, 12, &param) == 0 && param.type == EHPROBE_PARAM_U64) {
        if (param.value.u64 > 0) {
            printf(" container_id=%lu", param.value.u64);
        }
    }
    
    // Parameter 14: container_level (U32)
    if (ehprobe_get_param(event, 13, &param) == 0 && param.type == EHPROBE_PARAM_U32) {
        if (param.value.u32 > 0) {
            printf(" container_level=%u", param.value.u32);
        }
    }
    
    printf("\n");
}

static void handle_exit_event(const ehprobe_event_t *event) {
    ehprobe_param_t param;
    
    print_timestamp(event->timestamp_ns);
    printf(" EXIT:");
    
    // Parameter 1: pid (S64)
    if (ehprobe_get_param(event, 0, &param) == 0 && param.type == EHPROBE_PARAM_S64) {
        printf(" pid=%ld", param.value.s64);
    }
    
    // Parameter 2: exit_code (S64)
    if (ehprobe_get_param(event, 1, &param) == 0 && param.type == EHPROBE_PARAM_S64) {
        printf(" status=%ld", param.value.s64);
    }
    
    // Parameter 3: ret (S64)
    if (ehprobe_get_param(event, 2, &param) == 0 && param.type == EHPROBE_PARAM_S64) {
        printf(" ret=%ld", param.value.s64);
    }
    
    // Parameter 4: sig (U32)
    if (ehprobe_get_param(event, 3, &param) == 0 && param.type == EHPROBE_PARAM_U32) {
        if (param.value.u32 > 0) {
            printf(" sig=%u(%s)", param.value.u32, get_signal_name(param.value.u32));
        }
    }
    
    // Parameter 5: core (U32)
    if (ehprobe_get_param(event, 4, &param) == 0 && param.type == EHPROBE_PARAM_U32) {
        if (param.value.u32 > 0) {
            printf(" core=%u", param.value.u32);
        }
    }
    
    // Parameter 6: container_id (U64)
    if (ehprobe_get_param(event, 5, &param) == 0 && param.type == EHPROBE_PARAM_U64) {
        if (param.value.u64 > 0) {
            printf(" container_id=%lu", param.value.u64);
        }
    }
    
    // Parameter 7: container_level (U32)
    if (ehprobe_get_param(event, 6, &param) == 0 && param.type == EHPROBE_PARAM_U32) {
        if (param.value.u32 > 0) {
            printf(" container_level=%u", param.value.u32);
        }
    }
    
    printf("\n");
}

static void handle_fork_event(const ehprobe_event_t *event) {
    ehprobe_param_t param;

    print_timestamp(event->timestamp_ns);
    printf(" FORK:");

    // Parameter 0: child_pid (S64)
    if (ehprobe_get_param(event, 0, &param) == 0 && param.type == EHPROBE_PARAM_S64) {
        printf(" child_pid=%ld", param.value.s64);
    }

    // Parameter 1: parent_pid (S64)
    if (ehprobe_get_param(event, 1, &param) == 0 && param.type == EHPROBE_PARAM_S64) {
        printf(" parent_pid=%ld", param.value.s64);
    }

    // Parameter 2: comm (STRING)
    if (ehprobe_get_param(event, 2, &param) == 0 && param.type == EHPROBE_PARAM_STRING) {
        printf(" child_comm=");
        print_param_string(&param);
    }

    // Parameter 3: parent_exe (STRING or NONE)
    if (ehprobe_get_param(event, 3, &param) == 0) {
        if (param.type == EHPROBE_PARAM_STRING) {
            printf(" parent_exe=");
            print_param_string(&param);
        } else if (debug_output && param.type == EHPROBE_PARAM_NONE) {
            printf(" parent_exe=<not_available>");
        }
    }

    // Parameter 4: container_id (U64)
    if (ehprobe_get_param(event, 4, &param) == 0 && param.type == EHPROBE_PARAM_U64) {
        if (param.value.u64 > 0) {
            printf(" container_id=%lu", param.value.u64);
        }
    }

    // Parameter 5: container_level (U32)
    if (ehprobe_get_param(event, 5, &param) == 0 && param.type == EHPROBE_PARAM_U32) {
        if (param.value.u32 > 0) {
            printf(" container_level=%u", param.value.u32);
        }
    }

    printf("\n");
}

static void handle_new_fs_exec_event(const ehprobe_event_t *event) {
    ehprobe_param_t param;
    
    print_timestamp(event->timestamp_ns);
    printf(" NEW_FS_EXEC:");
    
    // Parameter 1: path
    if (ehprobe_get_param(event, 0, &param) == 0) {
        if (param.type == EHPROBE_PARAM_STRING) {
            printf(" path=");
            print_param_string(&param);
        } else if (debug_output && param.type == EHPROBE_PARAM_NONE) {
            printf(" path=<not_available>");
        }
    }
    
    // Parameter 2: hash
    if (ehprobe_get_param(event, 1, &param) == 0) {
        if (param.type == EHPROBE_PARAM_BYTEBUF) {
            printf(" hash=");
            print_param_bytebuf(&param);
        } else if (debug_output && param.type == EHPROBE_PARAM_NONE) {
            printf(" hash=<not_available>");
        }
    }
    
    // Parameter 3: pid (S64)
    if (ehprobe_get_param(event, 2, &param) == 0 && param.type == EHPROBE_PARAM_S64) {
        printf(" pid=%ld", param.value.s64);
    }
    
    // Parameter 4: process_path
    if (ehprobe_get_param(event, 3, &param) == 0) {
        if (param.type == EHPROBE_PARAM_STRING) {
            printf(" process_path=");
            print_param_string(&param);
        } else if (debug_output && param.type == EHPROBE_PARAM_NONE) {
            printf(" process_path=<not_available>");
        }
    }
    
    // Parameter 5: operation (U32)
    if (ehprobe_get_param(event, 4, &param) == 0 && param.type == EHPROBE_PARAM_U32) {
        const char *op_name = "UNKNOWN";
        switch(param.value.u32) {
            case 1: op_name = "CREATE"; break;
            case 2: op_name = "CHMOD"; break;
        }
        printf(" operation=%s(%u)", op_name, param.value.u32);
    }
    
    // Parameter 6: container_id (U64)
    if (ehprobe_get_param(event, 5, &param) == 0 && param.type == EHPROBE_PARAM_U64) {
        if (param.value.u64 > 0) {
            printf(" container_id=%lu", param.value.u64);
        }
    }
    
    // Parameter 7: container_level (U32)
    if (ehprobe_get_param(event, 6, &param) == 0 && param.type == EHPROBE_PARAM_U32) {
        if (param.value.u32 > 0) {
            printf(" container_level=%u", param.value.u32);
        }
    }
    
    printf("\n");
}

static void handle_exec_security_event(const ehprobe_event_t *event) {
    ehprobe_param_t param;
    
    print_timestamp(event->timestamp_ns);
    printf(" EXEC_SECURITY:");
    
    // Parameter 1: path (STRING)
    if (ehprobe_get_param(event, 0, &param) == 0 && param.type == EHPROBE_PARAM_STRING) {
        printf(" path=");
        print_param_string(&param);
    }
    
    // Parameter 2: hash (BYTEBUF or NONE)
    if (ehprobe_get_param(event, 1, &param) == 0) {
        if (param.type == EHPROBE_PARAM_BYTEBUF) {
            printf(" hash=");
            print_param_bytebuf(&param);
        } else if (debug_output && param.type == EHPROBE_PARAM_NONE) {
            printf(" hash=<not_available>");
        }
    }
    
    // Parameter 3: pid (S64)
    if (ehprobe_get_param(event, 2, &param) == 0 && param.type == EHPROBE_PARAM_S64) {
        printf(" pid=%ld", param.value.s64);
    }
    
    // Parameter 4: container_id (U64)
    if (ehprobe_get_param(event, 3, &param) == 0 && param.type == EHPROBE_PARAM_U64) {
        if (param.value.u64 > 0) {
            printf(" container_id=%lu", param.value.u64);
        }
    }
    
    // Parameter 5: container_level (U32)
    if (ehprobe_get_param(event, 4, &param) == 0 && param.type == EHPROBE_PARAM_U32) {
        if (param.value.u32 > 0) {
            printf(" container_level=%u", param.value.u32);
        }
    }
    
    // Parameter 6: allow (U32)
    if (ehprobe_get_param(event, 5, &param) == 0 && param.type == EHPROBE_PARAM_U32) {
        const char *decision = (param.value.u32 != 0) ? "ALLOWED" : "DENIED";
        printf(" decision=%s", decision);

        // Highlight denied executions
        if (param.value.u32 == 0) {
            printf(" [BLOCKED]");
        }
    }

    // Parameter 7: blocking_mode (U32)
    if (ehprobe_get_param(event, 6, &param) == 0 && param.type == EHPROBE_PARAM_U32) {
        const char *mode_str = "off";
        switch (param.value.u32) {
            case EHPROBE_BLOCKING_MODE_AUDIT:   mode_str = "audit";   break;
            case EHPROBE_BLOCKING_MODE_ENFORCE: mode_str = "enforce"; break;
        }
        printf(" blocking_mode=%s", mode_str);
    }

    printf("\n");
}

static void handle_container_start_event(const ehprobe_event_t *event) {
    ehprobe_param_t param;
    uint64_t container_id = 0;
    int64_t container_pid = 0;
    uint32_t blocking_mode = EHPROBE_BLOCKING_MODE_OFF;
    
    print_timestamp(event->timestamp_ns);
    printf(" CONTAINER_START:");
    
    // Parameter 1: container_id (U64)
    if (ehprobe_get_param(event, 0, &param) == 0 && param.type == EHPROBE_PARAM_U64) {
        container_id = param.value.u64;
        printf(" container_id=%lu", container_id);
    }
    
    // Parameter 2: level (U32)
    if (ehprobe_get_param(event, 1, &param) == 0 && param.type == EHPROBE_PARAM_U32) {
        printf(" level=%u", param.value.u32);
    }
    
    // Parameter 3: pid (S64)
    if (ehprobe_get_param(event, 2, &param) == 0 && param.type == EHPROBE_PARAM_S64) {
        container_pid = param.value.s64;
        printf(" pid=%ld", container_pid);
    }
    
    // Parameter 4: ppid (S64)
    if (ehprobe_get_param(event, 3, &param) == 0 && param.type == EHPROBE_PARAM_S64) {
        printf(" ppid=%ld", param.value.s64);
    }
    
    // Parameter 5: pid_ns_inum (U64)
    if (ehprobe_get_param(event, 4, &param) == 0 && param.type == EHPROBE_PARAM_U64) {
        printf(" pid_ns=%lu", param.value.u64);
    }
    
    // Parameter 6: mnt_ns_inum (U64)
    if (ehprobe_get_param(event, 5, &param) == 0 && param.type == EHPROBE_PARAM_U64) {
        printf(" mnt_ns=%lu", param.value.u64);
    }
    
    // Parameter 7: net_ns_inum (U64)
    if (ehprobe_get_param(event, 6, &param) == 0 && param.type == EHPROBE_PARAM_U64) {
        printf(" net_ns=%lu", param.value.u64);
    }
    
    // Parameter 8: cgroup_id (U64)
    if (ehprobe_get_param(event, 7, &param) == 0 && param.type == EHPROBE_PARAM_U64) {
        printf(" cgroup=%lu", param.value.u64);
    }
    
    // Parameter 9: runtime (STRING)
    if (ehprobe_get_param(event, 8, &param) == 0 && param.type == EHPROBE_PARAM_STRING) {
        printf(" runtime=");
        print_param_string(&param);
    }
    
    // Parameter 10: blocking_mode (U32)
    if (ehprobe_get_param(event, 9, &param) == 0 && param.type == EHPROBE_PARAM_U32) {
        blocking_mode = param.value.u32;
        if (blocking_mode == EHPROBE_BLOCKING_MODE_AUDIT) {
            printf(" [BLOCKING_AUDIT]");
        } else if (blocking_mode == EHPROBE_BLOCKING_MODE_ENFORCE) {
            printf(" [BLOCKING_ENFORCE]");
        }
    }
    
    printf("\n");
    
    // Build allowlist for container if we have the necessary info
    if (container_id > 0 && container_pid > 0) {
        track_container(container_id);
        
        int num_added = build_container_allowlist(container_id, container_pid);
        
        if (num_added > 0 && blocking_mode != EHPROBE_BLOCKING_MODE_OFF) {
            printf("Setting blocking mode for container %lu...\n", container_id);
            int ret = ehprobe_set_container_blocking_mode(container_id, blocking_mode);
            if (ret != 0) {
                fprintf(stderr, "Failed to set blocking mode for container %lu: %d\n",
                        container_id, ret);
            } else {
                const char *mode_str = (blocking_mode == EHPROBE_BLOCKING_MODE_AUDIT) ? "audit" : "enforce";
                printf("Container %lu blocking mode set to %s\n", container_id, mode_str);
            }
        } else if (num_added == 0) {
            fprintf(stderr, "Warning: No executables added for container %lu\n", container_id);
        }
    }
}

static void handle_container_stop_event(const ehprobe_event_t *event) {
    ehprobe_param_t param;
    uint64_t container_id = 0;
    
    print_timestamp(event->timestamp_ns);
    printf(" CONTAINER_STOP:");
    
    // Parameter 1: container_id (U64)
    if (ehprobe_get_param(event, 0, &param) == 0 && param.type == EHPROBE_PARAM_U64) {
        container_id = param.value.u64;
        printf(" container_id=%lu", container_id);
    }
    
    // Parameter 2: level (U32)
    if (ehprobe_get_param(event, 1, &param) == 0 && param.type == EHPROBE_PARAM_U32) {
        printf(" level=%u", param.value.u32);
    }
    
    // Parameter 3: exit_signal (U32)
    if (ehprobe_get_param(event, 2, &param) == 0 && param.type == EHPROBE_PARAM_U32) {
        if (param.value.u32 > 0) {
            printf(" exit_signal=%u(%s)", param.value.u32, get_signal_name(param.value.u32));
        }
    }
    
    // Parameter 4: exit_code (S64)
    if (ehprobe_get_param(event, 3, &param) == 0 && param.type == EHPROBE_PARAM_S64) {
        printf(" exit_code=%ld", param.value.s64);
    }
    
    // Parameter 5: runtime (STRING)
    if (ehprobe_get_param(event, 4, &param) == 0 && param.type == EHPROBE_PARAM_STRING) {
        printf(" runtime=");
        print_param_string(&param);
    }
    
    // Parameter 6: blocking_mode (U32)
    if (ehprobe_get_param(event, 5, &param) == 0 && param.type == EHPROBE_PARAM_U32) {
        if (param.value.u32 == EHPROBE_BLOCKING_MODE_AUDIT) {
            printf(" [BLOCKING_AUDIT]");
        } else if (param.value.u32 == EHPROBE_BLOCKING_MODE_ENFORCE) {
            printf(" [BLOCKING_ENFORCE]");
        }
    }
    
    printf("\n");
    
    // Clean up container allowlist if we were tracking it
    if (container_id > 0) {
        printf("Cleaning up container %lu allowlist...\n", container_id);
        ehprobe_remove_container_from_exec_allowlist(container_id);
        untrack_container(container_id);
    }
}

static void handle_bprm_check_event(const ehprobe_event_t *event) {
    ehprobe_param_t param;
    struct passwd *pwd;
    struct group *grp;
    
    print_timestamp(event->timestamp_ns);
    printf(" BPRM_CHECK: pid=%d", event->pid);
    
    if (ehprobe_get_param(event, 0, &param) == 0 && param.type == EHPROBE_PARAM_U32) {
        pwd = getpwuid(param.value.u32);
        printf(" uid=%u(%s)", param.value.u32, pwd ? pwd->pw_name : "?");
    }
    
    if (ehprobe_get_param(event, 1, &param) == 0 && param.type == EHPROBE_PARAM_U32) {
        grp = getgrgid(param.value.u32);
        printf(" gid=%u(%s)", param.value.u32, grp ? grp->gr_name : "?");
    }
    
    if (ehprobe_get_param(event, 2, &param) == 0) {
        printf(" file=");
        print_param_string(&param);
    }
    printf("\n");
}

static void handle_block_kill_event(const ehprobe_event_t *event) {
    ehprobe_param_t param;
    
    print_timestamp(event->timestamp_ns);
    printf(" BLOCK_KILL:");
    
    // Parameter 1: source_pid (S64)
    if (ehprobe_get_param(event, 0, &param) == 0 && param.type == EHPROBE_PARAM_S64) {
        printf(" source_pid=%ld", param.value.s64);
    }
    
    // Parameter 2: sig (U32)
    if (ehprobe_get_param(event, 1, &param) == 0 && param.type == EHPROBE_PARAM_U32) {
        printf(" signal=%u(%s)", param.value.u32, get_signal_name(param.value.u32));
        printf(" [BLOCKED]");
    }
    
    printf("\n");
}

static void handle_task_kill_event(const ehprobe_event_t *event) {
    ehprobe_param_t param;
    
    print_timestamp(event->timestamp_ns);
    printf(" TASK_KILL: pid=%d", event->pid);
    
    if (ehprobe_get_param(event, 0, &param) == 0 && param.type == EHPROBE_PARAM_U32) {
        printf(" -> target_pid=%u", param.value.u32);
    }
    
    if (ehprobe_get_param(event, 1, &param) == 0 && param.type == EHPROBE_PARAM_S32) {
        printf(" signal=%d(%s)", param.value.s32, get_signal_name(param.value.s32));
    }
    
    if (ehprobe_get_param(event, 2, &param) == 0) {
        printf(" target=");
        print_param_string(&param);
    }
    printf("\n");
}

static void handle_file_open_event(const ehprobe_event_t *event) {
    ehprobe_param_t param;
    
    print_timestamp(event->timestamp_ns);
    printf(" FILE_OPEN: pid=%d", event->pid);
    
    if (ehprobe_get_param(event, 0, &param) == 0 && param.type == EHPROBE_PARAM_U32) {
        printf(" flags=0x%x", param.value.u32);
    }
    
    if (ehprobe_get_param(event, 1, &param) == 0 && param.type == EHPROBE_PARAM_U32) {
        printf(" mode=0x%x", param.value.u32);
    }
    
    if (ehprobe_get_param(event, 2, &param) == 0 && param.type == EHPROBE_PARAM_U32) {
        printf(" inode=%u", param.value.u32);
    }
    
    if (ehprobe_get_param(event, 3, &param) == 0 && param.type == EHPROBE_PARAM_U32) {
        printf(" dev=%u", param.value.u32);
    }
    
    if (ehprobe_get_param(event, 4, &param) == 0) {
        printf(" file=");
        print_param_string(&param);
    }
    printf("\n");
}

static void handle_path_chmod_event(const ehprobe_event_t *event) {
    ehprobe_param_t param;
    ehprobe_param_t new_mode, old_mode;
    
    print_timestamp(event->timestamp_ns);
    printf(" PATH_CHMOD: pid=%d", event->pid);
    
    if (ehprobe_get_param(event, 0, &new_mode) == 0 && new_mode.type == EHPROBE_PARAM_U32 &&
        ehprobe_get_param(event, 1, &old_mode) == 0 && old_mode.type == EHPROBE_PARAM_U32) {
        printf(" mode=%04o -> %04o", 
               old_mode.value.u32 & 07777, new_mode.value.u32 & 07777);
    }
    
    if (ehprobe_get_param(event, 2, &param) == 0) {
        printf(" file=");
        print_param_string(&param);
    }
    printf("\n");
}

static void handle_net_tcp_event(const ehprobe_event_t *event) {
    ehprobe_param_t param;
    
    print_timestamp(event->timestamp_ns);
    printf(" NET_TCP: pid=%d", event->pid);
    
    // Parameter 0: pid (S64)
    if (ehprobe_get_param(event, 0, &param) == 0 && param.type == EHPROBE_PARAM_S64) {
        printf(" tid=%ld", param.value.s64);
    }
    
    // Parameter 1: comm (STRING)
    if (ehprobe_get_param(event, 1, &param) == 0 && param.type == EHPROBE_PARAM_STRING) {
        printf(" comm=");
        print_param_string(&param);
    }
    
    // Parameter 2: fd (S64)
    if (ehprobe_get_param(event, 2, &param) == 0 && param.type == EHPROBE_PARAM_S64) {
        printf(" fd=%ld", param.value.s64);
    }
    
    // Parameter 3: family (U32)
    uint32_t family = 0;
    if (ehprobe_get_param(event, 3, &param) == 0 && param.type == EHPROBE_PARAM_U32) {
        family = param.value.u32;
        printf(" family=%s", family == AF_INET ? "IPv4" : "IPv6");
    }
    
    // Parameter 4: dest_addr (BYTEBUF)
    if (ehprobe_get_param(event, 4, &param) == 0 && param.type == EHPROBE_PARAM_BYTEBUF) {
        char addr_str[INET6_ADDRSTRLEN];
        if (family == AF_INET && param.length == 4) {
            inet_ntop(AF_INET, param.value.bytebuf, addr_str, sizeof(addr_str));
        } else if (family == AF_INET6 && param.length == 16) {
            inet_ntop(AF_INET6, param.value.bytebuf, addr_str, sizeof(addr_str));
        } else {
            snprintf(addr_str, sizeof(addr_str), "<invalid>");
        }
        printf(" dest=%s", addr_str);
    }
    
    // Parameter 5: dest_port (U32)
    if (ehprobe_get_param(event, 5, &param) == 0 && param.type == EHPROBE_PARAM_U32) {
        printf(":%u", param.value.u32);
    }
    
    // Parameter 6: local_port (U32)
    if (ehprobe_get_param(event, 6, &param) == 0 && param.type == EHPROBE_PARAM_U32) {
        printf(" local_port=%u", param.value.u32);
    }
    
    // Parameter 7: initiator (U32)
    if (ehprobe_get_param(event, 7, &param) == 0 && param.type == EHPROBE_PARAM_U32) {
        const char *dir = (param.value.u32 == 1) ? "outbound" : "inbound";
        printf(" initiator=%s", dir);
    }
    
    // Parameter 8: uid (U32)
    if (ehprobe_get_param(event, 8, &param) == 0 && param.type == EHPROBE_PARAM_U32) {
        struct passwd *pwd = getpwuid(param.value.u32);
        printf(" uid=%u(%s)", param.value.u32, pwd ? pwd->pw_name : "?");
    }
    
    // Parameter 9: container_id (U64)
    if (ehprobe_get_param(event, 9, &param) == 0 && param.type == EHPROBE_PARAM_U64) {
        if (param.value.u64 > 0) {
            printf(" container_id=%lu", param.value.u64);
        }
    }
    
    // Parameter 10: container_level (U32)
    if (ehprobe_get_param(event, 10, &param) == 0 && param.type == EHPROBE_PARAM_U32) {
        if (param.value.u32 > 0) {
            printf(" container_level=%u", param.value.u32);
        }
    }
    
    printf("\n");
}

static void handle_net_udp_event(const ehprobe_event_t *event) {
    ehprobe_param_t param;
    
    print_timestamp(event->timestamp_ns);
    printf(" NET_UDP: pid=%d", event->pid);
    
    // Parameter 0: pid (S64)
    if (ehprobe_get_param(event, 0, &param) == 0 && param.type == EHPROBE_PARAM_S64) {
        printf(" tid=%ld", param.value.s64);
    }
    
    // Parameter 1: comm (STRING)
    if (ehprobe_get_param(event, 1, &param) == 0 && param.type == EHPROBE_PARAM_STRING) {
        printf(" comm=");
        print_param_string(&param);
    }
    
    // Parameter 2: family (U32)
    uint32_t family = 0;
    if (ehprobe_get_param(event, 2, &param) == 0 && param.type == EHPROBE_PARAM_U32) {
        family = param.value.u32;
        printf(" family=%s", family == AF_INET ? "IPv4" : "IPv6");
    }
    
    // Parameter 3: remote_addr (BYTEBUF)
    if (ehprobe_get_param(event, 3, &param) == 0 && param.type == EHPROBE_PARAM_BYTEBUF) {
        char addr_str[INET6_ADDRSTRLEN];
        if (family == AF_INET && param.length == 4) {
            inet_ntop(AF_INET, param.value.bytebuf, addr_str, sizeof(addr_str));
        } else if (family == AF_INET6 && param.length == 16) {
            inet_ntop(AF_INET6, param.value.bytebuf, addr_str, sizeof(addr_str));
        } else {
            snprintf(addr_str, sizeof(addr_str), "<invalid>");
        }
        printf(" remote=%s", addr_str);
    }
    
    // Parameter 4: remote_port (U32)
    if (ehprobe_get_param(event, 4, &param) == 0 && param.type == EHPROBE_PARAM_U32) {
        printf(":%u", param.value.u32);
    }
    
    // Parameter 5: local_port (U32)
    if (ehprobe_get_param(event, 5, &param) == 0 && param.type == EHPROBE_PARAM_U32) {
        printf(" local_port=%u", param.value.u32);
    }
    
    // Parameter 6: initiator (U32)
    if (ehprobe_get_param(event, 6, &param) == 0 && param.type == EHPROBE_PARAM_U32) {
        const char *dir = (param.value.u32 == 1) ? "outbound" : "inbound";
        printf(" initiator=%s", dir);
    }
    
    // Parameter 7: uid (U32)
    if (ehprobe_get_param(event, 7, &param) == 0 && param.type == EHPROBE_PARAM_U32) {
        struct passwd *pwd = getpwuid(param.value.u32);
        printf(" uid=%u(%s)", param.value.u32, pwd ? pwd->pw_name : "?");
    }
    
    // Parameter 8: container_id (U64)
    if (ehprobe_get_param(event, 8, &param) == 0 && param.type == EHPROBE_PARAM_U64) {
        if (param.value.u64 > 0) {
            printf(" container_id=%lu", param.value.u64);
        }
    }
    
    // Parameter 9: container_level (U32)
    if (ehprobe_get_param(event, 9, &param) == 0 && param.type == EHPROBE_PARAM_U32) {
        if (param.value.u32 > 0) {
            printf(" container_level=%u", param.value.u32);
        }
    }
    
    printf("\n");
}

// Helper function to get DNS query type name
static const char *get_dns_qtype_name(uint16_t qtype) {
    switch (qtype) {
    case 1:   return "A";
    case 2:   return "NS";
    case 5:   return "CNAME";
    case 6:   return "SOA";
    case 12:  return "PTR";
    case 15:  return "MX";
    case 16:  return "TXT";
    case 28:  return "AAAA";
    case 33:  return "SRV";
    case 255: return "ANY";
    default:  return "UNKNOWN";
    }
}

// Helper function to get DNS response code name
static const char *get_dns_rcode_name(uint8_t rcode) {
    switch (rcode) {
    case 0: return "NOERROR";
    case 1: return "FORMERR";
    case 2: return "SERVFAIL";
    case 3: return "NXDOMAIN";
    case 4: return "NOTIMP";
    case 5: return "REFUSED";
    default: return "UNKNOWN";
    }
}

// Helper function to parse DNS name from payload
// Returns the number of bytes consumed, or -1 on error
static int parse_dns_name(const unsigned char *payload, uint32_t payload_len, 
                          uint32_t offset, char *name_buf, size_t name_buf_size) {
    size_t name_pos = 0;
    uint32_t pos = offset;
    int jumps = 0;
    const int max_jumps = 10;  // Prevent infinite loops from malformed packets
    
    while (pos < payload_len && jumps < max_jumps) {
        uint8_t label_len = payload[pos];
        
        if (label_len == 0) {
            // End of name
            if (name_pos > 0 && name_pos < name_buf_size) {
                name_buf[name_pos - 1] = '\0';  // Remove trailing dot
            } else if (name_pos < name_buf_size) {
                name_buf[name_pos] = '\0';
            }
            return (pos - offset) + 1;
        }
        
        // Check for compression pointer (top 2 bits set)
        if ((label_len & 0xC0) == 0xC0) {
            if (pos + 1 >= payload_len) {
                return -1;
            }
            uint16_t ptr_offset = ((label_len & 0x3F) << 8) | payload[pos + 1];
            if (ptr_offset >= payload_len) {
                return -1;
            }
            // Follow the pointer (recursively parse from that offset)
            // For simplicity, we'll just note compression was used
            pos = ptr_offset;
            jumps++;
            continue;
        }
        
        // Regular label
        if (pos + 1 + label_len > payload_len) {
            return -1;
        }
        
        // Copy label to buffer
        for (uint8_t i = 0; i < label_len && name_pos < name_buf_size - 2; i++) {
            name_buf[name_pos++] = payload[pos + 1 + i];
        }
        if (name_pos < name_buf_size - 1) {
            name_buf[name_pos++] = '.';
        }
        
        pos += 1 + label_len;
    }
    
    // Null-terminate
    if (name_pos < name_buf_size) {
        name_buf[name_pos] = '\0';
    } else if (name_buf_size > 0) {
        name_buf[name_buf_size - 1] = '\0';
    }
    
    return -1;  // Didn't find end of name
}

static void handle_device_open_event(const ehprobe_event_t *event) {
    ehprobe_param_t param;

    print_timestamp(event->timestamp_ns);
    printf(" DEVICE_OPEN: pid=%d", event->pid);

    // Parameter 0: device_path (STRING)
    if (ehprobe_get_param(event, 0, &param) == 0 && param.type == EHPROBE_PARAM_STRING) {
        printf(" device=");
        print_param_string(&param);
    }

    // Parameter 1: device_major (U32)
    if (ehprobe_get_param(event, 1, &param) == 0 && param.type == EHPROBE_PARAM_U32) {
        printf(" major=%u", param.value.u32);
    }

    // Parameter 2: device_minor (U32)
    if (ehprobe_get_param(event, 2, &param) == 0 && param.type == EHPROBE_PARAM_U32) {
        printf(" minor=%u", param.value.u32);
    }

    // Parameter 3: device_class (STRING)
    if (ehprobe_get_param(event, 3, &param) == 0 && param.type == EHPROBE_PARAM_STRING) {
        printf(" class=");
        print_param_string(&param);
    }

    // Parameter 4: executable_path (STRING)
    if (ehprobe_get_param(event, 4, &param) == 0 && param.type == EHPROBE_PARAM_STRING) {
        printf(" exe=");
        print_param_string(&param);
    }

    // Parameter 5: container_id (U64)
    if (ehprobe_get_param(event, 5, &param) == 0 && param.type == EHPROBE_PARAM_U64) {
        if (param.value.u64 > 0) {
            printf(" container_id=%lu", param.value.u64);
        }
    }

    // Parameter 6: container_level (U32)
    if (ehprobe_get_param(event, 6, &param) == 0 && param.type == EHPROBE_PARAM_U32) {
        if (param.value.u32 > 0) {
            printf(" container_level=%u", param.value.u32);
        }
    }

    printf("\n");
}

static void handle_dns_event(const ehprobe_event_t *event) {
    ehprobe_param_t param;

    print_timestamp(event->timestamp_ns);
    printf(" DNS: pid=%d", event->pid);
    
    // Parameter 0: pid (S64)
    if (ehprobe_get_param(event, 0, &param) == 0 && param.type == EHPROBE_PARAM_S64) {
        printf(" tid=%ld", param.value.s64);
    }
    
    // Parameter 1: comm (STRING)
    if (ehprobe_get_param(event, 1, &param) == 0 && param.type == EHPROBE_PARAM_STRING) {
        printf(" comm=");
        print_param_string(&param);
    }
    
    // Parameter 2: uid (U32)
    if (ehprobe_get_param(event, 2, &param) == 0 && param.type == EHPROBE_PARAM_U32) {
        struct passwd *pwd = getpwuid(param.value.u32);
        printf(" uid=%u(%s)", param.value.u32, pwd ? pwd->pw_name : "?");
    }
    
    // Parameter 3: direction (U32)
    uint32_t direction = 0;
    if (ehprobe_get_param(event, 3, &param) == 0 && param.type == EHPROBE_PARAM_U32) {
        direction = param.value.u32;
        const char *dir = (direction == 1) ? "query" : "response";
        printf(" direction=%s", dir);
    }
    
    // Parameter 4: dns_server_addr (BYTEBUF)
    uint32_t family = 0;
    // We need to get family first (parameter 6)
    if (ehprobe_get_param(event, 6, &param) == 0 && param.type == EHPROBE_PARAM_U32) {
        family = param.value.u32;
    }
    
    if (ehprobe_get_param(event, 4, &param) == 0 && param.type == EHPROBE_PARAM_BYTEBUF) {
        char addr_str[INET6_ADDRSTRLEN];
        if (family == AF_INET && param.length == 4) {
            inet_ntop(AF_INET, param.value.bytebuf, addr_str, sizeof(addr_str));
        } else if (family == AF_INET6 && param.length == 16) {
            inet_ntop(AF_INET6, param.value.bytebuf, addr_str, sizeof(addr_str));
        } else {
            snprintf(addr_str, sizeof(addr_str), "<invalid>");
        }
        printf(" server=%s", addr_str);
    }
    
    // Parameter 5: dns_server_port (U32)
    if (ehprobe_get_param(event, 5, &param) == 0 && param.type == EHPROBE_PARAM_U32) {
        printf(":%u", param.value.u32);
    }
    
    // Parameter 6: family (U32) - already read above
    printf(" family=%s", family == AF_INET ? "IPv4" : "IPv6");
    
    // Parameter 7: dns_payload (BYTEBUF)
    if (ehprobe_get_param(event, 7, &param) == 0 && param.type == EHPROBE_PARAM_BYTEBUF) {
        const unsigned char *payload = param.value.bytebuf;
        uint32_t payload_len = param.length;
        
        if (payload_len >= 12) {
            // Parse DNS header
            uint16_t tx_id = (payload[0] << 8) | payload[1];
            uint16_t flags = (payload[2] << 8) | payload[3];
            uint16_t qdcount = (payload[4] << 8) | payload[5];
            uint16_t ancount = (payload[6] << 8) | payload[7];
            
            uint8_t qr = (flags >> 15) & 0x1;
            uint8_t rcode = flags & 0x0F;
            
            printf(" tx_id=0x%04x", tx_id);
            printf(" qr=%s", qr ? "response" : "query");
            
            if (qr) {
                // Response - show response code
                printf(" rcode=%s(%u)", get_dns_rcode_name(rcode), rcode);
                printf(" answers=%u", ancount);
            }
            
            printf(" questions=%u", qdcount);
            
            // Try to parse the first question
            if (qdcount > 0 && payload_len > 12) {
                char qname[256] = {0};
                int name_len = parse_dns_name(payload, payload_len, 12, qname, sizeof(qname));
                
                if (name_len > 0 && qname[0] != '\0') {
                    printf(" qname=%s", qname);
                    
                    // Get query type (2 bytes after the name)
                    uint32_t qtype_offset = 12 + name_len;
                    if (qtype_offset + 2 <= payload_len) {
                        uint16_t qtype = (payload[qtype_offset] << 8) | payload[qtype_offset + 1];
                        printf(" qtype=%s(%u)", get_dns_qtype_name(qtype), qtype);
                    }
                }
            }
        }
        
        // Show payload size
        printf(" payload_size=%u", payload_len);
    }
    
    // Parameter 8: payload_len (U32) - original length
    if (ehprobe_get_param(event, 8, &param) == 0 && param.type == EHPROBE_PARAM_U32) {
        printf(" original_len=%u", param.value.u32);
    }
    
    // Parameter 9: container_id (U64)
    if (ehprobe_get_param(event, 9, &param) == 0 && param.type == EHPROBE_PARAM_U64) {
        if (param.value.u64 > 0) {
            printf(" container_id=%lu", param.value.u64);
        }
    }
    
    // Parameter 10: container_level (U32)
    if (ehprobe_get_param(event, 10, &param) == 0 && param.type == EHPROBE_PARAM_U32) {
        if (param.value.u32 > 0) {
            printf(" container_level=%u", param.value.u32);
        }
    }
    
    printf("\n");
}

int event_handler(const ehprobe_event_t *event, void *user_context) {
    if (!running) {
        return -1;
    }
    
    switch (event->event_type) {
    case EHPROBE_EVENT_EXEC:
        handle_exec_event(event);
        break;
        
    case EHPROBE_EVENT_EXIT:
        handle_exit_event(event);
        break;

    case EHPROBE_EVENT_FORK:
        handle_fork_event(event);
        break;

    case EHPROBE_EVENT_NEW_FS_EXEC:
        handle_new_fs_exec_event(event);
        break;
        
    case EHPROBE_EVENT_EXEC_SECURITY:
        handle_exec_security_event(event);
        break;
        
    case EHPROBE_EVENT_CONTAINER_START:
        handle_container_start_event(event);
        break;
        
    case EHPROBE_EVENT_CONTAINER_STOP:
        handle_container_stop_event(event);
        break;
        
    case EHPROBE_EVENT_BPRM_CHECK:
        handle_bprm_check_event(event);
        break;
        
    case EHPROBE_EVENT_BLOCK_KILL:
        handle_block_kill_event(event);
        break;
        
    case EHPROBE_EVENT_TASK_KILL:
        handle_task_kill_event(event);
        break;
        
    case EHPROBE_EVENT_FILE_OPEN:
        handle_file_open_event(event);
        break;
        
    case EHPROBE_EVENT_PATH_CHMOD:
        handle_path_chmod_event(event);
        break;

    case EHPROBE_EVENT_DEVICE_OPEN:
        handle_device_open_event(event);
        break;

    case EHPROBE_EVENT_NET_TCP:
        handle_net_tcp_event(event);
        break;

    case EHPROBE_EVENT_NET_UDP:
        handle_net_udp_event(event);
        break;

    case EHPROBE_EVENT_DNS:
        handle_dns_event(event);
        break;

    default:
        printf("Unknown event type: %d\n", event->event_type);
        break;
    }
    
    return 0;
}
