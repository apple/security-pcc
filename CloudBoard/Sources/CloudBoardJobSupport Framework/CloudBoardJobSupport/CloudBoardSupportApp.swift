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

import CloudBoardDomain
package import CloudBoardJobSupportAPI
internal import CloudBoardLogging
internal import CloudBoardOSActivity
import Foundation
import os
internal import Synchronization

private let log: Logger = .init(
    subsystem: "com.apple.cloudos.cloudboard",
    category: "CloudBoardSupportApp"
)

public protocol CloudBoardSupportApp: Sendable {
    init()
    /// If there is expensive work which can be deferred till after init, but which must be done before
    /// ``run(input:responder:environment:)`` it can be done here
    func warmup() async throws
    /// Performs any necessary teardown work.
    /// Returning from this function signals acknowledgement of the
    /// teardown request. The run() routine will be cancelled after this function
    /// returns.
    func teardown() async throws
    /// This will be called only once (and may never be called if the cloud (support) app is never used for an actual
    /// request).
    /// - Parameters:
    ///   - environment: Provides request metadata such as tracing information as well as ways to interact with other
    ///   components and data managed by CloudBoard, such as supplementary crypto material.
    func run(environment: CloudBoardSupportAppEnvironment) async throws
}

extension CloudBoardSupportApp {
    public func warmup() async throws {
        // Can be overridden by implementing type.
    }

    public func teardown() async throws {
        // Returning from this function signals acknowledgement of the
        // teardown request. The run() routine will be cancelled after this function
        // returns.
    }
}

extension CloudBoardSupportApp {
    /// Convenience boostrapping based on the type and an empty initialiser
    package static func bootstrap(server: CloudBoardSupportAppAPIServerProtocol) async throws {
        try await CloudBoardSupportAppRunner.bootstrap(
            appInstance: Self(),
            server: server
        )
    }
}

package enum CloudBoardSupportAppRunner {
    package static func bootstrap(
        appInstance: some CloudBoardSupportApp,
        server: CloudBoardSupportAppAPIServerProtocol
    ) async throws {
        // Create the stream and associated continuation to forward teardown requests
        let (teardownRequestStream, teardownRequestStreamContinuation) = AsyncStream<Void>.makeStream()

        // the intention here is to just touch the `log` logger early on bootstrap to avoid any lazy initialization
        log.log("Bootstrapping support app \(type(of: appInstance))")

        let xpcMessenger = await JobHelperMessenger(
            server: server,
            teardownContinuation: teardownRequestStreamContinuation,
            log: log,
            appInstance: appInstance
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withThrowingTaskGroup(of: Void.self) { subGroup in
                    subGroup.addTask {
                        try await xpcMessenger.waitForWarmupComplete()

                        let parameters = try await xpcMessenger.waitForParameters()
                        do {
                            let environment = CloudBoardSupportAppEnvironment(
                                plaintextMetadata: .init(parameters.plaintextMetadata),
                                cryptoMaterialHelper: CryptoMaterialHelper(
                                    jobHelperMessenger: xpcMessenger,
                                    clientRequestID: parameters.plaintextMetadata.requestID
                                ),
                                keyDerivationHelper: KeyDerivationHelper(
                                    jobHelperMessenger: xpcMessenger,
                                    clientRequestID: parameters.plaintextMetadata.requestID
                                ),
                                traceContext: .init(parameters.traceContext)
                            )

                            log.log("""
                            CloudBoardSupportApp invoked with: \
                            request.uuid=\(environment.plaintextMetadata.requestID, privacy: .public)
                            bundleID=\(environment.plaintextMetadata.bundleID, privacy: .public)
                            bundleVersion=\(environment.plaintextMetadata.bundleVersion, privacy: .public)
                            featureID=\(environment.plaintextMetadata.featureID, privacy: .public)
                            automatedDeviceGroup=\(environment.plaintextMetadata.automatedDeviceGroup, privacy: .public)
                            clientInfo=\(environment.plaintextMetadata.clientInfo, privacy: .public)
                            traceID=\(environment.traceContext.traceID, privacy: .public)
                            spanID=\(environment.traceContext.spanID, privacy: .public)
                            """)
                            try await appInstance.run(
                                environment: environment
                            )
                        } catch {
                            await xpcMessenger.internalError()
                            log.error("""
                            Support App failed with error: \
                            \(String(reportable: error), privacy: .public) \
                            (\(error))
                            """)
                            throw error
                        }
                    }
                    var endJobCalled = false
                    do {
                        try await subGroup.waitForAll()
                        endJobCalled = true
                        try await xpcMessenger.endJob()
                    } catch {
                        // No point in calling `endJob` again if that threw earlier and got us here in the first place
                        if !endJobCalled {
                            try await xpcMessenger.endJob()
                        }
                        throw error
                    }
                }
            }

            group.addTask {
                for await _ in teardownRequestStream {}
                if !Task.isCancelled {
                    log.info("Tearing down support app")
                    try await appInstance.teardown()
                }
            }

            // If one of these terminates, we want to cancel the other.
            _ = try await group.next()
            log.info("Cancelling all subtasks")
            await xpcMessenger.cancel()
            group.cancelAll()
        }
    }
}

extension CloudBoardSupportAppEnvironment.PlaintextMetadata {
    init(_ receivedData: ParametersData.PlaintextMetadata?) {
        if let receivedData {
            self.init(
                bundleID: receivedData.bundleID,
                bundleVersion: receivedData.bundleVersion,
                featureID: receivedData.featureID,
                clientInfo: receivedData.clientInfo,
                workloadType: receivedData.workloadType,
                workloadParameters: receivedData.workloadParameters,
                requestID: receivedData.requestID,
                automatedDeviceGroup: receivedData.automatedDeviceGroup
            )
        } else {
            self.init(
                bundleID: "",
                bundleVersion: "",
                featureID: "",
                clientInfo: "",
                workloadType: "",
                workloadParameters: [:],
                requestID: "",
                automatedDeviceGroup: ""
            )
        }
    }
}

// Trace Context with UInt64 representation of spanID
extension CloudBoardSupportAppEnvironment.TraceContext {
    init(_ receivedData: CloudBoardTraceContext?) {
        if let receivedData {
            self.init(
                traceID: UUID(uuidString: receivedData.traceID) ?? UUID(),
                spanID: receivedData.spanID
            )
        } else {
            self.init(
                traceID: UUID(),
                spanID: UInt64.random(in: 0 ..< UInt64.max)
            )
        }
    }
}

enum CloudBoardSupportAppError: Error {
    case unsupported
}
