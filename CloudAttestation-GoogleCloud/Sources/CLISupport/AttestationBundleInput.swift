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
//  AttestationBundleInput.swift
//  CloudAttestationV2
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//

import ArgumentParser
import CloudAttestationV2
import Foundation

/// Resolved input format for an attestation bundle file.
public enum InputFormat: String, Sendable {
    case json
    case binary
    case appleIntelligenceReport = "apple-intelligence-report"
}

/// User-facing `--input-format` argument value. `auto` sniffs the input data
/// and resolves to one of the concrete formats.
public enum AttestationFormat: String, ExpressibleByArgument, Sendable {
    case auto
    case json
    case binary
    case appleIntelligenceReport = "apple-intelligence-report"

    public func resolve(data: Data) -> InputFormat {
        switch self {
        case .json: return .json
        case .binary: return .binary
        case .appleIntelligenceReport: return .appleIntelligenceReport
        case .auto:
            guard data.drop(while: { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }).first == UInt8(ascii: "{") else {
                return .binary
            }
            // Both raw protobuf-JSON bundles and Apple Intelligence Reports are JSON
            // objects. Distinguish by presence of the AIR top-level key so users don't
            // have to pass `--input-format apple-intelligence-report` explicitly.
            if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                object.keys.contains("privateCloudComputeRequests")
            {
                return .appleIntelligenceReport
            }
            return .json
        }
    }
}

/// Errors raised when reading or decoding an attestation bundle from CLI input.
public enum AttestationBundleInputError: Swift.Error, CustomStringConvertible {
    case fileNotFound(path: String)
    case malformedBundle(reason: String)

    public var description: String {
        switch self {
        case .fileNotFound(let path): "File not found: \(path)"
        case .malformedBundle(let reason): "Malformed bundle: \(reason)"
        }
    }
}

/// Reads bytes from `path`, or stdin when `path == "-"`.
public func readInputData(at path: String) throws -> Data {
    if path == "-" {
        return try FileHandle.standardInput.readToEnd() ?? Data()
    }

    guard let fileHandle = FileHandle(forReadingAtPath: path) else {
        throw AttestationBundleInputError.fileNotFound(path: path)
    }
    defer {
        try? fileHandle.close()
    }

    return try fileHandle.readToEnd() ?? Data()
}

/// Decodes an `AttestationBundle` from raw bytes according to the resolved
/// `InputFormat`. For `appleIntelligenceReport`, `requestIndex` and
/// `attestationIndex` select which embedded bundle to decode; if neither is
/// supplied the report is scanned for GCPv1 bundles (Apple Silicon
/// attestations are skipped) and the last one is returned.
public func loadAttestationBundle(
    data: Data,
    format: InputFormat,
    requestIndex: Int? = nil,
    attestationIndex: Int? = nil
) throws -> AttestationBundle {
    guard !data.isEmpty else {
        throw AttestationBundleInputError.malformedBundle(reason: "Empty bundle")
    }

    switch format {
    case .json:
        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw AttestationBundleInputError.malformedBundle(reason: "JSON bundle contains invalid UTF-8")
        }
        return try AttestationBundle(jsonString: jsonString)

    case .binary:
        do {
            return try AttestationBundle(data: data)
        } catch {
            if let decoded = Data(base64Encoded: data) {
                return try AttestationBundle(data: decoded)
            }
            throw AttestationBundleInputError.malformedBundle(reason: error.localizedDescription)
        }

    case .appleIntelligenceReport:
        let report: AppleIntelligenceReport
        do {
            report = try JSONDecoder().decode(AppleIntelligenceReport.self, from: data)
        } catch {
            throw AttestationBundleInputError.malformedBundle(reason: "Failed to decode Apple Intelligence Report: \(error.localizedDescription)")
        }

        if let requestIndex, let attestationIndex {
            guard report.privateCloudComputeRequests.indices.contains(requestIndex) else {
                throw AttestationBundleInputError.malformedBundle(
                    reason: "Request index \(requestIndex) out of range (report has \(report.privateCloudComputeRequests.count) requests)"
                )
            }
            let request = report.privateCloudComputeRequests[requestIndex]
            let nodes = request.nodes ?? []

            guard nodes.indices.contains(attestationIndex) else {
                throw AttestationBundleInputError.malformedBundle(
                    reason: "Attestation index \(attestationIndex) out of range (request has \(nodes.count) nodes)"
                )
            }

            return try decodeAttestationBundle(from: nodes[attestationIndex].attestationBundle)
        }

        // Apple Intelligence Reports interleave Apple silicon attestations with GCPv1
        // attestations. Subcommands like `release` currently only operate on GCPv1 bundles,
        // so we need to filter these.
        let gcpv1Bundles = report.privateCloudComputeRequests
            .flatMap { $0.nodes ?? [] }
            .compactMap { try? decodeAttestationBundle(from: $0.attestationBundle) }
            .filter {
                if case .gcpv1AttestationBundle = $0.proto.attestationBundle { return true }
                return false
            }

        guard let last = gcpv1Bundles.last else {
            throw AttestationBundleInputError.malformedBundle(reason: "No parseable GCPv1 attestation bundle found in Apple Intelligence Report")
        }

        return last
    }
}

private func decodeAttestationBundle(from base64String: String) throws -> AttestationBundle {
    guard !base64String.isEmpty else {
        throw AttestationBundleInputError.malformedBundle(reason: "Empty attestation bundle")
    }
    guard let attestationData = Data(base64Encoded: base64String) else {
        throw AttestationBundleInputError.malformedBundle(reason: "Attestation bundle is not valid base64")
    }
    return try AttestationBundle(data: attestationData)
}

/// Shared `@OptionGroup` for CLI subcommands that take an attestation bundle as
/// input. Encapsulates file-or-stdin selection, the input-format flag, and the
/// Apple-Intelligence-Report request/attestation indices.
public struct BundleInputOptions: ParsableArguments {
    public init() {}

    @Argument(help: "Path to the attestation bundle file, or - for stdin.")
    public var file: String = "-"

    @Option(name: [.long, .short], help: "Input format: auto, json, binary, or apple-intelligence-report.")
    public var inputFormat: AttestationFormat = .auto

    @Option(
        name: [.long, .short],
        help: "Index of the request to use when parsing an Apple Intelligence Report."
    )
    public var requestIndex: Int?

    @Option(
        name: [.long, .short],
        help: "Index of the attestation to use when parsing an Apple Intelligence Report."
    )
    public var attestationIndex: Int?

    public func validate() throws {
        switch inputFormat {
        case .appleIntelligenceReport, .auto:
            if (requestIndex == nil) != (attestationIndex == nil) {
                throw ValidationError(
                    "--request-index and --attestation-index must be supplied together for Apple Intelligence Report input."
                )
            }
        case .json, .binary:
            if requestIndex != nil || attestationIndex != nil {
                throw ValidationError(
                    "--request-index and --attestation-index are only valid for Apple Intelligence Report input."
                )
            }
        }
    }

    public func bundle() throws -> AttestationBundle {
        try bundle(from: readInputData(at: file))
    }

    /// Builds the bundle from already-read input. Use this when the caller has read the input
    /// itself (e.g. to also hash it) so stdin isn't read twice — a second read of a pipe yields
    /// empty data.
    public func bundle(from data: Data) throws -> AttestationBundle {
        let resolvedFormat = inputFormat.resolve(data: data)
        return try loadAttestationBundle(
            data: data,
            format: resolvedFormat,
            requestIndex: requestIndex,
            attestationIndex: attestationIndex
        )
    }
}
