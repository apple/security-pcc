# Copyright © 2026 Apple Inc. All Rights Reserved.

# APPLE INC.
# PRIVATE CLOUD COMPUTE SOURCE CODE INTERNAL USE LICENSE AGREEMENT
# PLEASE READ THE FOLLOWING PRIVATE CLOUD COMPUTE SOURCE CODE INTERNAL USE LICENSE AGREEMENT (“AGREEMENT”) CAREFULLY BEFORE DOWNLOADING OR USING THE APPLE SOFTWARE ACCOMPANYING THIS AGREEMENT(AS DEFINED BELOW). BY DOWNLOADING OR USING THE APPLE SOFTWARE, YOU ARE AGREEING TO BE BOUND BY THE TERMS OF THIS AGREEMENT. IF YOU DO NOT AGREE TO THE TERMS OF THIS AGREEMENT, DO NOT DOWNLOAD OR USE THE APPLE SOFTWARE. THESE TERMS AND CONDITIONS CONSTITUTE A LEGAL AGREEMENT BETWEEN YOU AND APPLE.
# IMPORTANT NOTE: BY DOWNLOADING OR USING THE APPLE SOFTWARE, YOU ARE AGREEING ON YOUR OWN BEHALF AND/OR ON BEHALF OF YOUR COMPANY OR ORGANIZATION TO THE TERMS OF THIS AGREEMENT.
# 1. As used in this Agreement, the term “Apple Software” collectively means and includes all of the Apple Private Cloud Compute materials provided by Apple here, including but not limited to the Apple Private Cloud Compute software, tools, data, files, frameworks, libraries, documentation, logs and other Apple-created materials. In consideration for your agreement to abide by the following terms, conditioned upon your compliance with these terms and subject to these terms, Apple grants you, for a period of ninety (90) days from the date you download the Apple Software, a limited, non-exclusive, non-sublicensable license under Apple’s copyrights in the Apple Software to download, install, compile and run the Apple Software internally within your organization only on a single Apple-branded computer you own or control, for the sole purpose of verifying the security and privacy characteristics of Apple Private Cloud Compute. This Agreement does not allow the Apple Software to exist on more than one Apple-branded computer at a time, and you may not distribute or make the Apple Software available over a network where it could be used by multiple devices at the same time. You may not, directly or indirectly, redistribute the Apple Software or any portions thereof. The Apple Software is only licensed and intended for use as expressly stated above and may not be used for other purposes or in other contexts without Apple's prior written permission. Except as expressly stated in this notice, no other rights or licenses, express or implied, are granted by Apple herein.
# 2. The Apple Software is provided by Apple on an "AS IS" basis. APPLE MAKES NO WARRANTIES, EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION THE IMPLIED WARRANTIES OF NON-INFRINGEMENT, MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE, REGARDING THE APPLE SOFTWARE OR ITS USE AND OPERATION ALONE OR IN COMBINATION WITH YOUR PRODUCTS, SYSTEMS, OR SERVICES. APPLE DOES NOT WARRANT THAT THE APPLE SOFTWARE WILL MEET YOUR REQUIREMENTS, THAT THE OPERATION OF THE APPLE SOFTWARE WILL BE UNINTERRUPTED OR ERROR-FREE, THAT DEFECTS IN THE APPLE SOFTWARE WILL BE CORRECTED, OR THAT THE APPLE SOFTWARE WILL BE COMPATIBLE WITH FUTURE APPLE PRODUCTS, SOFTWARE OR SERVICES. NO ORAL OR WRITTEN INFORMATION OR ADVICE GIVEN BY APPLE OR AN APPLE AUTHORIZED REPRESENTATIVE WILL CREATE A WARRANTY.
# 3. IN NO EVENT SHALL APPLE BE LIABLE FOR ANY DIRECT, SPECIAL, INDIRECT, INCIDENTAL OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) ARISING IN ANY WAY OUT OF THE USE, REPRODUCTION, COMPILATION OR OPERATION OF THE APPLE SOFTWARE, HOWEVER CAUSED AND WHETHER UNDER THEORY OF CONTRACT, TORT (INCLUDING NEGLIGENCE), STRICT LIABILITY OR OTHERWISE, EVEN IF APPLE HAS BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
# 4. This Agreement is effective until terminated. Your rights under this Agreement will terminate automatically without notice from Apple if you fail to comply with any term(s) of this Agreement. Upon termination, you agree to cease all use of the Apple Software and destroy all copies, full or partial, of the Apple Software. This Agreement constitutes the entire understanding of the parties with respect to the subject matter contained herein, and supersedes all prior negotiations, representations, or understandings, written or oral. This Agreement will be governed and construed in accordance with the laws of the State of California, without regard to its choice of law rules.
# You may report security issues about Apple products to product-security@apple.com, as described here: https://www.apple.com/support/security/. Non-security bugs and enhancement requests can be made via https://bugreport.apple.com as described here: https://developer.apple.com/bug-reporting/
# EA1937
# 10/02/2024

#!/usr/bin/env bash
#
# check-coverage.sh — Measures code coverage for the library target and
# compares against the baseline in coverage-baseline.json.
#
# Usage:
#   bash Scripts/check-coverage.sh
#
# Requires: swift, llvm-cov, python3
# Expects to be run from the repository root (i.e. /build inside Docker).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

BASELINE_FILE="$REPO_ROOT/coverage-baseline.json"
LIBRARY_SOURCE_DIRS=("Sources/AEAStreamDownloader" "Sources/OTelConfiguration" "Sources/WhisperClient")

# Step 1: Build and test with coverage.
echo "=== Running tests with code coverage ==="
swift test --skip-update --enable-code-coverage 2>&1

# Clean up stray profraw left by build tool plugins (e.g. OpenAPIGenerator)
# that get instrumented as a side effect of --enable-code-coverage.
rm -f "$REPO_ROOT/default.profraw"

# Step 2: Find the profdata and test binary.
PROFDATA=".build/debug/codecov/default.profdata"
if [ ! -f "$PROFDATA" ]; then
    echo "ERROR: Could not find profdata at $PROFDATA"
    exit 1
fi

# Find the test binary — on Linux it's the package test runner.
# Find the test binary — on Linux it's the package test runner.
TEST_BIN=$(ls .build/debug/*PackageTests.xctest 2>/dev/null | head -1)
if [ -z "$TEST_BIN" ]; then
    TEST_BIN=$(ls .build/debug/*.xctest 2>/dev/null | head -1)
fi
if [ -z "$TEST_BIN" ]; then
    echo "ERROR: Could not find test binary"
    exit 1
fi

echo "=== Test binary: $TEST_BIN ==="
echo "=== Profile data: $PROFDATA ==="

# Step 3: Generate JSON export filtered to library sources.
echo "=== Generating coverage report ==="
COVERAGE_JSON_FILE=$(mktemp)
trap "rm -f '$COVERAGE_JSON_FILE'" EXIT

SOURCE_FLAGS=()
for dir in "${LIBRARY_SOURCE_DIRS[@]}"; do
    SOURCE_FLAGS+=(-sources "$dir/")
done

llvm-cov export "$TEST_BIN" \
    -instr-profile "$PROFDATA" \
    "${SOURCE_FLAGS[@]}" \
    --format=text > "$COVERAGE_JSON_FILE" 2>/dev/null

# Step 4: Parse coverage and compare against baseline.
echo "=== Checking coverage against baseline ==="

# Join source dirs with colons for the Python script.
SOURCE_DIRS_ARG=$(IFS=:; echo "${LIBRARY_SOURCE_DIRS[*]}")

python3 - "$BASELINE_FILE" "$SOURCE_DIRS_ARG" "$COVERAGE_JSON_FILE" <<'PYEOF'
import json
import sys
import os

baseline_path = sys.argv[1]
source_dirs = sys.argv[2].split(":")
coverage_json_file = sys.argv[3]

with open(coverage_json_file) as f:
    cov_data = json.load(f)

# Build per-file coverage from the llvm-cov data.
file_coverage = {}
# Also collect uncovered line ranges per file from segment data.
# Segments are [line, col, count, has_count, is_region_entry, is_gap].
file_uncovered_lines = {}
for file_data in cov_data.get("data", [{}])[0].get("files", []):
    filename = file_data["filename"]
    # Make path relative to repo root.
    cwd = os.getcwd()
    if filename.startswith(cwd + "/"):
        filename = filename[len(cwd) + 1:]

    # Only consider files in one of the library source dirs.
    if not any(filename.startswith(d + "/") for d in source_dirs):
        continue

    summary = file_data["summary"]
    lines = summary["lines"]
    total = lines["count"]
    covered = lines["covered"]
    pct = (covered / total * 100.0) if total > 0 else 100.0
    file_coverage[filename] = {
        "line_coverage": round(pct, 2),
        "covered_lines": covered,
        "total_lines": total,
    }

    # Extract uncovered lines from segments.
    # Each segment is [line, col, count, has_count, is_region_entry, is_gap_region].
    # We track the current execution count and record lines where count == 0.
    uncovered = set()
    segments = file_data.get("segments", [])
    for i, seg in enumerate(segments):
        seg_line, seg_col, seg_count, seg_has_count = seg[0], seg[1], seg[2], seg[3]
        if not seg_has_count:
            continue
        if seg_count == 0:
            # This segment starts an uncovered region. Find where it ends.
            end_line = seg_line
            if i + 1 < len(segments):
                end_line = segments[i + 1][0]
            for line_no in range(seg_line, end_line):
                uncovered.add(line_no)

    if uncovered:
        file_uncovered_lines[filename] = sorted(uncovered)

# Load baseline.
if not os.path.exists(baseline_path):
    print(f"WARNING: No baseline file at {baseline_path}")
    print("Coverage results (no baseline to compare):")
    for f, c in sorted(file_coverage.items()):
        print(f"  {f}: {c['line_coverage']:.2f}% ({c['covered_lines']}/{c['total_lines']})")
    sys.exit(0)

with open(baseline_path) as f:
    baseline = json.load(f)

# Compare.
min_coverage = baseline.get("minimum_line_coverage", 0.0)
file_baselines = baseline.get("files", {})

print(f"\n{'File':<70} {'Actual':>8} {'Baseline':>10} {'Status':>8}")
print("-" * 100)

failures = []
for filename, cov in sorted(file_coverage.items()):
    actual = cov["line_coverage"]
    file_baseline = file_baselines.get(filename, {}).get("line_coverage", min_coverage)
    status = "OK" if actual >= file_baseline else "FAIL"
    print(f"  {filename:<68} {actual:>7.2f}% {file_baseline:>9.2f}% {status:>8}")
    if actual < file_baseline:
        failures.append((filename, actual, file_baseline))

# Check for files in baseline that are missing from coverage.
for filename in sorted(file_baselines.keys()):
    if filename not in file_coverage:
        print(f"  {filename:<68} {'N/A':>8} {file_baselines[filename].get('line_coverage', 0):>9.2f}% {'MISSING':>8}")
        failures.append((filename, 0, file_baselines[filename].get("line_coverage", 0)))

print("-" * 100)

total_covered = sum(c["covered_lines"] for c in file_coverage.values())
total_lines = sum(c["total_lines"] for c in file_coverage.values())
overall = (total_covered / total_lines * 100.0) if total_lines > 0 else 100.0
print(f"  {'Overall':<68} {overall:>7.2f}%")

# Print uncovered lines for any file that isn't at 100%.
def collapse_ranges(lines):
    """Collapse a sorted list of line numbers into 'N' or 'N-M' range strings."""
    if not lines:
        return []
    ranges = []
    start = lines[0]
    end = lines[0]
    for line in lines[1:]:
        if line == end + 1:
            end = line
        else:
            ranges.append(f"{start}" if start == end else f"{start}-{end}")
            start = end = line
    ranges.append(f"{start}" if start == end else f"{start}-{end}")
    return ranges

has_uncovered = False
for filename in sorted(file_uncovered_lines.keys()):
    cov = file_coverage[filename]
    if cov["line_coverage"] >= 100.0:
        continue
    if not has_uncovered:
        print("\n=== Uncovered lines ===")
        has_uncovered = True
    ranges = collapse_ranges(file_uncovered_lines[filename])
    print(f"\n  {filename} ({cov['covered_lines']}/{cov['total_lines']} lines covered)")
    # Print ranges, wrapping at ~100 chars.
    line = "    Lines: "
    for i, r in enumerate(ranges):
        addition = r if i == 0 else f", {r}"
        if len(line) + len(addition) > 100:
            print(line)
            line = "           " + r
        else:
            line += addition
    print(line)

if failures:
    print(f"\nFAILED: {len(failures)} file(s) below baseline:")
    for f, actual, expected in failures:
        print(f"  {f}: {actual:.2f}% < {expected:.2f}%")
    sys.exit(1)
else:
    print("\nAll files meet or exceed baseline coverage.")
    sys.exit(0)
PYEOF
