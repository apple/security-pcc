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
import Foundation
import OSPrivate_os_log
import Virtualization

private let defaultVMName = "vrevm"
private let envPrefix = "VREVM"
private let envAppDir = "\(envPrefix)_APPLICATIONDIR"
private let envDataDir = "\(envPrefix)_DATADIR"
private let envVMName = "\(envPrefix)_VMNAME"
private let envNoAsk = "\(envPrefix)_NOASK"
private let envDebug = "\(envPrefix)_DEBUG"
private let envExitOnPID = "\(envPrefix)_EXIT_ON_PID"

struct CLI: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: commandName,
        abstract: "Research Environment VM manager",
        subcommands: [
            LicenseCmd.self,
            CreateCmd.self,
            ModifyCmd.self,
            ListCmd.self,
            RestoreCmd.self,
            RunCmd.self,
            RemoveCmd.self,
            ShowCmd.self,
        ]
    )

    static var logger = os.Logger(subsystem: applicationName, category: "CLI")

    struct globalOptions: ParsableArguments {
        @Option(name: [.customLong("datadir")], help: "Alternate directory of VM guests.")
        var datadir: String = cmdDefaults.dataDir

        @Flag(name: [.customLong("debug"), .customShort("d")], help: "Enable debugging.")
        var debugEnable: Bool = cmdDefaults.debugEnable

        @Flag(name: [.customLong("noask"), .customShort("f")], help: "Never ask confirmation.")
        var noAsk: Bool = cmdDefaults.noAsk
    }

    // setupDebugStderr configures log.debug messages to write to stderr when --debug enabled
    static func setupDebugStderr(debugEnable: Bool = false) {
        guard debugEnable else {
            return
        }

        var previous_hook: os_log_hook_t?
        previous_hook = os_log_set_hook(OSLogType.debug) { level, msg in
            if let subsystemCStr = msg?.pointee.subsystem,
               String(cString: subsystemCStr) == applicationName,
               let msgCStr = os_log_copy_message_string(msg)
            {
                fputs("DEBUG: " + String(cString: msgCStr) + "\n", stderr)
                free(msgCStr)
                fflush(stderr)
            }

            previous_hook?(level, msg)
        }
    }

    // set stdout/err to linebuf for print()
    static func setOutputLineBuf() {
        setlinebuf(stdout)
        setlinebuf(stderr)
    }

    // validateVMName returns arg as String after checking whether valid name for a VM;
    //   non-empty and contains no whitespace
    static func validateVMName(_ arg: String) throws -> String {
        guard !arg.isEmpty,
              arg.unicodeScalars.allSatisfy({ CharacterSet.urlHostAllowed.contains($0) })
        else {
            throw ValidationError("invalid VM name")
        }

        return arg
    }

    // validateNVramArgs returns a dictionary derived from arg representing nvram arguments to pass into
    //  guest. Settings are separated by whitespace (values containing whitespace are not supported).
    //  Valid forms: "key=value" & "key" (value set to empty string but passed in as bare key to VM)
    static func validateNVramArgs(_ arg: String) throws -> [String: String] {
        var bootArgs: [String: String] = [:]
        for p in arg.components(separatedBy: .whitespacesAndNewlines) {
            let kv = p.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)

            if kv.count > 1 { // typical key=value
                bootArgs[String(kv[0])] = String(kv[1])
            } else { // otherwise, add bare token to args
                bootArgs[String(kv[0])] = ""
            }
        }

        return bootArgs
    }

    // validateMACAddr returns arg as String after ensuring it can be parsed as a MAC address;
    //   validation performed by VZMACAddress()
    static func validateMACAddr(_ arg: String) throws -> String {
        guard let mac = VZMACAddress(string: arg) else {
            throw ValidationError("invalid mac address")
        }

        // throw error if multicast bit set (LSB of first octet)
        let octs = arg.split(separator: ":", maxSplits: 2)
        guard octs.count > 1,
              let oct0 = UInt8(octs[0], radix: 16),
              oct0 & 0x1 == 0
        else {
            throw ValidationError("invalid MAC address (multicast)")
        }

        return mac.string.lowercased()
    }

    // validateNetIfName returns arg as String representing a network interface name;
    //   non-empty and contains no whitespace
    static func validateNetIfName(_ arg: String) throws -> String {
        guard !arg.isEmpty, arg.rangeOfCharacter(from: .whitespaces) == nil else {
            throw ValidationError("invalid network interface name")
        }

        return arg
    }

    // validateNetworkConfig returns a VM.NetworkConfig representing a network configuration
    //   from arg: <mode: nat, bridged, hostonly>[,subopt=<val>,..] where subopt is among:
    //      mac=<addr>|random  (also "macaddr")
    //      bridgeIf=<ifname>  (bridged mode only)
    //
    static func validateNetworkConfig(_ arg: String) throws -> VM.NetworkConfig {
        var spec = arg.split(separator: ",", omittingEmptySubsequences: true)
        guard spec.count > 0 else {
            throw ValidationError("invalid network config")
        }

        let modeStr = spec.removeFirst()
        guard let mode = VM.NetworkMode(rawValue: String(modeStr)) else {
            throw ValidationError("invalid network mode: \(modeStr)")
        }

        if mode == .bridged && !CLI.internalBuild {
            throw ValidationError("invalid network mode: \(modeStr)")
        }

        var macAddr: String? = nil
        var bridgeIf: String? = nil

        for opt in spec {
            let kv = opt.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: true)
            guard kv.count == 2 else {
                throw ValidationError("invalid network config")
            }

            switch kv[0] {
            case "mac", "macaddr":
                if kv[1] != "random" {
                    macAddr = try validateMACAddr(String(kv[1]))
                }

            case "sharedInterface":
                guard mode == .bridged else {
                    throw ValidationError("invalid network config: bridgeIf only valid for bridged mode")
                }

                bridgeIf = try validateNetIfName(String(kv[1]))

            default:
                throw ValidationError("invalid network option: \(kv[0])")
            }
        }

        return VM.NetworkConfig(
            mode: mode,
            macAddr: macAddr,
            bridgeIf: bridgeIf
        )
    }

    // validateFilePath returns arg (representing a path to a file) as String after checking
    //  whether it exists as a file (symlinks are resolved as part of the test)
    static func validateFilePath(_ arg: String) throws -> String {
        guard FileManager.isExist(arg, resolve: true) else {
            throw ValidationError("\(arg): not found")
        }

        guard FileManager.isRegularFile(arg, resolve: true) else {
            throw ValidationError("\(arg): not a file")
        }

        return arg
    }

    // validateDirectoryPath returns arg after checking that it exists as a directory
    static func validateDirectoryPath(_ arg: String) throws -> String {
        guard FileManager.isExist(arg, resolve: true) else {
            throw ValidationError("\(arg): not found")
        }

        guard FileManager.isDirectory(arg, resolve: true) else {
            throw ValidationError("\(arg): not a directory")
        }

        return arg
    }

    // validateOSVariant returns arg if it is known among a set of "short hand" labels
    static func validateOSVariant(_ arg: String) throws -> String {
        if !CLI.osVariants.contains(arg) {
            throw ValidationError("invalid variant specified")
        }

        return arg
    }

    // confirmYN displays prompt (with " (y/n) " trailer) and reads input from stdin; if input
    //  (after whitespace trimmed) begins with "y" or "Y", true is returned, otherwise false
    static func confirmYN(prompt: String) -> Bool {
        print(prompt, terminator: " (y/n) ")
        if let yn = readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespaces).uppercased() {
            return yn.hasPrefix("Y")
        }

        return false
    }

    // nvramArgsMap returns dictionary of bootArgs and nvramArgs merged together; CLI input treats boot-args
    //  vs other nvram arguments separately (for convenience) but otherwise the former is merely mapped to
    //  "boot-args" nvramArgs key (and "bare" parameters [e.g. "-v"] are emitted as such)
    static func nvramArgsMap(bootArgs: String?, nvramArgs: [String: String]?) -> VM.NVRAMmap? {
        var res: VM.NVRAMmap = [:]
        if let bootArgs {
            res["boot-args"] = bootArgs.data(using: .utf8)
        }

        if let nvramArgs {
            res.merge(nvramArgs.mapValues { $0.data(using: .utf8) ?? Data() },
                      uniquingKeysWith: { k, _ in k })
        }

        return res.count > 0 ? res : nil
    }

    // awaitInterrupt parks the main process thread until interrupted -- if _EXIT_ON_PID envvar is set
    //  (containing a PID, typically that of pccvre process that launched us), monitor the process in
    //  case it exits (possibly abnormally - normal exit usually sends termination signal) and shut down
    //  with a non-zero exit code (if PID doesn't exist, it will immediately exit). When vm passed in, it
    //  will formally stop() it when PID monitor triggered.
    static func awaitInterrupt(vm: VM? = nil) async {
        let rq: DispatchQueue
        let dsps: DispatchSourceProcess
        if let pidenv = ProcessInfo().environment[envExitOnPID],
           let pid = pid_t(pidenv), pid > 0
        {
            rq = vm?.runQueue ?? .init(label: applicationName)
            dsps = DispatchSource.makeProcessSource(identifier: pid,
                                                    eventMask: .exit,
                                                    queue: rq)
            dsps.setEventHandler {
                VM.logger.log("exiting upon PID [\(pid, privacy: .public)] termination")
                if let vzVM = vm?.vzVM {
                    vzVM.stop { _ in exit(withError: ExitCode.failure) }
                } else {
                    exit(withError: ExitCode.failure)
                }
            }

            dsps.resume()
        }

        let (stream, _) = AsyncStream<Void>.makeStream()
        for try await _ in stream {} // park until interrupted
    }
}

extension CLI {
    // internalBuild returns true when local host OS is an "internal" build
    static var internalBuild: Bool { os_variant_allows_internal_security_policies(applicationName) }

    // osVariants holds shorthand forms of OS variants (for --variant arg)
    static var osVariants: [String] {
        let publicVariants: [String] = [
            "customer",
            "research",
        ]
        let internalVariants: [String] = [
            "internal-development",
            "internal-debug",
        ]

        return CLI.internalBuild ? publicVariants + internalVariants : publicVariants
    }

    // restoreVariantName returns the full variant name string associated with the variant label
    static func restoreVariantName(_ variant: String) throws -> String {
        return switch variant {
        case "customer": "Darwin Cloud Customer Erase Install (IPSW)"
        case "research": "Research Darwin Cloud Customer Erase Install (IPSW)"
        case "internal-development": "Darwin Cloud Internal Development"
        case "internal-debug": "Darwin Cloud Internal Debug"
        default: throw ValidationError("invalid variant specified")
        }
    }
}

// CLIError provides a generic error wrapper for top-level CLI commands
struct CLIError: Error, CustomStringConvertible {
    var message: String
    var description: String { message }

    init(_ message: String) {
        VM.logger.error("\(message, privacy: .public)")
        self.message = message
    }
}

// cmdDefaults provides global defaults from envvars or presets
enum cmdDefaults {
    // applicationDir returns value of VREVM_APPLICATIONDIR envvar or default location under ~/Library
    static var applicationDir: String {
        if let base = ProcessInfo().environment[envAppDir] {
            return base
        } else {
            // $HOME/Library/Application Support/com.apple.security-research.vrevm/
            return URL.applicationSupportDirectory.appendingPathComponent(applicationName).path
        }
    }

    // dataDir returns value of VREVM_DATADIR envvar or default location under ~/Library
    static var dataDir: String {
        if let base = ProcessInfo().environment[envDataDir] {
            return base
        } else {
            // <applicationDir>/VM-Library/
            return FileManager.fileURL(cmdDefaults.applicationDir)
                .appendingPathComponent("VM-Library")
                .path
        }
    }

    // vmName returns value of VREVM_VMNAME or defaultVMName
    static var vmName: String {
        if let name = ProcessInfo().environment[envVMName] {
            if let name = try? CLI.validateVMName(name) {
                return name
            }
        }

        return defaultVMName
    }

    // noAsk returns false if VREVM_NOASK is unset or starts with [fFnN0]; true if set to anything else
    static var noAsk: Bool {
        if let noask = ProcessInfo().environment[envNoAsk] {
            // false if starts with "n(o)", "f(alse)", "0", else true (if set)
            return !noask.lowercased().starts(with: ["n", "f", "0"])
        }

        return false
    }

    // debugEnable returns false if VREVM_DEBUG is unset or starts with [fFnN0]; true if set to anything else
    static var debugEnable: Bool {
        if let debug = ProcessInfo().environment[envDebug] {
            // false if starts with "n(o)", "f(alse)", "0", else true (if set)
            return !debug.lowercased().starts(with: ["n", "f", "0"])
        }

        return false
    }
}
