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

// swift-tools-version: 6.0

import Foundation
import PackageDescription

func computeBuildVersion() -> String {
    let env = ProcessInfo.processInfo.environment

    if env["RC_XBS"] != nil || env["RC_BUILDIT"] != nil {
        let xbsVersion = env["RC_ProjectSourceVersion"].flatMap { $0.isEmpty ? nil : $0 } ?? "0"
        return "EventHorizon-\(xbsVersion)"
    }

    if let gitTag = env["GIT_TAG"], gitTag.hasPrefix("EventHorizon-") {
        return gitTag
    }

    if let rioBuild = env["RIO_BUILD_NUMBER"], !rioBuild.isEmpty {
        let commit = env["GIT_COMMIT_SHORT"] ?? String((env["GIT_COMMIT"] ?? "unknown").prefix(12))
        var group = "rio"
        if let specID = env["PIPELINE_SPEC_ID"], let projectID = env["PROJECT_ID"] {
            let stripped = specID.dropFirst(projectID.count + 1)
            if let branchDash = stripped.range(of: "-rel-") ?? stripped.range(of: "-main") {
                group = String(stripped[stripped.startIndex..<branchDash.lowerBound])
            }
        }
        return "\(group)-\(rioBuild)-\(commit)"
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["describe", "--tags", "--match", "EventHorizon-*", "--abbrev=12"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus == 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let version = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !version.isEmpty {
                return version
            }
        }
    } catch {}

    return "unknown"
}

let buildVersion = computeBuildVersion()
var swiftSettings: [PackageDescription.SwiftSetting] = [
    .enableUpcomingFeature("MemberImportVisibility")
]
var productTargets = ["EventHorizon"]
var eventHorizonDeps: [Target.Dependency] = [.product(name: "SwiftOPA", package: "swift-opa"), "CBuildVersion"]
var eventHorizonTestDeps: [Target.Dependency] = ["EventHorizon", .product(name: "SwiftOPA", package: "swift-opa")]
var eventHorizonCMacTarget: [Target] = []
var linkerSettings: [PackageDescription.LinkerSetting] = []
var packageDependencies: [Package.Dependency] = [.package(path: "../swift-opa")]
var platformDependentTargets: [Target] = []
var platformDependentProducts: [Product] = []
let packageRoot = ProcessInfo.processInfo.environment["EH_PACKAGE_ROOT"] ?? "."

#if !os(Linux)
linkerSettings.append(.linkedLibrary("EndpointSecurity"))
linkerSettings.append(.linkedLibrary("bsm"))

#if canImport(ArgumentParserInternal)
let systemlibwrappers = ["cryptex", "proc"]
#else
let isXBS = ProcessInfo.processInfo.environment["RC_XBS"] != nil || ProcessInfo.processInfo.environment["RC_LUXON"] != nil || ProcessInfo.processInfo.environment["RC_ProjectName"] != nil
let isXcode = ProcessInfo.processInfo.environment["__CFBundleIdentifier"] == "com.apple.dt.Xcode"
let isInternalSDK = ProcessInfo.processInfo.environment["EH_INTERNAL_SDK"] != nil
let systemlibwrappers = (isXBS || isXcode || isInternalSDK) ? ["cryptex", "proc"] : ["proc"]
if !isXBS {
    packageDependencies.append(.package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"))
    eventHorizonDeps.append(.product(name: "ArgumentParser", package: "swift-argument-parser"))
    eventHorizonTestDeps.append(.product(name: "ArgumentParser", package: "swift-argument-parser"))
}
#endif
systemlibwrappers.forEach {
    eventHorizonDeps.append(.target(name: "Clib\($0)"))
    eventHorizonTestDeps.append(.target(name: "Clib\($0)"))
    platformDependentTargets.append(.systemLibrary(name: "Clib\($0)", path: "Sources/Clib\($0)" ))
}
#else
packageDependencies.append(.package(url: "https://github.com/apple/swift-log", from: "1.12.0"))
eventHorizonDeps.append(.product(name: "Logging", package: "swift-log"))
packageDependencies.append(.package(url: "https://github.com/apple/swift-crypto.git", from: "4.4.0"))
eventHorizonDeps.append(.product(name: "Crypto", package: "swift-crypto"))
packageDependencies.append(.package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"))
eventHorizonDeps.append(.product(name: "ArgumentParser", package: "swift-argument-parser"))
packageDependencies.append(.package(url: "https://github.com/apple/swift-metrics.git", from: "2.10.0"))
eventHorizonDeps.append(.product(name: "Metrics", package: "swift-metrics"))
packageDependencies.append(.package(url: "https://github.com/apple/swift-distributed-tracing.git", from: "1.4.1"))
eventHorizonDeps.append(.product(name: "Tracing", package: "swift-distributed-tracing"))
packageDependencies.append(.package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.11.0"))
eventHorizonDeps.append(.product(name: "ServiceLifecycle", package: "swift-service-lifecycle"))
packageDependencies.append(.package(url: "https://github.com/swift-server/swift-prometheus.git", from: "2.0.0"))
eventHorizonDeps.append(.product(name: "Prometheus", package: "swift-prometheus"))
packageDependencies.append(.package(url: "https://github.com/swift-otel/swift-otel.git", from: "1.0.5"))
eventHorizonDeps.append(.product(name: "OTel", package: "swift-otel"))
eventHorizonDeps.append("Cehprobe")
swiftSettings.append(.unsafeFlags(["-I", "\(packageRoot)/Sources/Cehprobe"]))
let muslDepsPath = ProcessInfo.processInfo.environment["EH_MUSL_DEPS"]
if let muslDepsPath {
    linkerSettings.append(.unsafeFlags(["-L", muslDepsPath + "/lib"]))
    linkerSettings.append(.unsafeFlags(["-L", "\(packageRoot)/Sources/Cehprobe"]))
    linkerSettings.append(.linkedLibrary("ehprobe"))
    linkerSettings.append(.linkedLibrary("bpf"))
    linkerSettings.append(.linkedLibrary("elf"))
    linkerSettings.append(.linkedLibrary("z"))
} else {
    linkerSettings.append(.unsafeFlags(["-L", "\(packageRoot)/Sources/Cehprobe"]))
    linkerSettings.append(.linkedLibrary("ehprobe"))
    linkerSettings.append(.linkedLibrary("bpf"))
    linkerSettings.append(.linkedLibrary("z"))
}
platformDependentTargets.append(.target(name: "Cehprobe"))
platformDependentTargets.append(.target(
    name: "Czlib",
    path: "Sources/Czlib",
    publicHeadersPath: "include",
    linkerSettings: [.linkedLibrary("z")]
))
eventHorizonDeps.append(.target(name: "Czlib"))
#endif
let package = Package(
    name: "EventHorizon",
    platforms: [
        .macOS("15.4.internal"), .iOS("18.0.internal")
    ],
    products: [
        .library(name: "EventHorizon", targets: productTargets),
        .executable(name: "lsecuritymonitorlited", targets: ["lsecuritymonitorlited"])
    ] + platformDependentProducts,
    dependencies: packageDependencies,
    targets: [
        .target(
            name: "CBuildVersion",
            cSettings: [
                .define("EH_BUILD_VERSION", to: "\"\(buildVersion)\"")
            ]
        ),
        .target(
            name: "EventHorizon",
            dependencies: eventHorizonDeps,
            swiftSettings: swiftSettings,
            linkerSettings: linkerSettings
        ),
        .testTarget(
            name: "EventHorizonTests",
            dependencies: eventHorizonTestDeps,
            swiftSettings: swiftSettings,
            linkerSettings: linkerSettings
        ),
        .executableTarget(
            name: "lsecuritymonitorlited",
            dependencies: [
                "EventHorizon"
            ] + eventHorizonDeps,
            swiftSettings: swiftSettings,
            linkerSettings: linkerSettings
        )

    ] + platformDependentTargets
)
