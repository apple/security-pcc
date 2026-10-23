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
//  crd_tcpdump.cpp
//
//  Created by Marco Magdy on 1/24/24.
//

#include "crd_core.h"
#include "crd_scope_guard.h"

#include <os/log.h>
#include <dispatch/dispatch.h>
#include <pcap.h>

#include <memory>
#include <mutex>
#include <string>

namespace {

class TcpCaptureContext {
    pcap_t* const m_handle;
    std::mutex m_locker;
    bool m_capture_completed = false;
public:
    explicit TcpCaptureContext(pcap_t* handle) : m_handle(handle) { }

    void set_capture_completed() { m_capture_completed = true; }
    bool is_capture_completed() const { return m_capture_completed; }
    pcap_t* pcap_handle() const { return m_handle; }
    void lock() { m_locker.lock(); }
    void unlock() { m_locker.unlock(); }
};

static void timeout_handler(void *data)
{
    TcpCaptureContext* context = static_cast<TcpCaptureContext*>(data);
    std::lock_guard<TcpCaptureContext> lock(*context);

    if (context->is_capture_completed()) {
        delete context;
        return;
    }

    context->set_capture_completed();
    pcap_breakloop(context->pcap_handle());
}

} // namespace


crd_tcpdump_result crd_tcpdump(const crd_tcpdump_settings* settings)
{
    const os_log_t log = os_log_create("cloudremotediagd", "tcpdump");

    char errbuf[PCAP_ERRBUF_SIZE];
    constexpr bool promiscuous = true;
    constexpr int packet_timeout_ms = 2000; // timeout until the next packet is received
    constexpr int snapshot_length = 1024; // only capture the first 1024 bytes of each packet
    pcap_t* const handle = pcap_open_live(settings->interface, snapshot_length, promiscuous, packet_timeout_ms, errbuf);
    if (handle == nullptr) {
        os_log_error(log, "pcap_open_live failed: %s", errbuf);
        return { nullptr, false };
    }
    auto handle_guard = crd::ScopeGuard([handle] { pcap_close(handle); });

    // compile the filter
    struct bpf_program filter;
    if (pcap_compile(handle, &filter, settings->filter, 0, PCAP_NETMASK_UNKNOWN) == -1) {
        os_log_error(log, "pcap_compile failed: %s", pcap_geterr(handle));
        return { nullptr, false };
    }

    auto filter_guard = crd::ScopeGuard([&filter] { pcap_freecode(&filter); });

    // apply the filter
    if (pcap_setfilter(handle, &filter) == -1) {
        os_log_error(log, "pcap_setfilter failed: %s", pcap_geterr(handle));
        return { nullptr, false };
    }

    // create a temporary file to store the output
    char temp_file[] = "/tmp/crd_tcpdump_XXXXXX";
    const int fd = mkstemp(temp_file);
    if (fd == -1) {
        os_log_error(OS_LOG_DEFAULT, "mkstemp failed: %s", strerror(errno));
        return { nullptr, false };
    }
    FILE* const capture_file = fdopen(fd, "w");
    if (capture_file == nullptr) {
        os_log_error(log, "fdopen failed: %s", strerror(errno));
        return { nullptr, false };
    }
    auto capture_file_guard = crd::ScopeGuard([capture_file] { fclose(capture_file); });

    // start capturing packets and writing them to the temporary file
    pcap_dumper_t* const dumper = pcap_dump_fopen(handle, capture_file);
    if (dumper == nullptr) {
        os_log_error(log, "pcap_dump_fopen failed: %s", pcap_geterr(handle));
        return { nullptr, false };
    }
    auto dumper_guard = crd::ScopeGuard([dumper] { pcap_dump_close(dumper); });

    // max_packets is validated in Swift to be between [1, 10,000]
    const int32_t max_packets = static_cast<int>(settings->max_packets);

    auto* context = new TcpCaptureContext(handle); // Freed by timeout_handler below.

    // cancel the loop after 'timeout_seconds' if we haven't received the max number of packets.
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, settings->timeout_seconds * NSEC_PER_SEC), dispatch_get_main_queue(), context, timeout_handler);

    const int packet_count = pcap_loop(handle, max_packets, pcap_dump, reinterpret_cast<u_char*>(dumper));

    // Take a lock to ensure the next few lines do not interleave with the timeout_handler.
    // This is necessary because the timeout_handler may be called after pcap_loop returns.
    std::lock_guard<TcpCaptureContext> lock(*context);
    if (context->is_capture_completed()) { // timeout_handler beat us to it.
        delete context;
    }
    else {
        context->set_capture_completed();
    }

    if (packet_count == -1) {
        os_log_error(log, "pcap_loop failed: %s", pcap_geterr(handle));
        return { nullptr, false };
    }

    return { strdup(temp_file), true };
}

void crd_tcpdump_free_result(struct crd_tcpdump_result* result)
{
    free(const_cast<char*>(result->output_file));
}
