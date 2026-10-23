// Copyright © 2026 Apple Inc. All Rights Reserved.

// APPLE INC.
// PRIVATE CLOUD COMPUTE SOURCE CODE INTERNAL USE LICENSE AGREEMENT
// PLEASE READ THE FOLLOWING PRIVATE CLOUD COMPUTE SOURCE CODE INTERNAL USE LICENSE AGREEMENT (“AGREEMENT”) CAREFULLY BEFORE DOWNLOADING OR USING THE APPLE SOFTWARE ACCOMPANYING THIS AGREEMENT(AS DEFINED BELOW). BY DOWNLOADING OR USING THE APPLE SOFTWARE, YOU ARE AGREEING TO BE BOUND BY THE TERMS OF THIS AGREEMENT. IF YOU DO NOT AGREE TO THE TERMS OF THIS AGREEMENT, DO NOT DOWNLOAD OR USE THE APPLE SOFTWARE. THESE TERMS AND CONDITIONS CONSTITUTE A LEGAL AGREEMENT BETWEEN YOU AND APPLE.
// IMPORTANT NOTE: BY DOWNLOADING OR USING THE APPLE SOFTWARE, YOU ARE AGREEING ON YOUR OWN BEHALF AND/OR ON BEHALF OF YOUR COMPANY OR ORGANIZATION TO THE TERMS OF THIS AGREEMENT.
// 1. As used in this Agreement, the term “Apple Software” collectively means and includes all of the Apple Private Cloud Compute materials provided by Apple here, including but not limited to the Apple Private Cloud Compute software, tools, data, files, frameworks, libraries, documentation, logs and other Apple-created materials. In consideration for your agreement to abide by the following terms, conditioned upon your compliance with these terms and subject to these terms, Apple grants you, for a period of ninety (90) days from the date you download the Apple Software, a limited, non-exclusive, non-sublicensable license under Apple’s copyrights in the Apple Software to download, install, compile and run the Apple Software internally within your organization only on a single Apple-branded computer you own or control, for the sole purpose of verifying the security and privacy characteristics of Apple Private Cloud Compute. This Agreement does not allow the Apple Software to exist on more than one Apple-branded computer at a time, and you may not distribute or make the Apple Software available over a network where it could be used by multiple devices at the same time. You may not, directly or indirectly, redistribute the Apple Software or any portions thereof. The Apple Software is only licensed and intended for use as expressly stated above and may not be used for other purposes or in other contexts without Apple's prior written permission. Except as expressly stated in this notice, no other rights or licenses, express or implied, are granted by Apple herein.
// 2. The Apple Software is provided by Apple on an "AS IS" basis. APPLE MAKES NO WARRANTIES, EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION THE IMPLIED WARRANTIES OF NON-INFRINGEMENT, MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE, REGARDING THE APPLE SOFTWARE OR ITS USE AND OPERATION ALONE OR IN COMBINATION WITH YOUR PRODUCTS, SYSTEMS, OR SERVICES. APPLE DOES NOT WARRANT THAT THE APPLE SOFTWARE WILL MEET YOUR REQUIREMENTS, THAT THE OPERATION OF THE APPLE SOFTWARE WILL BE UNINTERRUPTED OR ERROR-FREE, THAT DEFECTS IN THE APPLE SOFTWARE WILL BE CORRECTED, OR THAT THE APPLE SOFTWARE WILL BE COMPATIBLE WITH FUTURE APPLE PRODUCTS, SOFTWARE OR SERVICES. NO ORAL OR WRITTEN INFORMATION OR ADVICE GIVEN BY APPLE OR AN APPLE AUTHORIZED REPRESENTATIVE WILL CREATE A WARRANTY.
// 3. IN NO EVENT SHALL APPLE BE LIABLE FOR ANY DIRECT, SPECIAL, INDIRECT, INCIDENTAL OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) ARISING IN ANY WAY OUT OF THE USE, REPRODUCTION, COMPILATION OR OPERATION OF THE APPLE SOFTWARE, HOWEVER CAUSED AND WHETHER UNDER THEORY OF CONTRACT, TORT (INCLUDING NEGLIGENCE), STRICT LIABILITY OR OTHERWISE, EVEN IF APPLE HAS BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
// 4. This Agreement is effective until terminated. Your rights under this Agreement will terminate automatically without notice from Apple if you fail to comply with any term(s) of this Agreement. Upon termination, you agree to cease all use of the Apple Software and destroy all copies, full or partial, of the Apple Software. This Agreement constitutes the entire understanding of the parties with respect to the subject matter contained herein, and supersedes all prior negotiations, representations, or understandings, written or oral. This Agreement will be governed and construed in accordance with the laws of the State of California, without regard to its choice of law rules.
// You may report security issues about Apple products to product-security@apple.com, as described here: https://www.apple.com/support/security/. Non-security bugs and enhancement requests can be made via https://bugreport.apple.com as described here: https://developer.apple.com/bug-reporting/
// EA1937
// 10/02/2024

//
//  topbridge.cpp
//  remotediag
//
//  Created by Marco Magdy on 10/10/23.
//

#include "crd_core.h"
#include <libtop.h>
#include <stdio.h>
#include <stdarg.h>
#include <errno.h>
#include <pmufw/pmu_fw_interface.h>
#include <os/log.h>

#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

namespace {
struct topb_data_s {
    const libtop_psamp_t* current;
    const libtop_tsamp_t* time_sample;
};
struct ProcessInfoInternal {
    pid_t pid;
    std::string command;
    double cpu;
    int64_t memory_bytes;
    int64_t thread_count;

};
}

static os_log_t logger;

static double calculate_cpu(libtop_psamp_t const* process_sample, libtop_tsamp_t const* time_sample)
{
    constexpr double nsec_per_usec = 1000;
    if (process_sample->seq == 0) {
        return 0;
    }
    double used_us = (process_sample->total_timens - process_sample->p_total_timens) / nsec_per_usec;
    double elapsed_us = (time_sample->timens - time_sample->p_timens) / nsec_per_usec;

    if (elapsed_us > 0) {
        return used_us / elapsed_us * 100;
    }
    return 0;
}

size_t crd_process_sample_collect(struct crd_process_sample* output, size_t length)
{
    std::vector<ProcessInfoInternal> process_stats;
    struct topb_data_s snapshot = {};
    os_log_debug(logger, "collecting samples..");
    // Get a new sample for all processes
    if (libtop_sample(false, false)) {
        os_log_error(logger, "Failed to get any samples");
        return 0;
    }
    snapshot.time_sample = libtop_tsamp();
    snapshot.current = libtop_piterate();
    while (snapshot.current) {
        ProcessInfoInternal current;
        current.pid = snapshot.current->pid;
        current.command = snapshot.current->command;
        current.cpu = calculate_cpu(snapshot.current, snapshot.time_sample);
        current.memory_bytes = snapshot.current->pfootprint;
        current.thread_count = snapshot.current->th;
        process_stats.push_back(current);
        snapshot.current = libtop_piterate();
    }

    // Sort descendingly by cpu utilization
    std::sort(process_stats.begin(), process_stats.end(), [](auto const& a, auto const& b) {
        return a.cpu > b.cpu;
    });

    size_t written = 0;
    for (auto&& proc : process_stats) {
        output->pid = proc.pid;
        output->name = strdup(proc.command.c_str());
        output->cpu_utilization_percent = proc.cpu;
        output->thread_count = proc.thread_count;
        output->memory_used_bytes = proc.memory_bytes;
        output++;
        written++;
        if (written == length) break;
    }
    os_log_debug(logger, "Collected a sample for %{public}lu processes", written);
    return written;
}
    
void crd_process_stats_shutdown(void)
{
    libtop_fini();
}

static int libtop_logger(void *, const char *a_format, ...)
{
    // construct the log message
    char buffer[1024];
    va_list args;
    va_start(args, a_format);
    auto sz = vsnprintf(buffer, sizeof(buffer), a_format, args);
    va_end(args);
    if (sz < 0) {
        os_log_error(logger, "Failed to construct libtop log message. vsprintf returned a negative value");
        return 0;
    }
    os_log_debug(logger, "libtop log message: %s", buffer);
    return 0;
}

void crd_process_stats_initialize(void)
{
    logger = os_log_create("process_sampling", "sampling");
    libtop_init_with_options(libtop_logger, nullptr, LIBTOP_INIT_INSPECT);
}
