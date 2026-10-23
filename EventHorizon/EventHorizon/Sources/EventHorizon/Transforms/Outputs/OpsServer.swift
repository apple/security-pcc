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


import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif
#if canImport(os)
import os
#endif
import Synchronization

public final class OpsServerTransform: EHTransform, Sendable {
    public let name = "OpsServerTransform"
    private static let log = EHLog.withCategory(OpsServerTransform.self)


    private static let _configuredPort: Mutex<(value: Int?, set: Bool)> = Mutex((nil, false))
    private static let _configuredPrometheusEnabled: Mutex<(value: Bool?, set: Bool)> = Mutex((nil, false))
    private static let _configuredHealthEnabled: Mutex<(value: Bool?, set: Bool)> = Mutex((nil, false))

    public static func setConfiguredPort(_ value: Int) {
        _configuredPort.withLock { state in
            if state.set {
                os_log(.error, log: log, "configuredPort already set, ignoring subsequent call")
                return
            }
            state.value = value
            state.set = true
        }
    }

    public static func setConfiguredPrometheusEnabled(_ value: Bool) {
        _configuredPrometheusEnabled.withLock { state in
            if state.set {
                os_log(.error, log: log, "configuredPrometheusEnabled already set, ignoring subsequent call")
                return
            }
            state.value = value
            state.set = true
        }
    }

    public static func setConfiguredHealthEnabled(_ value: Bool) {
        _configuredHealthEnabled.withLock { state in
            if state.set {
                os_log(.error, log: log, "configuredHealthEnabled already set, ignoring subsequent call")
                return
            }
            state.value = value
            state.set = true
        }
    }


    private let serverRef: Mutex<EHOpsHTTPServer?> = Mutex(nil)

    public init() {}


    public func configure() async throws {
        let port: Int? = Self._configuredPort.withLock { $0.value }

        guard let port else {
            os_log(.info, log: Self.log, "OpsServer: no port configured, server disabled")
            return
        }

        guard port > 1023 && port <= 65535 else {
            os_log(.error, log: Self.log, "OpsServer: refusing to bind to port %d (must be 1024-65535)", port)
            return
        }

        let prometheusEnabled: Bool = Self._configuredPrometheusEnabled.withLock { $0.value } ?? true
        let healthEnabled: Bool = Self._configuredHealthEnabled.withLock { $0.value } ?? true

        let server = EHOpsHTTPServer(
            port: port,
            prometheusEnabled: prometheusEnabled,
            healthEnabled: healthEnabled
        )

        do {
            try server.start()
            serverRef.withLock { $0 = server }
            os_log(.info, log: Self.log, "OpsServer: listening on port %d (prometheus=%{public}s, health=%{public}s)",
                   port, prometheusEnabled ? "on" : "off", healthEnabled ? "on" : "off")
        } catch {
            os_log(.error, log: Self.log, "OpsServer: failed to start on port %d: %{public}@",
                   port, error.localizedDescription)
        }
    }

    public func process(_ event: any EHUEFEvent) async -> EHTransformReturn {
        (.proceed, nil, nil, nil)
    }
}


final class EHOpsHTTPServer: @unchecked Sendable {
    private let port: Int
    private let prometheusEnabled: Bool
    private let healthEnabled: Bool
    private let startTime: ContinuousClock.Instant
    private var serverFD: Int32 = -1
    private static let log = EHLog.withCategory(EHOpsHTTPServer.self)

    enum ServerError: Error, CustomStringConvertible {
        case socketCreationFailed(Int32)
        case bindFailed(Int32)
        case listenFailed(Int32)

        var description: String {
            switch self {
            case .socketCreationFailed(let errno): return "socket() failed: \(String(cString: strerror(errno)))"
            case .bindFailed(let errno): return "bind() failed: \(String(cString: strerror(errno)))"
            case .listenFailed(let errno): return "listen() failed: \(String(cString: strerror(errno)))"
            }
        }
    }

    init(port: Int, prometheusEnabled: Bool, healthEnabled: Bool) {
        self.port = port
        self.prometheusEnabled = prometheusEnabled
        self.healthEnabled = healthEnabled
        self.startTime = ContinuousClock.now
    }

    func start() throws {
        #if canImport(Glibc)
        let sockStream = Int32(SOCK_STREAM.rawValue)
        #else
        let sockStream: Int32 = SOCK_STREAM
        #endif

        let fd = socket(AF_INET, sockStream, 0)
        if fd < 0 {
            throw ServerError.socketCreationFailed(errno)
        }

        var reuseAddr: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = UInt32(0x7f000001).bigEndian

        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bindResult < 0 {
            let err = errno
            close(fd)
            throw ServerError.bindFailed(err)
        }

        if listen(fd, 8) < 0 {
            let err = errno
            close(fd)
            throw ServerError.listenFailed(err)
        }

        self.serverFD = fd

        let thread = Thread { [weak self] in
            self?.dropPrivilegesAndServe()
        }
        thread.name = "com.apple.eventhorizond.ops-server"
        thread.qualityOfService = .utility
        thread.start()
    }

    private func dropPrivilegesAndServe() {
        acceptLoop()
    }

    private func acceptLoop() {
        while true {
            var clientAddr = sockaddr_in()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    accept(serverFD, sockaddrPtr, &clientAddrLen)
                }
            }

            if clientFD < 0 {
                if errno == EINTR {
                    continue
                }
                break
            }

            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

            handleConnection(clientFD)
        }
    }

    private func handleConnection(_ fd: Int32) {
        defer { close(fd) }

        var buf = [UInt8](repeating: 0, count: 4096)
        let bytesRead = read(fd, &buf, buf.count)
        if bytesRead <= 0 {
            return
        }

        let request = String(bytes: buf[0..<bytesRead], encoding: .utf8) ?? ""
        let path = parseRequestPath(request)

        switch path {
        case "/metrics" where prometheusEnabled:
            handleMetrics(fd)
        case "/health" where healthEnabled:
            handleHealth(fd)
        default:
            sendResponse(fd, status: "404 Not Found", contentType: "text/plain", body: "Not Found\n")
        }
    }

    private func parseRequestPath(_ request: String) -> String {
        guard let firstLine = request.split(separator: "\r\n", maxSplits: 1).first else {
            return ""
        }
        let parts = firstLine.split(separator: " ")
        if parts.count >= 2 {
            return String(parts[1])
        }
        return ""
    }

    private func handleMetrics(_ fd: Int32) {
        let semaphore = DispatchSemaphore(value: 0)
        let bodyStore: Mutex<String> = Mutex("")

        Task { @Sendable in
            let result = await EHMetrics.shared.exportPrometheus()
            bodyStore.withLock { $0 = result }
            semaphore.signal()
        }
        semaphore.wait()

        let body = bodyStore.withLock { $0 }
        sendResponse(
            fd,
            status: "200 OK",
            contentType: "text/plain; version=0.0.4; charset=utf-8",
            body: body
        )
    }

    private func handleHealth(_ fd: Int32) {
        let elapsed = ContinuousClock.now - startTime
        let uptimeSeconds = elapsed.components.seconds
        let body = "{\"status\":\"ok\",\"uptime_seconds\":\(uptimeSeconds)}\n"
        sendResponse(fd, status: "200 OK", contentType: "application/json", body: body)
    }

    private func sendResponse(_ fd: Int32, status: String, contentType: String, body: String) {
        let bodyData = Array(body.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        let headerData = Array(header.utf8)

        _ = headerData.withUnsafeBufferPointer { ptr in
            write(fd, ptr.baseAddress, ptr.count)
        }
        _ = bodyData.withUnsafeBufferPointer { ptr in
            write(fd, ptr.baseAddress, ptr.count)
        }
    }
}
