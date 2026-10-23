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

package policy.common

import rego.v1

default has_key(_, _) := false

has_key(data_object, key_name) if {
    is_object(data_object)
    key_name in object.keys(data_object)
}

# paths enumerates every key path in a nested object/array as arrays of
# string segments.  Array indices are converted to their decimal string
# representation so that allowlist patterns can match them with "*".
# Returning arrays (instead of slash-joined strings) avoids ambiguity when a
# key itself contains a "/" (e.g. a URL used as a cryptex identifier).
# Example: {"a": [{"b": 1}]} produces {["a"], ["a","0"], ["a","0","b"]}.
paths(x) := result if {
    result := {path |
        walk(x, [path_array, _])
        count(path_array) > 0
        path := [s |
            some idx in numbers.range(0, count(path_array) - 1)
            k := path_array[idx]
            s := _key_to_string(k)
        ]
    }
}

_key_to_string(k) := k if is_string(k)
_key_to_string(k) := sprintf("%d", [k]) if not is_string(k)

# path_in_allowed checks whether a config path is permitted by an allowlist.
# It returns true when the path matches at least one pattern in allowed_paths.
#
# Supported pattern syntax:
#   "a/b/c"   — exact literal match
#   "a/*/c"   — single-segment wildcard: * matches exactly one path segment
#   "a/**"    — trailing multi-segment wildcard: matches a/ and everything below
#
# IMPORTANT: ** is ONLY valid as a trailing "/**" suffix.  Patterns with **
# in any other position (e.g. "a/**/b") are invalid and must be caught by
# invalid_patterns() — see below.
#
# Implicit parent matching: if a child path is listed (e.g. "a/b/c"), then
# its parent paths ("a" and "a/b") are also considered allowed.  This avoids
# false positives from walk() emitting intermediate container paths.
path_in_allowed(path, allowed_paths) if {
    some pattern in allowed_paths
    _path_matches(path, pattern)
}

# invalid_patterns returns the subset of patterns that misuse **.
# ** is only supported as a trailing "/**" suffix.  Any pattern that contains
# ** elsewhere (e.g. "a/**/b") is a bug in the policy definition.
# Policy files should import this and add a deny rule to surface the error.
invalid_patterns(patterns) := {pattern |
    some pattern in patterns
    contains(pattern, "**")
    not endswith(pattern, "/**")
}

# Exact or single-wildcard match: the path and pattern have the same number
# of segments and each segment either matches literally or via *.
_path_matches(path, pattern) if {
    not endswith(pattern, "/**")
    pattern_parts := split(pattern, "/")
    count(path) == count(pattern_parts)
    every i in numbers.range(0, count(path) - 1) {
        _segment_matches(path[i], pattern_parts[i])
    }
}

# Trailing /** match: all prefix segments must match and the path must be at
# or beyond the prefix depth (i.e. "a/**" matches "a", "a/b", "a/b/c", ...).
_path_matches(path, pattern) if {
    endswith(pattern, "/**")
    prefix := trim_suffix(pattern, "/**")
    prefix_parts := split(prefix, "/")
    count(path) >= count(prefix_parts)
    every i in numbers.range(0, count(prefix_parts) - 1) {
        _segment_matches(path[i], prefix_parts[i])
    }
}

# Parent match: the path has fewer segments than the pattern, meaning it is a
# parent container.  We allow it when every segment of the path matches the
# corresponding segment of the pattern (so listing "a/b/c" implicitly allows
# "a" and "a/b").
_path_matches(path, pattern) if {
    pattern_parts := _effective_parts(pattern)
    count(path) < count(pattern_parts)
    every i in numbers.range(0, count(path) - 1) {
        _segment_matches(path[i], pattern_parts[i])
    }
}

# For ** patterns, effective parts are just the prefix; otherwise all parts.
_effective_parts(pattern) := split(trim_suffix(pattern, "/**"), "/") if endswith(pattern, "/**")
_effective_parts(pattern) := split(pattern, "/") if not endswith(pattern, "/**")

# _segment_matches succeeds when a single path segment matches a pattern segment.
_segment_matches(actual, pattern_seg) if pattern_seg == "*"
_segment_matches(actual, pattern_seg) if actual == pattern_seg
