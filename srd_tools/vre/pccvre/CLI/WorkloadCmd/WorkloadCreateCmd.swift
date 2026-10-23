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
import CoreAnalytics
import Foundation
import System

extension CLI.WorkloadCmd {
    private struct CreateOptions: ParsableArguments {
        // SW releases are selected by <release> indexnum for given <logEnvironment>
        @Option(name: [.customLong("environment"), .customShort("E")],
                help: ArgumentHelp("SW Transparency Log environment.",
                                   visibility: .customerHidden))
        var logEnvironment: TransparencyLog.Environment = CLIDefaults.ktEnvironment

        @Option(name: [.customLong("http-endpoint")],
                help: "Bind built-in HTTP service to <addr>[:<port>] or 'none'. (default: automatic)",
                transform: { try CLI.validateHTTPService($0) })
        var httpService: HTTPServer.Configuration? = .virtual(HTTPServer.Configuration.Virtual(mode: .nat))

        @Flag(help: ArgumentHelp("Skip the release requirements check.",
                                 visibility: .customerHidden))
        var skipReleaseRequirementsCheck: Bool = false

        @Flag(help: ArgumentHelp("Force creation by removing any VMs that already exist with the same names."))
        var force: Bool = false

        @Option(name: [.customShort("c"), .customLong("configuration")],
                help: "Configuration specifying one or more instance configurations",
                completion: .file(),
                transform: { try WorkloadConfiguration(fromFile: $0) })
        var workload: WorkloadConfiguration
    }

    struct WorkloadCreateCmd: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "create",
            abstract: "Create a new Virtual Research Environment workload consisting of multiple VMs.",
            discussion: """
            The standard flow for this command uses the configuration and assets
            provided within release metadata (using the --release option). After
            completing successfully, a VM has been created and restored with the
            configured OS image and left stopped.

            It's also possible to create a VRE instance using --osimage if --release
            is not used.

            Use the instance 'configure' command to manage individual cryptexes and
            replace darwin-init configuration.
            """
        )

        @OptionGroup var globalOptions: CLI.globalOptions
        @OptionGroup private var createOptions: CLI.WorkloadCmd.CreateOptions

        func run() async throws {
            var configuration = createOptions.workload
            configuration.skipReleaseRequirementsCheck = createOptions.skipReleaseRequirementsCheck

            CLI.logger.debug("Create VRE from configuration \(configuration.debugDescription, privacy: .public)")

            try CLI.validateRequiredMemoryToCreate(instanceOptions: configuration.instances)

            // VM creation itself is slow and the API is synchronous, so care needs to be
            // taken as it will block the threads, but that's likely not a concern for the
            // CLI use.
            try await withThrowingTaskGroup { group in
                for instance in configuration.instances {
                    group.addTask {
                        try CLI.createVREInstance(
                            instanceOptions: instance,
                            httpService: createOptions.httpService,
                            force: createOptions.force
                        )
                    }
                }
                try await group.waitForAll()
            }

        }
    }
}


struct WorkloadConfiguration: SharedVREInstanceOptions {
    var release: String?
    
    var transparencyLogEnvironment: TransparencyLog.Environment?

    var osImage: String?
    
    var osVariant: String?
    
    var osVariantName: String?
    
    var fusing: String?

    var instances: [InstanceOptions]

    private func resolveConfig() throws -> WorkloadConfiguration {
        var manifest = self

        manifest.instances = manifest.instances.map {
            var updated = $0

            updated.transparencyLogEnvironment = $0.transparencyLogEnvironment ?? self.transparencyLogEnvironment
            updated.osImage = $0.osImage ?? self.osImage
            updated.osVariant = $0.osVariant ?? self.osVariant
            updated.osVariantName = $0.osVariantName ?? self.osVariantName
            if updated.osVariantName == nil, updated.osVariant == nil {
                updated.osVariant = CLI.defaultOSVariant
            }
            updated.release = $0.release ?? self.release
            updated.fusing = $0.fusing ?? self.fusing
            updated.networks = $0.networks ?? [
                VRE.VMConfig.Network(mode: .nat, macAddr: nil),
                VRE.VMConfig.Network(mode: .hostOnly)
            ]
            updated.ncpu = $0.ncpu ?? 4 // the default vCPUs for an inference node
            return updated
        }
        return manifest
    }

    func validate() throws {
        guard release != nil || instances.allSatisfy({ $0.release != nil  }) else {
            throw ValidationError("Either workload release of per-instance releases must be specified.")
        }
    }
}

extension WorkloadConfiguration: CustomDebugStringConvertible {
    var debugDescription: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "INVALID"
    }
}

extension WorkloadConfiguration {
    init(fromFile filePath: String) throws {
        let decoder = JSONDecoder()
        let data = try Data(contentsOf: .init(filePath: filePath))
        let intermediaryConfig = try decoder.decode(WorkloadConfiguration.self, from: data)

        try intermediaryConfig.validate()

        self = try intermediaryConfig.resolveConfig()
    }

    var skipReleaseRequirementsCheck: Bool {
        get {
            instances.first?.skipReleaseRequirementsCheck ?? false
        }
        set {
            for var instance in self.instances {
                instance.skipReleaseRequirementsCheck = newValue
            }
        }
    }
}

extension InstanceOptions {
    enum UnstructuredJSON: Codable, Equatable {
        case bool(Bool)
        case int(Int)
        case string(String)
        case list([Self?])
        case dictionary([String : Self?])

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let boolean = try? container.decode(Bool.self) {
                self = .bool(boolean)
            } else if let number = try? container.decode(Int.self) {
                self = .int(number)
            } else if let string = try? container.decode(String.self) {
                self = .string(string)
            } else if let array = try? container.decode([UnstructuredJSON?].self) {
                self = .list(array)
            } else if let dictionary = try? container.decode([String: UnstructuredJSON?].self) {
                self = .dictionary(dictionary)
            } else {
                throw DecodingError.typeMismatch(Any.self, .init(codingPath: decoder.codingPath, debugDescription: ""))
            }
         }

         public func encode(to encoder: Encoder) throws {
             var container = encoder.singleValueContainer()
             switch self {
             case .bool(let bool): try container.encode(bool)
             case .int(let int): try container.encode(int)
             case .string(let string): try container.encode(string)
             case .list(let list): try container.encode(list)
             case .dictionary(let dictionary): try container.encode(dictionary)
             }
         }

         static func ==(_ lhs: Self, _ rhs: Self) -> Bool {
             switch (lhs, rhs) {
             case (.bool(let v1), .bool(let v2)): return v1 == v2
             case (.int(let int1), .int(let int2)): return int1 == int2
             case (.string(let string1), .string(let string2)): return string1 == string2
             case (.list(let list1), .list(let list2)): return list1 == list2
             case (.dictionary(let dict1), .dictionary(let dict2)): return dict1 == dict2
             default: return false
             }
         }
    }
}
