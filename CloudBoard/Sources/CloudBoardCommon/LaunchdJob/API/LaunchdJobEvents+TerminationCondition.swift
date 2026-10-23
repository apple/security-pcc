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

import CloudBoardMetrics
import System
import XPC

//  We should expose this level of information on the API as it is used for logging/telemetry
// so abstracting it would be strctly reducing the utility of it being available
// We do not envisage ever making business logic decisions about the details of this information
extension LaunchdJobEvents.TerminationCondition {
    /// Maps to OS reason namespaces as defined in /usr/local/include/sys/reason.h
    ///
    /// The majority of these will be irrelevant but OSLaunchdJobExitStatus uses os reasons to inform of exit reasons.
    enum OSReasonNamespace: Int, CustomStringConvertible {
        case invalid = 0
        case jetsam = 1
        case signal = 2
        case codesigning = 3
        case hangtracer = 4
        case test = 5
        case dyld = 6
        case libxpc = 7
        case objc = 8
        case exec = 9
        case springboard = 10
        case tcc = 11
        case reportcrash = 12
        case coreanimation = 13
        case aggregated = 14
        case runningboard = 15
        case skywalk = 16
        case settings = 17
        case libsystem = 18
        case foundation = 19
        case watchdog = 20
        case metal = 21
        case watchkit = 22
        case `guard` = 23
        case analytics = 24
        case sandbox = 25
        case security = 26
        case endpointsecurity = 27
        case pacException = 28
        case bluetoothChip = 29
        case portSpace = 30
        case webkit = 31
        case backlightservices = 32
        case media = 33
        case rosetta = 34
        case libgnition = 35
        case bootmount = 36

        var description: String {
            switch self {
            case .invalid: return "invalid"
            case .jetsam: return "jetsam"
            case .signal: return "signal"
            case .codesigning: return "codesigning"
            case .hangtracer: return "hangtracer"
            case .test: return "test"
            case .dyld: return "dyld"
            case .libxpc: return "libxpc"
            case .objc: return "objc"
            case .exec: return "exec"
            case .springboard: return "springboard"
            case .tcc: return "tcc"
            case .reportcrash: return "report crash"
            case .coreanimation: return "core animation"
            case .aggregated: return "aggregated"
            case .runningboard: return "runningboad"
            case .skywalk: return "skywalk"
            case .settings: return "settings"
            case .libsystem: return "libsystem"
            case .foundation: return "foundation"
            case .watchdog: return "watchdog"
            case .metal: return "metal"
            case .watchkit: return "watchkit"
            case .guard: return "guard"
            case .analytics: return "analytics"
            case .sandbox: return "sandbox"
            case .security: return "security"
            case .endpointsecurity: return "endpoint security"
            case .pacException: return "pac exception"
            case .bluetoothChip: return "bluetooth chip"
            case .portSpace: return "port space"
            case .webkit: return "webkit"
            case .backlightservices: return "backlightservices"
            case .media: return "media"
            case .rosetta: return "rosetta"
            case .libgnition: return "libignition"
            case .bootmount: return "bootmount"
            }
        }

        func codeDescription(for reason: Int) -> String {
            switch self {
            case .signal: return OSReasonSignal(rawValue: reason).map { "\(reason) (\($0))" } ?? "\(reason)"
            case .codesigning: return OSReasonCodesigning(rawValue: reason).map { "\(reason) (\($0))" } ?? "\(reason)"
            case .exec: return OSReasonExec(rawValue: reason).map { "\(reason) (\($0))" } ?? "\(reason)"
            case .guard: return OSReasonGuard(rawValue: reason).map { "\(reason) (\($0))" } ?? "\(reason)"
            case .libxpc: return OSReasonLibXPC(rawValue: reason).map { "\(reason) (\($0))" } ?? "\(reason)"
            default: return "\(reason)"
            }
        }
    }

    /// Signals as defined in /usr/include/sys/signal.h
    enum OSReasonSignal: Int, CustomStringConvertible {
        case sighup = 1 // hangup
        case sigint = 2 // interrupt
        case sigquit = 3 // quit
        case sigill = 4 // illegal instruction (not reset when caught)
        case sigtrap = 5 // trace trap (not reset when caught)
        case sigabrt = 6 // abort()
        case sigemt = 7 // EMT instruction
        case sigfpe = 8 // floating point exception
        case sigkill = 9 // kill (cannot be caught or ignored)
        case sigbus = 10 // bus error
        case sigsegv = 11 // segmentation violation
        case sigsys = 12 // bad argument to system call
        case sigpipe = 13 // write on a pipe with no one to read it
        case sigalrm = 14 // alarm clock
        case sigterm = 15 // software termination signal from kill
        case sigurg = 16 // urgent condition on io channel
        case sigstop = 17 // sendable stop signal not from tty
        case sigtstp = 18 // stop signal from tty
        case sigcont = 19 // continue a stopped process
        case sigchld = 20 // to parent on child stop or exit
        case sigttin = 21 // to readers pgrp upon background tty read
        case sigttou = 22 // like TTIN for output if (tp->t_local&LTOSTOP)
        case sigio = 23 // input/output possible signal
        case sigxcpu = 24 // exceeded cpu time limit
        case sigxfsz = 25 // exceeded file size limit
        case sigvtalrm = 26 // virtual time alarm
        case sigprof = 27 // profiling time alarm
        case sigwinch = 28 // window size changes
        case siginfo = 29 // information request
        case sigusr1 = 30 // user defined signal 1
        case sigusr2 = 31 // user defined signal 2

        var description: String {
            switch self {
            case .sighup: return "sighup"
            case .sigint: return "sigint"
            case .sigquit: return "sigquit"
            case .sigill: return "sigill"
            case .sigtrap: return "sigtrap"
            case .sigabrt: return "sigabrt"
            case .sigemt: return "sigemt"
            case .sigfpe: return "sigfpe"
            case .sigkill: return "sigkill"
            case .sigbus: return "sigbus"
            case .sigsegv: return "sigsegv"
            case .sigsys: return "sigsys"
            case .sigpipe: return "sigpipe"
            case .sigalrm: return "sigalrm"
            case .sigterm: return "sigterm"
            case .sigurg: return "sigurg"
            case .sigstop: return "sigstop"
            case .sigtstp: return "sigstp"
            case .sigcont: return "sigcont"
            case .sigchld: return "sigchld"
            case .sigttin: return "sigttin"
            case .sigttou: return "sigttou"
            case .sigio: return "sigio"
            case .sigxcpu: return "sigxcpu"
            case .sigxfsz: return "sigxfsz"
            case .sigvtalrm: return "sigvtalrm"
            case .sigprof: return "sigprof"
            case .sigwinch: return "sigwinch"
            case .siginfo: return "siginfo"
            case .sigusr1: return "sigusr1"
            case .sigusr2: return "sigusr2"
            }
        }
    }

    /// Codesigning exit reasons as defined in /usr/local/include/sys/reason.h
    enum OSReasonCodesigning: Int, CustomStringConvertible {
        case taskgatedInvalidSig = 1
        case invalidPage = 2
        case taskAccessPort = 3
        case launchdConstraintViolation = 4

        var description: String {
            switch self {
            case .taskgatedInvalidSig: return "task gated invalid signature"
            case .invalidPage: return "invalid page"
            case .taskAccessPort: return "task access port"
            case .launchdConstraintViolation: return "launchd constraint violation"
            }
        }
    }

    /// Exec exit reasons as defined in /usr/local/include/sys/reason.h
    enum OSReasonExec: Int, CustomStringConvertible {
        case badMacho = 1
        case sugidFailure = 2
        case actvThreadstate = 3
        case stackAlloc = 4
        case appleStringInit = 5
        case copyoutStrings = 6
        case copyoutDynlinker = 7
        case securityPolicy = 8
        case taskgatedOther = 9
        case fairplayDecrypt = 10
        case decrypt = 11
        case upx = 12
        case no32exec = 13
        case wrongPlatform = 14
        case mainFdAlloc = 15
        case copyoutRosetta = 16
        case setDyldInfo = 17
        case machineThread = 18
        case badPsAttr = 19

        var description: String {
            switch self {
            case .badMacho: return "bad macho"
            case .sugidFailure: return "sugid failure"
            case .actvThreadstate: return "actv threadstate"
            case .stackAlloc: return "stack alloc"
            case .appleStringInit: return "apple string init"
            case .copyoutStrings: return "copyout string"
            case .copyoutDynlinker: return "copyout dynlinker"
            case .securityPolicy: return "securty policy"
            case .taskgatedOther: return "task gated other"
            case .fairplayDecrypt: return "fairplay decrypt"
            case .decrypt: return "decrypt"
            case .upx: return "upx"
            case .no32exec: return "no 32-bit exec"
            case .wrongPlatform: return "wrong platform"
            case .mainFdAlloc: return "main fd alloc"
            case .copyoutRosetta: return "copyout rosetta"
            case .setDyldInfo: return "set dyld info"
            case .machineThread: return "machine thread"
            case .badPsAttr: return "bad ps attribute"
            }
        }
    }

    /// Guard exit reasons as defined in /usr/local/include/sys/reason.h
    enum OSReasonGuard: Int, CustomStringConvertible {
        case vnode = 1
        case virtualMemory = 2
        case machPort = 3

        var description: String {
            switch self {
            case .vnode: return "vnode"
            case .virtualMemory: return "virtual memory"
            case .machPort: return "mach port"
            }
        }
    }

    /// Codesigning exit reasons as defined in /usr/local/include/xpc/exit_reason_private.h
    enum OSReasonLibXPC: Int, CustomStringConvertible {
        case reserved = 1
        case unknownIPC = 2
        case extensionCheckInTimeout = 3
        case sigtermTimeout = 4
        case abandoned = 5
        case sandboxFilteredIPC = 6
        case fastLogout = 7
        case unmanaged = 8
        case fault = 9

        var description: String {
            switch self {
            case .reserved: return "reserved"
            case .unknownIPC: return "unknown IPC"
            case .extensionCheckInTimeout: return "extension check in timeout"
            case .sigtermTimeout: return "sigterm timeout"
            case .abandoned: return "abandoned"
            case .sandboxFilteredIPC: return "sandbox filtered ipc"
            case .fastLogout: return "fast logout"
            case .unmanaged: return "unmanaged"
            case .fault: return "fault"
            }
        }
    }

    public func emitMetrics(metricsSystem: MetricsSystem, counterFactory: any CounterFactory<LaunchDJobExitDetails>) {
        let exitDetails: LaunchDJobExitDetails = switch self {
        case .exited(let exitStatus):
            switch exitStatus {
            case .osStatus(let namespace, let code):
                .init(
                    exitCode: OSReasonNamespace(rawValue: namespace)?.codeDescription(for: code) ?? "\(code)",
                    reasonNamespace: OSReasonNamespace(rawValue: namespace)?.description ?? "\(namespace)"
                )
            case .wait4Status(let exitCode):
                .init(
                    exitCode: "\(exitCode.map { String($0) } ?? "unknown")",
                    reasonNamespace: "exit"
                )
            case .unknown:
                .init(
                    exitCode: "unknown",
                    reasonNamespace: "unknown"
                )
            }
        case .launchdError(let errno):
            .init(
                exitCode: String(errno.rawValue),
                reasonNamespace: "launchd"
            )
        case .spawnFailed(let errno):
            .init(
                exitCode: String(errno.rawValue),
                reasonNamespace: "spawn failed"
            )
        case .uncleanShutdown:
            .init(
                exitCode: "unknown",
                reasonNamespace: "unclean shutdown"
            )
        case .failedToRun:
            .init(
                exitCode: "unknown",
                reasonNamespace: "failed to run"
            )
        }

        metricsSystem.emit(counterFactory.make(exitDetails))
    }
}
