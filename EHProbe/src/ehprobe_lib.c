// ehprobe_lib.c - Core lifecycle implementation
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sched.h>
#include <sys/stat.h>
#include <pthread.h>
#include <bpf/libbpf.h>
#include <bpf/bpf.h>
#include "ehprobe_internal.h"
#include "data.h"
#include "events.h"

// Global state definition
struct ehprobe_state g_ehprobe = {0};

// ============================================================================
// Internal Helper Functions
// ============================================================================

static int init_mutex(void) {
    int ret;
    pthread_mutexattr_t attr;
    
    if (g_ehprobe.mutex_initialized) {
        return EHPROBE_SUCCESS;
    }
    
    ret = pthread_mutexattr_init(&attr);
    if (ret != 0) {
        report_log(EHPROBE_LOG_ERROR, "Failed to initialize mutex attributes: %s", strerror(ret));
        return EHPROBE_ERROR_INIT;
    }
    
    ret = pthread_mutexattr_settype(&attr, 0);
    if (ret != 0) {
        pthread_mutexattr_destroy(&attr);
        report_log(EHPROBE_LOG_ERROR, "Failed to set mutex type to recursive: %s", strerror(ret));
        return EHPROBE_ERROR_INIT;
    }
    
    ret = pthread_mutex_init(&g_ehprobe.state_mutex, &attr);
    if (ret != 0) {
        pthread_mutexattr_destroy(&attr);
        report_log(EHPROBE_LOG_ERROR, "Failed to initialize state mutex: %s", strerror(ret));
        return EHPROBE_ERROR_INIT;
    }
    
    pthread_mutexattr_destroy(&attr);
    g_ehprobe.mutex_initialized = true;
    return EHPROBE_SUCCESS;
}

// ============================================================================
// Public API Implementation
// ============================================================================

int ehprobe_init(const ehprobe_config_t *config) {
    int err;
    
    err = init_mutex();
    if (err != EHPROBE_SUCCESS) {
        report_log(EHPROBE_LOG_ERROR, "Failed to initialize mutexes");
        return err;
    }
    
    pthread_mutex_lock(&g_ehprobe.state_mutex);
    
    if (g_ehprobe.initialized) {
        pthread_mutex_unlock(&g_ehprobe.state_mutex);
        report_log(EHPROBE_LOG_ERROR, "ehprobe is already initialized");
        return EHPROBE_ERROR_ALREADY_RUNNING;
    }
    
    if (!config || !config->event_handler) {
        pthread_mutex_unlock(&g_ehprobe.state_mutex);
        return EHPROBE_ERROR_INVALID_PARAM;
    }
    
    g_ehprobe.config = *config;
    
    if (g_ehprobe.config.ring_buffer_size_kb == 0) {
        g_ehprobe.config.ring_buffer_size_kb = 256;
    }
    if (g_ehprobe.config.poll_timeout_ms == 0) {
        g_ehprobe.config.poll_timeout_ms = 100;
    }
    
    report_log(EHPROBE_LOG_INFO, "Initializing ehprobe with features=0x%x, ring_buffer=%uKB, timeout=%ums",
               g_ehprobe.config.features, 
               g_ehprobe.config.ring_buffer_size_kb,
               g_ehprobe.config.poll_timeout_ms);
    
    libbpf_set_strict_mode(LIBBPF_STRICT_ALL);
    libbpf_set_print(libbpf_print_fn);

    // Probe once which features the kernel can support and strip
    // unsupported bits from the requested set.  The mask is cached
    // so ehprobe_set_features() can re-use it without re-parsing BTF.
    g_ehprobe.supported_features = probe_supported_features();
    uint32_t unsupported = g_ehprobe.config.features & ~g_ehprobe.supported_features;
    if (unsupported) {
        report_log(EHPROBE_LOG_WARNING,
                   "Requested features 0x%x not supported by kernel, masking to 0x%x",
                   unsupported,
                   g_ehprobe.config.features & g_ehprobe.supported_features);
        g_ehprobe.config.features &= g_ehprobe.supported_features;
    }

    report_log(EHPROBE_LOG_DEBUG, "Opening BPF skeleton");
    g_ehprobe.skel = ehprobe_bpf__open();
    if (!g_ehprobe.skel) {
        pthread_mutex_unlock(&g_ehprobe.state_mutex);
        report_log(EHPROBE_LOG_ERROR, "Failed to open BPF skeleton");
        return EHPROBE_ERROR_BPF_LOAD;
    }
    
    report_log(EHPROBE_LOG_DEBUG, "Setting ring buffer size to %u KB",
               g_ehprobe.config.ring_buffer_size_kb);
    bpf_map__set_max_entries(g_ehprobe.skel->maps.rb,
                             g_ehprobe.config.ring_buffer_size_kb * 1024);

    build_prog_table(g_ehprobe.skel);
    configure_autoload(g_ehprobe.skel, g_ehprobe.supported_features);

    report_log(EHPROBE_LOG_INFO, "Loading BPF programs");
    err = ehprobe_bpf__load(g_ehprobe.skel);
    if (err) {
        report_log(EHPROBE_LOG_ERROR,
                   "Failed to load BPF programs: %s", strerror(-err));
        ehprobe_bpf__destroy(g_ehprobe.skel);
        g_ehprobe.skel = NULL;
        pthread_mutex_unlock(&g_ehprobe.state_mutex);
        return EHPROBE_ERROR_BPF_LOAD;
    }

    int map_fd = bpf_map__fd(g_ehprobe.skel->maps.ehprobe_env_map);
    if (map_fd < 0) {
        report_log(EHPROBE_LOG_ERROR, "Failed to find env map");
        ehprobe_bpf__destroy(g_ehprobe.skel);
        g_ehprobe.skel = NULL;
        pthread_mutex_unlock(&g_ehprobe.state_mutex);
        return EHPROBE_ERROR_INIT;
    }

    uint32_t map_id = 0;
    struct ehprobe_env env = {0};

    // Enable file path filtering by default (secure by default)
    // This ensures file events generated during ehprobe_start() are filtered out
    // before the userspace has a chance to configure specific paths
    env.flag_file_path_filter = 1;

    err = get_host_pid_namespace(&(env.host_pid_ns));
    if (err) {
        report_log(EHPROBE_LOG_ERROR, "Failed to get PID namespace for the host, error %d", err);
        ehprobe_bpf__destroy(g_ehprobe.skel);
        g_ehprobe.skel = NULL;
        pthread_mutex_unlock(&g_ehprobe.state_mutex);
        return EHPROBE_ERROR_INIT;
    }
    
    report_log(EHPROBE_LOG_INFO, "Detected host PID namespace: %lu", env.host_pid_ns);
    
    struct stat self_pid_ns_stat, self_mnt_ns_stat, host_mnt_ns_stat;
    struct stat self_cgroup_ns_stat, host_cgroup_ns_stat;
    
    env.running_in_container = 0;
    env.monitor_pid_ns = env.host_pid_ns;
    
    if (stat("/proc/self/ns/pid", &self_pid_ns_stat) == 0) {
        env.monitor_pid_ns = (uint64_t)self_pid_ns_stat.st_ino;
    }
    
    if (stat("/proc/self/ns/mnt", &self_mnt_ns_stat) == 0 &&
        stat("/proc/1/ns/mnt", &host_mnt_ns_stat) == 0) {
        if (self_mnt_ns_stat.st_ino != host_mnt_ns_stat.st_ino) {
            env.running_in_container = 1;
        }
    }
    
    if (!env.running_in_container) {
        if (stat("/proc/self/ns/cgroup", &self_cgroup_ns_stat) == 0 &&
            stat("/proc/1/ns/cgroup", &host_cgroup_ns_stat) == 0) {
            if (self_cgroup_ns_stat.st_ino != host_cgroup_ns_stat.st_ino) {
                env.running_in_container = 1;
            }
        }
    }
    
    if (env.running_in_container) {
        if (env.monitor_pid_ns == env.host_pid_ns) {
            report_log(EHPROBE_LOG_INFO, 
                "Running inside container with --pid=host (PID NS: %lu, shared with host)",
                env.monitor_pid_ns);
        } else {
            report_log(EHPROBE_LOG_WARNING, 
                "Running inside container WITHOUT --pid=host (monitor PID NS: %lu, host PID NS: %lu). "
                "Pre-existing container discovery will be limited. "
                "For full functionality, restart with --pid=host flag.",
                env.monitor_pid_ns, env.host_pid_ns);
        }
    } else {
        report_log(EHPROBE_LOG_INFO, "Running on host (PID NS: %lu)", env.monitor_pid_ns);
    }
    
    err = bpf_map_update_elem(map_fd, &map_id, &env, BPF_ANY);
    if (err < 0) {
        report_log(EHPROBE_LOG_ERROR, "Failed to initialize env map: %s", strerror(errno));
        ehprobe_bpf__destroy(g_ehprobe.skel);
        g_ehprobe.skel = NULL;
        pthread_mutex_unlock(&g_ehprobe.state_mutex);
        return EHPROBE_ERROR_INIT;
    }

    err = init_percpu_buffers();
    if (err != EHPROBE_SUCCESS) {
        ehprobe_bpf__destroy(g_ehprobe.skel);
        g_ehprobe.skel = NULL;
        pthread_mutex_unlock(&g_ehprobe.state_mutex);
        return err;
    }

    err = update_env_flags(g_ehprobe.config.features);
    if (err) {
        ehprobe_bpf__destroy(g_ehprobe.skel);
        g_ehprobe.skel = NULL;
        pthread_mutex_unlock(&g_ehprobe.state_mutex);
        return EHPROBE_ERROR_INIT;
    }

    report_log(EHPROBE_LOG_INFO, "Attaching BPF programs for features: 0x%x", 
               g_ehprobe.config.features);
    err = configure_bpf_programs(g_ehprobe.config.features);
    if (err) {
        report_log(EHPROBE_LOG_ERROR,
                   "Failed to attach BPF programs: %s", strerror(-err));
        detach_all_programs();
        ehprobe_bpf__destroy(g_ehprobe.skel);
        g_ehprobe.skel = NULL;
        pthread_mutex_unlock(&g_ehprobe.state_mutex);
        return EHPROBE_ERROR_BPF_ATTACH;
    }
    
    report_log(EHPROBE_LOG_DEBUG, "Creating ring buffer");
    g_ehprobe.rb = ring_buffer__new(bpf_map__fd(g_ehprobe.skel->maps.rb), 
                                    ringbuf_event_callback, NULL, NULL);
    if (!g_ehprobe.rb) {
        report_log(EHPROBE_LOG_ERROR, "Failed to create ring buffer");
        detach_all_programs();
        ehprobe_bpf__destroy(g_ehprobe.skel);
        g_ehprobe.skel = NULL;
        pthread_mutex_unlock(&g_ehprobe.state_mutex);
        return EHPROBE_ERROR_RINGBUF;
    }
    
    g_ehprobe.initialized = true;
    
    report_log(EHPROBE_LOG_INFO, "Discovering pre-existing containers...");
    err = discover_existing_containers(env.host_pid_ns);
    if (err != 0) {
        report_log(EHPROBE_LOG_WARNING, 
            "Container discovery encountered issues (error %d), will track new containers only",
            err);
    }
    
    pthread_mutex_unlock(&g_ehprobe.state_mutex);

    report_log(EHPROBE_LOG_INFO, "ehprobe initialized successfully");
    return EHPROBE_SUCCESS;
}

void ehprobe_destroy(void) {
    pthread_mutex_lock(&g_ehprobe.state_mutex);
    
    if (!g_ehprobe.initialized) {
        pthread_mutex_unlock(&g_ehprobe.state_mutex);
        report_log(EHPROBE_LOG_WARNING, "ehprobe_destroy called but not initialized");
        return;
    }
    
    report_log(EHPROBE_LOG_INFO, "Destroying ehprobe instance");
    
    if (g_ehprobe.running) {
        report_log(EHPROBE_LOG_DEBUG, "Stopping monitoring before destroy");
        g_ehprobe.running = false;
    }
    
    detach_all_programs();
    
    if (g_ehprobe.rb) {
        report_log(EHPROBE_LOG_DEBUG, "Freeing ring buffer");
        ring_buffer__free(g_ehprobe.rb);
        g_ehprobe.rb = NULL;
    }
    
    if (g_ehprobe.skel) {
        report_log(EHPROBE_LOG_DEBUG, "Destroying BPF skeleton");
        ehprobe_bpf__destroy(g_ehprobe.skel);
        g_ehprobe.skel = NULL;
    }
    
    g_ehprobe.initialized = false;
    pthread_mutex_unlock(&g_ehprobe.state_mutex);

    report_log(EHPROBE_LOG_INFO, "ehprobe destroyed");
}

int ehprobe_start(void) {
    pthread_mutex_lock(&g_ehprobe.state_mutex);
    
    if (!g_ehprobe.initialized) {
        pthread_mutex_unlock(&g_ehprobe.state_mutex);
        report_log(EHPROBE_LOG_ERROR, "ehprobe not initialized");
        return EHPROBE_ERROR_NOT_INITIALIZED;
    }
    
    if (g_ehprobe.running) {
        pthread_mutex_unlock(&g_ehprobe.state_mutex);
        report_log(EHPROBE_LOG_WARNING, "ehprobe already running");
        return EHPROBE_ERROR_ALREADY_RUNNING;
    }
    
    g_ehprobe.running = true;
    pthread_mutex_unlock(&g_ehprobe.state_mutex);

    report_log(EHPROBE_LOG_INFO, "ehprobe monitoring started");
    return EHPROBE_SUCCESS;
}

int ehprobe_stop(void) {
    pthread_mutex_lock(&g_ehprobe.state_mutex);
    
    if (!g_ehprobe.initialized) {
        pthread_mutex_unlock(&g_ehprobe.state_mutex);
        report_log(EHPROBE_LOG_ERROR, "ehprobe not initialized");
        return EHPROBE_ERROR_NOT_INITIALIZED;
    }
    
    if (!g_ehprobe.running) {
        pthread_mutex_unlock(&g_ehprobe.state_mutex);
        report_log(EHPROBE_LOG_WARNING, "ehprobe not running");
        return EHPROBE_ERROR_NOT_RUNNING;
    }
    
    g_ehprobe.running = false;
    pthread_mutex_unlock(&g_ehprobe.state_mutex);
    
    report_log(EHPROBE_LOG_INFO, "ehprobe monitoring stopped");
    return EHPROBE_SUCCESS;
}

bool ehprobe_is_running(void) {
    pthread_mutex_lock(&g_ehprobe.state_mutex);
    bool running = g_ehprobe.running;
    pthread_mutex_unlock(&g_ehprobe.state_mutex);    
    return running;
}

int ehprobe_set_features(uint32_t features) {
    pthread_mutex_lock(&g_ehprobe.state_mutex);
    
    if (!g_ehprobe.initialized) {
        pthread_mutex_unlock(&g_ehprobe.state_mutex);
        report_log(EHPROBE_LOG_ERROR, "ehprobe not initialized");
        return EHPROBE_ERROR_NOT_INITIALIZED;
    }
    
    uint32_t old_features = g_ehprobe.config.features;
    
    if (old_features == features) {
        pthread_mutex_unlock(&g_ehprobe.state_mutex);
        report_log(EHPROBE_LOG_DEBUG, "Features unchanged: 0x%x", features);
        return EHPROBE_SUCCESS;
    }
    
    report_log(EHPROBE_LOG_INFO, "Changing features from 0x%x to 0x%x", old_features, features);

    // Strip features the kernel doesn't support (cached from init-time BTF probe)
    features &= g_ehprobe.supported_features;

    int err = update_env_flags(features);
    if (err) {
        pthread_mutex_unlock(&g_ehprobe.state_mutex);
        return err;
    }
    
    err = configure_bpf_programs(features);
    if (err) {
        update_env_flags(old_features);
        pthread_mutex_unlock(&g_ehprobe.state_mutex);
        report_log(EHPROBE_LOG_ERROR, "Failed to configure programs for new features, rolled back");
        return err;
    }
    
    g_ehprobe.config.features = features;
    pthread_mutex_unlock(&g_ehprobe.state_mutex);
    
    report_log(EHPROBE_LOG_INFO, "Features set to 0x%x", features);
    return EHPROBE_SUCCESS;
}

int ehprobe_set_blocking_mode(uint64_t mode) {
    pthread_mutex_lock(&g_ehprobe.state_mutex);

    if (!g_ehprobe.initialized) {
        pthread_mutex_unlock(&g_ehprobe.state_mutex);
        report_log(EHPROBE_LOG_ERROR, "ehprobe not initialized");
        return EHPROBE_ERROR_NOT_INITIALIZED;
    }

    if (mode != EHPROBE_BLOCKING_MODE_OFF &&
        mode != EHPROBE_BLOCKING_MODE_AUDIT &&
        mode != EHPROBE_BLOCKING_MODE_ENFORCE) {
        pthread_mutex_unlock(&g_ehprobe.state_mutex);
        report_log(EHPROBE_LOG_ERROR, "Invalid blocking mode value: %lu", mode);
        return -EINVAL;
    }

    if (mode != EHPROBE_BLOCKING_MODE_OFF &&
        !(g_ehprobe.config.features & EHPROBE_FEATURE_BLOCK_EXEC)) {
        pthread_mutex_unlock(&g_ehprobe.state_mutex);
        report_log(EHPROBE_LOG_ERROR, "Unable to set blocking mode when BLOCK_EXEC feature is not enabled");
        return -EINVAL;
    }

    int map_fd = bpf_map__fd(g_ehprobe.skel->maps.ehprobe_env_map);
    if (map_fd < 0) {
        pthread_mutex_unlock(&g_ehprobe.state_mutex);
        report_log(EHPROBE_LOG_ERROR, "Failed to get global config map: %s", strerror(errno));
        return -errno;
    }

    uint32_t map_id = 0;
    struct ehprobe_env env = {0};
    int ret = bpf_map_lookup_elem(map_fd, &map_id, &env);
    if (ret) {
        pthread_mutex_unlock(&g_ehprobe.state_mutex);
        report_log(EHPROBE_LOG_ERROR, "Failed to query global config: %s", strerror(errno));
        return -errno;
    }

    env.blocking_mode = mode;

    ret = bpf_map_update_elem(map_fd, &map_id, &env, BPF_ANY);
    if (ret != 0) {
        pthread_mutex_unlock(&g_ehprobe.state_mutex);
        report_log(EHPROBE_LOG_ERROR, "Failed to update env map: %s", strerror(errno));
        return -errno;
    }

    pthread_mutex_unlock(&g_ehprobe.state_mutex);
    const char *mode_str = (mode == EHPROBE_BLOCKING_MODE_OFF) ? "off" :
                           (mode == EHPROBE_BLOCKING_MODE_AUDIT) ? "audit" : "enforce";
    report_log(EHPROBE_LOG_INFO, "Blocking mode set to: %s", mode_str);
    return 0;
}

int ehprobe_set_script_blocking_mode(uint64_t mode) {
    pthread_mutex_lock(&g_ehprobe.state_mutex);

    if (!g_ehprobe.initialized) {
        pthread_mutex_unlock(&g_ehprobe.state_mutex);
        report_log(EHPROBE_LOG_ERROR, "ehprobe not initialized");
        return EHPROBE_ERROR_NOT_INITIALIZED;
    }

    if (mode != EHPROBE_BLOCKING_MODE_OFF &&
        mode != EHPROBE_BLOCKING_MODE_AUDIT &&
        mode != EHPROBE_BLOCKING_MODE_ENFORCE) {
        pthread_mutex_unlock(&g_ehprobe.state_mutex);
        report_log(EHPROBE_LOG_ERROR, "Invalid script blocking mode value: %lu", mode);
        return -EINVAL;
    }

    if (mode != EHPROBE_BLOCKING_MODE_OFF &&
        !(g_ehprobe.config.features & EHPROBE_FEATURE_BLOCK_SCRIPT)) {
        pthread_mutex_unlock(&g_ehprobe.state_mutex);
        report_log(EHPROBE_LOG_ERROR, "Unable to set script blocking mode when BLOCK_SCRIPT feature is not enabled");
        return -EINVAL;
    }

    int map_fd = bpf_map__fd(g_ehprobe.skel->maps.ehprobe_env_map);
    if (map_fd < 0) {
        int saved_errno = errno;
        pthread_mutex_unlock(&g_ehprobe.state_mutex);
        report_log(EHPROBE_LOG_ERROR, "Failed to get global config map: %s", strerror(saved_errno));
        return -saved_errno;
    }

    uint32_t map_id = 0;
    struct ehprobe_env env = {0};
    int ret = bpf_map_lookup_elem(map_fd, &map_id, &env);
    if (ret) {
        int saved_errno = errno;
        pthread_mutex_unlock(&g_ehprobe.state_mutex);
        report_log(EHPROBE_LOG_ERROR, "Failed to query global config: %s", strerror(saved_errno));
        return -saved_errno;
    }

    env.script_blocking_mode = mode;

    ret = bpf_map_update_elem(map_fd, &map_id, &env, BPF_ANY);
    if (ret != 0) {
        int saved_errno = errno;
        pthread_mutex_unlock(&g_ehprobe.state_mutex);
        report_log(EHPROBE_LOG_ERROR, "Failed to update env map: %s", strerror(saved_errno));
        return -saved_errno;
    }

    pthread_mutex_unlock(&g_ehprobe.state_mutex);
    const char *mode_str = (mode == EHPROBE_BLOCKING_MODE_OFF) ? "off" :
                           (mode == EHPROBE_BLOCKING_MODE_AUDIT) ? "audit" : "enforce";
    report_log(EHPROBE_LOG_INFO, "Script blocking mode set to: %s", mode_str);
    return 0;
}

int ehprobe_set_af_alg_block_mode(uint64_t mode) {
    pthread_mutex_lock(&g_ehprobe.state_mutex);

    if (!g_ehprobe.initialized) {
        pthread_mutex_unlock(&g_ehprobe.state_mutex);
        report_log(EHPROBE_LOG_ERROR, "ehprobe not initialized");
        return EHPROBE_ERROR_NOT_INITIALIZED;
    }

    if (mode != EHPROBE_BLOCKING_MODE_OFF &&
        mode != EHPROBE_BLOCKING_MODE_AUDIT &&
        mode != EHPROBE_BLOCKING_MODE_ENFORCE) {
        pthread_mutex_unlock(&g_ehprobe.state_mutex);
        report_log(EHPROBE_LOG_ERROR, "Invalid AF_ALG block mode value: %lu", mode);
        return -EINVAL;
    }

    // AF_ALG blocking requires the lsm/socket_bind probe (its own
    // feature group, independent of NETWORK). Mirrors the BLOCK_EXEC
    // check in ehprobe_set_blocking_mode.
    if (mode != EHPROBE_BLOCKING_MODE_OFF &&
        !(g_ehprobe.config.features & EHPROBE_FEATURE_AF_ALG)) {
        pthread_mutex_unlock(&g_ehprobe.state_mutex);
        report_log(EHPROBE_LOG_ERROR, "Unable to set AF_ALG block mode when AF_ALG feature is not enabled");
        return -EINVAL;
    }

    int map_fd = bpf_map__fd(g_ehprobe.skel->maps.ehprobe_env_map);
    if (map_fd < 0) {
        int saved_errno = errno;
        pthread_mutex_unlock(&g_ehprobe.state_mutex);
        report_log(EHPROBE_LOG_ERROR, "Failed to get global config map: %s", strerror(saved_errno));
        return -saved_errno;
    }

    uint32_t map_id = 0;
    struct ehprobe_env env = {0};
    int ret = bpf_map_lookup_elem(map_fd, &map_id, &env);
    if (ret) {
        int saved_errno = errno;
        pthread_mutex_unlock(&g_ehprobe.state_mutex);
        report_log(EHPROBE_LOG_ERROR, "Failed to query global config: %s", strerror(saved_errno));
        return -saved_errno;
    }

    env.af_alg_block_mode = mode;

    ret = bpf_map_update_elem(map_fd, &map_id, &env, BPF_ANY);
    if (ret != 0) {
        int saved_errno = errno;
        pthread_mutex_unlock(&g_ehprobe.state_mutex);
        report_log(EHPROBE_LOG_ERROR, "Failed to update env map: %s", strerror(saved_errno));
        return -saved_errno;
    }

    pthread_mutex_unlock(&g_ehprobe.state_mutex);
    const char *mode_str = (mode == EHPROBE_BLOCKING_MODE_OFF) ? "off" :
                           (mode == EHPROBE_BLOCKING_MODE_AUDIT) ? "audit" : "enforce";
    report_log(EHPROBE_LOG_INFO, "AF_ALG block mode set to: %s", mode_str);
    return 0;
}


int ehprobe_set_module_load_block_mode(uint64_t mode) {
    pthread_mutex_lock(&g_ehprobe.state_mutex);

    if (!g_ehprobe.initialized) {
        pthread_mutex_unlock(&g_ehprobe.state_mutex);
        report_log(EHPROBE_LOG_ERROR, "ehprobe not initialized");
        return EHPROBE_ERROR_NOT_INITIALIZED;
    }

    if (mode != EHPROBE_BLOCKING_MODE_OFF &&
        mode != EHPROBE_BLOCKING_MODE_AUDIT &&
        mode != EHPROBE_BLOCKING_MODE_ENFORCE) {
        pthread_mutex_unlock(&g_ehprobe.state_mutex);
        report_log(EHPROBE_LOG_ERROR, "Invalid module-load block mode value: %lu", mode);
        return -EINVAL;
    }

    if (mode != EHPROBE_BLOCKING_MODE_OFF &&
        !(g_ehprobe.config.features & EHPROBE_FEATURE_MODULE_LOAD)) {
        pthread_mutex_unlock(&g_ehprobe.state_mutex);
        report_log(EHPROBE_LOG_ERROR,
                   "Unable to set module-load block mode when MODULE_LOAD feature is not enabled");
        return -EINVAL;
    }

    int map_fd = bpf_map__fd(g_ehprobe.skel->maps.ehprobe_env_map);
    if (map_fd < 0) {
        int saved_errno = errno;
        pthread_mutex_unlock(&g_ehprobe.state_mutex);
        report_log(EHPROBE_LOG_ERROR, "Failed to get global config map: %s", strerror(saved_errno));
        return -saved_errno;
    }

    uint32_t map_id = 0;
    struct ehprobe_env env = {0};
    int ret = bpf_map_lookup_elem(map_fd, &map_id, &env);
    if (ret) {
        int saved_errno = errno;
        pthread_mutex_unlock(&g_ehprobe.state_mutex);
        report_log(EHPROBE_LOG_ERROR, "Failed to query global config: %s", strerror(saved_errno));
        return -saved_errno;
    }

    env.module_load_block_mode = mode;

    ret = bpf_map_update_elem(map_fd, &map_id, &env, BPF_ANY);
    if (ret != 0) {
        int saved_errno = errno;
        pthread_mutex_unlock(&g_ehprobe.state_mutex);
        report_log(EHPROBE_LOG_ERROR, "Failed to update env map: %s", strerror(saved_errno));
        return -saved_errno;
    }

    pthread_mutex_unlock(&g_ehprobe.state_mutex);
    const char *mode_str = (mode == EHPROBE_BLOCKING_MODE_OFF) ? "off" :
                           (mode == EHPROBE_BLOCKING_MODE_AUDIT) ? "audit" : "enforce";
    report_log(EHPROBE_LOG_INFO, "Module-load block mode set to: %s", mode_str);
    return 0;
}


int ehprobe_set_xfrm_sa_new_block_mode(uint64_t mode) {
    pthread_mutex_lock(&g_ehprobe.state_mutex);

    if (!g_ehprobe.initialized) {
        pthread_mutex_unlock(&g_ehprobe.state_mutex);
        report_log(EHPROBE_LOG_ERROR, "ehprobe not initialized");
        return EHPROBE_ERROR_NOT_INITIALIZED;
    }

    if (mode != EHPROBE_BLOCKING_MODE_OFF &&
        mode != EHPROBE_BLOCKING_MODE_AUDIT &&
        mode != EHPROBE_BLOCKING_MODE_ENFORCE) {
        pthread_mutex_unlock(&g_ehprobe.state_mutex);
        report_log(EHPROBE_LOG_ERROR, "Invalid XFRM SA block mode value: %lu", mode);
        return -EINVAL;
    }

    if (mode != EHPROBE_BLOCKING_MODE_OFF &&
        !(g_ehprobe.config.features & EHPROBE_FEATURE_XFRM_SA_NEW)) {
        pthread_mutex_unlock(&g_ehprobe.state_mutex);
        report_log(EHPROBE_LOG_ERROR,
                   "Unable to set XFRM SA block mode when XFRM_SA_NEW feature is not enabled");
        return -EINVAL;
    }

    int map_fd = bpf_map__fd(g_ehprobe.skel->maps.ehprobe_env_map);
    if (map_fd < 0) {
        int saved_errno = errno;
        pthread_mutex_unlock(&g_ehprobe.state_mutex);
        report_log(EHPROBE_LOG_ERROR, "Failed to get global config map: %s", strerror(saved_errno));
        return -saved_errno;
    }

    uint32_t map_id = 0;
    struct ehprobe_env env = {0};
    int ret = bpf_map_lookup_elem(map_fd, &map_id, &env);
    if (ret) {
        int saved_errno = errno;
        pthread_mutex_unlock(&g_ehprobe.state_mutex);
        report_log(EHPROBE_LOG_ERROR, "Failed to query global config: %s", strerror(saved_errno));
        return -saved_errno;
    }

    env.xfrm_sa_new_block_mode = mode;

    ret = bpf_map_update_elem(map_fd, &map_id, &env, BPF_ANY);
    if (ret != 0) {
        int saved_errno = errno;
        pthread_mutex_unlock(&g_ehprobe.state_mutex);
        report_log(EHPROBE_LOG_ERROR, "Failed to update env map: %s", strerror(saved_errno));
        return -saved_errno;
    }

    pthread_mutex_unlock(&g_ehprobe.state_mutex);
    const char *mode_str = (mode == EHPROBE_BLOCKING_MODE_OFF) ? "off" :
                           (mode == EHPROBE_BLOCKING_MODE_AUDIT) ? "audit" : "enforce";
    report_log(EHPROBE_LOG_INFO, "XFRM SA block mode set to: %s", mode_str);
    return 0;
}


int ehprobe_poll(int timeout_ms) {
    pthread_mutex_lock(&g_ehprobe.state_mutex);
    
    if (!g_ehprobe.initialized) {
        pthread_mutex_unlock(&g_ehprobe.state_mutex);
        report_log(EHPROBE_LOG_ERROR, "ehprobe not initialized");
        return EHPROBE_ERROR_NOT_INITIALIZED;
    }
    
    if (!g_ehprobe.running) {
        pthread_mutex_unlock(&g_ehprobe.state_mutex);
        report_log(EHPROBE_LOG_ERROR, "ehprobe not running");
        return EHPROBE_ERROR_NOT_RUNNING;
    }
    
    pthread_mutex_unlock(&g_ehprobe.state_mutex);

    g_ehprobe.events_processed = 0;
    g_ehprobe.handler_return = 0;
    
    int err = ring_buffer__poll(g_ehprobe.rb, timeout_ms);    
    if (err < 0) {
        report_log(EHPROBE_LOG_ERROR,
                   "Ring buffer poll failed: %s", strerror(-err));
        return EHPROBE_ERROR_RINGBUF;
    }
    
    if (g_ehprobe.handler_return != 0) {
        report_log(EHPROBE_LOG_DEBUG, "Returning handler's stop request: %d", 
                   g_ehprobe.handler_return);
        return g_ehprobe.handler_return;
    }
    
    return g_ehprobe.events_processed;
}

// ============================================================================
// Helper Wrapper Functions
// ============================================================================

int ehprobe_unshare_wrapper(int flags) {
    return unshare(flags);
}

int ehprobe_setns_wrapper(int fd, int nstype) {
    return setns(fd, nstype);
}
