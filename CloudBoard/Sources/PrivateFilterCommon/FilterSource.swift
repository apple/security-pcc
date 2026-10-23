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

/// Controls how a filter listed in `filterIDs` is obtained.
///
/// Stored per-filter in SecureConfig at
/// `com.apple.privatefilter.service.filter.<id>.source` as a string value.
/// Defaults to `.standard` when not set.
package enum FilterSource: String, Codable, Sendable, CustomStringConvertible {
    /// Real filter: remote filters are downloaded from the CDN with shard
    /// awareness; local (inline) filters are read directly from the cryptex.
    case standard

    /// The downloader skips this filter; the controller generates a fake that
    /// mimics a downloaded (remote) filter. Default sizing is large / multi-fragment,
    /// overridable via `fakeFilter.<id>.*`.
    case fakeRemote

    /// The downloader skips this filter; the controller generates a fake that
    /// mimics a local (inline) filter. Default sizing is small / single-fragment,
    /// overridable via `fakeFilter.<id>.*`.
    case fakeLocal

    /// The downloader skips this filter; the controller skips both real loading
    /// and the on-disk fake-filter builder, and instead serves the filter as a
    /// pure deterministic function of the BinaryKey with a configured hit
    /// probability and per-call latency drawn from a configured log-normal.
    /// Sized for a remote (multi-fragment) layout: default hit probability 0.4,
    /// default fragment count 64. Sharding is enforced bit-for-bit identically
    /// to a real filter — keys whose fragment falls outside this shard's range
    /// throw the same `FilterError.fragmentNotCovered`.
    case syntheticRemote

    /// Synthetic filter sized as a single-fragment (local/inline) layout.
    /// Default hit probability 1e-6, default fragment count 1. See
    /// `.syntheticRemote` for the rest of the semantics.
    case syntheticLocal

    /// `true` for either `.syntheticRemote` or `.syntheticLocal`. Synthetic
    /// filters are served from in-process state with no on-disk artifact, so
    /// the downloader and FakeFilterBuilder both skip them.
    package var isSynthetic: Bool {
        switch self {
        case .syntheticRemote, .syntheticLocal: true
        case .standard, .fakeRemote, .fakeLocal: false
        }
    }

    package var description: String { self.rawValue }
}

/// Per-filter configuration loaded from the shared
/// `com.apple.privatefilter.service.filter.<id>.*` keys.
package struct PerFilterConfig: Hashable, CustomStringConvertible {
    package let source: FilterSource
    package let shardConfig: FilterShardConfig
    /// Optional hashingID override from
    /// `com.apple.privatefilter.service.filter.<id>.hashingIDOverride`.
    /// Set to `HashingIDOverride.wildcardConfigValue` (`"*"`) to skip
    /// validation, or any other string to force that hashID.
    package let hashingIDOverride: String?
    /// Optional list of base64-encoded 12-byte BinaryKey values. Queries
    /// whose key matches one of these are answered as `.miss` without
    /// consulting the underlying filter. The strings are validated
    /// (base64-decoded into BinaryKey) at controller startup; a malformed
    /// entry terminates the process.
    package let queryAllowList: [String]?
    /// Optional override for the filterID path segment of the fragment download
    /// URL, from `com.apple.privatefilter.service.filter.<id>.urlFilterIDOverride`.
    /// When set, the downloader builds `<urlPrefix>/<urlFilterIDOverride>/<rev>/…`
    /// instead of using the filterID verbatim; everything else (cache directory,
    /// descriptor, discovery) still uses the real filterID. Remediation lever for
    /// filters whose CDN path differs from their filterID.
    package let urlFilterIDOverride: String?

    package init(
        source: FilterSource,
        shardConfig: FilterShardConfig,
        hashingIDOverride: String? = nil,
        queryAllowList: [String]? = nil,
        urlFilterIDOverride: String? = nil
    ) {
        self.source = source
        self.shardConfig = shardConfig
        self.hashingIDOverride = hashingIDOverride
        self.queryAllowList = queryAllowList
        self.urlFilterIDOverride = urlFilterIDOverride
    }

    package var description: String {
        var desc = "PerFilterConfig(source: \(self.source), shardConfig: \(self.shardConfig)"
        if let override = hashingIDOverride {
            desc += ", hashingIDOverride: \(override)"
        }
        if let allowList = queryAllowList {
            desc += ", queryAllowList: \(allowList.count) entries"
        }
        if let urlFilterIDOverride {
            desc += ", urlFilterIDOverride: \(urlFilterIDOverride)"
        }
        desc += ")"
        return desc
    }
}
