// SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause
// handle_kernel_read_file.bpf.c - Detect and optionally block explicit
// module loads via `finit_module(fd)` for Dirty Frag modules.
//
// Fires from `lsm/kernel_read_file` when the kernel is about to read a
// file into a buffer. When `id == READING_MODULE` this is the
// `finit_module` path that modern modprobe uses on RHEL 9. We extract
// the file basename and match against the Dirty Frag blocklist.
//
// Pairs with `handle_kernel_module_request.bpf.c` which covers the
// autoload (`request_module`) path. Between the two we catch every
// realistic module-load route on RHEL 9. Known gap: `init_module(buf,
// len, args)` uses no backing file, so it would fire a different LSM
// hook (`kernel_load_data`) and is deliberately out of scope — modern
// RHEL userland exclusively uses `finit_module`.
#include <ehprobe_common.h>
#include <module_events.h>

char LICENSE[] SEC("license") = "Dual BSD/GPL";

#define EHPROBE_EPERM 1

// Extract the trailing filename component of a dentry into `out`, up to
// `cap` bytes. Returns the number of bytes copied (including null
// terminator) or 0 on failure. Safe for use in LSM hooks.
static __always_inline uint32_t read_dentry_basename(struct dentry *dentry,
                                                     char *out,
                                                     uint32_t cap)
{
    if (!dentry || !out || cap == 0) {
        return 0;
    }
    struct qstr name = BPF_CORE_READ(dentry, d_name);
    if (!name.name) {
        return 0;
    }
    long n = bpf_probe_read_kernel_str(out, cap, (void *)name.name);
    if (n <= 0) {
        return 0;
    }
    return (uint32_t)n;
}

SEC("lsm/kernel_read_file")
int BPF_PROG(handle_kernel_read_file, struct file *file, enum kernel_read_file_id id, bool contents)
{
    // Use the BTF-derived enum value so a future kernel that reorders
    // `enum kernel_read_file_id` doesn't silently break matching.
    // `bpf_core_enum_value` resolves to the vmlinux BTF value at load
    // time.
    if ((int)id != bpf_core_enum_value(enum kernel_read_file_id, READING_MODULE)) {
        return 0;
    }

    u32 map_key = 0;
    struct ehprobe_env *env = bpf_map_lookup_elem(&ehprobe_env_map, &map_key);
    if (!env || !env->flag_module_load) {
        return 0;
    }
    u64 block_mode = env->module_load_block_mode;

    // Pull the basename out of the file's dentry.  Buffer is sized to
    // EHPROBE_BLOCKLIST_NAMELEN so the bounded string-equality helper
    // used by the blocklist can safely read to the end.
    char basename[EHPROBE_BLOCKLIST_NAMELEN] = {};
    uint32_t n = read_dentry_basename(BPF_CORE_READ(file, f_path.dentry),
                                      basename, sizeof(basename));
    if (n == 0) {
        return 0;
    }
    basename[sizeof(basename) - 1] = '\0';

    // Only emit for modules on the blocklist — see the companion
    // comment in handle_kernel_module_request.bpf.c. On RHEL the
    // finit_module path runs during boot for every module in the
    // loaded set and we don't want that torrent of events.
    if (!kmod_basename_is_blocked(basename)) {
        return 0;
    }

    int emit_ret = ehprobe_module_load_request(
        basename, n, file,
        EHPROBE_MODULE_HOOK_READ,
        block_mode
    );
    if (emit_ret < 0) {
        trace_log("EHPROBE_LSM_KERNEL_READ_FILE: failed to emit event for %s", basename);
    }

    if (block_mode == EHPROBE_BLOCKING_MODE_ENFORCE) {
        trace_log("EHPROBE_LSM_KERNEL_READ_FILE: blocking %s load (pid=%d)",
                  basename, bpf_get_current_pid_tgid() >> 32);
        return -EHPROBE_EPERM;
    }

    return 0;
}
