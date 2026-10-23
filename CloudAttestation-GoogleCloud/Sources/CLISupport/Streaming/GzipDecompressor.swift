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
//  GzipDecompressor.swift
//  CloudAttestationV2
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//

#if canImport(Darwin)
import zlib
#elseif canImport(CZlib)
import CZlib
#endif
import Foundation

/// Streaming gzip decompressor built on the system zlib. Used by `OSImageStore`
/// (internal) and `extractDiskImage(fromTarball:)` (public) to extract raw disk
/// images from `.tar.gz` OS image bundles without staging the full uncompressed
/// payload in memory.
///
/// Per RFC 1952 §2.2 a gzip file may be a concatenation of independent members;
/// this decoder loops across members transparently so the caller sees a single
/// contiguous decompressed stream. Google's Confidential Space image builds emit
/// multi-member archives (a fresh member every ~3 GiB), so single-member decode
/// is not sufficient.
///
/// Apple's `Compression` framework is deliberately not used: on
/// `COMPRESSION_STATUS_END` it has already read past the end of the DEFLATE
/// stream into an internal buffer and cannot hand the overshoot back, so member
/// boundaries cannot be recovered. zlib reports the exact leftover via
/// `avail_in`, and with `windowBits = 16 + 15` it consumes the gzip header and
/// trailer itself, so no manual framing is required.
public final class GzipDecompressor {
    private static let outputBufferSize = 262_144

    private var stream = z_stream()
    private let outputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: outputBufferSize)
    private var streamInitialized = false

    public init() {}

    deinit {
        if streamInitialized {
            inflateEnd(&stream)
        }
        outputBuffer.deallocate()
    }

    public func process(_ input: Data) throws -> Data {
        if !streamInitialized {
            stream.zalloc = nil
            stream.zfree = nil
            stream.opaque = nil
            // 16 + 15: enable gzip framing (zlib parses the header and validates
            // the CRC32/ISIZE trailer for us).
            guard inflateInit2_(&stream, 16 + 15, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                throw GzipDecompressorError.initializationFailed
            }
            streamInitialized = true
        }

        guard !input.isEmpty else { return Data() }

        return try input.withUnsafeBytes { rawInput in
            let src = rawInput.bindMemory(to: UInt8.self)
            stream.next_in = UnsafeMutablePointer(mutating: src.baseAddress!)
            stream.avail_in = UInt32(src.count)

            var output = Data()

            while true {
                stream.next_out = outputBuffer
                stream.avail_out = UInt32(Self.outputBufferSize)
                let status = inflate(&stream, Z_NO_FLUSH)
                let produced = Self.outputBufferSize - Int(stream.avail_out)
                if produced > 0 {
                    output.append(outputBuffer, count: produced)
                }

                switch status {
                case Z_STREAM_END:
                    // End of one member. `next_in`/`avail_in` sit exactly after the
                    // gzip trailer; reset the inflater and, if input remains, keep
                    // going into the next member.
                    guard inflateReset(&stream) == Z_OK else {
                        throw GzipDecompressorError.initializationFailed
                    }
                    if stream.avail_in == 0 { return output }

                case Z_OK:
                    if stream.avail_in == 0 && stream.avail_out > 0 { return output }

                case Z_BUF_ERROR:
                    // No progress possible with the input provided so far — caller
                    // will feed more on the next `process` call.
                    return output

                default:
                    throw GzipDecompressorError.decompressionFailed(code: status, message: stream.msg.map { String(cString: $0) })
                }
            }
        }
    }
}

public enum GzipDecompressorError: Error, CustomStringConvertible {
    case initializationFailed
    case decompressionFailed(code: Int32, message: String?)

    public var description: String {
        switch self {
        case .initializationFailed: "Failed to initialize gzip decompressor"
        case .decompressionFailed(let code, let message): "Gzip decompression error (zlib \(code)\(message.map { ": \($0)" } ?? ""))"
        }
    }
}
