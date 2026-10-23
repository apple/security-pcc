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

import CloudBoardDomain
import Foundation
import os

enum LengthPrefixMessageChunkerError: RequestExecutionErrorProtocol, Equatable {
    case exceedingMaxMessageSize(maxSize: Int, announcedSize: Int)
    case outsideUInt32Limits

    var errorSource: RequestExecutionErrorSource {
        .cloudAppFramework
    }

    var staticStringRepresentation: StaticString {
        switch self {
        case .exceedingMaxMessageSize: "exceedingMaxMessageSize"
        case .outsideUInt32Limits: "outsideUInt32Limits"
        }
    }

    var errorCode: UInt32 {
        switch self {
        case .exceedingMaxMessageSize: CloudAppFrameworkErrorCodes.exceedingMaxMessageSize.rawValue
        case .outsideUInt32Limits: CloudAppFrameworkErrorCodes.outsideUInt32Limits.rawValue
        }
    }
}

/// Chunks incoming data from cloudApp into fixed-size segments.
///
/// **Input:** Raw data from cloudApp
/// **Output:** Length-prefixed chunks
///
/// **Format:**
/// - First chunk: 4-byte length prefix + chunk size=`ApplicationDataChunkingConfiguration->chunkSize`)
/// - Subsequent chunks: Remaining payload split into chunks of `ApplicationDataChunkingConfiguration->chunkSize`
///
/// **Applied to Data Paths:**
/// - Proxy → Compute (proxy chunks worker requests data)
/// - Compute → Proxy (compute node chunks worker response data)
/// - Compute → Device (compute node chunks final response data when response bypass is set)
/// - Proxy → Device (proxy chunks final response data when response bypass is not set)
///
/// **Configuration:**
/// - The chunk size on all the above data paths is currently controlled by device(Capabilities)
/// - maxApplicationLayerMessageSize is set per cloudApp during the warmup phase
///
/// /// - Note: Chunk size is ideally tuned to avoid further network-layer fragmentation
struct LengthPrefixMessageChunker {
    fileprivate static let log = Logger(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "LengthPrefixMessageChunker"
    )

    let config: ApplicationDataChunkingConfiguration
    let maxApplicationLayerMessageSize: Int

    init(
        config: ApplicationDataChunkingConfiguration,
        maxApplicationLayerMessageSize: Int
    ) {
        self.config = config
        self.maxApplicationLayerMessageSize = maxApplicationLayerMessageSize
    }

    func chunkData(
        data: Data,
        requestID: String,
        subrequestID: UInt64 = JobHelperMessenger.defaultSubrequestID
    ) throws -> [Data] {
        // Early return for disabled chunking
        guard case .enabled(let applicationDataChunkSize) = config else {
            Self.log.debug(
                "Chunking disabled for request with requestID=\(requestID, privacy: .public), subrequestID=\(subrequestID, privacy: .public)"
            )
            return [data]
        }

        // Validate size
        guard data.count <= self.maxApplicationLayerMessageSize else {
            Self.log.error(
                "Received cloud app response exceeding maxApplicationLayerMessageSize for request with requestID=\(requestID, privacy: .public), subrequestID=\(subrequestID, privacy: .public), maxApplicationLayerMessageSize=\(self.maxApplicationLayerMessageSize, privacy: .public)"
            )
            throw LengthPrefixMessageChunkerError.exceedingMaxMessageSize(
                maxSize: self.maxApplicationLayerMessageSize,
                announcedSize: data.count
            )
        }

        let headerData = try data.lengthTo4Bytes()

        let chunkCount = (data.count + applicationDataChunkSize - 1) / applicationDataChunkSize
        var chunkedData = [Data]()
        chunkedData.reserveCapacity(chunkCount)

        // First chunk: header + data
        var offset = data.startIndex
        let firstDataEnd = min(data.startIndex + applicationDataChunkSize, data.endIndex)
        var firstChunk = headerData
        firstChunk.append(data[offset ..< firstDataEnd])
        chunkedData.append(firstChunk)
        offset = firstDataEnd

        // Remaining chunks: just data
        while offset < data.endIndex {
            let endIndex = min(offset + applicationDataChunkSize, data.endIndex)
            chunkedData.append(data[offset ..< endIndex])
            offset = endIndex
        }

        return chunkedData
    }
}

extension Data {
    fileprivate func lengthTo4Bytes() throws -> Data {
        guard let length = UInt32(exactly: self.count) else {
            throw LengthPrefixMessageChunkerError.outsideUInt32Limits
        }

        // swiftformat:disable all
        return Data([
            UInt8(truncatingIfNeeded: length >> 24),
            UInt8(truncatingIfNeeded: length >> 16),
            UInt8(truncatingIfNeeded: length >>  8),
            UInt8(truncatingIfNeeded: length)
        ])
    }
}
