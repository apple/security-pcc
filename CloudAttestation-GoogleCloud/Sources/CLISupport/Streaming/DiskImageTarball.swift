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
//  DiskImageTarball.swift
//  CloudAttestationV2
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//

import Foundation

/// Errors raised by ``extractDiskImage(fromTarball:into:chunkSize:)``.
public enum DiskImageTarballError: Error, CustomStringConvertible {
    case noDiskImageFound(path: String)
    case createOutputFailed(path: String)

    public var description: String {
        switch self {
        case .noDiskImageFound(let path):
            "No .img or .raw entry found in tarball \(path)"
        case .createOutputFailed(let path):
            "Could not create output file at \(path)"
        }
    }
}

/// Extract the first `.img`/`.raw` entry from a (gzip-compressed or plain)
/// tar archive on disk and write it to a file under `directory` (default:
/// the system temporary directory). Returns the URL of the extracted disk
/// image.
///
/// The archive is streamed in `chunkSize` blocks; the gzip layer is skipped
/// when the file lacks the gzip magic bytes so plain `.tar` archives also
/// work. Used by ``Release/VerifyImage`` so callers can hand it the
/// downloaded `.tar.gz` directly instead of extracting themselves.
public func extractDiskImage(
    fromTarball tarball: URL,
    into directory: URL = FileManager.default.temporaryDirectory,
    chunkSize: Int = 1 << 20
) throws -> URL {
    let input = try FileHandle(forReadingFrom: tarball)
    defer { try? input.close() }

    // Sniff for the gzip magic so plain .tar inputs are supported too.
    let head = try input.read(upToCount: 2) ?? Data()
    try input.seek(toOffset: 0)
    let isGzip = head.count == 2 && head[0] == 0x1F && head[1] == 0x8B

    let decompressor: GzipDecompressor? = isGzip ? GzipDecompressor() : nil
    var tar = TarExtractor { name in
        name.hasSuffix(".img") || name.hasSuffix(".raw")
    }

    let outputDir = directory.appending(path: "cloudattestationv2-verify-image-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    let outputURL = outputDir.appending(path: tarball.deletingPathExtension().deletingPathExtension().lastPathComponent + ".img")

    guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
        throw DiskImageTarballError.createOutputFailed(path: outputURL.path)
    }
    let output = try FileHandle(forWritingTo: outputURL)
    defer { try? output.close() }

    var bytesWritten: UInt64 = 0
    while let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty {
        let decompressed = try decompressor?.process(chunk) ?? chunk
        let imageBytes = tar.feed(decompressed)
        if !imageBytes.isEmpty {
            try output.write(contentsOf: imageBytes)
            bytesWritten += UInt64(imageBytes.count)
        }
    }

    guard bytesWritten > 0 else {
        try? FileManager.default.removeItem(at: outputDir)
        throw DiskImageTarballError.noDiskImageFound(path: tarball.path)
    }

    return outputURL
}

/// Read a single (small) entry from a tar archive on disk into memory, where
/// the archive may be gzip-compressed. Returns `nil` if no entry matches.
/// Stops decompressing/reading as soon as the matching entry is fully
/// consumed, so callers can pull tiny metadata files (e.g. `index.json`) out
/// of multi-gigabyte container tarballs without paying for the rest.
///
/// Unsuitable for large entries — the result is buffered in memory; use
/// ``extractDiskImage(fromTarball:into:chunkSize:)`` (which streams to disk)
/// for those.
public func readTarballEntry(
    at url: URL,
    where predicate: @escaping (String) -> Bool,
    chunkSize: Int = 1 << 20
) throws -> Data? {
    let input = try FileHandle(forReadingFrom: url)
    defer { try? input.close() }

    let head = try input.read(upToCount: 2) ?? Data()
    try input.seek(toOffset: 0)
    let isGzip = head.count == 2 && head[0] == 0x1F && head[1] == 0x8B

    let decompressor: GzipDecompressor? = isGzip ? GzipDecompressor() : nil
    var tar = TarExtractor(matching: predicate)
    var output = Data()

    while let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty {
        let decompressed = try decompressor?.process(chunk) ?? chunk
        output.append(tar.feed(decompressed))
        if tar.isDone { break }
    }

    return tar.matchedEntryName != nil ? output : nil
}
