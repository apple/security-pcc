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

// Required for ISO8601DateFormatter and FileHandle
import Foundation

package enum SystemBootIdentifierError: Error {
    case bootIDUnreadable(path: String, underlying: any Error)
    case bootIDMalformed(path: String, value: String)
    case procStatUnreadable(path: String, underlying: any Error)
    case procStatMissingBtime(path: String)
    case procStatBtimeMalformed(path: String, value: String)
}

/// All-zero placeholder used when the kernel boot identifier cannot be read.
package let fallbackSystemBootIdentifier = "00000000T000000.000Z-00000000-0000-0000-0000-000000000000"

/// All-zero placeholder used when no `FLEET_NODE_ID` is configured.
package let fallbackEnsembleID = "ensemble-00000000-0000-0000-0000-000000000000"

/// Reads a deterministic, host-boot-scoped identifier from the Linux kernel.
///
/// The result combines `/proc/stat`'s `btime` line with the kernel boot UUID
/// from `/proc/sys/kernel/random/boot_id`, formatted as
/// `{ISO8601-basic-with-fractional-seconds}-{UUID}`. Stable across process
/// restarts within a host boot; changes when the host reboots.
package func readSystemBootIdentifier(
    bootIDPath: String = "/proc/sys/kernel/random/boot_id",
    procStatPath: String = "/proc/stat"
) throws -> String {
    let bootID = try readKernelBootID(path: bootIDPath)
    let bootTime = try readKernelBootTime(path: procStatPath)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.formatOptions.subtract(.withColonSeparatorInTime)
    formatter.formatOptions.subtract(.withDashSeparatorInDate)
    let timestamp = formatter.string(from: bootTime)
    return "\(timestamp)-\(bootID)"
}

// Procfs files generate content lazily at read time, so `stat()` does not
// reliably report their size. `String(contentsOfFile:)` has been observed
// to crash intermittently on `/proc/stat` with an assertion in
// `UnsafeMutablePointer.initialize(from:count:)`. Stream to EOF via
// `FileHandle` to avoid relying on the stat-reported size.
private func readProcFile(path: String) throws -> String {
    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    defer { try? handle.close() }
    let data = try handle.readToEnd() ?? Data()
    return String(decoding: data, as: UTF8.self)
}

private func readKernelBootID(path: String) throws -> String {
    let raw: String
    do {
        raw = try readProcFile(path: path)
    } catch {
        throw SystemBootIdentifierError.bootIDUnreadable(path: path, underlying: error)
    }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    // The kernel returns a lowercased UUID; uppercase it so the wire format
    // matches Foundation's `UUID().uuidString`.
    guard let uuid = UUID(uuidString: trimmed) else {
        throw SystemBootIdentifierError.bootIDMalformed(path: path, value: trimmed)
    }
    return uuid.uuidString
}

private func readKernelBootTime(path: String) throws -> Date {
    let raw: String
    do {
        raw = try readProcFile(path: path)
    } catch {
        throw SystemBootIdentifierError.procStatUnreadable(path: path, underlying: error)
    }
    for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
        guard line.hasPrefix("btime ") else { continue }
        let value = line.dropFirst("btime ".count).trimmingCharacters(in: .whitespaces)
        guard let seconds = TimeInterval(value) else {
            throw SystemBootIdentifierError.procStatBtimeMalformed(path: path, value: value)
        }
        return Date(timeIntervalSince1970: seconds)
    }
    throw SystemBootIdentifierError.procStatMissingBtime(path: path)
}
