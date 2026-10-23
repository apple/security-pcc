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

extension PCCFrontend {
    public struct PrivacyApprovedEvents: AllEventsIterable {
        public static let allEvents: [any EHUEFEvent.Type] = [
            Self.PCCNormalizedProcessEvent.self,
            Self.PCCNormalizedNetworkEvent.self,
            Self.PCCNormalizedDnsEvent.self,
            Self.PCCNormalizedDeviceEvent.self,
            Self.PCCNormalizedSSHEvent.self,
            Self.ProcExitEvent.self,
            Self.IOKitOpenEvent.self,
            Self.SSHLoginEvent.self,
            Self.SSHLogoutEvent.self,
            Self.NWEvent.self,
            Self.SandboxViolationEvent.self,
            Self.RestrictedExecutionModeViolationEvent.self,
            Self.MDNSResponderQueriesEvent.self,
            Self.CryptexInstallEvent.self,
            Self.CryptexUpgradedEvent.self,
            Self.CryptexUninstallEvent.self,
            Self.AlertEngineEvent.self
        ]

        public struct PCCNormalizedProcessEvent: EHUEFEvent {
            public var metadata = EHEventMetadata()
            public var event_category: EHUEFCategory = .process
            public var event_type: String = "pcc_\(EventNormalizer.NormalizedProcess().event_type)"
            public var start_time: Double = 0
            public var cwd: String = ""
            public var args: [String] = []
            public var exe: String = ""
            public var tty: String = ""
            public var pid: Int64 = 0
            public var uid: UInt32 = 0
            public var gid: UInt32 = 0
            public var ppid: Int64 = 0
            public var p_exe: String = ""
            public var non_normalizable: [String: EHValueType] = [:]

            public init() {}
            init(from: EventNormalizer.NormalizedProcess) {
                self.tags = from.tags

                self.start_time = from.start_time
                self.cwd = from.cwd
                self.args = from.args
                self.exe = from.exe
                self.tty = from.tty
                self.pid = from.pid
                self.uid = from.uid
                self.gid = from.gid
                self.ppid = from.ppid
                self.p_exe = from.p_exe
                for allowedFields in [
                    "signingID",
                    "platformBinary",
                    "script",
                    "codesigningFlags",
                    "parentSigningID",
                    "parentPlatformBinary"
                ] {
                    self.non_normalizable[allowedFields] = from.non_normalizable[allowedFields]
                }
                self.copyHostMetadata(from)
            }
        }
        public struct PCCNormalizedNetworkEvent: EHUEFEvent {
            public var metadata = EHEventMetadata()
            public var event_category: EHUEFCategory = .network
            public var event_type: String = "pcc_\(EventNormalizer.NormalizedNetwork().event_type)"
            public var start_time: Double = 0
            public var pid: Int64 = 0
            public var proc_name: String = ""
            public var remote_addr: String = ""
            public var remote_port: UInt16 = 0
            public var local_port: UInt16 = 0
            public var direction: String = ""
            public var `protocol`: String = ""
            public var uid: UInt32 = 0

            public var non_normalizable: [String: EHValueType] = [:]

            public init() {}
            init(from: EventNormalizer.NormalizedNetwork) {
                self.tags = from.tags

                self.start_time = from.start_time
                self.pid = from.pid
                self.proc_name = from.proc_name
                self.remote_addr = from.remote_addr
                self.remote_port = from.remote_port
                self.local_port = from.local_port
                self.direction = from.direction
                self.protocol = from.protocol
                self.uid = from.uid

                self.copyHostMetadata(from)
            }
        }
        public struct PCCNormalizedDnsEvent: EHUEFEvent {
            public var metadata = EHEventMetadata()
            public var event_category: EHUEFCategory = .network
            public var event_type: String = "pcc_\(EventNormalizer.NormalizedDns().event_type)"
            public var start_time: Double = 0
            public var pid: Int64 = 0
            public var proc_name: String = ""
            public var rowtype: String = ""
            public var qname: String = ""
            public var qtype: String = ""
            public var rcode: String = ""
            public var rdata: String = ""
            public var qname_entropy: Double = 0
            public var subqname: String = ""
            public var subqname_entropy: Double = 0

            public var non_normalizable: [String: EHValueType] = [:]

            public init() {}
            init(from: EventNormalizer.NormalizedDns) {
                self.tags = from.tags

                self.start_time = from.start_time
                self.pid = from.pid
                self.proc_name = from.proc_name
                self.rowtype = from.rowtype
                self.qname = from.qname
                self.qtype = from.qtype
                self.rcode = from.rcode
                self.rdata = from.rdata
                self.qname_entropy = from.qname_entropy
                self.subqname = from.subqname
                self.subqname_entropy = from.subqname_entropy

                for allowedFields in [
                    "namehash",
                    "queryID",
                    "interfaceIndex",
                    "flags"
                ] {
                    self.non_normalizable[allowedFields] = from.non_normalizable[allowedFields]
                }

                self.copyHostMetadata(from)
            }
        }
        public struct PCCNormalizedDeviceEvent: EHUEFEvent {
            public var metadata = EHEventMetadata()
            public var event_category: EHUEFCategory = .resource
            public var event_type: String = "pcc_\(EventNormalizer.NormalizedDevice().event_type)"
            public var timestamp: Double = 0
            public var pid: Int64 = 0
            public var executable: String = ""
            public var device_identifier: String = ""
            public var device_path: String = ""
            public var device_major: UInt32?
            public var device_minor: UInt32?

            public var non_normalizable: [String: EHValueType] = [:]

            public init() {}
            init(from: EventNormalizer.NormalizedDevice) {
                self.tags = from.tags

                self.timestamp = from.timestamp
                self.pid = from.pid
                self.executable = from.executable
                self.device_identifier = from.device_identifier
                self.device_path = from.device_path
                self.device_major = from.device_major
                self.device_minor = from.device_minor

                self.copyHostMetadata(from)
            }
        }

        public struct PCCNormalizedSSHEvent: EHUEFEvent {
            public var metadata = EHEventMetadata()
            public var event_category: EHUEFCategory = .system
            public var event_type: String = "pcc_\(EventNormalizer.NormalizedSSH().event_type)"
            public var start_time: Double = 0
            public var src_addr: String = ""
            public var username: String = ""
            public var success: Bool = false
            public var uid: UInt32 = 0
            public var pid: Int64 = 0
            public var action: String = ""

            public var non_normalizable: [String: EHValueType] = [:]

            public init() {}
            init(from: EventNormalizer.NormalizedSSH) {
                self.tags = from.tags
                self.start_time = from.start_time
                self.src_addr = from.src_addr
                self.username = from.username
                self.success = from.success
                self.uid = from.uid
                self.pid = from.pid
                self.action = from.action
                self.copyHostMetadata(from)
            }
        }

        public struct ProcExitEvent: EHUEFEvent {
            public var metadata = EHEventMetadata()
            public var event_category: EHUEFCategory = .process
            public var event_type: String = "pcc_proc_exit"
            public var timestamp: TimeInterval = 0
            public var pid: UInt32 = 0
            public var executable: String = ""
            public var exitStatus: Int32 = 0
            public init() {}
            init(from: ESClient.ESClientProcExitEvent) {
                self.tags = from.tags
                self.timestamp = from.timestamp
                self.pid = from.pid
                self.executable = from.executable
                self.exitStatus = from.exitStatus
                self.copyHostMetadata(from)
            }
        }

        public struct IOKitOpenEvent: EHUEFEvent {
            public var metadata = EHEventMetadata()
            public var event_category: EHUEFCategory = .resource
            public var event_type: String = "pcc_iokit_open"
            public var timestamp: TimeInterval = 0
            public var pid: UInt32 = 0
            public var executable: String = ""
            public var userClientClass: String = ""
            public var userClientType: UInt32 = 0
            public var binName: String = ""
            public init() {}
            init(from: ESClient.ESClientIOKitOpenEvent) {
                self.tags = from.tags
                self.timestamp = from.timestamp
                self.pid = from.pid
                self.executable = from.executable
                self.userClientClass = from.userClientClass
                self.userClientType = from.userClientType
                self.binName = from.binName
                self.copyHostMetadata(from)
            }
        }

        public struct SSHLoginEvent: EHUEFEvent {
            public var metadata = EHEventMetadata()
            public var event_category: EHUEFCategory = .system
            public var event_type: String = "pcc_ssh_login"
            public var timestamp: TimeInterval = 0
            public var srcAddr: String = ""
            public var username: String = ""
            public var success: String = ""
            public var uid: String = ""
            public init() {}
            init(from: ESClient.ESClientSSHLoginEvent) {
                self.tags = from.tags
                self.timestamp = from.timestamp
                self.srcAddr = from.srcAddr
                self.username = from.username
                self.success = from.success
                self.uid = from.uid
                self.copyHostMetadata(from)
            }
        }

        public struct SSHLogoutEvent: EHUEFEvent {
            public var metadata = EHEventMetadata()
            public var event_category: EHUEFCategory = .system
            public var event_type: String = "pcc_ssh_logout"
            public var timestamp: TimeInterval = 0
            public var srcAddr: String = ""
            public var username: String = ""
            public var uid: UInt32 = 0
            public init() {}
            init(from: ESClient.ESClientSSHLogoutEvent) {
                self.tags = from.tags
                self.timestamp = from.timestamp
                self.srcAddr = from.srcAddr
                self.username = from.username
                self.uid = from.uid
                self.copyHostMetadata(from)
            }
        }
        public struct NWEvent: EHUEFEvent {
            public var metadata = EHEventMetadata()
            public var event_category: EHUEFCategory = .network
            public var event_type: String = "pcc_nw_open"
            public var startTime: Double = 0
            public var remoteAddr: String = ""
            public var remotePort: UInt16 = 0
            public var localPort: UInt16 = 0
            public var epid: pid_t = 0
            public var procName: String = ""
            public var uid: uid_t = 0
            public var direction: String = ""
            public init() {}
            init(from: NStatClient.NStatClientNWEvent) {
                self.tags = from.tags
                self.startTime = from.startTime
                self.remoteAddr = from.remoteAddr
                self.remotePort = from.remotePort
                self.localPort = from.localPort
                self.epid = from.epid
                self.procName = from.procName
                self.uid = from.uid
                self.direction = from.direction
                self.copyHostMetadata(from)
            }
        }

        public struct SandboxViolationEvent: EHUEFEvent {
            public var metadata = EHEventMetadata()
            public var event_category: EHUEFCategory = .system
            public var event_type: String = "pcc_SandboxViolation"
            public var process: String = ""
            public var processID: pid_t = 0
            public var action: String = ""
            public var rule: String = ""
            public var path: String = ""
            public var timestamp: TimeInterval = 0
            public var duplicates: Int = 0
            public init() {}
            init(from: SandboxViolation.Event) {
                self.tags = from.tags
                self.process = from.process
                self.processID = from.processID
                self.action = from.action
                self.rule = from.rule
                self.path = from.path
                self.timestamp = from.timestamp
                self.duplicates = from.duplicates
                self.copyHostMetadata(from)
            }
        }

        public struct RestrictedExecutionModeViolationEvent: EHUEFEvent {
            public var metadata = EHEventMetadata()
            public var event_category: EHUEFCategory = .system
            public var event_type: String = "pcc_RestrictedExecutionModeViolation"
            public var binary: String = ""
            public var identity: String = ""
            public var remstate: String = ""
            public var reason: String = ""
            public var timestamp: TimeInterval = 0
            public init() {}
            init(from: RestrictedExecutionModeViolation.Event) {
                self.tags = from.tags
                self.binary = from.binary
                self.identity = from.identity
                self.remstate = from.remstate
                self.reason = from.reason
                self.timestamp = from.timestamp
                self.copyHostMetadata(from)
            }
        }

        public struct MDNSResponderQueriesEvent: EHUEFEvent {
            public var metadata = EHEventMetadata()
            public var event_category: EHUEFCategory = .system
            public var event_type: String = "pcc_DNSServiceQueryRecord"
            public var rowtype: String = ""
            public var timestamp: TimeInterval = 0
            public var queryID: String = ""
            public var process: String = ""
            public var processID: pid_t = 0
            public var qname: String = ""
            public var qtype: String = ""
            public var flags: String = ""
            public var interfaceIndex: Int = 0
            public var namehash: String = ""
            public var rdata: String = ""
            public var qnameSE: Double = 0
            public var subqname: String = ""
            public var subqnameSE: Double = 0
            public init() {}
            init(from: MDNSResponderQueries.Event) {
                self.tags = from.tags
                self.rowtype = from.rowtype
                self.timestamp = from.timestamp
                self.queryID = from.queryID
                self.process = from.process
                self.processID = from.processID
                self.qname = from.qname
                self.qtype = from.qtype
                self.flags = from.flags
                self.interfaceIndex = from.interfaceIndex
                self.namehash = from.namehash
                self.rdata = from.rdata
                self.qnameSE = from.qnameSE
                self.subqname = from.subqname
                self.subqnameSE = from.subqnameSE
                self.copyHostMetadata(from)
            }
        }
        public struct CryptexInstallEvent: EHUEFEvent {
            public var metadata = EHEventMetadata()
            public var event_category: EHUEFCategory = .system
            public var event_type: String = "pcc_\(CryptexGenerator.CryptexInstallEvent().event_type)"
            public var name: String = ""
            public var identifier: String = ""
            public var version: String = ""
            public var alreadyInstalled: Bool = false
            public var timestamp: Double = 0
            public init() {}
            init(from: CryptexGenerator.CryptexInstallEvent) {
                self.tags = from.tags
                self.name = from.name
                self.identifier = from.identifier
                self.version = from.version
                self.alreadyInstalled = from.alreadyInstalled
                self.timestamp = from.timestamp
                self.copyHostMetadata(from)
            }
        }
        public struct CryptexUninstallEvent: EHUEFEvent {
            public var metadata = EHEventMetadata()
            public var event_category: EHUEFCategory = .system
            public var event_type: String = "pcc_\(CryptexGenerator.CryptexUninstallEvent().event_type)"
            public var name: String = ""
            public var identifier: String = ""
            public var version: String = ""
            public var timestamp: Double = 0
            public init() {}
            init(from: CryptexGenerator.CryptexUninstallEvent) {
                self.tags = from.tags
                self.name = from.name
                self.identifier = from.identifier
                self.version = from.version
                self.timestamp = from.timestamp
                self.copyHostMetadata(from)
            }
        }
        public struct CryptexUpgradedEvent: EHUEFEvent {
            public var metadata = EHEventMetadata()
            public var event_category: EHUEFCategory = .system
            public var event_type: String = "pcc_\(CryptexGenerator.CryptexUpgradedEvent().event_type)"
            public var name: String = ""
            public var identifier: String = ""
            public var version: String = ""
            public var timestamp: Double = 0
            public init() {}
            init(from: CryptexGenerator.CryptexUpgradedEvent) {
                self.tags = from.tags
                self.name = from.name
                self.identifier = from.identifier
                self.version = from.version
                self.timestamp = from.timestamp
                self.copyHostMetadata(from)
            }
        }
        public struct AlertEngineEvent: EHUEFEvent {
            public init() {}
            public var metadata = EHEventMetadata()
            public var event_category: EHUEFCategory = .alert
            public var event_type: String = "pcc_\(RegoEngine.AlertEvent().event_type)"

            public var timestamp: TimeInterval = 0
            public var name: String = ""
            public var identifier: String = ""
            public var severity: Double = 0
            public var confidence: Double = 0
            public var payload: String = ""
            init(from: RegoEngine.AlertEvent) {
                self.tags = from.tags
                self.name = from.name
                self.timestamp = from.timestamp
                self.name = from.name
                self.identifier = from.identifier
                self.severity = from.severity
                self.confidence = from.confidence
                self.payload = from.sourceEvent?.jsonString ?? ""
                self.copyHostMetadata(from)
            }
        }
    }
}


extension EHUEFEvent {
    mutating func copyHostMetadata(_ other: any EHUEFEvent) {
        for key in [
            HostInfoEnricher.Keys.prod_fused,
            HostInfoEnricher.Keys.os_variant,
            HostInfoEnricher.Keys.eh_frontend,
            HostInfoEnricher.Keys.eh_version,
            HostInfoEnricher.Keys.eh_variant,
            HostInfoEnricher.Keys.product_name,
            HostInfoEnricher.Keys.hw_model,
            HostInfoEnricher.Keys.serial,
            HostInfoEnricher.Keys.environment,
            HostInfoEnricher.Keys.boot_session,
            HostInfoEnricher.Keys.observability_labels,
            HostInfoEnricher.Keys.application_name
        ] {
            self.fields[key.rawValue] = other.fields[key.rawValue]
        }
    }
}


final class PCCPrivacyEventCaster: EHTransform {
    public let name = "PCCPrivacyEventCaster"
    func configure() async throws { }

    func process(_ event: any EHUEFEvent) async -> EHTransformReturn {
        if let e = event as? EventNormalizer.NormalizedProcess {
            return (.proceed_mutated, [PCCFrontend.PrivacyApprovedEvents.PCCNormalizedProcessEvent(from: e)], nil, nil)
        } else if let e = event as? EventNormalizer.NormalizedNetwork {
            return (.proceed_mutated, [PCCFrontend.PrivacyApprovedEvents.PCCNormalizedNetworkEvent(from: e)], nil, nil)
        } else if let e = event as? EventNormalizer.NormalizedDns {
            return (.proceed_mutated, [PCCFrontend.PrivacyApprovedEvents.PCCNormalizedDnsEvent(from: e)], nil, nil)
        } else if let e = event as? EventNormalizer.NormalizedDevice {
            return (.proceed_mutated, [PCCFrontend.PrivacyApprovedEvents.PCCNormalizedDeviceEvent(from: e)], nil, nil)
        } else if let e = event as? EventNormalizer.NormalizedSSH {
            return (.proceed_mutated, [PCCFrontend.PrivacyApprovedEvents.PCCNormalizedSSHEvent(from: e)], nil, nil)
        } else if let e = event as? ESClient.ESClientProcExitEvent {
            return (.proceed_mutated, [PCCFrontend.PrivacyApprovedEvents.ProcExitEvent(from: e)], nil, nil)
        } else if let e = event as? ESClient.ESClientIOKitOpenEvent {
            return (.proceed_mutated, [PCCFrontend.PrivacyApprovedEvents.IOKitOpenEvent(from: e)], nil, nil)
        } else if let e = event as? ESClient.ESClientSSHLoginEvent {
            return (.proceed_mutated, [PCCFrontend.PrivacyApprovedEvents.SSHLoginEvent(from: e)], nil, nil)
        } else if let e = event as? ESClient.ESClientSSHLogoutEvent {
            return (.proceed_mutated, [PCCFrontend.PrivacyApprovedEvents.SSHLogoutEvent(from: e)], nil, nil)
        } else if let e = event as? NStatClient.NStatClientNWEvent {
            return (.proceed_mutated, [PCCFrontend.PrivacyApprovedEvents.NWEvent(from: e)], nil, nil)
        } else if let e = event as? SandboxViolation.Event {
            return (.proceed_mutated, [PCCFrontend.PrivacyApprovedEvents.SandboxViolationEvent(from: e)], nil, nil)
        } else if let e = event as? RestrictedExecutionModeViolation.Event {
            return (.proceed_mutated, [PCCFrontend.PrivacyApprovedEvents.RestrictedExecutionModeViolationEvent(from: e)], nil, nil)
        } else if let e = event as? MDNSResponderQueries.Event {
            return (.proceed_mutated, [PCCFrontend.PrivacyApprovedEvents.MDNSResponderQueriesEvent(from: e)], nil, nil)
        } else if let e = event as? CryptexGenerator.CryptexInstallEvent {
            return (.proceed_mutated, [PCCFrontend.PrivacyApprovedEvents.CryptexInstallEvent(from: e)], nil, nil)
        } else if let e = event as? CryptexGenerator.CryptexUninstallEvent {
            return (.proceed_mutated, [PCCFrontend.PrivacyApprovedEvents.CryptexUninstallEvent(from: e)], nil, nil)
        } else if let e = event as? CryptexGenerator.CryptexUpgradedEvent {
            return (.proceed_mutated, [PCCFrontend.PrivacyApprovedEvents.CryptexUpgradedEvent(from: e)], nil, nil)
        } else if let e = event as? RegoEngine.AlertEvent {
            return (.proceed_mutated, [PCCFrontend.PrivacyApprovedEvents.AlertEngineEvent(from: e)], nil, nil)
        }

        return (.drop, nil, nil, nil)
    }
}
