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

//
//  Attestation.swift
//  CloudAttestationV2
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//

import ArgumentParser
import CloudAttestationV2
import Common
import Crypto
import Foundation
import GCPv1
import Metrics
import MetricsTestKit
import PrivateCloudCompute
import SwiftASN1
import SwiftEventLog
import SwiftNVAttestation
import SwiftProtobuf
import SwiftTDX
import SwiftTPM
import X509

/// `attestation` command tree. Both `cloudattestationv2ctl` and
/// `pccvre-attestation-helper` (in PCRT) compose this directly so they share a
/// single implementation of `parse` and `verify`.
public struct Attestation: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "attestation",
        abstract: "Work with attestation bundles.",
        subcommands: [Parse.self, Verify.self, CheckFreshness.self]
    )

    public init() {}

    public struct Parse: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            abstract: "Parse an AttestationBundle from a file and display its contents as JSON."
        )

        public init() {}

        @OptionGroup
        public var inputOptions: BundleInputOptions

        @Flag(name: .long, help: "Print raw JSON output of the attestation bundle.")
        public var debug: Bool = false

        @Option(
            name: [.long, .customShort("f")],
            help: "Output format: text (human-readable dump) or json (SubprocessEnvelope; detail.bundle is the protobuf-JSON of the AttestationBundle)."
        )
        public var outputFormat: OutputOptions.OutputFormat = .text

        public func run() async throws {
            let fileData = try readInputData(at: inputOptions.file)
            let digest = SHA256.hash(data: fileData)

            // Reuse the already-read bytes: reading stdin a second time would yield an empty pipe.
            let bundle: AttestationBundle
            do {
                bundle = try inputOptions.bundle(from: fileData)
            } catch {
                // A malformed bundle under -f json is a structured negative
                // result (envelope on stdout, exit 1) — not an unhandled throw
                // — so subprocess callers can distinguish "this isn't a bundle"
                // from "the helper crashed". See Docs/SubprocessContract.md.
                if outputFormat == .json {
                    try SubprocessEnvelope.failure(.domainFailure, summary: "failed to decode attestation bundle", error: error).print()
                    throw ExitCode(1)
                }
                throw error
            }

            if outputFormat == .json {
                let kind: ParseDetail.BundleKind
                switch bundle.proto.attestationBundle {
                case .gcpv1AttestationBundle: kind = .gcpv1
                case .appleSiliconAttestationBundle: kind = .appleSilicon
                case .testAttestationBundle: kind = .test
                case nil: kind = .unknown
                }
                try SubprocessEnvelope(
                    ok: true,
                    summary: "\(kind.rawValue) attestation bundle (\(fileData.count) bytes)",
                    digest: Data(digest).hexString,
                    detail: ParseDetail(kind: kind, bundle: try bundle.jsonString())
                ).print()
                return
            }

            print("--- Attestation Bundle ---")
            print("  SHA256: \(Data(digest).base64EncodedString())")
            print()

            if debug {
                print(try bundle.jsonString())
            }

            let gcpv1 = bundle.proto.gcpv1AttestationBundle.gcpv1Attestation

            let keyProtectionExtraData = gcpv1.tdxKeyProtection.extraData
            if !keyProtectionExtraData.isEmpty {
                do {
                    let keyClaims = try Keymanager_KeyClaims(serializedBytes: keyProtectionExtraData)
                    print("--- Attested Key ---")
                    print("  KEM Public Key: \(keyClaims.vmKeyClaims.kemPubKey.publicKey.base64EncodedString())")
                    if keyClaims.vmKeyClaims.expirationTime != 0 {
                        let expiry = Date(timeIntervalSince1970: keyClaims.vmKeyClaims.expirationTime)
                        print("  Key Expiry:     \(expiry.formatted(.iso8601))")
                    }
                } catch {
                    print("  Failed to parse KeyClaims: \(error)")
                }
            }

            for (label, vmAttestation) in [("workload", gcpv1.tdxWorkload), ("key-protection", gcpv1.tdxKeyProtection)] {
                let ccel = vmAttestation.quote.tdxCcelQuote
                guard !ccel.tdQuote.isEmpty else {
                    continue
                }

                print()
                print("--- TDX Quote (\(label)) ---")
                print("  Label:     \(vmAttestation.label.hexString)")
                print("  Challenge: \(vmAttestation.challenge.hexString)")
                if !vmAttestation.extraData.isEmpty {
                    print("  ExtraData: \(vmAttestation.extraData.hexString)")
                }

                var buffer = ArraySlice([UInt8](ccel.tdQuote))
                let quote: V4.Quote
                do {
                    quote = try V4.Quote(from: &buffer)
                } catch {
                    print("  Failed to parse TDX quote: \(error)")
                    continue
                }

                print(quote.cliDescription(indent: "  "))

                if let pck = quote.pckCertificate {
                    print()
                    print(pck.cliDescription(indent: "  "))
                }

                if !ccel.ccelBootEventLog.isEmpty {
                    print()
                    print("  CCEL Boot Event Log (\(ccel.ccelBootEventLog.count) bytes):")
                    do {
                        var bootBuffer = ArraySlice([UInt8](ccel.ccelBootEventLog))
                        let eventLog = try TCGEventLog(from: &bootBuffer)
                        print(eventLog.cliDescription(indent: "    "))
                    } catch {
                        print("    Failed to parse TCG event log: \(error)")
                        print("    \(ccel.ccelBootEventLog.hexDump.replacingOccurrences(of: "\n", with: "\n    "))")
                    }
                }

                if !ccel.celLaunchEventLog.isEmpty {
                    print()
                    print("  CEL Launch Event Log (\(ccel.celLaunchEventLog.count) bytes):")
                    do {
                        let eventLog = try CEL(from: ccel.celLaunchEventLog)
                        print(eventLog.cliDescription(indent: "    "))

                        for record in eventLog.records {
                            if case .cos(let cos) = record.content,
                                let cosType = CosEventType(rawValue: cos.cosType),
                                cosType == .gpuDeviceAttestationBinding
                            {
                                printDeviceAttestationReport(Data(cos.eventContent), indent: "    ")
                            }
                        }

                        let cselClaims = try CSELClaims.Generator().generateClaims(for: eventLog)
                        if let envVars = cselClaims.environmentVariables {
                            print()
                            print("    Environment Variables (\(envVars.count)):")
                            for envVar in envVars {
                                print("      \(envVar.name)=\(envVar.value)")
                            }
                        }
                        if let overrideEnvVars = cselClaims.overrideEnvironmentVariables {
                            print()
                            print("    Override Environment Variables (\(overrideEnvVars.count)):")
                            for envVar in overrideEnvVars {
                                print("      \(envVar.name)=\(envVar.value)")
                            }
                        }
                    } catch {
                        print("    Failed to parse as CEL: \(error)")
                        print("    \(ccel.celLaunchEventLog.hexDump.replacingOccurrences(of: "\n", with: "\n    "))")
                    }
                }
            }

            // Host Attestation (bare-metal Titan host)
            if gcpv1.hasHostAttestation {
                let host = gcpv1.hostAttestation
                print()
                print("--- Host Attestation ---")
                print("  Label:     \(String(decoding: host.label, as: UTF8.self))")
                print("  Challenge: \(host.challenge.hexString)")

                do {
                    let tpm = try await TPMClaims.Generator().generateClaims(for: host.tpmQuote)
                    print("  TPM Quote (\(tpm.pcrBank ?? "no SHA-256 quote")):")
                    print("    Verified: \(tpm.verified.map { "\($0)" } ?? "unknown")")
                    if let pcr = tpm.pcr0 { print("    PCR[0]  BMC H-CRTM: \(pcr.hexString)") }
                    if let pcr = tpm.pcr17 { print("    PCR[17] BIOS DRTM:  \(pcr.hexString)") }
                    if let pcr = tpm.pcr19 { print("    PCR[19] launch:     \(pcr.hexString)") }
                    if let pcr = tpm.pcr21 { print("    PCR[21] boot apps:  \(pcr.hexString)") }
                    if let titan = tpm.titanFirmwareDigest { print("    Titan RW FW hash:   \(titan.hexString)") }
                } catch {
                    print("    Failed to parse host TPM quote: \(error)")
                }

                let titanEndorsement = host.tpmQuote.endorsement.titanEndorsement
                if !titanEndorsement.ekCert.isEmpty || !titanEndorsement.diceCertChain.isEmpty {
                    print("  Titan Endorsement: EK cert \(titanEndorsement.ekCert.count) bytes, DICE chain \(titanEndorsement.diceCertChain.count) bytes")
                }

                if !host.auxAttestation.signedNvs.isEmpty {
                    let auxiliary = try await AuxiliaryClaims.Generator().generateClaims(for: host)
                    print("  Auxiliary NV Attestations (\(auxiliary.nvs.count)):")
                    for nv in auxiliary.nvs {
                        let index = nv.index.map { "0x\(String(format: "%08X", $0))" } ?? "unknown"
                        print("    NV \(index): verified=\(nv.verified.map { "\($0)" } ?? "unknown") value=\(nv.value?.hexString ?? "none")")
                    }
                }

                if !host.tpmQuote.pcclientBootEventLog.isEmpty {
                    print()
                    print("  PC Client Boot Event Log (\(host.tpmQuote.pcclientBootEventLog.count) bytes):")
                    do {
                        var bootBuffer = ArraySlice([UInt8](host.tpmQuote.pcclientBootEventLog))
                        let eventLog = try TCGEventLog(from: &bootBuffer)
                        print(eventLog.cliDescription(indent: "    "))

                        let hostClaims = try HostClaims.Generator().generateClaims(for: eventLog)
                        print()
                        print("  Derived Host Measurements:")
                        if let bmc = hostClaims.bmcFirmwareDigest { print("    BMC firmware:     \(bmc.hexString)") }
                        if let bios = hostClaims.biosDigest { print("    BIOS:             \(bios.hexString)") }
                        for uki in hostClaims.bootApplicationDigests ?? [] { print("    Host UKI:         \(uki.hexString)") }
                        if let pcr = hostClaims.replayedPCR17 { print("    replayed PCR[17]: \(pcr.hexString)") }
                        if let pcr = hostClaims.replayedPCR21 { print("    replayed PCR[21]: \(pcr.hexString)") }
                    } catch {
                        print("    Failed to parse boot event log: \(error)")
                    }
                }

                if !host.tpmQuote.celLaunchEventLog.isEmpty {
                    print()
                    print("  CEL Launch Event Log (\(host.tpmQuote.celLaunchEventLog.count) bytes):")
                    do {
                        let eventLog = try CEL(from: host.tpmQuote.celLaunchEventLog)
                        print(eventLog.cliDescription(indent: "    "))

                        let launchClaims = try CSELClaims.Generator(index: .pcr(19)).generateClaims(for: eventLog)
                        if let piid = launchClaims.cpuPIID { print("    CPU PIID: \(piid.hexString)") }
                    } catch {
                        print("    Failed to parse as CEL: \(error)")
                    }
                }
            }

            // Platform Certificates (Apple-issued device identity chain, leaf first)
            let appleChain = bundle.proto.gcpv1AttestationBundle.platformCertificates.appleChain
            if !appleChain.isEmpty {
                print()
                print("--- Platform Certificates ---")
                if let leaf = appleChain.first {
                    print("  Leaf SHA256: \(Data(leaf.digest(using: SHA256.self)).hexString)")
                }
                for (i, der) in appleChain.enumerated() {
                    let label = i == 0 ? "Leaf" : "[\(i)]"
                    do {
                        let cert = try X509.Certificate(derEncoded: [UInt8](der))
                        print("  \(label) Subject: \(cert.subject)")
                        print("  \(label) Issuer:  \(cert.issuer)")
                        print("  \(label) Issued:  \(cert.notValidBefore.formatted(.iso8601)) (expires \(cert.notValidAfter.formatted(.iso8601)))")

                        // Only the leaf carries the manifest that was bound at issuance. Print it
                        // alongside the evidence-computed manifest below so a mismatch between the
                        // two — which policy rejects — is visible from `parse` alone.
                        if i == 0 {
                            if let manifest = GCPv1PlatformCertificate(cert).deviceIdentityManifest {
                                print("  \(label) Device Identity Manifest (bound at issuance):")
                                print(manifest.cliDescription(indent: "    "))
                            } else {
                                print("  \(label) Device Identity Manifest: (extension absent or unparseable)")
                            }
                        }
                    } catch {
                        print("  \(label): \(der.count) bytes (failed to parse: \(error))")
                    }
                }
            }

            // Self-validate the bundle through the canonical GCPv1 pipeline with a noop
            // policy so the release/manifest helpers can read pre-generated claims.
            let interim: Result<Validated.AttestationBundle, any Error>
            do {
                interim = .success(try await GCPv1Validator().validate(bundle: bundle, against: GCPv1Validator.structuralPolicy))
            } catch {
                interim = .failure(error)
            }

            // Device Identity Manifest, computed from the attestation evidence (TDX PCK +
            // GPU leaves + Titan DeviceID). Distinct from the manifest embedded in the
            // platform certificate above; policy compares the two.
            print()
            print("--- Device Identity Manifest (computed from evidence) ---")
            do {
                let manifest = try interim.get().deviceIdentityManifest()
                if let cli = manifest as? any CLIDescribable {
                    print(cli.cliDescription(indent: "  "))
                } else {
                    print("  (\(type(of: manifest)) is not CLIDescribable)")
                }
            } catch {
                print("  Failed to generate: \(error)")
            }

            // Release
            print()
            print("--- Workload Release ---")
            do {
                let release = try interim.get().workloadRelease()
                print(release.cliDescription(indent: "  "))
            } catch {
                print("  Failed to generate: \(error)")
            }

            // Firmware Release
            print()
            print("--- Firmware Release ---")
            do {
                let release = try interim.get().firmwareRelease()
                print(release.cliDescription(indent: "  "))
            } catch {
                print("  Failed to generate: \(error)")
            }

            // Transparency Proofs
            print()
            print("--- Transparency Proofs ---")
            print(bundle.proto.gcpv1AttestationBundle.transparencyProofs.cliDescription(indent: "  "))
        }
    }

    public struct CheckFreshness: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "check-freshness",
            abstract: "Pre-rollout probe of transparency log-head freshness across an Apple Intelligence report.",
            discussion: """
                Probes the certificate-transparency log-head freshness gate that will guard production \
                verification, using the software release proof as a stand-in for the (not-yet-rolled-out) \
                certificate proof. For every node in the report this reads the software transparency log \
                head and measures its age against the current time: freshness holds when the log head is \
                at most `--window-hours` old. The transparency server won't hand out a milestone that is \
                too old even under `preferOldest`, so a recent log head is evidence the attestation was \
                minted recently; a log head older than the window is flagged as stale.

                A safety probe, not the security gate: software proofs are not quote-bound, so trust these log \
                heads only for reports you obtained yourself. Requires an Apple Intelligence report as input.
                """
        )

        public init() {}

        @Argument(help: "Path to an Apple Intelligence report (JSON), or - for stdin.")
        public var file: String = "-"

        @Option(name: .long, help: "Freshness window in hours (default 72).")
        public var windowHours: Double = 72

        public func run() async throws {
            let data = try readInputData(at: file)
            let report: AppleIntelligenceReport
            do {
                report = try JSONDecoder().decode(AppleIntelligenceReport.self, from: data)
            } catch {
                throw ValidationError("check-freshness requires an Apple Intelligence report (JSON): \(error.localizedDescription)")
            }

            let now = Date()
            var evaluated = 0
            var failures = 0

            for (requestIndex, request) in report.privateCloudComputeRequests.enumerated() {
                for node in request.nodes ?? [] {
                    let label = "request \(requestIndex): node \(shortID(node.node))"

                    // Read the node's software transparency log head; nodes whose bundle doesn't decode or
                    // carries no software proof have nothing to probe and are skipped silently.
                    guard let proofs = softwareProofs(node), let logHead = softwareLogHeadTimestamp(proofs) else {
                        continue
                    }
                    evaluated += 1

                    // Now-based freshness: how old is the log head relative to the current time? A log head
                    // in the future (negative age) is trivially fresh. This is the check the certificate gate
                    // will apply once CT proofs ship — a compute node minting against a stale milestone is what
                    // we want to catch.
                    let ageHours = now.timeIntervalSince(logHead) / 3600
                    let detail = "log head \(iso(logHead)), age \(fmt(ageHours))h (window \(fmt(windowHours))h)"
                    if ageHours <= windowHours {
                        print("  PASS  \(label): \(detail)")
                    } else {
                        print("  FAIL  \(label): \(detail) — older than the window by \(fmt(ageHours - windowHours))h; the gate would reject this attestation")
                        failures += 1
                    }
                }
            }

            guard evaluated > 0 else {
                throw ValidationError("No attestation bundles with a software transparency log head found in the report; nothing to check.")
            }

            print("")
            print("Checked \(evaluated) node(s) as of \(iso(now)); \(failures) would fail the freshness gate.")
            if failures > 0 {
                throw ExitCode(1)
            }
        }

        private func fmt(_ value: Double) -> String { String(format: "%.1f", value) }

        private func iso(_ date: Date) -> String {
            date.formatted(.iso8601.year().month().day().dateTimeSeparator(.standard).time(includingFractionalSeconds: true))
        }

        private func shortID(_ id: String?) -> String {
            guard let id, !id.isEmpty else { return "?" }
            return String(id.prefix(12))
        }

        /// Returns the software-transparency proof set for a report node, unwrapping either bundle
        /// variant to the common `ATLogProofs` shape. Apple Silicon proxy/compute nodes carry software
        /// proofs at `AppleSiliconAttestationBundle.transparency_proofs.proofs`; GCPv1 nodes at
        /// `GCPv1AttestationBundle.transparency_proofs.software_transparency_proofs`. Returns an empty
        /// `ATLogProofs` (not nil) when the bundle decodes but the field is absent, so the caller's
        /// "no software log head" branch — not the "no bundle" branch — reports it.
        private func softwareProofs(_ node: AppleIntelligenceReport.Node) -> ATLogProofs? {
            guard let data = Data(base64Encoded: node.attestationBundle),
                let bundle = try? AttestationBundle(data: data)
            else {
                return nil
            }
            switch bundle.proto.attestationBundle {
            case .gcpv1AttestationBundle(let gcp):
                return gcp.transparencyProofs.softwareTransparencyProofs
            case .appleSiliconAttestationBundle(let asBundle):
                return asBundle.transparencyProofs.proofs
            case .testAttestationBundle, .none:
                return nil
            }
        }

        /// Reads a proof set's log-head timestamp by deserializing the signed log head (`SLH`) carried in
        /// its inclusion proof and returning the log-assigned `timestampMs`. Returns `nil` when the proof
        /// carries no SLH, or the log head fails to parse / has a zero timestamp.
        private func softwareLogHeadTimestamp(_ proofs: ATLogProofs) -> Date? {
            let slhObject = proofs.inclusionProof.slh.object
            guard !slhObject.isEmpty,
                let logHead = try? LogHead(serializedBytes: slhObject),
                logHead.timestampMs > 0
            else {
                return nil
            }
            return Date(timeIntervalSince1970: Double(logHead.timestampMs) / 1000)
        }
    }

    public struct Verify: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            abstract: "Verify an attestation bundle against an environment's policy."
        )

        public init() {}

        @OptionGroup
        public var inputOptions: BundleInputOptions

        @Option(
            name: .long,
            help: "Environment whose policy to validate against (currently dev or qa)."
        )
        public var environment: Environment = .dev

        @Flag(
            name: .long,
            help: "Fetch fresh proxy proofs from the live transparency log for the chosen environment, transitively binding the bundle's witnessed proofs to the canonical tree."
        )
        public var verifyTransparencyProofs: Bool = false

        @Option(
            name: .long,
            help:
                "Path to a V1 AppleSiliconAttestationBundle (raw protobuf or base64) whose transparency proofs are used as proxy proofs for transitive verification of this V2 bundle. Mutually exclusive with --verify-transparency-proofs."
        )
        public var proxyProofsFrom: String?

        @Flag(
            name: .long,
            help: "Print every swift-metrics counter, meter, recorder, and timer the library emitted during this verification to stderr."
        )
        public var printMetrics: Bool = false

        @Option(
            name: [.long, .customShort("f")],
            help: "Output format: text (human-readable summary) or json (SubprocessEnvelope)."
        )
        public var outputFormat: OutputOptions.OutputFormat = .text

        public func validate() throws {
            if proxyProofsFrom != nil && verifyTransparencyProofs {
                throw ValidationError("--proxy-proofs-from and --verify-transparency-proofs are mutually exclusive.")
            }
        }

        public func run() async throws {
            // Install an in-memory metrics backend before any library counter is
            // touched. swift-metrics enforces a one-shot bootstrap, but this leaf
            // runs at most once per process invocation, so we're safe.
            let metricsSink: TestMetrics? = printMetrics ? bootstrapMetrics() : nil
            defer {
                if let metricsSink {
                    MetricsDump.write(metricsSink, to: FileHandle.standardError)
                }
            }

            let validated: Validated.AttestationBundle
            do {
                let bundle = try inputOptions.bundle()
                let validator = UniversalValidator(transparencyVerifier: try await makeTransitiveVerifier(for: bundle))
                let policy = UniversalValidator.policy(for: environment)
                validated = try await validator.validate(bundle: bundle, against: policy)
            } catch {
                // Bundle-decode failure, transparency-proof setup failure, or
                // policy rejection under -f json is a structured negative
                // result (envelope on stdout, exit 1) so subprocess callers
                // see {ok:false, errorKind:"domain-failure"} rather than a
                // bare stderr-only throw. See Docs/SubprocessContract.md.
                if outputFormat == .json {
                    try SubprocessEnvelope.failure(
                        .domainFailure,
                        summary: "verification failed against \(environment) policy",
                        error: error
                    ).print()
                    throw ExitCode(1)
                }
                throw error
            }

            let transparencyMode: VerifyDetail.TransparencyMode =
                if proxyProofsFrom != nil { .v1ProxyBundle } else if verifyTransparencyProofs { .liveLog } else { .local }

            if outputFormat == .json {
                try SubprocessEnvelope(
                    ok: true,
                    summary: "verified against \(environment) policy; key valid until \(validated.expiration.formatted(.iso8601))",
                    detail: VerifyDetail(
                        environment: "\(environment)",
                        transparencyMode: transparencyMode,
                        publicKey: .init(validated.publicKey),
                        expiration: validated.expiration
                    )
                ).print()
                return
            }

            print("--- Verification OK ---")
            print("  Environment: \(environment)")
            if let proxyProofsFrom {
                print("  Transparency: bundle proofs transitively bound to V1 proxy bundle at \(proxyProofsFrom) (live \(environment) log consulted to bridge revisions)")
            } else if verifyTransparencyProofs {
                print("  Transparency: bundle proofs transitively bound to live \(environment) tree")
            } else {
                print("  Transparency: bundle proofs verified locally (use --verify-transparency-proofs to bind to live tree)")
            }
            print("  Public Key:  \(validated.publicKey)")
            print("  Expiration:  \(validated.expiration.formatted(.iso8601))")
        }

        private func makeTransitiveVerifier(for bundle: AttestationBundle) async throws -> PCCTransparencyLog.TransitiveVerifier {
            guard case .gcpv1AttestationBundle(let gcpBundle) = bundle.proto.attestationBundle else {
                throw ValidationError("Transparency verification is only supported for GCPv1 attestation bundles.")
            }

            if let proxyProofsFrom {
                // Use the proofs witnessed in a separate, presumed-trustworthy V1 bundle as the proxy.
                // TransitiveVerifier will bridge revisions via the live log when the V1 bundle predates
                // the V2 compute-node revision; when they share a revision the merkle math runs locally.
                let v1 = try Self.loadV1Bundle(at: proxyProofsFrom)

                return PCCTransparencyLog.TransitiveVerifier(
                    certificateProofs: v1.certificateTransparencyProofs.proofs,
                    softwareProofs: v1.transparencyProofs.proofs,
                    firmwareProofs: v1.transparencyProofs.proofs,
                    transparencyProver: PCCTransparencyLog(environment: environment)
                )
            }

            if verifyTransparencyProofs {
                // Fetch fresh proxy proofs from the live transparency log so the verifier can
                // confirm the bundle's witnessed proofs sit in the right tree (matching treeID)
                // and at a revision consistent with the canonical log head.
                guard let leafCert = gcpBundle.platformCertificates.appleChain.first else {
                    throw ValidationError("Bundle has no platform certificate chain; cannot verify certificate transparency.")
                }
                let certDigest = Data(leafCert.digest(using: SHA256.self))
                let claims = try await UniversalClaimsGenerator().generateClaims(for: bundle)
                let workloadRelease = try ReleaseV2.workload(bundle: bundle, claims: claims)
                let softwareReleaseDigest = Data(try workloadRelease.digest(using: SHA256.self))
                let firmwareRelease = try ReleaseV2.firmware(bundle: bundle, claims: claims)
                let firmwareReleaseDigest = Data(try firmwareRelease.digest(using: SHA256.self))

                let transparencyProver = PCCTransparencyLog(environment: environment)

                let certificateProofs = try await transparencyProver.proveInclusion(
                    of: certDigest,
                    at: nil,
                    coveringAll: .serverNode,
                    preferOldest: true
                )
                let softwareProofs = try await transparencyProver.proveInclusion(
                    of: softwareReleaseDigest,
                    at: nil,
                    coveringAll: .release,
                    preferOldest: true
                )
                let firmwareProofs = try await transparencyProver.proveInclusion(
                    of: firmwareReleaseDigest,
                    at: nil,
                    coveringAll: .release,
                    preferOldest: true
                )

                return PCCTransparencyLog.TransitiveVerifier(
                    certificateProofs: certificateProofs,
                    softwareProofs: softwareProofs,
                    firmwareProofs: firmwareProofs,
                    transparencyProver: transparencyProver
                )
            }

            // Use the proofs that were witnessed at attestation time as both the compute-node
            // proof and the proxy. Since proxy and compute share a revision, the verifier's
            // consistency/freshness branches collapse to just running the merkle inclusion math
            // on each proof — no live transparency-log access needed.
            return PCCTransparencyLog.TransitiveVerifier(
                certificateProofs: gcpBundle.transparencyProofs.certificateTransparencyProofs,
                softwareProofs: gcpBundle.transparencyProofs.softwareTransparencyProofs,
                firmwareProofs: gcpBundle.transparencyProofs.firmwareTransparencyProofs,
                transparencyProver: NopTransparencyLog()
            )
        }

        /// Bootstraps the swift-metrics system with an in-memory ``TestMetrics``
        /// backend so the counters the library emits during verification can be
        /// dumped at exit. Idempotent across this process: only ever called once
        /// because `--print-metrics` is the only caller and the one-shot
        /// `MetricsSystem.bootstrap` precondition is fine here.
        private func bootstrapMetrics() -> TestMetrics {
            let factory = TestMetrics()
            MetricsSystem.bootstrap(factory)
            return factory
        }

        /// Loads a `PrivateCloudCompute_AppleSiliconAttestationBundle` from disk (or stdin when
        /// `path == "-"`). Accepts raw protobuf or base64-encoded protobuf, mirroring how
        /// `loadAttestationBundle(data:format:…)` handles the V2 wire format.
        private static func loadV1Bundle(at path: String) throws -> PrivateCloudCompute_AppleSiliconAttestationBundle {
            let data = try readInputData(at: path)
            guard !data.isEmpty else {
                throw ValidationError("Proxy V1 bundle at \(path) is empty.")
            }
            do {
                return try PrivateCloudCompute_AppleSiliconAttestationBundle(serializedBytes: data)
            } catch {
                if let decoded = Data(base64Encoded: data),
                    let bundle = try? PrivateCloudCompute_AppleSiliconAttestationBundle(serializedBytes: decoded)
                {
                    return bundle
                }
                throw ValidationError("Proxy V1 bundle at \(path) is not a valid AppleSiliconAttestationBundle: \(error.localizedDescription)")
            }
        }
    }
}

private func printDeviceAttestationReport(_ data: Data, indent: String) {
    do {
        let report = try ConfidentialSpace_NvidiaAttestationReport(serializedBytes: data)
        print()
        print("\(indent)GPU Device Attestation Report:")

        var gpuInfos: [ConfidentialSpace_GpuInfo] = []
        switch report.ccFeature {
        case .spt(let spt):
            print("\(indent)  Mode: Single GPU Passthrough (SPT)")
            if spt.hasGpuQuote {
                gpuInfos.append(spt.gpuQuote)
            }
        case .mpt(let mpt):
            print("\(indent)  Mode: Multi-GPU Secure Passthrough (MPT)")
            gpuInfos = mpt.gpuQuotes
        case nil:
            print("\(indent)  Mode: unknown")
        }

        for (i, gpu) in gpuInfos.enumerated() {
            print()
            let prefix = gpuInfos.count > 1 ? "GPU[\(i)] " : ""
            print("\(indent)  \(prefix)UUID: \(gpu.uuid)")
            print("\(indent)  \(prefix)Driver: \(gpu.driverVersion)")
            print("\(indent)  \(prefix)VBIOS: \(gpu.vbiosVersion)")
            print("\(indent)  \(prefix)Architecture: \(gpu.gpuArchitectureType)")
            if !gpu.attestationCertificateChain.isEmpty {
                do {
                    let pemString = String(decoding: gpu.attestationCertificateChain, as: UTF8.self)
                    let pems = try PEMDocument.parseMultiple(pemString: pemString)
                    print("\(indent)  \(prefix)Cert chain:")
                    for (j, pem) in pems.enumerated() {
                        let cert = try X509.Certificate(pemDocument: pem)
                        let certLabel = pems.count > 1 ? "[\(j)] " : ""
                        print("\(indent)    \(certLabel)Subject: \(cert.subject)")
                    }
                } catch {
                    print("\(indent)  \(prefix)Cert chain: \(gpu.attestationCertificateChain.count) bytes (failed to parse: \(error))")
                }
            }
            if !gpu.attestationReport.isEmpty {
                do {
                    let spdmReport = try Blackwell.AttestationReport(from: gpu.attestationReport)
                    print(spdmReport.cliDescription(indent: "\(indent)  \(prefix)"))
                } catch {
                    print("\(indent)  \(prefix)Attestation report: \(gpu.attestationReport.count) bytes (failed to parse: \(error))")
                }
            }
        }
    } catch {
        print("\(indent)Failed to parse NvidiaAttestationReport: \(error)")
    }
}

// MARK: - SubprocessEnvelope detail payloads

extension Attestation.Parse {
    /// `SubprocessEnvelope.detail` for `attestation parse -f json`.
    public struct ParseDetail: Codable, Sendable {
        public enum BundleKind: String, Codable, Sendable {
            case gcpv1
            case appleSilicon
            case test
            case unknown
        }

        public let kind: BundleKind
        /// Protobuf-JSON of the AttestationBundle envelope.
        public let bundle: String

        public init(kind: BundleKind, bundle: String) {
            self.kind = kind
            self.bundle = bundle
        }
    }
}

extension Attestation.Verify {
    /// `SubprocessEnvelope.detail` for `attestation verify -f json`.
    public struct VerifyDetail: Codable, Sendable {
        public enum TransparencyMode: String, Codable, Sendable {
            case local
            case liveLog = "live-log"
            case v1ProxyBundle = "v1-proxy-bundle"
        }

        public let environment: String
        public let transparencyMode: TransparencyMode
        public let publicKey: PublicKey
        public let expiration: Date

        public init(environment: String, transparencyMode: TransparencyMode, publicKey: PublicKey, expiration: Date) {
            self.environment = environment
            self.transparencyMode = transparencyMode
            self.publicKey = publicKey
            self.expiration = expiration
        }

        /// Explicit, stable serialization of the validated public key. Avoids
        /// depending on `PublicKeyContainer`'s `description` (which would be
        /// the default enum debug-print and could drift for display reasons).
        public struct PublicKey: Codable, Sendable {
            public enum Algorithm: String, Codable, Sendable {
                case curve25519
            }

            public let algorithm: Algorithm
            /// Base64-encoded raw key bytes.
            public let data: String

            public init(_ key: PublicKeyContainer) {
                switch key {
                case .curve25519(let bytes):
                    self.algorithm = .curve25519
                    self.data = bytes.base64EncodedString()
                }
            }
        }
    }
}
