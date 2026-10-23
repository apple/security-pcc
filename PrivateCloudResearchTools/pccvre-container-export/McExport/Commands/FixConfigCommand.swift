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

import ArgumentParser
import Containerization
import ContainerizationOCI
import Foundation

struct FixConfigCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fix-config",
        abstract: "Restore EXPOSE / VOLUME metadata dropped by apple/container build.",
        discussion: """
            fix-config restores .config.ExposedPorts and .config.Volumes on a
            megacontainer that lost them going through `container build`. It
            reads the correct values from --from, then applies them to the
            patched image via a generated Dockerfile fed to `container build`.

            All three references (--from, <patched-ref>, --output) must use
            the apple-container: prefix.
            """
    )

    @OptionGroup var global: GlobalOptions

    @Option(
        name: .long,
        help: "Clean megacontainer providing the correct ExposedPorts / Volumes."
    )
    var from: String

    @Argument(help: "Patched megacontainer whose config is missing the fields.")
    var patchedRef: String

    @Option(
        name: [.customShort("o"), .long],
        help: "Destination reference for the fixed image."
    )
    var output: String

    func run() async throws {
        // Enforce apple-container: on all three refs.
        try validateAppleContainerRef(from, label: "--from")
        try validateAppleContainerRef(patchedRef, label: "<patched-ref>")
        try validateAppleContainerRef(output, label: "--output")

        let cleanBare = stripAppleContainerPrefix(from)
        let patchedBare = stripAppleContainerPrefix(patchedRef)
        let outputBare = stripAppleContainerPrefix(output)

        // Read ExposedPorts + Volumes from the clean image.
        stderr("reading ExposedPorts and Volumes from \(from)")
        let store = try AppleContainerStore.open()
        let cleanImage: Containerization.Image
        do {
            cleanImage = try await store.get(reference: cleanBare, pull: false)
        } catch {
            throw McExportError("clean image \"\(cleanBare)\" not found in local store (\(error))")
        }
        let platform = Platform(arch: global.arch, os: global.os)
        let rawConfigBytes = try await readRawOuterConfig(image: cleanImage, platform: platform)
        let cfg = try decodeOuterConfig(rawConfigBytes)

        let ports = sortedPorts(cfg.config?.ExposedPorts ?? [:])
        let volumes = (cfg.config?.Volumes ?? [:]).keys.sorted()
        if ports.isEmpty && volumes.isEmpty {
            throw McExportError(
                "clean image \"\(cleanBare)\" has no ExposedPorts and no Volumes to restore " +
                "— is --from pointing at the right image?"
            )
        }
        stderr("found \(ports.count) exposed port(s), \(volumes.count) volume(s) to restore")

        // Generate the Dockerfile and shell out to `container build`.
        let tmpDir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: tmpDir)
        }

        let dockerfile = try renderDockerfile(
            fromRef: patchedBare,
            fromLabel: from,
            ports: ports,
            volumes: volumes
        )
        let dockerfileURL = tmpDir.appendingPathComponent("Dockerfile")
        try dockerfile.write(to: dockerfileURL, atomically: true, encoding: .utf8)

        stderr("building \(outputBare) (via container build)...")
        try runContainerBuild(
            contextDir: tmpDir,
            dockerfile: dockerfileURL,
            tag: outputBare,
            platform: "\(global.os)/\(global.arch)"
        )

        stderr("done: \(output)")
        if !ports.isEmpty {
            stderr("  restored ports:   \(ports.joined(separator: ", "))")
        }
        if !volumes.isEmpty {
            stderr("  restored volumes: \(volumes.joined(separator: ", "))")
        }
    }

    // MARK: Helpers

    private func validateAppleContainerRef(_ ref: String, label: String) throws {
        guard isAppleContainerRef(ref) else {
            throw ValidationError(
                "\(label) must use apple-container: prefix (got \"\(ref)\"); " +
                "fix-config is scoped to apple/container"
            )
        }
    }

    /// Sort ports numerically. "4442/tcp" and "8080/tcp" → in port order.
    private func sortedPorts(_ set: [String: OuterImageConfig.EmptyValue]) -> [String] {
        set.keys.sorted { a, b in
            let portA = Int(a.split(separator: "/").first ?? "0") ?? 0
            let portB = Int(b.split(separator: "/").first ?? "0") ?? 0
            return portA < portB
        }
    }

    private func renderDockerfile(
        fromRef: String,
        fromLabel: String,
        ports: [String],
        volumes: [String]
    ) throws -> String {
        // Every value below lands on its own Dockerfile line. A newline in
        // any of them would terminate that line early and turn the rest
        // into additional instructions. The refs come from argv, but the
        // port keys are read out of the source image's config, so they get
        // the same treatment.
        try requireSingleLine(fromLabel, label: "--from")
        try requireSingleLine(fromRef, label: "<patched-ref>")
        for p in ports {
            try requireSingleLine(p, label: "exposed port")
        }

        var b = ""
        b += "# Generated by `mcexport fix-config`\n"
        b += "# Restores ExposedPorts and Volumes from \(fromLabel)\n"
        b += "FROM \(fromRef)\n\n"

        for p in ports {
            b += "EXPOSE \(p)\n"
        }
        if !ports.isEmpty && !volumes.isEmpty {
            b += "\n"
        }
        if !volumes.isEmpty {
            // Use JSON serialization for the volume array so paths
            // containing quotes or backslashes get escaped correctly.
            // (Values from the source image's config, so untrusted in
            // principle — cheap to be safe.)
            let jsonArray = (try? JSONSerialization.data(withJSONObject: volumes))
                .flatMap { String(data: $0, encoding: .utf8) }
                ?? "[]"
            b += "VOLUME \(jsonArray)\n"
        }
        return b
    }

    private func makeTempDir() throws -> URL {
        try makeMcexportTempDir(prefix: "fix-config")
    }

    /// Shells out to `container build`, streaming its stdout+stderr
    /// through to the user's terminal so build progress is visible.
    private func runContainerBuild(
        contextDir: URL,
        dockerfile: URL,
        tag: String,
        platform: String
    ) throws {
        // Find `container` in PATH. Foundation.Process.launchPath expects
        // an absolute path — resolve via `which` semantically.
        let bin = try locateContainerBinary()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = [
            "build",
            "--platform", platform,
            "-t", tag,
            "--file", dockerfile.path,
            contextDir.path,
        ]
        // Stream through — no piping, no capture. User sees the build.
        proc.standardOutput = FileHandle.standardError
        proc.standardError = FileHandle.standardError
        try proc.run()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            throw McExportError(
                "container build failed (exit status \(proc.terminationStatus))"
            )
        }
    }

    /// Resolve the `container` binary. Honors $CONTAINER_BIN like the Go
    /// version. Errors clearly if not on PATH.
    private func locateContainerBinary() throws -> String {
        if let override = ProcessInfo.processInfo.environment["CONTAINER_BIN"],
           !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override)
        {
            return override
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/container"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        throw McExportError(
            "\"container\" not found in PATH — install apple/container or set CONTAINER_BIN"
        )
    }

    // stderr() lives in McExportCore.CLIHelpers.
}
