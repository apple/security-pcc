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
//  SubprocessEnvelope.swift
//  CloudAttestationV2
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//

import Common
import Foundation

/// Stable JSON envelope emitted by CLISupport subcommands under `--json` (or
/// `-f json`). External callers — `pccvre` in srd_tools being the canonical one
/// — invoke `pccvre-attestation-helper` as a subprocess and decode this
/// envelope without carrying CLISupport's per-command schema.
///
/// **Stability contract:** `ok`, `schemaVersion`, `summary`, and `digest` are
/// stable across releases. `detail` is versioned by `schemaVersion` and may
/// grow additively within a major version. See `Docs/SubprocessContract.md`.
public struct SubprocessEnvelope<Detail: Encodable>: Encodable {
    /// Always `1` for now. Bumped when the shape of `detail` changes
    /// incompatibly for a given subcommand.
    public let schemaVersion: Int

    /// `true` when the subcommand completed successfully (parse succeeded,
    /// verification passed). `false` for negative results that are still
    /// structured outputs (e.g. `release verify-image` mismatch).
    public let ok: Bool

    /// Populated only when `ok == false`. Classifies the failure so callers
    /// can dispatch without parsing `summary` or stderr. See
    /// `Docs/SubprocessContract.md` for the exit code each kind maps to.
    public let errorKind: SubprocessErrorKind?

    /// One-line human-readable description suitable for table/list display.
    /// Consumers should not parse this string — use `detail` for structured
    /// access.
    public let summary: String

    /// Lowercase hex SHA-256 of the primary artifact, when the subcommand has
    /// one (the input bundle for `attestation parse`; the release for
    /// `release parse`/`attestation`/`verify-image`). Nil otherwise.
    public let digest: String?

    /// Subcommand-specific structured payload. Opaque to envelope-only
    /// consumers; the concrete shape per subcommand is documented in
    /// `Docs/SubprocessContract.md`.
    public let detail: Detail

    public init(
        ok: Bool,
        errorKind: SubprocessErrorKind? = nil,
        summary: String,
        digest: String? = nil,
        detail: Detail,
        schemaVersion: Int = 1
    ) {
        self.schemaVersion = schemaVersion
        self.ok = ok
        self.errorKind = errorKind
        self.summary = summary
        self.digest = digest
        self.detail = detail
    }

    /// Encode and print this envelope to stdout, pretty-printed with sorted
    /// keys and unescaped slashes. Dates are encoded as ISO-8601; `Data` is
    /// encoded as lowercase hex (so DER types like `ReleaseV2` can be used
    /// directly in `detail` without a JSON-mirror struct).
    public func print() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        encoder.dataEncodingStrategy = .custom { data, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(data.hexString)
        }
        let data = try encoder.encode(self)
        Swift.print(String(decoding: data, as: UTF8.self))
    }
}

/// Stable classification of `ok: false` envelopes. Additive — callers must
/// tolerate unknown future values.
public enum SubprocessErrorKind: String, Encodable, Sendable {
    /// Input bytes are well-formed but not the schema this subcommand
    /// handles (e.g. `release parse` given non-DER bytes). Caller should
    /// dispatch to a different decoder. Exit code 65.
    case wrongSchema = "wrong-schema"
    /// Subcommand ran to completion but the domain check failed
    /// (`attestation verify` policy rejection, `release verify-image`
    /// mismatch). Exit code 1.
    case domainFailure = "domain-failure"
}

/// `detail` payload for `ok: false` envelopes that have no structured
/// negative report of their own — just the error description. Contrast
/// `release verify-image`, which emits its full `VerifyImageReport` on
/// mismatch.
public struct SubprocessFailureDetail: Encodable, Sendable {
    public let error: String
    public init(error: String) { self.error = error }
}

extension SubprocessEnvelope where Detail == SubprocessFailureDetail {
    /// Convenience for emitting a failure envelope.
    public static func failure(_ kind: SubprocessErrorKind, summary: String, error: any Error) -> Self {
        Self(ok: false, errorKind: kind, summary: summary, detail: .init(error: String(describing: error)))
    }
}
