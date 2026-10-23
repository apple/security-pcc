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

#if os(Linux)
import Foundation
import Metrics
@preconcurrency import Prometheus
import Synchronization

public enum PrometheusBackend {
    public static let registry = PrometheusCollectorRegistry()

    public static func metricsFactory() -> PrometheusMetricsFactory {
        PrometheusMetricsFactory(registry: registry)
    }

    public static func exportText() -> String {
        var buffer: [UInt8] = []
        registry.emit(into: &buffer)
        let text = String(bytes: buffer, encoding: .utf8) ?? ""
        return text.hasSuffix("\n") ? text : text + "\n"
    }

    public static func bootstrapMetricsSystemForTests() {
        bootstrapped.withLock { done in
            guard !done else {
                return
            }
            MetricsSystem.bootstrap(metricsFactory())
            done = true
        }
    }

    private static let bootstrapped = Mutex<Bool>(false)
}


public struct MultiplexMetricsFactory: MetricsFactory {
    let factories: [MetricsFactory]

    public init(_ factories: [MetricsFactory]) {
        self.factories = factories
    }

    public func makeCounter(label: String, dimensions: [(String, String)]) -> CounterHandler {
        MultiplexCounter(handlers: self.factories.map { $0.makeCounter(label: label, dimensions: dimensions) })
    }

    public func makeFloatingPointCounter(label: String, dimensions: [(String, String)]) -> FloatingPointCounterHandler {
        MultiplexFloatingPointCounter(
            handlers: self.factories.map { $0.makeFloatingPointCounter(label: label, dimensions: dimensions) }
        )
    }

    public func makeRecorder(label: String, dimensions: [(String, String)], aggregate: Bool) -> RecorderHandler {
        MultiplexRecorder(
            handlers: self.factories.map { $0.makeRecorder(label: label, dimensions: dimensions, aggregate: aggregate) }
        )
    }

    public func makeMeter(label: String, dimensions: [(String, String)]) -> MeterHandler {
        MultiplexMeter(handlers: self.factories.map { $0.makeMeter(label: label, dimensions: dimensions) })
    }

    public func makeTimer(label: String, dimensions: [(String, String)]) -> TimerHandler {
        MultiplexTimer(handlers: self.factories.map { $0.makeTimer(label: label, dimensions: dimensions) })
    }

    public func destroyCounter(_ handler: CounterHandler) {
        guard let mux = handler as? MultiplexCounter else {
            return
        }
        for (factory, sub) in zip(self.factories, mux.handlers) {
            factory.destroyCounter(sub)
        }
    }

    public func destroyFloatingPointCounter(_ handler: FloatingPointCounterHandler) {
        guard let mux = handler as? MultiplexFloatingPointCounter else {
            return
        }
        for (factory, sub) in zip(self.factories, mux.handlers) {
            factory.destroyFloatingPointCounter(sub)
        }
    }

    public func destroyRecorder(_ handler: RecorderHandler) {
        guard let mux = handler as? MultiplexRecorder else {
            return
        }
        for (factory, sub) in zip(self.factories, mux.handlers) {
            factory.destroyRecorder(sub)
        }
    }

    public func destroyMeter(_ handler: MeterHandler) {
        guard let mux = handler as? MultiplexMeter else {
            return
        }
        for (factory, sub) in zip(self.factories, mux.handlers) {
            factory.destroyMeter(sub)
        }
    }

    public func destroyTimer(_ handler: TimerHandler) {
        guard let mux = handler as? MultiplexTimer else {
            return
        }
        for (factory, sub) in zip(self.factories, mux.handlers) {
            factory.destroyTimer(sub)
        }
    }
}


private final class MultiplexCounter: CounterHandler {
    let handlers: [CounterHandler]
    init(handlers: [CounterHandler]) { self.handlers = handlers }
    func increment(by amount: Int64) { for h in handlers { h.increment(by: amount) } }
    func reset() { for h in handlers { h.reset() } }
}

private final class MultiplexFloatingPointCounter: FloatingPointCounterHandler {
    let handlers: [FloatingPointCounterHandler]
    init(handlers: [FloatingPointCounterHandler]) { self.handlers = handlers }
    func increment(by amount: Double) { for h in handlers { h.increment(by: amount) } }
    func reset() { for h in handlers { h.reset() } }
}

private final class MultiplexRecorder: RecorderHandler {
    let handlers: [RecorderHandler]
    init(handlers: [RecorderHandler]) { self.handlers = handlers }
    func record(_ value: Int64) { for h in handlers { h.record(value) } }
    func record(_ value: Double) { for h in handlers { h.record(value) } }
}

private final class MultiplexMeter: MeterHandler {
    let handlers: [MeterHandler]
    init(handlers: [MeterHandler]) { self.handlers = handlers }
    func set(_ value: Int64) { for h in handlers { h.set(value) } }
    func set(_ value: Double) { for h in handlers { h.set(value) } }
    func increment(by amount: Double) { for h in handlers { h.increment(by: amount) } }
    func decrement(by amount: Double) { for h in handlers { h.decrement(by: amount) } }
}

private final class MultiplexTimer: TimerHandler {
    let handlers: [TimerHandler]
    init(handlers: [TimerHandler]) { self.handlers = handlers }
    func recordNanoseconds(_ duration: Int64) { for h in handlers { h.recordNanoseconds(duration) } }
    func preferDisplayUnit(_ unit: TimeUnit) { for h in handlers { h.preferDisplayUnit(unit) } }
}
#endif
