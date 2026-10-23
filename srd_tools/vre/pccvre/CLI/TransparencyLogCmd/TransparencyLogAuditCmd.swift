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

//  Copyright © 2024 Apple, Inc. All rights reserved.
//

import ArgumentParserInternal
import Dispatch
import Foundation

extension CLI.TransparencyLogCmd {
    final class AuditCmd: AsyncParsableCommand, Auditor.Delegate {
        static let configuration = CommandConfiguration(
            commandName: "audit",
            abstract: "Replay the entire Transparency Log to ensure integrity, and enumerates all Releases."
        )

        @OptionGroup var transparencyLogOptions: CLI.TransparencyLogCmd.options

        @Flag(name: [.customLong("continuous"), .customShort("c")],
              help: "Continuously audit the transparency log.")
        var continuous: Bool = false

        @Option(name: [.customLong("interval"), .customShort("i")],
                help: "Number of seconds to wait in between updates if using --continuous.")
        var interval: UInt = 30

        @Flag(name: [.customLong("application-tree-only"), .customShort("a")],
              help: "Only download and verify the Application Tree (AT); skip the Per Application (PAT) and Top Level (TLT) trees. This proves AT self-consistency only, not that AT is anchored into PAT/TLT.")
        var applicationTreeOnly: Bool = false

        @IgnoreDecodable
        private var tui: TUI = .init()

        func run() async throws {
            let task = Task {
                try await self.runCancellable()
            }

            let source = DispatchSource.makeSignalSource(signal: SIGINT)
            signal(SIGINT, SIG_IGN)
            source.setEventHandler {
                task.cancel()
            }
            source.resume()
            defer { source.cancel() }

            do {
                try await task.value
            } catch is CancellationError {
                await tui.setOperation(render: true, "Exiting...")
            } catch {
                throw error
            }
        }

        func runCancellable() async throws {
            let log = try await TransparencyLog(
                environment: transparencyLogOptions.environment,
                altKtInitEndpoint: transparencyLogOptions.ktInitEndpoint
            )

            let storageURL = FileManager.fileURL(transparencyLogOptions.storage)
                .appending(path: transparencyLogOptions.environment.rawValue)

            var auditor = try Auditor(for: log, storageURL: storageURL)
            auditor.delegate = self

            let mode: Auditor.UpdateMode = applicationTreeOnly ? .applicationTreeOnly : .full

            repeat {
                try await auditor.update(mode: mode)
                await tui.setOperation(render: true, "checkpointing leaves to storage...")
                try auditor.save(mode: mode)
                await tui.setOperation(render: true, "checkpointing leaves to storage... done")

                if interval == 0 || !continuous {
                    break
                }

                await tui.setOperation(render: true, "waiting \(interval)s until next fetch")
                try await Task.sleep(for: .seconds(interval))
            } while true
        }

        func handleAuditEvent(_ event: Auditor.Event) async {
            switch event {
            case .fetchedLogHead(tree: let tree, position: let position, count: let count):
                switch tree {
                case .application:
                    await tui.updateATStatus { status in
                        status.position = position
                        status.count = count
                    }
                    if (count - position) > 0 {
                        await tui.setOperation("Fetching \(count - position) new AT leaves")
                    }

                case .perApplication:
                    await tui.updatePATStatus { status in
                        status.position = position
                        status.count = count
                    }
                    if (count - position) > 0 {
                        await tui.setOperation("Fetching \(count - position) new PAT leaves")
                    }

                case .topLevel:
                    await tui.updateTLTStatus { status in
                        status.position = position
                        status.count = count
                    }
                    if (count - position) > 0 {
                        await tui.setOperation("Fetching \(count - position) new TLT leaves")
                    }
                }

            case .fetchedLeaf(tree: let tree, position: let position, digest: let digest):
                switch tree {
                case .application:
                    await tui.updateATStatus { status in
                        status.position = position
                        status.status = .current(digest: digest)
                    }

                case .perApplication:
                    await tui.updatePATStatus { status in
                        status.position = position
                        status.status = .current(digest: digest)
                    }

                case .topLevel:
                    await tui.updateTLTStatus { status in
                        status.position = position
                        status.status = .current(digest: digest)
                    }
                }

            case .constructionCompleted(tree: let tree, status: let completionStatus):
                switch tree {
                case .application:
                    await tui.updateATStatus { status in
                        switch completionStatus {
                        case .invalid:
                            status.status = .invalid

                        case .valid(rootDigest: let rootDigest):
                            status.status = .valid(rootDigest: rootDigest)
                        }
                    }

                case .perApplication:
                    await tui.updatePATStatus { status in
                        switch completionStatus {
                        case .invalid:
                            status.status = .invalid

                        case .valid(rootDigest: let rootDigest):
                            status.status = .valid(rootDigest: rootDigest)
                        }
                    }

                case .topLevel:
                    await tui.updateTLTStatus { status in
                        switch completionStatus {
                        case .invalid:
                            status.status = .invalid

                        case .valid(rootDigest: let rootDigest):
                            status.status = .valid(rootDigest: rootDigest)
                        }
                    }
                }
            }

            await tui.render()
        }
    }
}

// MARK: - Audit Text UI

extension CLI.TransparencyLogCmd.AuditCmd {
    actor TUI {
        /*
         Top Level Tree: (current/count)
            {CurrentHash | Invalid | Valid root digest: <Digest>}
         Per Application Tree: (current/count)
            {CurrentHash | Invalid | Valid root digest: <Digest>}
         Application Tree: (current/count) [{rootDigest}]
            {CurrentHash | Invalid | Valid root digest: <Digest>}
         {Current Operation}
         */

        var tltStatus: TreeDetails
        var patStatus: TreeDetails
        var atStatus: TreeDetails
        var operation: String?

        init() {
            self.tltStatus = .init()
            self.patStatus = .init()
            self.atStatus = .init()
            self.operation = nil
        }

        func setOperation(render: Bool = false, _ operation: String) {
            self.operation = operation
            if render {
                self.render()
            }
        }

        func updateTLTStatus(render: Bool = false, _ mutator: (inout TreeDetails) -> Void) {
            mutator(&tltStatus)
            if render {
                self.render()
            }
        }

        func updatePATStatus(render: Bool = false, _ mutator: (inout TreeDetails) -> Void) {
            mutator(&patStatus)
            if render {
                self.render()
            }
        }

        func updateATStatus(render: Bool = false, _ mutator: (inout TreeDetails) -> Void) {
            mutator(&atStatus)
            if render {
                self.render()
            }
        }

        struct TreeDetails {
            var position: UInt64?
            var count: UInt64?
            var status: Status?

            enum Status {
                case current(digest: Data)
                case invalid
                case valid(rootDigest: Data)
            }
        }

        private var linesToClear = 0

        func render() {
            if isatty(FileHandle.standardOutput.fileDescriptor) == 0 {
                return
            }

            clearPreviousLines(count: linesToClear)
            linesToClear = 0

            func printStatus(_ status: TreeDetails.Status?) {
                switch status {
                case .none:
                    printAndCount("\t...")

                case .invalid:
                    printAndCount("\tInvalid tree ❌")

                case .current(digest: let digest):
                    printAndCount("\t\(digest.hexString)")

                case .valid(rootDigest: let rootDigest):
                    printAndCount("\tValid root digest: \(rootDigest.hexString) ✅")
                }
            }

            printAndCount("Top Level Tree: (\(tltStatus.position ?? 0)/\(tltStatus.count ?? 0))")
            printStatus(tltStatus.status)
            printAndCount("Per Application Tree: (\(patStatus.position ?? 0)/\(patStatus.count ?? 0))")
            printStatus(patStatus.status)
            printAndCount("Application Tree: (\(atStatus.position ?? 0)/\(atStatus.count ?? 0))")
            printStatus(atStatus.status)
            printAndCount(operation ?? "...")
        }

        private func printAndCount(
            _ items: Any...,
            separator: String = " ",
            terminator: String = "\n"
        ) {
            var s = ""
            Swift.print(items, separator: separator, terminator: terminator, to: &s)
            linesToClear += s.count { $0 == "\n" }
            Swift.print(s, terminator: "")
        }

        private func clearPreviousLines(count: Int) {
            // move up lines
            print("\u{001B}[\(count)F", terminator: "")
            // erase trailing characters
            print("\u{001B}[0J", terminator: "")
            fflush(stdout)
        }
    }
}

// MARK: - Decodable workaround

@propertyWrapper
private struct IgnoreDecodable<T>: Decodable {
    var _wrappedValue: T?
    var wrappedValue: T {
        guard let _wrappedValue else {
            fatalError("impossible")
        }
        return _wrappedValue
    }

    init(wrappedValue: T) {
        self._wrappedValue = wrappedValue
    }

    init(from: Decoder) throws {
        self._wrappedValue = nil
    }
}
