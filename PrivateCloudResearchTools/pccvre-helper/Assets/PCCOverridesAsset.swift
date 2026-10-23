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

/// Regex-based reject rules for a single PCC Overrides resource.
///
/// Mirrors `OverrideRules` in PCCAgentSafety so the asset produced here decodes identically on the
/// PCC node. `regexReject` / `regexRejectStrict` are deny-list patterns; `windowSize` /
/// `windowSizeStrict` are the trailing check windows (UTF-16 code units) used by the streamed-output
/// filter. `regexReplace` / `regexReplaceStrict` keys are tolerated by the runtime but ignored, so we
/// neither require nor emit them.
struct OverrideRules: Codable, Equatable {
    var regexReject: [String]
    var regexRejectStrict: [String]
    var windowSize: Int
    var windowSizeStrict: Int

    enum CodingKeys: CodingKey {
        case regexReject
        case regexRejectStrict
        case windowSize
        case windowSizeStrict
    }

    init(
        regexReject: [String] = [],
        regexRejectStrict: [String] = [],
        windowSize: Int = 0,
        windowSizeStrict: Int = 0
    ) {
        self.regexReject = regexReject
        self.regexRejectStrict = regexRejectStrict
        self.windowSize = windowSize
        self.windowSizeStrict = windowSizeStrict
    }

    // All fields optional so legacy / replace-only assets still decode cleanly — matches the runtime
    // decoder in PCCAgentSafety/Override/OverrideRules.swift.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        regexReject = try container.decodeIfPresent([String].self, forKey: .regexReject) ?? []
        regexRejectStrict = try container.decodeIfPresent([String].self, forKey: .regexRejectStrict) ?? []
        windowSize = try container.decodeIfPresent(Int.self, forKey: .windowSize) ?? 0
        windowSizeStrict = try container.decodeIfPresent(Int.self, forKey: .windowSizeStrict) ?? 0
    }

    var allRejectPatterns: [String] { regexReject + regexRejectStrict }
}

/// A single override resource resolved from a metadata directory, keyed by its full resource ID
/// (the directory name, including the `.input` / `.output` suffix).
struct OverridesResource: Equatable {
    /// e.g. `com.apple.fm.language.instruct_server_v2.mail_profile_creation.input`
    let resourceID: String
    var rules: OverrideRules

    var isOutput: Bool { resourceID.hasSuffix(".output") }
}

/// Pluggable strategy for the `windowSize` / `windowSizeStrict` values written into the asset.
///
/// The window is the maximum match length of the corresponding pattern set in UTF-16 code units,
/// computed offline. The computation is shared with the pcc-overrides reference implementation
/// (`scripts/window_size.py`) via a golden-vector corpus so the two cannot drift — see
/// `WindowSizeEstimator` and `OverridesAssetTests.windowSizeEstimatorMatchesSharedGoldenVectors`.
protocol WindowSizeCalculating {
    func windowSizes(for rules: OverrideRules) -> (windowSize: Int, windowSizeStrict: Int)
}

/// Uses the `windowSize` / `windowSizeStrict` already present in each `metadata.json`, unchanged.
struct PassthroughWindowSizeCalculator: WindowSizeCalculating {
    func windowSizes(for rules: OverrideRules) -> (windowSize: Int, windowSizeStrict: Int) {
        (rules.windowSize, rules.windowSizeStrict)
    }
}

/// Computes each window as the max match length of its reject set (`regexReject` -> `windowSize`,
/// `regexRejectStrict` -> `windowSizeStrict`) via `WindowSizeEstimator`, ignoring any values in the
/// input metadata. Used when the caller supplies patterns without precomputed windows.
struct ComputedWindowSizeCalculator: WindowSizeCalculating {
    func windowSizes(for rules: OverrideRules) -> (windowSize: Int, windowSizeStrict: Int) {
        (
            WindowSizeEstimator.windowSize(forPatterns: rules.regexReject),
            WindowSizeEstimator.windowSize(forPatterns: rules.regexRejectStrict)
        )
    }
}

/// Builds a custom PCC Overrides asset tree from a metadata directory.
///
/// Input directory layout (as stored in PCCSystemAssets `Assets/Safety/Overrides`):
/// ```
/// <metadata-directory>/
///     <resource-id>.input/<base-model>/metadata.json
///     <resource-id>.output/<base-model>/metadata.json
/// ```
/// An already-flattened layout (`<resource-id>.input/metadata.json`) is also accepted.
///
/// Staged output layout (what the on-node `OverridesAssetLoader` reads after extraction):
/// ```
/// <staging>/
///     <resource-id>.input/metadata.json
///     <resource-id>.output/metadata.json
/// ```
struct OverridesAssetBuilder {
    let baseModel: String
    let windowSizeCalculator: WindowSizeCalculating

    init(baseModel: String = "v9", windowSizeCalculator: WindowSizeCalculating = PassthroughWindowSizeCalculator()) {
        self.baseModel = baseModel
        self.windowSizeCalculator = windowSizeCalculator
    }

    /// Discovers, decodes and validates every override resource under `metadataDirectory`.
    func loadResources(fromMetadataDirectory metadataDirectory: URL) throws -> [OverridesResource] {
        let fm = FileManager.default

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: metadataDirectory.path, isDirectory: &isDir), isDir.boolValue else {
            throw CLIError("Metadata directory does not exist or is not a directory: \(metadataDirectory.path)")
        }

        let entries = try fm.contentsOfDirectory(
            at: metadataDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var resources: [OverridesResource] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                continue
            }

            let resourceID = entry.lastPathComponent
            guard resourceID.hasSuffix(".input") || resourceID.hasSuffix(".output") else {
                CLI.debugPrint("Skipping \(resourceID): name does not end in .input or .output")
                continue
            }

            let metadataURL = try metadataFileURL(forResourceDirectory: entry)
            let rules = try decodeAndValidate(metadataURL: metadataURL, resourceID: resourceID)
            resources.append(OverridesResource(resourceID: resourceID, rules: rules))
        }

        guard !resources.isEmpty else {
            throw CLIError("""
                No override resources found in \(metadataDirectory.path). Expected one or more \
                subdirectories named <resource-id>.input or <resource-id>.output, each containing a \
                metadata.json (optionally nested under a \(baseModel)/ folder).
                """)
        }

        // A case-sensitive source volume can present ids that differ only by case; they would stage
        // to one path on the case-insensitive filesystem CAD serves from, silently dropping one.
        if let (a, b) = Self.caseOnlyCollision(in: resources.map(\.resourceID)) {
            throw CLIError("Resource id collision: \(a) and \(b) differ only by case.")
        }

        return resources
    }

    /// The first pair of resource ids that differ only by case (they collide on a case-insensitive
    /// filesystem), or nil.
    static func caseOnlyCollision(in resourceIDs: [String]) -> (String, String)? {
        var seen: [String: String] = [:]
        for id in resourceIDs {
            if let prior = seen.updateValue(id, forKey: id.lowercased()) { return (prior, id) }
        }
        return nil
    }

    /// Writes the flattened `<resource-id>/metadata.json` tree into `stagingDirectory`.
    func stage(_ resources: [OverridesResource], into stagingDirectory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        for resource in resources {
            let resourceDir = stagingDirectory.appendingPathComponent(resource.resourceID, isDirectory: true)
            try fm.createDirectory(at: resourceDir, withIntermediateDirectories: true)

            let (windowSize, windowSizeStrict) = windowSizeCalculator.windowSizes(for: resource.rules)
            var rules = resource.rules
            rules.windowSize = windowSize
            rules.windowSizeStrict = windowSizeStrict

            // Signaling with an unbounded window is O(n²) over a streamed turn; check the emitted
            // value (which --compute-window-size may have set) rather than the input.
            if resource.isOutput, !rules.regexReject.isEmpty, rules.windowSize == 0, rules.regexRejectStrict.isEmpty {
                FileHandle.standardError.write(Data("""
                    warning: \(resource.resourceID): output signaling patterns present with \
                    windowSize 0 — the runtime will re-scan the full accumulated output on every \
                    token (O(n²)). Set a bounded windowSize for long-output surfaces.\n
                    """.utf8))
            }

            let data = try encoder.encode(rules)
            try data.write(to: resourceDir.appendingPathComponent("metadata.json"))
        }
    }

    // MARK: - Private

    private func metadataFileURL(forResourceDirectory resourceDir: URL) throws -> URL {
        let fm = FileManager.default
        let nested = resourceDir.appendingPathComponent(baseModel).appendingPathComponent("metadata.json")
        if fm.fileExists(atPath: nested.path) {
            return nested
        }

        let flat = resourceDir.appendingPathComponent("metadata.json")
        if fm.fileExists(atPath: flat.path) {
            return flat
        }

        throw CLIError("""
            No metadata.json for resource \(resourceDir.lastPathComponent): looked for \
            \(baseModel)/metadata.json and metadata.json under \(resourceDir.path).
            """)
    }

    private func decodeAndValidate(metadataURL: URL, resourceID: String) throws -> OverrideRules {
        let data: Data
        do {
            data = try Data(contentsOf: metadataURL)
        } catch {
            throw CLIError("Could not read \(metadataURL.path): \(error.localizedDescription)")
        }

        let rules: OverrideRules
        do {
            rules = try JSONDecoder().decode(OverrideRules.self, from: data)
        } catch {
            throw CLIError("Invalid metadata.json for \(resourceID) at \(metadataURL.path): \(error)")
        }

        for pattern in rules.allRejectPatterns {
            do {
                _ = try NSRegularExpression(pattern: pattern)
            } catch {
                throw CLIError("""
                    Invalid regex in \(resourceID): \(pattern.debugDescription) — \
                    \(error.localizedDescription)
                    """)
            }
        }

        guard rules.windowSize >= 0, rules.windowSizeStrict >= 0 else {
            throw CLIError("windowSize and windowSizeStrict must be non-negative in \(resourceID).")
        }

        return rules
    }
}

/// Offline estimator for a deny pattern's maximum match length in UTF-16 code units — the value
/// written into `windowSize` / `windowSizeStrict`.
///
/// This is a hand-port of the canonical reference `scripts/window_size.py` in the pcc-overrides
/// repo. The two implementations are locked together by a shared golden-vector corpus
/// (`Tests/window_size_vectors.json`), asserted here by `OverridesAssetTests` and there by the
/// Python tests. If you change the algorithm, regenerate the corpus in pcc-overrides
/// (`scripts/gen_window_size_vectors.py`) and copy it here so both sides stay in step.
///
/// Length is budgeted per regex construct (exact max-match is undecidable for unbounded patterns):
/// anchors / inline flags are zero-width; literals count their UTF-16 length; a character class
/// counts its longest literal member; a backreference resolves to the referenced group's length
/// (forward / self / unknown -> 0); an unbounded quantifier (`+`) adds 1 slack over its minimum.
/// Matches the worked example in PCCAgentSafety `OverrideRules.swift`:
/// `\bORNATE\s+GRANITE\s+SERPENT\b` -> 24.
enum WindowSizeEstimator {
    /// Window size for a set of deny patterns: the max estimated match length, or 0 if empty.
    static func windowSize(forPatterns patterns: [String]) -> Int {
        patterns.map(maxMatchLength(_:)).max() ?? 0
    }

    /// Estimated maximum match length of `pattern`, in UTF-16 code units.
    static func maxMatchLength(_ pattern: String) -> Int {
        let s = Array(pattern.unicodeScalars)
        return parseAlternation(s, 0, s.count, Groups(total: countCapturingGroups(s))).length
    }

    // MARK: - Private

    /// Capturing-group max-lengths recorded left-to-right for backreference budgeting. ICU numbers
    /// capturing groups (named and unnamed) by opening-paren order; a length is recorded on close, so
    /// a backref to a closed group resolves while a forward / self reference finds nothing (0).
    private final class Groups {
        let total: Int   // total capturing groups (for the \N backref digit back-off)
        var nextNum = 1
        var byNum: [Int: Int] = [:]
        var byName: [String: Int] = [:]
        init(total: Int) { self.total = total }
    }

    /// Total capturing groups — plain `(` and named `(?<name>...)`, skipping escapes and class bodies.
    /// ICU uses this to decide whether `\N` is a backref or a backref plus literal digits, and a
    /// forward reference can name a group that opens later, so it must be known up front.
    private static func countCapturingGroups(_ s: [Unicode.Scalar]) -> Int {
        var count = 0
        var i = 0
        let n = s.count
        var inClass = false
        while i < n {
            let c = s[i]
            if c == "\\" { i += 2; continue }
            if inClass {
                if c == "]" { inClass = false }
                i += 1
                continue
            }
            if c == "[" {
                inClass = true
                i += 1
                if i < n, s[i] == "^" { i += 1 }
                if i < n, s[i] == "]" { i += 1 }   // leading literal ']'
                continue
            }
            if c == "(" {
                if !(i + 1 < n && s[i + 1] == "?") {                       // plain capturing group
                    count += 1
                } else if i + 2 < n, s[i + 2] == "<",                      // named (?<name>...)
                          !(i + 3 < n && (s[i + 3] == "=" || s[i + 3] == "!")) {
                    count += 1
                }
            }
            i += 1
        }
        return count
    }

    private static let zeroWidthEscapes: Set<Unicode.Scalar> = ["b", "B", "A", "Z", "z"]

    private static func isDigit(_ c: Unicode.Scalar) -> Bool { (48...57).contains(c.value) }

    /// UTF-16 code units for a single scalar (astral scalars need a surrogate pair -> 2).
    private static func utf16Len(_ c: Unicode.Scalar) -> Int { c.value > 0xFFFF ? 2 : 1 }

    /// Skip a trailing lazy (`?`) or possessive (`+`) quantifier modifier; length is unaffected.
    private static func skipLazyPossessive(_ s: [Unicode.Scalar], _ i: Int, _ end: Int) -> Int {
        (i < end && (s[i] == "?" || s[i] == "+")) ? i + 1 : i
    }

    // Lengths saturate at Int.max rather than trap: a window past any real output means "check
    // everything", so over-sizing is safe and under-sizing (or crashing) is not. window_size.py uses
    // Python bigints, so the two only diverge past Int.max — beyond any pattern in the shared corpus.
    private static func satMul(_ a: Int, _ b: Int) -> Int {
        let (r, overflow) = a.multipliedReportingOverflow(by: b)
        return overflow ? .max : r
    }

    private static func satAdd(_ a: Int, _ b: Int) -> Int {
        let (r, overflow) = a.addingReportingOverflow(b)
        return overflow ? .max : r
    }

    /// Parse a digit run as an Int, saturating to Int.max on overflow; nil if empty.
    private static func parseCount(_ digits: String) -> Int? {
        digits.isEmpty ? nil : (Int(digits) ?? .max)
    }

    private struct Brace { let lo: Int; let comma: Bool; let hi: Int?; let endIndex: Int }

    /// Parse a `{n}` / `{n,}` / `{n,m}` quantifier at `i` (where `s[i] == "{"`). Nil if not a valid
    /// brace quantifier (then `{` is treated as a literal atom). `hi` is nil for `{n}` and `{n,}`.
    private static func matchBrace(_ s: [Unicode.Scalar], _ i: Int, _ end: Int) -> Brace? {
        var j = i + 1
        var loStr = ""
        while j < end, isDigit(s[j]) { loStr.unicodeScalars.append(s[j]); j += 1 }
        guard let lo = parseCount(loStr) else { return nil }
        var comma = false
        var hi: Int?
        if j < end, s[j] == "," {
            comma = true
            j += 1
            var hiStr = ""
            while j < end, isDigit(s[j]) { hiStr.unicodeScalars.append(s[j]); j += 1 }
            hi = parseCount(hiStr)   // nil for {n,}, else the (saturating) upper bound
        }
        guard j < end, s[j] == "}" else { return nil }
        return Brace(lo: lo, comma: comma, hi: hi, endIndex: j + 1)
    }

    /// Apply a quantifier following an atom of length `base`. Slack of 1 unit is added for unbounded
    /// quantifiers, mirroring the `\s+`-budgeted-as-2 convention.
    private static func applyQuantifier(_ base: Int, _ s: [Unicode.Scalar], _ i: Int, _ end: Int)
        -> (length: Int, index: Int)
    {
        if i >= end { return (base, i) }
        let length: Int
        var next = i
        switch s[i] {
        case "?":
            length = base
            next = i + 1
        case "+":
            return (satAdd(base, 1), skipLazyPossessive(s, i + 1, end))
        case "*":
            return (1, skipLazyPossessive(s, i + 1, end))
        case "{":
            guard let brace = matchBrace(s, i, end) else { return (base, i) }
            if !brace.comma {                        // {n}
                length = satMul(base, brace.lo)
                next = brace.endIndex
            } else if brace.hi == nil {               // {n,}
                return (satAdd(satMul(base, brace.lo), 1), skipLazyPossessive(s, brace.endIndex, end))
            } else {                                  // {n,m}
                length = satMul(base, brace.hi!)
                next = brace.endIndex
            }
        default:
            return (base, i)
        }
        return (length, skipLazyPossessive(s, next, end))
    }

    /// Given `s[i] == "("`, return (body start, isZeroWidth, isCapturing, name). Zero-width groups are
    /// lookaround (`(?=` `(?!` `(?<=` `(?<!`) and flag-only `(?flags)`; capturing groups are plain `(`
    /// (name nil) and named `(?<name>...)`; all others are non-capturing.
    private static func groupInnerStart(_ s: [Unicode.Scalar], _ i: Int, _ end: Int)
        -> (start: Int, zeroWidth: Bool, capturing: Bool, name: String?)
    {
        if i + 1 >= end || s[i + 1] != "?" { return (i + 1, false, true, nil) }   // plain capturing group
        let k = i + 2
        if k < end, s[k] == "=" || s[k] == "!" { return (k + 1, true, false, nil) }              // lookahead
        if k < end, s[k] == "<", k + 1 < end, s[k + 1] == "=" || s[k + 1] == "!" {                // lookbehind
            return (k + 2, true, false, nil)
        }
        if k < end, s[k] == "<" {                                                                // (?<name>
            let close = indexOf(">", s, from: k, end: end)
            return close != -1 ? (close + 1, false, true, scalarString(s, k + 1, close)) : (k, false, true, nil)
        }
        if k < end, s[k] == ":" { return (k + 1, false, false, nil) }                            // (?:
        // Inline flags: (?flags:...) is a group; (?flags) is a zero-width directive.
        var j = k
        while j < end, s[j] != ":", s[j] != ")" { j += 1 }
        if j < end, s[j] == ":" { return (j + 1, false, false, nil) }
        return (j, true, false, nil)
    }

    private static func indexOf(_ target: Unicode.Scalar, _ s: [Unicode.Scalar], from k: Int, end: Int) -> Int {
        var j = k
        while j < end { if s[j] == target { return j }; j += 1 }
        return -1
    }

    /// Build a String from the scalar half-open range `from..<to`.
    private static func scalarString(_ s: [Unicode.Scalar], _ from: Int, _ to: Int) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: s[from..<to])
        return String(view)
    }

    /// Parse a character class at `s[i] == "["`; returns (widest member's UTF-16 width, index).
    /// Literal astral members and `\x{H..}` astral escapes count 2; every other escape (shorthand
    /// class, `\xHH`, `\uXXXX`, escaped literal) is BMP and counts 1. A negated class can match an
    /// astral scalar too, but that is budgeted at 1 per the documented any-character limitation.
    private static func classMaxUnit(_ s: [Unicode.Scalar], _ i: Int, _ end: Int) -> (maxUnit: Int, index: Int) {
        var j = i + 1
        if j < end, s[j] == "^" { j += 1 }
        if j < end, s[j] == "]" { j += 1 }      // literal ']' as first class member (width 1)
        var maxUnit = 1
        while j < end, s[j] != "]" {
            if s[j] == "\\" {
                if j + 2 < end, s[j + 1] == "x", s[j + 2] == "{" {   // \x{H..} may encode an astral scalar
                    let close = indexOf("}", s, from: j + 3, end: end)
                    if close != -1 {
                        if let cp = hexValue(s, j + 3, close), cp > 0xFFFF { maxUnit = 2 }
                        j = close + 1
                        continue
                    }
                }
                j += 2   // any other escape -> a single BMP unit
                continue
            }
            maxUnit = max(maxUnit, utf16Len(s[j]))
            j += 1
        }
        return (maxUnit, j < end ? j + 1 : j)
    }

    /// Parse scalars `from..<to` as a hexadecimal integer; nil if empty or non-hex.
    private static func hexValue(_ s: [Unicode.Scalar], _ from: Int, _ to: Int) -> Int? {
        from < to ? Int(scalarString(s, from, to), radix: 16) : nil
    }

    /// Parse a single atom (plus any quantifier) starting at `i`.
    private static func parseAtom(_ s: [Unicode.Scalar], _ i: Int, _ end: Int, _ groups: Groups)
        -> (length: Int, index: Int)
    {
        let c = s[i]

        if c == "(" {
            let (innerStart, zeroWidth, capturing, name) = groupInnerStart(s, i, end)
            var num: Int?
            if capturing {   // number the group at its opening paren (ICU numbers by paren order)
                num = groups.nextNum
                groups.nextNum += 1
            }
            let inner = parseAlternation(s, innerStart, end, groups)
            let afterGroup = (inner.index < end && s[inner.index] == ")") ? inner.index + 1 : inner.index
            if let num {
                groups.byNum[num] = inner.length
                if let name { groups.byName[name] = inner.length }
            }
            let base = zeroWidth ? 0 : inner.length
            return applyQuantifier(base, s, afterGroup, end)
        }

        if c == "[" {                               // character class -> longest literal member
            let (maxUnit, next) = classMaxUnit(s, i, end)
            return applyQuantifier(maxUnit, s, next, end)
        }

        if c == "\\" {
            if i + 1 >= end { return applyQuantifier(1, s, i + 1, end) }
            let nxt = s[i + 1]
            if zeroWidthEscapes.contains(nxt) { return applyQuantifier(0, s, i + 2, end) }
            if isDigit(nxt), nxt != "0" {           // numeric backreference — ICU drops trailing digits
                var j = i + 1                        // when fewer than N groups exist: \10 with 1 group
                while j < end, isDigit(s[j]) { j += 1 }  // is backref \1 then the literal '0'.
                let digitCount = j - (i + 1)
                // Longest digit prefix naming an existing group (values increase with length).
                var refLen = 0
                for k in 1...digitCount {
                    if (Int(scalarString(s, i + 1, i + 1 + k)) ?? .max) <= groups.total { refLen = k } else { break }
                }
                if refLen == 0 {                     // no such group (ICU-invalid, gated) — literal digit
                    return applyQuantifier(1, s, i + 2, end)
                }
                // Consume only the backref digits; trailing digits stay in the stream as literal atoms.
                let num = Int(scalarString(s, i + 1, i + 1 + refLen)) ?? 0
                return applyQuantifier(groups.byNum[num] ?? 0, s, i + 1 + refLen, end)
            }
            if nxt == "k", i + 2 < end, s[i + 2] == "<" {   // named backreference \k<name>
                let close = indexOf(">", s, from: i + 2, end: end)
                if close != -1 {
                    return applyQuantifier(groups.byName[scalarString(s, i + 3, close)] ?? 0, s, close + 1, end)
                }
            }
            return applyQuantifier(1, s, i + 2, end)   // ordinary escaped literal
        }

        if c == "^" || c == "$" { return (0, i + 1) }

        if c == "." { return applyQuantifier(1, s, i + 1, end) }

        return applyQuantifier(utf16Len(c), s, i + 1, end)
    }

    /// Parse a sequence with top-level `|` alternation until `)` or `end`; returns the max over
    /// alternatives.
    private static func parseAlternation(_ s: [Unicode.Scalar], _ i0: Int, _ end: Int, _ groups: Groups)
        -> (length: Int, index: Int)
    {
        var i = i0
        var best = 0
        var current = 0
        while i < end, s[i] != ")" {
            if s[i] == "|" {
                best = max(best, current)
                current = 0
                i += 1
                continue
            }
            let atom = parseAtom(s, i, end, groups)
            current = satAdd(current, atom.length)
            i = atom.index
        }
        return (max(best, current), i)
    }
}
