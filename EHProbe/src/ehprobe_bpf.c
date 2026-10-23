// ehprobe_bpf.c - BPF program management
#include <errno.h>
#include <string.h>
#include <unistd.h>
#include <bpf/libbpf.h>
#include <bpf/bpf.h>
#include <bpf/btf.h>
#include "ehprobe_internal.h"
#include "data.h"
#include "events.h"

// ============================================================================
// Program table — single source of truth for the program ↔ feature mapping.
// Drives configure_autoload(), configure_bpf_programs(), and
// detach_all_programs() so the mapping is never duplicated.
// ============================================================================

#define EHPROBE_MAX_PROGS 100
#define EHPROBE_MAX_TAILCALLS 16

struct prog_entry {
    struct bpf_program *prog;
    struct bpf_link   **link;
    uint32_t            feature;
    const char         *name;
};

struct tailcall_entry {
    struct bpf_program *prog;
    struct bpf_map    **map;
    uint32_t            key;
    uint32_t            feature;
    const char         *name;
};

static struct prog_entry g_prog_table[EHPROBE_MAX_PROGS];
static int g_prog_table_count;

static struct tailcall_entry g_tailcall_table[EHPROBE_MAX_TAILCALLS];
static int g_tailcall_table_count;

// Per-feature rollback policy.
// all_or_nothing = true:  one failed attach disables the entire feature group.
// all_or_nothing = false: individual failures are logged, rest of group stays.
static bool is_all_or_nothing(uint32_t feature) {
    switch (feature) {
    case EHPROBE_FEATURE_EXEC:
    case EHPROBE_FEATURE_NETWORK:
        return false;   // partial coverage still useful
    default:
        return true;    // FS, DPI, blocking: all or nothing
    }
}

void build_prog_table(struct ehprobe_bpf *skel) {
    int i = 0;

#define E(p, l, f, n) \
    g_prog_table[i++] = (struct prog_entry){ skel->progs.p, &g_ehprobe.links.l, f, n }

    // Exec / Exit / Fork
    E(handle_exec,                  handle_exec,                  EHPROBE_FEATURE_EXEC,         "handle_exec");
    E(handle_exit,                  handle_exit,                  EHPROBE_FEATURE_EXEC,         "handle_exit");
    E(handle_fork_tp,               handle_fork,                  EHPROBE_FEATURE_EXEC,         "handle_fork");
    E(handle_setuid,                handle_setuid,                EHPROBE_FEATURE_EXEC,         "handle_setuid");
    E(handle_setgid,                handle_setgid,                EHPROBE_FEATURE_EXEC,         "handle_setgid");

    // Filesystem
    E(handle_file_open,             handle_file_open,             EHPROBE_FEATURE_FS,           "handle_file_open");
    E(handle_file_open_new_exec,    handle_file_open_new_exec,    EHPROBE_FEATURE_FS,           "handle_file_open_new_exec");
    E(handle_path_chmod,            handle_path_chmod,            EHPROBE_FEATURE_FS,           "handle_path_chmod");
    E(handle_kprobe_chrdev_open,    handle_kprobe_chrdev_open,    EHPROBE_FEATURE_FS,           "handle_kprobe_chrdev_open");
    E(handle_kretprobe_chrdev_open, handle_kretprobe_chrdev_open, EHPROBE_FEATURE_FS,           "handle_kretprobe_chrdev_open");
    E(handle_kprobe_vfs_write,      handle_kprobe_vfs_write,      EHPROBE_FEATURE_FS,           "handle_kprobe_vfs_write");
    E(handle_kretprobe_vfs_write,   handle_kretprobe_vfs_write,   EHPROBE_FEATURE_FS,           "handle_kretprobe_vfs_write");
    E(handle_path_unlink,           handle_path_unlink,           EHPROBE_FEATURE_FS,           "handle_path_unlink");

    // Network
    E(handle_kprobe_socket,         handle_kprobe_socket,         EHPROBE_FEATURE_NETWORK,      "handle_kprobe_socket");
    E(handle_kretprobe_socket,      handle_kretprobe_socket,      EHPROBE_FEATURE_NETWORK,      "handle_kretprobe_socket");
    E(handle_kprobe_close,          handle_kprobe_close,          EHPROBE_FEATURE_NETWORK,      "handle_kprobe_close");
    E(handle_kprobe_connect,        handle_kprobe_connect,        EHPROBE_FEATURE_NETWORK,      "handle_kprobe_connect");
    E(handle_kretprobe_connect,     handle_kretprobe_connect,     EHPROBE_FEATURE_NETWORK,      "handle_kretprobe_connect");
    E(handle_kprobe_accept4,        handle_kprobe_accept4,        EHPROBE_FEATURE_NETWORK,      "handle_kprobe_accept4");
    E(handle_kretprobe_accept4,     handle_kretprobe_accept4,     EHPROBE_FEATURE_NETWORK,      "handle_kretprobe_accept4");
    E(handle_kprobe_sendto,         handle_kprobe_sendto,         EHPROBE_FEATURE_NETWORK,      "handle_kprobe_sendto");
    E(handle_kprobe_sendmsg,        handle_kprobe_sendmsg,        EHPROBE_FEATURE_NETWORK,      "handle_kprobe_sendmsg");
    E(handle_kprobe_sendmmsg,       handle_kprobe_sendmmsg,       EHPROBE_FEATURE_NETWORK,      "handle_kprobe_sendmmsg");
    E(handle_kprobe_recvfrom,       handle_kprobe_recvfrom,       EHPROBE_FEATURE_NETWORK,      "handle_kprobe_recvfrom");
    E(handle_kretprobe_recvfrom,    handle_kretprobe_recvfrom,    EHPROBE_FEATURE_NETWORK,      "handle_kretprobe_recvfrom");
    E(handle_kprobe_recvmsg,        handle_kprobe_recvmsg,        EHPROBE_FEATURE_NETWORK,      "handle_kprobe_recvmsg");
    E(handle_kretprobe_recvmsg,     handle_kretprobe_recvmsg,     EHPROBE_FEATURE_NETWORK,      "handle_kretprobe_recvmsg");

    // AF_ALG detection / blocking (CVE-2026-31431). Deliberately its own
    // feature — runs regardless of whether full NETWORK telemetry is on.
    E(handle_socket_bind,           handle_socket_bind,           EHPROBE_FEATURE_AF_ALG,       "handle_socket_bind");

    // Dirty Frag — kernel module load observer (autoload + finit_module).
    // Blocks rxrpc.ko loads originating from any source.
    E(handle_kernel_module_request, handle_kernel_module_request, EHPROBE_FEATURE_MODULE_LOAD,  "handle_kernel_module_request");
    E(handle_kernel_read_file,      handle_kernel_read_file,      EHPROBE_FEATURE_MODULE_LOAD,  "handle_kernel_read_file");

    // Dirty Frag — XFRM SA registration observer. Kills tasks in
    // non-init userns that register XFRM_STATE_ESN SAs (the ESP
    // variant's exact preconditions).
    E(handle_xfrm_add_sa,           handle_xfrm_add_sa,           EHPROBE_FEATURE_XFRM_SA_NEW,  "handle_xfrm_add_sa");

    // Blocking
    E(handle_bprm_check,            handle_bprm_check,            EHPROBE_FEATURE_BLOCK_EXEC,   "handle_bprm_check");
    E(handle_file_post_open,        handle_file_post_open,        EHPROBE_FEATURE_BLOCK_SCRIPT, "handle_file_post_open");
    E(handle_script_path_exec,      handle_script_path_exec,      EHPROBE_FEATURE_BLOCK_SCRIPT, "handle_script_path_exec");
    E(handle_task_kill,             handle_task_kill,             EHPROBE_FEATURE_BLOCK_KILL,   "handle_task_kill");

    // DPI
    E(handle_kprobe_tcp_sendmsg,    handle_kprobe_tcp_sendmsg,    EHPROBE_FEATURE_DPI,          "handle_kprobe_tcp_sendmsg");
    E(handle_kprobe_tcp_recvmsg,    handle_kprobe_tcp_recvmsg,    EHPROBE_FEATURE_DPI,          "handle_kprobe_tcp_recvmsg");
    E(handle_kretprobe_tcp_recvmsg, handle_kretprobe_tcp_recvmsg, EHPROBE_FEATURE_DPI,          "handle_kretprobe_tcp_recvmsg");

#undef E

    g_prog_table_count = i;

    // Tail call targets — loaded by the skeleton but placed into prog_array
    // maps rather than attached to hooks.
    int j = 0;

#define T(p, map, k, f, n) \
    g_tailcall_table[j++] = (struct tailcall_entry){ skel->progs.p, &skel->maps.map, k, f, n }

    T(handle_inline_code_exec,   inline_code_progs,  0, EHPROBE_FEATURE_BLOCK_SCRIPT, "handle_inline_code_exec");
    T(script_path_find_arg,      script_path_progs,  0, EHPROBE_FEATURE_BLOCK_SCRIPT, "script_path_find_arg");
    T(script_path_copy,          script_path_progs,  1, EHPROBE_FEATURE_BLOCK_SCRIPT, "script_path_copy");
    T(handle_bare_interp_exec,   bare_interp_progs,  0, EHPROBE_FEATURE_BLOCK_SCRIPT, "handle_bare_interp_exec");

#undef T

    g_tailcall_table_count = j;

    report_log(EHPROBE_LOG_DEBUG, "Built program table with %d entries, %d tail calls", i, j);
}

// ============================================================================
// BTF feature probing
// ============================================================================

uint32_t probe_supported_features(void) {
    uint32_t supported = ~0u;

    struct btf *vmlinux = btf__parse("/sys/kernel/btf/vmlinux", NULL);
    if (!vmlinux || libbpf_get_error(vmlinux)) {
        report_log(EHPROBE_LOG_WARNING,
                   "Cannot read /sys/kernel/btf/vmlinux, skipping feature probing");
        return supported;
    }

    struct {
        const char *func;
        uint32_t    feature;
        const char *label;
    } probes[] = {
        { "bpf_lsm_bprm_check_security",   EHPROBE_FEATURE_BLOCK_EXEC,   "BLOCK_EXEC"   },
        { "bpf_lsm_file_post_open",        EHPROBE_FEATURE_BLOCK_SCRIPT, "BLOCK_SCRIPT" },
        { "bpf_lsm_task_kill",             EHPROBE_FEATURE_BLOCK_KILL,   "BLOCK_KILL"   },
        { "bpf_lsm_kernel_module_request", EHPROBE_FEATURE_MODULE_LOAD,  "MODULE_LOAD"  },
        { "bpf_lsm_kernel_read_file",      EHPROBE_FEATURE_MODULE_LOAD,  "MODULE_LOAD"  },
    };

    for (size_t i = 0; i < sizeof(probes) / sizeof(probes[0]); i++) {
        if (btf__find_by_name_kind(vmlinux, probes[i].func, BTF_KIND_FUNC) <= 0) {
            supported &= ~probes[i].feature;
            report_log(EHPROBE_LOG_WARNING,
                       "Kernel lacks %s — %s feature unavailable",
                       probes[i].func, probes[i].label);
        }
    }

    btf__free(vmlinux);
    return supported;
}

// ============================================================================
// Attach / detach helpers
// ============================================================================

static int attach_prog(struct bpf_program *prog, struct bpf_link **link, const char *name) {
    if (*link) {
        return 0;
    }

    *link = bpf_program__attach(prog);
    if (!*link) {
        int err = -errno;
        report_log(EHPROBE_LOG_ERROR, "Failed to attach %s: %s", name, strerror(errno));
        return err;
    }

    report_log(EHPROBE_LOG_DEBUG, "Attached %s", name);
    return 0;
}

static void detach_prog(struct bpf_link **link, const char *name) {
    if (*link) {
        bpf_link__destroy(*link);
        *link = NULL;
        report_log(EHPROBE_LOG_DEBUG, "Detached %s", name);
    }
}

// ============================================================================
// Table-driven program management
// ============================================================================

int configure_autoload(struct ehprobe_bpf *skel, uint32_t features) {
    report_log(EHPROBE_LOG_DEBUG, "Configuring autoload for features: 0x%x", features);

    for (int i = 0; i < g_prog_table_count; i++) {
        if (!(features & g_prog_table[i].feature)) {
            bpf_program__set_autoload(g_prog_table[i].prog, false);
        }
    }

    for (int i = 0; i < g_tailcall_table_count; i++) {
        if (!(features & g_tailcall_table[i].feature)) {
            bpf_program__set_autoload(g_tailcall_table[i].prog, false);
        }
    }

    return 0;
}

int configure_bpf_programs(uint32_t features) {
    report_log(EHPROBE_LOG_DEBUG, "Configuring BPF programs for features: 0x%x", features);

    uint32_t failed_features = 0;

    for (int i = 0; i < g_prog_table_count; i++) {
        struct prog_entry *e = &g_prog_table[i];

        if (failed_features & e->feature) {
            continue;  // group already marked for rollback
        }

        if (features & e->feature) {
            int err = attach_prog(e->prog, e->link, e->name);
            if (err) {
                if (is_all_or_nothing(e->feature)) {
                    report_log(EHPROBE_LOG_WARNING,
                               "%s attach failed, disabling feature 0x%x", e->name, e->feature);
                    failed_features |= e->feature;
                } else {
                    report_log(EHPROBE_LOG_WARNING,
                               "%s attach failed, continuing with partial feature", e->name);
                }
            }
        } else {
            detach_prog(e->link, e->name);
        }
    }

    // Populate tail call prog_array maps
    for (int i = 0; i < g_tailcall_table_count; i++) {
        struct tailcall_entry *t = &g_tailcall_table[i];

        if (failed_features & t->feature) {
            continue;
        }

        if (features & t->feature) {
            int map_fd = bpf_map__fd(*t->map);
            int prog_fd = bpf_program__fd(t->prog);
            int err = bpf_map_update_elem(map_fd, &t->key, &prog_fd, BPF_ANY);
            if (err) {
                report_log(EHPROBE_LOG_ERROR,
                           "Failed to populate tail call %s: %s", t->name, strerror(errno));
                if (is_all_or_nothing(t->feature)) {
                    failed_features |= t->feature;
                }
            } else {
                report_log(EHPROBE_LOG_DEBUG, "Populated tail call %s", t->name);
            }
        } else {
            int map_fd = bpf_map__fd(*t->map);
            bpf_map_delete_elem(map_fd, &t->key);
        }
    }

    // Roll back all-or-nothing groups that had any failure
    if (failed_features) {
        for (int i = 0; i < g_prog_table_count; i++) {
            if (failed_features & g_prog_table[i].feature) {
                detach_prog(g_prog_table[i].link, g_prog_table[i].name);
            }
        }
        features &= ~failed_features;
        update_env_flags(features);
    }

    return 0;
}

void detach_all_programs(void) {
    report_log(EHPROBE_LOG_DEBUG, "Detaching all BPF programs");

    for (int i = 0; i < g_tailcall_table_count; i++) {
        int map_fd = bpf_map__fd(*g_tailcall_table[i].map);
        bpf_map_delete_elem(map_fd, &g_tailcall_table[i].key);
        report_log(EHPROBE_LOG_DEBUG, "Cleared tail call %s", g_tailcall_table[i].name);
    }

    for (int i = 0; i < g_prog_table_count; i++) {
        detach_prog(g_prog_table[i].link, g_prog_table[i].name);
    }
}

int update_env_flags(uint32_t features) {
    int map_fd = bpf_map__fd(g_ehprobe.skel->maps.ehprobe_env_map);
    if (map_fd < 0) {
        report_log(EHPROBE_LOG_ERROR, "Failed to get env map FD: %s", strerror(errno));
        return -errno;
    }

    uint32_t map_id = 0;
    struct ehprobe_env env = {0};
    int ret = bpf_map_lookup_elem(map_fd, &map_id, &env);
    if (ret < 0) {
        report_log(EHPROBE_LOG_ERROR, "Failed to lookup env map: %s", strerror(errno));
        return -errno;
    }

    env.flag_exec = (features & EHPROBE_FEATURE_EXEC) ? 1 : 0;
    env.flag_fs = (features & EHPROBE_FEATURE_FS) ? 1 : 0;
    env.flag_network = (features & EHPROBE_FEATURE_NETWORK) ? 1 : 0;
    // blocking_mode is set separately via ehprobe_set_blocking_mode(), not from feature flags
    env.flag_block_kill = (features & EHPROBE_FEATURE_BLOCK_KILL) ? 1 : 0;
    env.flag_dpi = (features & EHPROBE_FEATURE_DPI) ? 1 : 0;
    env.flag_block_script = (features & EHPROBE_FEATURE_BLOCK_SCRIPT) ? 1 : 0;
    env.flag_af_alg = (features & EHPROBE_FEATURE_AF_ALG) ? 1 : 0;
    env.flag_module_load = (features & EHPROBE_FEATURE_MODULE_LOAD) ? 1 : 0;
    env.flag_xfrm_sa_new = (features & EHPROBE_FEATURE_XFRM_SA_NEW) ? 1 : 0;
    // script_blocking_mode and af_alg_block_mode are set separately via dedicated API functions
    // module_load_block_mode and xfrm_sa_new_block_mode ditto

    report_log(EHPROBE_LOG_INFO, "update_env_flags: features=0x%x flag_dpi=%llu flag_network=%llu flag_af_alg=%llu",
               features, (unsigned long long)env.flag_dpi, (unsigned long long)env.flag_network,
               (unsigned long long)env.flag_af_alg);
    
    if (features & EHPROBE_FEATURE_BLOCK_KILL) {
        env.block_kill_pid_target = getpid();
        env.block_kill_pid_except_source = getppid();
    } else {
        env.block_kill_pid_target = 0;
        env.block_kill_pid_except_source = 0;
    }

    ret = bpf_map_update_elem(map_fd, &map_id, &env, BPF_ANY);
    if (ret < 0) {
        report_log(EHPROBE_LOG_ERROR, "Failed to update env map: %s", strerror(errno));
        return -errno;
    }

    return 0;
}

int init_percpu_buffers(void) {
    int map_fd = bpf_map__fd(g_ehprobe.skel->maps.event_context_map);
    int cpu_cnt = libbpf_num_possible_cpus();
    
    report_log(EHPROBE_LOG_DEBUG, "Initializing %d per-CPU buffers", cpu_cnt);
    
    struct event_context *init_values = calloc(cpu_cnt, sizeof(struct event_context));
    if (!init_values) {
        report_log(EHPROBE_LOG_ERROR, 
                   "Failed to allocate %d per-CPU buffers", cpu_cnt);
        return EHPROBE_ERROR_NOMEM;
    }
    
    uint32_t key = 0;
    int ret = bpf_map_update_elem(map_fd, &key, init_values, BPF_ANY);
    free(init_values);
    
    if (ret < 0) {
        report_log(EHPROBE_LOG_ERROR,
                   "Failed to initialize per-CPU buffers: %s", strerror(errno));
        return EHPROBE_ERROR_BPF_LOAD;
    }
    
    report_log(EHPROBE_LOG_DEBUG, "Per-CPU buffers initialized successfully");
    return EHPROBE_SUCCESS;
}
