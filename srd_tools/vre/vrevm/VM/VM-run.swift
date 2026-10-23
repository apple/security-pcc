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

import Foundation
import Virtualization
import Virtualization_Private

extension VM {
    // run opens an existing VM instance (if not already), re-applies NVRAM values from the
    //  bundle config (unless forRestore set), sets "darwin-init" arg (if available, and
    //  dfuMode not set), and starts the guest.
    // Note: We don't have the benefit of a hypervisor service, so this remains running in
    //  the foreground until a signal is received (eg Ctrl-C on the TTY)
    func run(
        dfuMode: Bool = false, // place VM into DFU mode (eg for restore operation)
        quietMode: Bool = false // disconnect VM stdout from terminal
    ) throws {
        try open()
        if isRunning() {
            throw VMError("VM appears to be running/locked")
        }

        guard let vzVM else {
            throw VMError("VM not loaded")
        }

        let vzStartOpts = VZMacOSVirtualMachineStartOptions()
        if dfuMode {
            vzStartOpts._forceDFU = true
        } else {
            try attachDarwinInit()
        }

        var consoleLog: URL?
        // setup console output capture (mirror to console.log and stdout)
        if let consoleOutput {
            do {
                consoleLog = try VMBundle.Logs(
                    topdir: bundle.logsPath,
                    folder: "console",
                    includeTimestamp: true
                ).file(name: "device")
                let consoleLogOutFH = try FileHandle(forWritingTo: consoleLog!)

                consoleOutput.fileHandleForReading.readabilityHandler = {
                    let data = $0.availableData
                    if !data.isEmpty {
                        consoleLogOutFH.write(data)
                        if !quietMode {
                            fputs(String(decoding: data, as: UTF8.self), stdout)
                            fflush(stdout)
                        }
                    }
                }
            } catch {
                throw VMError("setup console.log for \(name): \(error)")
            }
        }

        

        let delegate: MacOSVirtualMachineDelegate = .init()
        vzVM.delegate = delegate

        runQueue.async {
            VM.logger.log("starting VM")
            print("Starting VM: \(self.name) (ecid: \(self.ecidStr))")

            self.setSaveCoresHandler(vzVM: vzVM)

            vzVM.start(options: vzStartOpts) { error in
                if let error {
                    let startMsg = "Failed to start VM: \(error)"
                    VM.logger.error("\(startMsg, privacy: .public)")
                    print(startMsg)

                    exit(EXIT_FAILURE)
                }

                if let gdbStub = vzVM._debugStub as? _VZGDBDebugStub {
                    let gdbMsg = "GDB stub available at localhost:\(gdbStub.port)"
                    VM.logger.log("\(gdbMsg, privacy: .public)")
                    print(gdbMsg)
                }

                for coprocessor in vzVM._coprocessors {
                    if let sep = coprocessor as? _VZSEPCoprocessor {
                        if let sepGdbStub = sep.debugStub as? _VZGDBDebugStub {
                            let sepGdbMsg = "SEP GDB stub available at localhost:\(sepGdbStub.port)"
                            VM.logger.log("\(sepGdbMsg, privacy: .public)")
                            print(sepGdbMsg)
                        }
                    }
                }

                if let consoleLog {
                    print("Console log available at: \(consoleLog.path)")
                }

                VM.logger.log("started VM")
                print("Started VM: \(self.name)")
            }
        }
    }

    func setSaveCoresHandler(vzVM: VZVirtualMachine) {
        signal(SIGUSR1, SIG_IGN)
        let signalSource = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: self.runQueue)
        signalSource.setEventHandler {
            self.saveCores(vzVM: vzVM)
            // retain the source forever
            withExtendedLifetime(signalSource) {}
        }
        signalSource.activate()
    }

    func saveCores(vzVM: VZVirtualMachine) {
        print("Creating cores...")
        vzVM._createCores { cores, error in
            if let cores {
                print("Created cores for \(cores.keys), saving")
                let dir = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
                for (name, core) in cores {
                    do {
                        let path = dir.appendingPathComponent("\(name)-\(Date.now.ISO8601Format()).core")
                        try core.write(to: path)
                        print("Saved \(name) coredump to \(path.path(percentEncoded: false))")
                    } catch {
                        print("Failed to save \(name) coredump - \(error.localizedDescription))")
                    }
                }
            } else if let error {
                print("Failed to save cores - \(error.localizedDescription)")
            }
        }
    }

    // isRunning returns true if VM appears to be running (check whether auxiliaryStorage has an existing lock)
    func isRunning() -> Bool {
        if let lockTest = try? FileManager.tryEXLock(bundle.auxiliaryStoragePath) { // true if able to lock
            return !lockTest
        }

        return false
    }

    // attachDarwinInit sets "darwin-init" nvram parameter with encoded contents of darwin-init.json
    func attachDarwinInit() throws {
        // ignore if darwin-init.json not present in bundle
        guard FileManager.isRegularFile(bundle.darwinInitPath, resolve: true) else {
            return
        }

        let darwinInit: DarwinInitConfig
        do {
            darwinInit = try DarwinInitConfig(fromFile: bundle.darwinInitPath.path)
            VM.logger.debug("darwin-init: \(darwinInit.config, privacy: .public)")
        } catch {
            throw VMError("failed to load darwin-init: \(error)")
        }

        do {
            let nvram = try VM.NVRAM(auxStorageURL: bundle.auxiliaryStoragePath)
            try nvram.set("darwin-init", value: darwinInit.base64().data(using: .utf8))
        } catch {
            throw VMError("load darwin-init into nvram: \(error)")
        }
    }
}

private class MacOSVirtualMachineDelegate: NSObject, VZVirtualMachineDelegate {
    func virtualMachine(
        _: VZVirtualMachine,
        didStopWithError error: Error
    ) {
        VM.logger.error("VM stopped with error: \(error, privacy: .public)")
        exit(EXIT_FAILURE)
    }

    func guestDidStop(_: VZVirtualMachine) {
        VM.logger.log("VM stopped")
        exit(EXIT_SUCCESS)
    }

    func virtualMachine(
        _: VZVirtualMachine,
        networkDevice _: VZNetworkDevice,
        attachmentWasDisconnectedWithError error: any Error
    ) {
        VM.logger.error("attachmentWasDisconnectedWithError: \(error, privacy: .public)")
    }
}
