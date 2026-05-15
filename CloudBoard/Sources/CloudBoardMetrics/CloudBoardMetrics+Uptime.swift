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

// Standardised metrics for daemons and other, non daemon, processes realted to their life.
// Currently launch count, exit count, (terminal) error count and uptime.
// These are deliberately separated in _naming_ (using daemon and process respectively) to avoid
// confusion on consumers as to what should be restarting a lot, verses rarely
package enum Uptime {
    /// this becomes part of the metric lable - do not change it without consultation with SRE
    package enum ProcessType: String, CaseIterable {
        case daemon
        case process
    }

    // This is somewhat convoluted but avoid copy paste in all the various daemons/processes
    // Given the label must be statically known - but vary depending on the daemon/process
    // our options are limited.
    // Using generics directly may not have static stored properties, so either we have some global
    // register of them, or accept making new instances on each use.
    // For the specific use case of uptime this is fine - we update all but one of the metrics once and
    // only once for the life of the process, and uptime itself is updated on a fixed cadence except on exit

    /// A protocol that all processes must conform to in order to register themselves
    package protocol ProcessInfo {
        /// Important note to implementers:
        /// The plumbing for these values pushes the runtime ordering guarantees for initialisation
        /// Any implementation should declare the value as:
        /// ```
        /// static let prefix = "whatever_you_need"
        /// ```
        /// with *no* indirection at all.
        /// This becomes the canonical place to reference that value if it is needed elsewhere, often this
        /// is used for the ``CloudMetricsSystem(clientName:)``.
        static var prefix: String { get }
        static var type: ProcessType { get }
    }

    private struct StandardMetrics<Process: ProcessInfo> {
        struct LaunchCounter: Counter {
            static var label: MetricLabel { "\(Process.prefix)_\(Process.type)_launch_total" }

            var action: CounterAction
        }

        struct UptimeGauge: Gauge {
            static var label: MetricLabel { "\(Process.prefix)_\(Process.type)_uptime" }

            var value: Int
        }

        struct ErrorExitCounter: Counter {
            static var label: MetricLabel { "\(Process.prefix)_\(Process.type)_exit_error" }

            var action: CounterAction
            var dimensions: MetricDimensions<DefaultErrorDimensionKeys>
        }

        struct TotalExitCounter: Counter {
            static var label: MetricLabel { "\(Process.prefix)_\(Process.type)_exit_total" }

            var action: CounterAction
        }
    }

    /// This should wrap the main loop of the process/daemon
    /// It will not trap fatalErrors, but thrown errors will be accounted for
    package static func withStandardMetrics<Info: ProcessInfo, ReturnType: Sendable>(
        processInfo _: Info.Type = Info.self,
        metrics: MetricsSystem,
        _ body: @escaping @Sendable () async throws -> ReturnType
    ) async rethrows -> ReturnType {
        let startInstant: ContinuousClock.Instant = ContinuousClock.now
        func uptimeGaugeUpdate() {
            let uptime = Int(clamping: startInstant.duration(to: .now).components.seconds)
            // This causes an allocation of the label each time - we accept that
            metrics.emit(StandardMetrics<Info>.UptimeGauge(value: uptime))
        }
        metrics.emit(StandardMetrics<Info>.LaunchCounter(action: .increment))
        uptimeGaugeUpdate()

        defer {
            uptimeGaugeUpdate()
            metrics.emit(StandardMetrics<Info>.TotalExitCounter(action: .increment))
        }
        do {
            return try await withThrowingTaskGroup { group in
                group.addTask {
                    do {
                        while true {
                            // During the life of the process the update frequency of this value
                            // is fine at human perceptible levels of precision
                            // on exit it will be updated again so that aggregations are not subject to
                            // excessive bias
                            try await Task.sleep(for: .seconds(5))
                            uptimeGaugeUpdate()
                        }
                    } catch is CancellationError {
                        return ReturnType?.none
                    }
                    return ReturnType?.none
                }
                group.addTask {
                    return try await body()
                }

                var bodyResult: ReturnType? = nil
                for try await result in group {
                    // only the body returns anything but nil
                    if let result {
                        group.cancelAll()
                        bodyResult = result
                    }
                }
                guard let bodyResult else {
                    // either:
                    // 1: the body returns non nil (happy path)
                    // 2: it throws - so this code is never reached
                    fatalError("This should be impossible to reach")
                }
                return bodyResult
            }
        } catch {
            throw error
        }
    }
}
