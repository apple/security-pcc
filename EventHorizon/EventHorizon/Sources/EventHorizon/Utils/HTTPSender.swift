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
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(os)
import os
#endif
import Synchronization


enum HTTPSenderPayload: Sendable {
    case batched(data: Data), immediate(data: Data)

    func data() -> Data {
        switch self {
        case .batched(let data): return data
        case .immediate(let data): return data
        }
    }
}

protocol HTTPSenderBufferDelegate: AnyObject {
    func timerDidExpire(data: Data)
    func bufferWouldOverflow(data: Data)
    func handleDirectly(payload: HTTPSenderPayload)
}

final class HTTPSenderBuffer {
    let queue: DispatchQueue
    let capacity: Int
    var data: Data
    var timer: DispatchSourceTimer
    weak var delegate: HTTPSenderBufferDelegate?

    init(capacity: Int, timeout: Double, sharedQueue: DispatchQueue) {
        self.queue = sharedQueue
        self.capacity = capacity
        self.data = Data(capacity: capacity)
        self.timer = DispatchSource.makeTimerSource(queue: self.queue)
        timer.schedule(deadline: .now() + timeout, repeating: timeout)
        timer.setEventHandler { [weak self] in
            guard let self else {
                return
            }
            self.delegate?.timerDidExpire(data: self.data)
            self.data.removeAll(keepingCapacity: true)
        }
        timer.activate()
    }

    deinit {
        timer.setEventHandler {}
        timer.cancel()
    }

    func handle(incoming payload: HTTPSenderPayload) -> Bool {
        return self.queue.sync {
            switch payload {
            case let .batched(batch):
                if batch.count > capacity {
                    delegate?.handleDirectly(payload: payload)
                } else if batch.count + data.count > capacity {
                    delegate?.bufferWouldOverflow(data: data)
                    self.data.removeAll(keepingCapacity: true)
                    return false
                } else {
                    self.data.append(batch)
                }
            case .immediate:
                delegate?.handleDirectly(payload: payload)
            }
            return true
        }
    }
}

final class HTTPSenderRotatingBuffer {
    private static let serial: Mutex<Int> = .init(0)
    let sharedQueue: DispatchQueue
    var buffers: [HTTPSenderBuffer]
    let activeIndex: Mutex<Int>

    init(bufferCount: Int, bufferSize: Int, timeout: Double) {
        let queue = Self.serial.withLock { serial in
            serial += 1
            return DispatchQueue(label: "\(EventHorizonKit.framework_name).httpsender-\(serial)")
        }
        self.sharedQueue = queue
        self.activeIndex = Mutex(0)
        self.buffers = (0..<bufferCount).map { _ in
            HTTPSenderBuffer(capacity: bufferSize, timeout: timeout, sharedQueue: queue)
        }
    }

    func updateDelegate(to newDelegate: HTTPSenderBufferDelegate?) {
        guard let newDelegate else {
            return
        }
        self.buffers.forEach { $0.delegate = newDelegate }
    }

    func handle(incoming payload: HTTPSenderPayload) -> Bool {
        while true {
            let currentIndex = self.activeIndex.withLock { $0 }
            let buffer = self.buffers[currentIndex]
            if buffer.handle(incoming: payload) {
                return true
            }
            self.activeIndex.withLock { index in
                if index == currentIndex {
                    index = (index + 1) % buffers.count
                }
            }
        }
    }
}


enum HTTPSenderError: Error {
    case invalidURL
}

#if canImport(Darwin)
final class HTTPSenderTLSBypassDelegate: NSObject, URLSessionDelegate, Sendable {
    private static let log = EHLog.withCategory(HTTPSenderTLSBypassDelegate.self)

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let hostname = challenge.protectionSpace.host
        let policy = SecPolicyCreateSSL(true, hostname as CFString)
        SecTrustSetPolicies(serverTrust, policy)
        var error: CFError?
        if SecTrustEvaluateWithError(serverTrust, &error) {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else if let error {
            let code = CFErrorGetCode(error)
            let chainErrors: Set<CFIndex> = [-25318, -25843, -67843]
            if chainErrors.contains(code) {
                os_log(.info, log: Self.log, "TLS bypass: accepting untrusted chain for host %{public}@", hostname)
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
            } else {
                os_log(.error, log: Self.log, "TLS bypass: rejecting certificate for host %{public}@: %{public}@", hostname, error.localizedDescription)
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
#endif

actor HTTPSenderOffloader {
    let endpoint: URL
    let authHeader: String?
    let posterName: String
    let quiet: Bool
    private let log = EHLog.withCategory(HTTPSenderOffloader.self)
    let urlSession: URLSession

    init(endpoint: URL, path: String, authHeader: String?, posterName: String, quiet: Bool, urlSession: URLSession) throws {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: true) else {
            throw HTTPSenderError.invalidURL
        }
        components.path = path
        guard let resolved = components.url else {
            throw HTTPSenderError.invalidURL
        }
        self.endpoint = resolved
        self.authHeader = authHeader
        self.posterName = posterName
        self.quiet = quiet
        self.urlSession = urlSession
    }

    private func emitQuietError(_ message: String) {
        let line = "[\(posterName)-httpsender] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    private func offload(payload: HTTPSenderPayload) async {
        let incoming = payload.data()
        guard !incoming.isEmpty else {
            return
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = incoming
        if let authHeader {
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        }
        let dims: [(String, String)] = [("poster", posterName)]
        let maxRetries = 5
        var attempts = 0

        await withDiscardingTaskGroup { metrics in
            let size = Double(incoming.count)
            metrics.addTask {
                await EHMetrics.Labels.Gauges.httpposter_size_bytes.set(size, extraDimensions: dims)
            }
            if !quiet {
                os_log(.debug, log: log, "sending HTTP POST to: %{public}@", endpoint.absoluteString)
            }

            while attempts < maxRetries {
                do { try await Task.sleep(for: .milliseconds(125 * attempts)) } catch { return }
                do {
                    let (_, response) = try await urlSession.data(for: request)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw NSError(domain: "HTTPSenderOffloader", code: 1, userInfo: ["error": "Unexpected URL Response type"])
                    }
                    let status = httpResponse.statusCode
                    if status == 200 {
                        metrics.addTask {
                            await EHMetrics.Labels.Counters.httpposter_post_success_count.increment(extraDimensions: dims)
                        }
                        return
                    } else {
                        metrics.addTask {
                            await EHMetrics.Labels.Counters.httpposter_post_failure_count.increment(extraDimensions: dims)
                        }
                        if quiet {
                            emitQuietError("HTTP POST failed: status=\(status)")
                        } else {
                            os_log(.error, log: log, "HTTP POST failed: status=%d", status)
                        }
                        attempts = maxRetries
                    }
                } catch {
                    metrics.addTask {
                        await EHMetrics.Labels.Counters.httpposter_post_failure_count.increment(extraDimensions: dims)
                    }
                    if quiet {
                        emitQuietError("HTTP POST failed: \(error.localizedDescription)")
                    } else {
                        os_log(.error, log: log, "HTTP POST failed:\n\(error.localizedDescription, privacy: .public)")
                    }
                    attempts += 1
                }
            }
            metrics.addTask {
                await EHMetrics.Labels.Counters.httpposter_post_drop_count.increment(extraDimensions: dims)
            }
        }
    }
}

extension HTTPSenderOffloader: HTTPSenderBufferDelegate {
    nonisolated func timerDidExpire(data: Data) {
        if data.isEmpty {
            return
        }
        Task {
            await self.offload(payload: .batched(data: data))
        }
    }

    nonisolated func bufferWouldOverflow(data: Data) {
        Task {
            await self.offload(payload: .batched(data: data))
        }
    }

    nonisolated func handleDirectly(payload: HTTPSenderPayload) {
        Task {
            await self.offload(payload: payload)
        }
    }
}


public final class HTTPSender: Sendable {
    private static let log = EHLog.withCategory(HTTPSender.self)

    private let buffer: Mutex<HTTPSenderRotatingBuffer>
    private let offloader: HTTPSenderOffloader
    private let customURLSession: URLSession?

    public init?(
        endpoint: URL,
        path: String = "/services/collector",
        token: String? = nil,
        disableTLSValidation: Bool = false,
        bufferCount: Int,
        bufferSize: Int,
        timeout: Double,
        posterName: String,
        quiet: Bool = false
    ) {
        let session = Self.makeURLSession(disableTLSValidation: disableTLSValidation)
        self.customURLSession = (session !== URLSession.shared) ? session : nil
        let authHeader: String? = token.map { "Splunk \($0)" }
        do {
            let off = try HTTPSenderOffloader(
                endpoint: endpoint,
                path: path,
                authHeader: authHeader,
                posterName: posterName,
                quiet: quiet,
                urlSession: session
            )
            self.offloader = off
        } catch {
            return nil
        }
        let buf = HTTPSenderRotatingBuffer(bufferCount: bufferCount, bufferSize: bufferSize, timeout: timeout)
        buf.updateDelegate(to: self.offloader)
        self.buffer = .init(buf)
    }

    deinit {
        customURLSession?.invalidateAndCancel()
    }

    public func send(_ data: Data, immediate: Bool = false) {
        let payload: HTTPSenderPayload = immediate ? .immediate(data: data) : .batched(data: data)
        self.buffer.withLock {
            _ = $0.handle(incoming: payload)
        }
    }

    static func makeURLSession(disableTLSValidation: Bool) -> URLSession {
        if disableTLSValidation {
            os_log(.error, log: log, "TLS certificate validation is DISABLED for HTTPSender")
            #if canImport(Darwin)
            return URLSession(
                configuration: .default,
                delegate: HTTPSenderTLSBypassDelegate(),
                delegateQueue: nil
            )
            #else
            os_log(.error, log: log, "TLS bypass not supported on this platform, using default session")
            return .shared
            #endif
        }
        return .shared
    }
}
