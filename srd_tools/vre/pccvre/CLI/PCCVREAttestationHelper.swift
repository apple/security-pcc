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

//  Copyright © 2026 Apple, Inc. All rights reserved.
//

import Foundation

/// Wrapper around the cloudattestationv2-built `pccvre-attestation-helper`
/// binary, which carries the OSS-friendly attestation/release parsing and
/// verification surface. Mirrors `PCCVREHelper` for symmetry.
///
/// The wrapper does not decode the helper's output beyond the stable
/// `SubprocessEnvelope` top-level fields; `detail` is captured as a raw JSON
/// string so callers can forward it opaquely or decode it against a
/// per-subcommand shape themselves. See cloudattestationv2
/// `Docs/SubprocessContract.md` for the full contract.
struct PCCVREAttestationHelper {
    static var configuredPath: String?

    let path: String
    let toolsDMGs: [CryptexHelper]

    static func pathInToolsDir(_ toolsDir: URL) -> String {
        toolsDir.path(percentEncoded: false) + "/usr/bin/pccvre-attestation-helper"
    }

    /// A helper bound only to `configuredPath`, or nil. Used by the resolver
    /// as its `primary` candidate; everything else goes through the resolver's
    /// lazy fetch.
    static func configured() -> Self? {
        guard let configuredPath else { return nil }
        return Self(path: configuredPath, toolsDMGs: [])
    }

    static func inToolsDMG(_ toolsDMGPath: String) throws -> Self {
        let toolsDMGs = try VRE.mountPCHostTools(dmgPath: toolsDMGPath)
        guard let toolsDir = toolsDMGs.first?.mountPoint else {
            throw CLIError("Unable to obtain Tools dmg mountpoint")
        }
        let path = pathInToolsDir(toolsDir)
        // Distinguish "DMG mounted but helper binary absent" from mount /
        // codesign failures with a typed error, so `fromLatestHostTools` can
        // stop rather than walk backwards to older DMGs (which won't have it
        // either — the helper is a forward-only addition). rdar://182240821.
        guard Globals.computer.fileSystem.isExecutableFile(atPath: path) else {
            throw PCCVREAttestationHelperError.notFound(path: path)
        }
        try HelperCodeSign.verify(path)
        return Self(path: path, toolsDMGs: toolsDMGs)
    }

    private init(path: String, toolsDMGs: [CryptexHelper]) {
        self.path = path
        self.toolsDMGs = toolsDMGs
    }

    /// Ask the helper to decode raw DER bytes as a ReleaseV2 manifest.
    /// Returns the helper's envelope on success, or `.unrecognized` when the
    /// helper says the bytes aren't a ReleaseV2 (exit 65, errorKind
    /// `wrong-schema`) — callers can then dispatch to a different decoder.
    /// Throws only on infrastructure errors (helper missing, crashed, IO).
    func releaseParse(bytes: Data) throws -> ParseResult {
        let tempFile = try FileManager.spillToTempFile(bytes, prefix: "release-der")
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let result = try invoke(
            arguments: ["release", "parse", tempFile.path(percentEncoded: false), "-f", "json"]
        )

        switch result.exitCode {
        case 0:
            return .parsed(try Envelope(jsonStdout: result.stdout))
        case 65:
            // Contract: exit 65 = wrong-schema, envelope on stdout with
            // errorKind:"wrong-schema". Dispatch elsewhere.
            return .unrecognized
        case 64 where result.stderr.contains("Failed to decode ReleaseV2"):
            // Legacy fallback for helpers predating the exit-65 contract.
            // TODO(rdar://170744332): remove once the PCRT bump carrying
            //   cloudattestationv2#125 has aged out of all hostTools DMGs.
            return .unrecognized
        default:
            throw PCCVREAttestationHelperError.failed(
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }
    }

    /// Ask the helper to re-measure the OS image at `imagePath` and compare
    /// against the published ReleaseV2 DER bytes. Returns the decoded
    /// envelope on success or mismatch (the envelope's `ok` field carries the
    /// verdict). Throws on infrastructure errors. The helper auto-detects
    /// host-vs-VM from the image's EFI partition (`--image-kind auto`), so we
    /// don't pass `--host` here.
    func releaseVerifyImage(
        imagePath: String,
        releaseDER: Data,
        verifyNvidiaDriver: Bool,
        containerImageLayout: String?
    ) throws -> Envelope {
        let derFile = try FileManager.spillToTempFile(releaseDER, prefix: "release-der")
        defer { try? FileManager.default.removeItem(at: derFile) }

        var arguments = [
            "release", "verify-image",
            "--image", imagePath,
            "--release", derFile.path(percentEncoded: false),
            "-f", "json",
        ]
        if verifyNvidiaDriver { arguments.append("--verify-nvidia-driver") }
        if let containerImageLayout { arguments += ["--container-image-layout", containerImageLayout] }

        return try runEnvelope(arguments: arguments)
    }

    enum ParseResult {
        case parsed(Envelope)
        case unrecognized
    }

    /// Run an arbitrary subcommand under `-f json` and decode the resulting
    /// `SubprocessEnvelope`. Per the contract: exit 0 → ok:true envelope on
    /// stdout; exit 1 → ok:false envelope on stdout (domain failure — policy
    /// reject, mismatch); anything else (or exit 1 with no envelope, e.g. an
    /// unhandled throw inside the helper) is an infrastructure failure.
    func runEnvelope(arguments: [String]) throws -> Envelope {
        let result = try invoke(arguments: arguments)
        switch result.exitCode {
        case 0:
            return try Envelope(jsonStdout: result.stdout)
        case 1 where result.stdout.first == "{":
            // Domain failure with envelope. ExecCommand trims stdout, so a
            // leading `{` is a reliable discriminator vs. exit-1-stderr-only.
            return try Envelope(jsonStdout: result.stdout)
        default:
            throw PCCVREAttestationHelperError.failed(
                exitCode: result.exitCode,
                stderr: result.stderr.isEmpty ? result.stdout : result.stderr
            )
        }
    }

    private struct InvocationResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private func invoke(arguments: [String]) throws -> InvocationResult {
        guard Globals.computer.fileSystem.isExecutableFile(atPath: path) else {
            throw PCCVREAttestationHelperError.notFound(path: path)
        }

        let (exitCode, stdout, stderr) = try Globals.computer.processRunner.run(
            command: [path] + arguments,
            environment: nil,
            outputMode: .capture,
            queue: DispatchQueue(label: "\(applicationName).PCCVREAttestationHelper")
        )
        return InvocationResult(exitCode: exitCode, stdout: stdout, stderr: stderr)
    }
}

enum PCCVREAttestationHelperError: Error, CustomStringConvertible {
    case notFound(path: String)
    case failed(exitCode: Int32, stderr: String)
    case malformedEnvelope(String)

    var description: String {
        switch self {
        case .notFound(let path):
            return "pccvre-attestation-helper not found at \(path)"
        case .failed(let exitCode, let stderr):
            return "pccvre-attestation-helper failed with exit code \(exitCode): \(stderr)"
        case .malformedEnvelope(let reason):
            return "pccvre-attestation-helper returned a malformed JSON envelope: \(reason)"
        }
    }

    /// True when the failure indicates the helper *itself* is broken or stale
    /// (binary missing, or argument-level rejection — exit 64 — meaning it
    /// doesn't recognise our flags). Domain failures (exit 1 envelope) and
    /// infrastructure crashes inside the helper return false: re-fetching a
    /// newer helper won't change those outcomes.
    var warrantsNewerHelper: Bool {
        switch self {
        case .notFound: true
        case .failed(64, _): true
        case .failed, .malformedEnvelope: false
        }
    }
}

extension PCCVREAttestationHelper {
    /// Decoded view of CLISupport's `SubprocessEnvelope`. Only the stable
    /// top-level fields are decoded; `detail` is captured as a raw JSON string
    /// so callers can forward it opaquely or decode it against a per-subcommand
    /// shape themselves. See cloudattestationv2 `Docs/SubprocessContract.md`.
    struct Envelope: Sendable {
        let schemaVersion: Int
        let ok: Bool
        let errorKind: String?
        let summary: String
        let digest: String?
        /// Raw JSON of the `detail` payload (re-serialized via JSONSerialization
        /// so it stays a valid standalone JSON document).
        let detail: String

        init(jsonStdout: String) throws {
            guard let data = jsonStdout.data(using: .utf8),
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                throw PCCVREAttestationHelperError.malformedEnvelope("not a JSON object")
            }
            guard let schemaVersion = obj["schemaVersion"] as? Int,
                  let ok = obj["ok"] as? Bool,
                  let summary = obj["summary"] as? String
            else {
                throw PCCVREAttestationHelperError.malformedEnvelope("missing schemaVersion/ok/summary")
            }
            self.schemaVersion = schemaVersion
            self.ok = ok
            self.errorKind = obj["errorKind"] as? String
            self.summary = summary
            self.digest = obj["digest"] as? String
            if let detailObj = obj["detail"],
               let detailData = try? JSONSerialization.data(withJSONObject: detailObj, options: [.sortedKeys, .withoutEscapingSlashes])
            {
                self.detail = String(decoding: detailData, as: UTF8.self)
            } else {
                self.detail = "{}"
            }
        }
    }
}

/// Stateful wrapper that lazily resolves a `PCCVREAttestationHelper`
/// (configured path → cached → fetch latest hostTools from the
/// transparency log) and retries once with a freshly-fetched helper when
/// the resolved one is missing or argument-incompatible. Shared across
/// calls in a single `release list`/`dump`/`download` invocation so the
/// fetch+mount only happens once.
actor PCCVREAttestationHelperResolver {
    /// Cap on how far back the bootstrap walks the transparency log looking
    /// for a hostTools asset. Without it the loop would walk the entire log
    /// once it's mostly v2 (since `reqCount` counts *decoded* releases and
    /// v2 leaves land in `skippedLeaves` when `helper:` is nil).
    private static let bootstrapLookback: Int64 = 10_000

    private let environment: TransparencyLog.Environment
    private var primary: PCCVREAttestationHelper?
    private var latest: PCCVREAttestationHelper?
    private var triedLatest = false
    /// Set on the first helper-resolution failure so subsequent leaves in the
    /// same run degrade quietly instead of re-warning per leaf.
    private var resolutionUnavailable = false

    init(environment: TransparencyLog.Environment) {
        self.environment = environment
        self.primary = PCCVREAttestationHelper.configured()
    }

    /// Resolve a helper and run `body` against it. If `body` throws an error
    /// that suggests the helper itself is stale or missing (`.notFound`, or
    /// exit 64 from an unrecognized flag), fetch the latest hostTools (once)
    /// and retry against that helper. Domain failures (exit 1 envelope) and
    /// in-helper crashes are *not* retried — a fresh helper wouldn't help.
    private func withResolvedHelper<T>(_ body: (PCCVREAttestationHelper) throws -> T) async throws -> T {
        let helper = try await resolve()
        do {
            return try body(helper)
        } catch let error as PCCVREAttestationHelperError where error.warrantsNewerHelper {
            if let fresh = try? await acquireLatest(replacingFailed: helper) {
                return try body(fresh)
            }
            throw error
        }
    }

    /// Decode raw release-leaf bytes via whichever helper we can find.
    ///
    /// This is the *degrading* entry point: if the helper cannot be resolved
    /// at all (no `--pccvre-attestation-helper`, hostTools fetch/mount failed),
    /// a user-visible warning is emitted **once** per resolver and the call
    /// returns `.unrecognized` so `release list`/`dump`/`download` can still
    /// complete with v2 leaves shown as unparsed rather than aborting the
    /// whole command. Contrast `runEnvelope`/`releaseVerifyImage`, which are
    /// invoked for a single explicit target and *do* propagate resolution
    /// failures.
    func releaseParse(bytes: Data) async -> PCCVREAttestationHelper.ParseResult {
        if resolutionUnavailable { return .unrecognized }
        do {
            return try await withResolvedHelper { try $0.releaseParse(bytes: bytes) }
        } catch {
            resolutionUnavailable = true
            let msg = "Unable to show v2 release metadata: pccvre-attestation-helper is unavailable (\(error)). v2 entries will appear without parsed contents."
            CLI.logger.error("\(msg, privacy: .public)")
            fputs("warning: \(msg)\n", stderr)
            return .unrecognized
        }
    }

    /// Explicitly fetch the latest hostTools (if not already done) and retry
    /// `releaseParse` against it. Callers invoke this as a last resort after
    /// both the resolved helper returned `.unrecognized` *and* the legacy v1
    /// decoder rejected the bytes — that combination suggests a future release
    /// schema the bundled helper doesn't know yet.
    ///
    /// Infrastructure failures during escalation (download error, DMG mount
    /// failure, helper crash) are logged and surfaced as `.unrecognized` so
    /// the caller's "not v1 or v2" handling fires; the underlying error is
    /// preserved in os_log for debugging.
    func escalateAndRetry(bytes: Data) async -> PCCVREAttestationHelper.ParseResult {
        if resolutionUnavailable { return .unrecognized }
        let fresh: PCCVREAttestationHelper
        do {
            fresh = try await acquireLatest(replacingFailed: primary ?? latest)
        } catch {
            CLI.logger.error("pccvre-attestation-helper escalation: failed to acquire latest hostTools: \(String(describing: error), privacy: .public)")
            return .unrecognized
        }
        do {
            let result = try fresh.releaseParse(bytes: bytes)
            if case .parsed = result {
                // The fresh helper understands this schema; demote the stale
                // primary so subsequent leaves go straight to `latest` instead
                // of bouncing through primary→.unrecognized→escalate each time.
                self.primary = nil
            }
            return result
        } catch {
            CLI.logger.error("pccvre-attestation-helper escalation: latest helper failed: \(String(describing: error), privacy: .public)")
            return .unrecognized
        }
    }

    /// Resolve a helper and run `release verify-image`. Same retry policy as
    /// `releaseParse`.
    func releaseVerifyImage(
        imagePath: String,
        releaseDER: Data,
        verifyNvidiaDriver: Bool,
        containerImageLayout: String?
    ) async throws -> PCCVREAttestationHelper.Envelope {
        try await withResolvedHelper {
            try $0.releaseVerifyImage(
                imagePath: imagePath,
                releaseDER: releaseDER,
                verifyNvidiaDriver: verifyNvidiaDriver,
                containerImageLayout: containerImageLayout
            )
        }
    }

    /// Generic pass-through that decodes the helper's `SubprocessEnvelope`
    /// JSON, with the standard fetch-latest-then-retry policy.
    func runEnvelope(arguments: [String]) async throws -> PCCVREAttestationHelper.Envelope {
        try await withResolvedHelper { try $0.runEnvelope(arguments: arguments) }
    }

    private func resolve() async throws -> PCCVREAttestationHelper {
        if let primary { return primary }
        if let latest { return latest }
        return try await acquireLatest(replacingFailed: nil)
    }

    private func acquireLatest(replacingFailed failed: PCCVREAttestationHelper?) async throws -> PCCVREAttestationHelper {
        // If we already fetched and it's not the helper that just failed, return it.
        if let latest, failed == nil || latest.path != failed?.path {
            return latest
        }
        if triedLatest {
            throw CLIError("pccvre-attestation-helper: latest hostTools already tried")
        }
        triedLatest = true

        let helper = try await Self.fromLatestHostTools(environment: environment)
        self.latest = helper
        return helper
    }

    /// Find the most recent release in the transparency log that publishes a
    /// hostTools asset, download that asset (if not already cached locally),
    /// mount it, and return a helper pointed at the mounted binary.
    private static func fromLatestHostTools(
        environment: TransparencyLog.Environment
    ) async throws -> PCCVREAttestationHelper {
        CLI.logger.log("pccvre-attestation-helper: resolving from latest hostTools (\(environment.rawValue, privacy: .public))")

        var swlog = try await SWReleases(environment: environment)
        // helper:nil — we only need leaf metadata, not parsed contents.
        // v2 leaves decode as `.v2(nil)` (metadata populated), so reqCount is
        // meaningful again; ask for enough recent releases that at least one
        // carries a hostTools asset, with searchRangeStart as a hard cap.
        try await swlog.fetchReleases(
            helper: nil,
            reqCount: 200,
            includeAll: false,
            searchRangeStart: -bootstrapLookback
        )

        let assetHelper = try AssetHelper(directory: CLIDefaults.assetsDirectory.path)

        // Collect hostTools-bearing leaves across decoded releases + skipped
        // leaves, newest first, deduped by asset URL (many releases reference
        // the same DMG). A single dead URL (asset in metadata but never
        // uploaded → CDN 403) shouldn't take out the resolver, so try each in
        // turn until one downloads + mounts + contains the helper.
        let decoded = swlog.compactMap { rel in
            rel.metadata?.hostToolsAsset().map { (index: rel.index, asset: $0) }
        }
        let skipped = swlog.skippedLeaves.compactMap { leaf in
            (try? SWReleaseMetadata(leaf: leaf))?.hostToolsAsset().map { (index: leaf.index, asset: $0) }
        }
        var seenURLs = Set<String>()
        let candidates = (decoded + skipped)
            .sorted { $0.index > $1.index }
            .filter { seenURLs.insert($0.asset.url).inserted }
            .prefix(5)

        guard !candidates.isEmpty else {
            throw CLIError("No release with a hostTools asset found in the latest \(bootstrapLookback) transparency-log entries")
        }

        var lastError: (any Error)?
        for (relIndex, hostTools) in candidates {
            do {
                guard let url = URL(string: hostTools.url) else {
                    throw CLIError("Release \(relIndex): hostTools asset URL is malformed: \(hostTools.url)")
                }
                // Verify the downloaded DMG against the published digest before
                // mounting and executing the binary inside it.
                let verifier = try SWReleaseMetadata.assetVerifier(hostTools)

                let dmgPath: String
                if let cached = assetHelper.assetPath(url.lastPathComponent),
                   FileManager.isRegularFile(cached),
                   verifier(cached)
                {
                    CLI.logger.log("pccvre-attestation-helper: using cached hostTools \(cached.path, privacy: .public)")
                    dmgPath = cached.path
                } else {
                    fputs("Fetching host tools from release \(relIndex) to decode v2 release entries...\n", stderr)
                    let downloaded = try await assetHelper.downloadAsset(from: url, verifier: verifier)
                    dmgPath = downloaded.path
                }

                return try PCCVREAttestationHelper.inToolsDMG(dmgPath)
            } catch PCCVREAttestationHelperError.notFound {
                // DMG downloaded and mounted fine but doesn't contain the
                // helper binary. It's a forward-only addition to hostTools, so
                // older candidates won't have it either — stop here rather
                // than burn time downloading/mounting them. rdar://182240821.
                throw CLIError("newest available hostTools DMG (release \(relIndex)) does not yet include pccvre-attestation-helper")
            } catch {
                CLI.logger.error("pccvre-attestation-helper: hostTools candidate at release \(relIndex) failed (\(String(describing: error), privacy: .public)); trying next")
                lastError = error
            }
        }

        throw CLIError("No usable hostTools asset among the \(candidates.count) newest candidates: \(lastError.map { String(describing: $0) } ?? "unknown error")")
    }
}
