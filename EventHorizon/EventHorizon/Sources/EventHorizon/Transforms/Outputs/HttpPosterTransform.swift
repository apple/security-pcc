// Copyright © 2025 Apple Inc. All Rights Reserved.

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

protocol HTTPPosterEventHandler {
    func handle(incoming event: HTTPPosterEvent) -> Bool
}

enum HTTPPosterEvent: Sendable {
    case jsonEvent(data: Data), immediateJsonEvent(data: Data)

    func data() -> Data {
        switch self {
        case .jsonEvent(let data):
            return data
        case .immediateJsonEvent(let data):
            return data
        }
    }
}

extension HTTPPosterEvent: CustomStringConvertible {
    var description: String {
        switch self {
        case .immediateJsonEvent:
            return "immediateJsonEvent"
        case .jsonEvent:
            return "jsonEvent"
        }
    }
}

protocol HTTPPosterEventBufferDelegate: AnyObject {
    func timerDidExpire(data: Data)

    func bufferWouldOverflow(data: Data)

    func handleDirectly(event: HTTPPosterEvent)
}

class HTTPPosterEventBuffer {
    static let serial: Mutex<Int> = .init(0)
    let queue: DispatchQueue
    let capacity: Int
    var data: Data
    var timer: DispatchSourceTimer
    weak var delegate: HTTPPosterEventBufferDelegate?

    init(capacity: Int, timeout: Double) {
        self.queue = Self.serial.withLock { serial in
            serial += 1
            return DispatchQueue(label: "\(EventHorizonKit.framework_name).httpbuffer-\(serial)")
        }

        self.capacity = capacity
        self.data = Data(capacity: capacity)

        self.timer = DispatchSource.makeTimerSource(queue: self.queue)
        timer.schedule(deadline: .now() + timeout, repeating: timeout)

        timer.setEventHandler {
            self.delegate?.timerDidExpire(data: self.data)
            self.data.removeAll(keepingCapacity: true)
        }
        timer.activate()
    }

    deinit {
        timer.setEventHandler {}
        timer.cancel()
    }

    private func appendToBuffer(_ batch: Data) {
        self.queue.sync {
            self.data.append(batch)
        }
    }

    private func clearBuffer() {
        self.queue.sync {
            self.data.removeAll(keepingCapacity: true)
        }
    }
}

extension HTTPPosterEventBuffer: HTTPPosterEventHandler {
    func handle(incoming event: HTTPPosterEvent) -> Bool {
        switch event {
        case let .jsonEvent(batch):
            if batch.count > capacity {
                delegate?.handleDirectly(event: event)
            } else if batch.count + data.count > capacity {
                delegate?.bufferWouldOverflow(data: data)
                self.clearBuffer()
                return false
            } else {
                self.appendToBuffer(batch)
            }
        case .immediateJsonEvent:
            delegate?.handleDirectly(event: event)
        }
        return true
    }
}

enum HTTPPosterEventOffloaderError: Error {
    case invalidHTTPPosterURL
}

typealias HttpPostMethodType = (_ request: URLRequest) async throws -> (Data, URLResponse)

func urlReqToString(_ req: URLRequest) -> String {
    guard let body = req.httpBody else {
        return "<nil>"
    }
    return body.map { String(format: "%c", $0) }.joined()
}

actor HTTPPosterEventOffloader {
    let jsonEndpoint: URL
    private let log = EHLog.withCategory(HTTPPosterEventOffloader.self)
    var refreshEventRecieved: Bool = true
    var acdcActorURLSession: URLSession?

    private func offload(event: HTTPPosterEvent) async {
        let incoming = event.data()
        guard !incoming.isEmpty else {
            return
        }

        let requestEndpoint = jsonEndpoint
        let maxRetries = 5
        var attempts = 0

        var request = URLRequest(url: requestEndpoint)
        request.httpMethod = "POST"
        request.httpBody = incoming
        await withDiscardingTaskGroup {metrics in
            metrics.addTask { await EHMetrics.Labels.Gauges.httpposter_size_bytes.set(Double(incoming.count)) }

            os_log(.info, log: log, "sending HTTP POST: \(String(describing: request), privacy: .public)")
            os_log(.debug, log: log, "forwarding pipeline event body contents: \(urlReqToString(request), privacy: .public)")

            while attempts < maxRetries {
                do { try await Task.sleep(for: .milliseconds(125 * attempts)) } catch { return }
                do {
                    var data: Data
                    var response: URLResponse
                    (data, response) = try await URLSession.shared.data(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw NSError(domain: "HTTPPosterEventOffloader", code: 1, userInfo: ["error": "Unexpected URL Response type"])
                    }

                    let status = httpResponse.statusCode
                    if 200 == status {
                        metrics.addTask { await EHMetrics.Labels.Counters.httpposter_post_success_count.increment() }
                        return
                    } else {
                        metrics.addTask { await EHMetrics.Labels.Counters.httpposter_post_failure_count.increment() }
                        os_log(.error, log: log, """
                        ERROR: Response: %d
                        ERROR: %{public}s
                        ERROR: Request body:\n
                        """, status, (String(bytes: data, encoding: .utf8) ?? "error"), String(bytes: request.httpBody ?? Data(), encoding: .utf8) ?? "error"
                        )
                        attempts = maxRetries
                    }
                } catch {
                    metrics.addTask { await EHMetrics.Labels.Counters.httpposter_post_failure_count.increment() }
                    os_log(.error, log: log, "HTTPPoster HTTP POST failed:\n\(error.localizedDescription, privacy: .public)")
                    attempts += 1
                }
            }
            metrics.addTask { await EHMetrics.Labels.Counters.httpposter_post_drop_count.increment() }
        }
    }

    public init(httpEndpoint: URL) throws {
        guard let httpEndpoint = URLComponents(url: httpEndpoint, resolvingAgainstBaseURL: true) else {
            throw HTTPPosterEventOffloaderError.invalidHTTPPosterURL
        }

        var jsonEndpoint = httpEndpoint
        jsonEndpoint.path = "/services/collector"
        guard let jsonURL = jsonEndpoint.url else {
            throw HTTPPosterEventOffloaderError.invalidHTTPPosterURL
        }
        self.jsonEndpoint = jsonURL
    }
}

extension HTTPPosterEventOffloader: HTTPPosterEventBufferDelegate {
    nonisolated func timerDidExpire(data: Data) {
        os_log(.debug, log: log, "Timer fired, uploading \(data.count) bytes")
        if data.isEmpty {
            return
        }
        Task {
            await self.offload(event: .jsonEvent(data: data))
        }
    }

    nonisolated func bufferWouldOverflow(data: Data) {
        os_log(.debug, log: log, "Timer fired, uploading \(data.count) bytes")
        Task {
            await self.offload(event: .jsonEvent(data: data))
        }
    }

    nonisolated func handleDirectly(event: HTTPPosterEvent) {
        Task {
            await self.offload(event: event)
        }
    }
}

class HTTPPosterEventRotatingBuffer {
    var buffers: [HTTPPosterEventBuffer]
    var activeIndex = 0

    init(bufferCount: Int, bufferSize: Int, timeout: Double) {
        let optionalBuffers = [HTTPPosterEventBuffer?](repeating: nil, count: bufferCount)

        self.buffers = optionalBuffers.map { _ -> HTTPPosterEventBuffer in
            return HTTPPosterEventBuffer(capacity: bufferSize, timeout: timeout)
        }
    }

    func updateDelegate(to newDelegate: HTTPPosterEventBufferDelegate?) {
        guard let newDelegate else {
            return
        }
        self.buffers.forEach { $0.delegate = newDelegate }
    }
}

extension HTTPPosterEventRotatingBuffer: HTTPPosterEventHandler {
    func handle(incoming event: HTTPPosterEvent) -> Bool {
        while true {
            let buffer = self.buffers[activeIndex]
            if buffer.handle(incoming: event) {
                return true
            }
            activeIndex = (activeIndex + 1) % buffers.count
        }
    }
}

public protocol HTTPPosterTransformEncoder: Sendable {
    static func encode(event: any EHUEFEvent) -> Data?
}
public final class HTTPPosterTransform: EHTransform {
    public let name = "HTTPPosterTransform"
    enum Tags: String, CaseIterable {
        case log_println
    }

    static let ServerDefaultURL = "https://dzv2.apple.com"
    static let ServerConfigParameterKey = "com.apple.securitymonitorlited.serverURL"

    let buffer: Mutex<HTTPPosterEventRotatingBuffer>
    let offloader: HTTPPosterEventOffloader
    let encoder: any HTTPPosterTransformEncoder.Type
    private static let log = EHLog.withCategory(HTTPPosterTransform.self)

    static func getURL() -> URL {
        let defaultUrl = URL(string: HTTPPosterTransform.ServerDefaultURL)!
        let configServerURL: String? = EHConfigResolver(
            SecureConfigProvider(),
            DefaultConfigProvider(value: defaultUrl)
        ).resolve(key: HTTPPosterTransform.ServerConfigParameterKey, domain: nil)

        if let configServerURL {
            guard let parsedUrl = URL(string: configServerURL) else {
                os_log(.error, log: log, "SecureConfigParameters passed invalid URL: \(configServerURL, privacy: .public), using \(HTTPPosterTransform.ServerDefaultURL, privacy: .public)")
                return defaultUrl
            }
            os_log(.info, log: log, "Setting server URL to match SecureConfigParameters: \(configServerURL, privacy: .public)")
            return parsedUrl
        }
        return defaultUrl
    }

    public init? (bufferCount: Int, bufferSize: Int, timeout: Double, encodingStrategy: any HTTPPosterTransformEncoder.Type) {
        if let offloader = try? HTTPPosterEventOffloader(httpEndpoint: Self.getURL()) {
            self.offloader = offloader
            let buf = HTTPPosterEventRotatingBuffer(bufferCount: bufferCount, bufferSize: bufferSize, timeout: timeout)
            buf.updateDelegate(to: self.offloader)
            self.buffer = .init(buf)
            self.encoder = encodingStrategy
        } else {
            return nil
        }
    }

    public func process(_ event: any EHUEFEvent) async -> EHTransformReturn {
        if let adata = encoder.encode(event: event) {
            let evt = {
                if event.tags.contains(SharedTags.high_priority.rawValue) {
                    return HTTPPosterEvent.immediateJsonEvent(data: adata)
                }
                return HTTPPosterEvent.jsonEvent(data: adata)
            }()
            self.buffer.withLock {
                let result = $0.handle(incoming: evt)
                os_log(.debug, log: Self.log, "HTTP Offloader Result: \(result)")
            }
        }
        return (.proceed, nil, nil, nil)
    }

    public func configure() throws {
        _ = getHostName()
    }
}
