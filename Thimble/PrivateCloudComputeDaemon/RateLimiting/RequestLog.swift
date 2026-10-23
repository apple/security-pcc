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
//  RequestLog.swift
//  PrivateCloudCompute
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

internal import CollectionsInternal
import Foundation
import PrivateCloudCompute

// MARK: - RequestLog

// This is a circular buffer of all the requests that have gone
// through, for use by the rate limiter. The rate limiter needs to
// know how many requests of a given type have occurred over what
// time period, and to do so it consults this thing.
struct RequestLog: Sendable, Equatable {
    private var log: Deque<Element> = []

    struct Element: Sendable, Equatable, Hashable, Comparable {
        fileprivate final class Storage: Sendable {
            let requestMetadata: RateLimiterRequestMetadata

            init(requestMetadata: RateLimiterRequestMetadata) {
                self.requestMetadata = requestMetadata
            }
        }

        fileprivate let storage: Storage
        var requestMetadata: RateLimiterRequestMetadata {
            self.storage.requestMetadata
        }
        var timestamp: Date

        init(requestMetadata: RateLimiterRequestMetadata, timestamp: Date) {
            self.storage = Storage(requestMetadata: requestMetadata)
            self.timestamp = timestamp
        }

        fileprivate init(storage: Storage, timestamp: Date) {
            self.storage = storage
            self.timestamp = timestamp
        }

        static func < (lhs: Element, rhs: Element) -> Bool {
            return lhs.timestamp < rhs.timestamp
        }

        static func == (lhs: Element, rhs: Element) -> Bool {
            lhs.requestMetadata == rhs.requestMetadata && lhs.timestamp == rhs.timestamp
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(self.requestMetadata)
            hasher.combine(self.timestamp)
        }
    }
}

extension RequestLog: Encodable {
    enum CodingKeys: CodingKey {
        case log
        case metadata
    }

    enum ElementCodingKeys: CodingKey {
        case metadataIndex
        case timestamp
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        var logContainer = container.nestedUnkeyedContainer(forKey: .log)
        var metadataContainer = container.nestedUnkeyedContainer(forKey: .metadata)
        var metadataLookup: [RateLimiterRequestMetadata: Int] = [:]

        for log in self.log {
            let index: Int
            if let existingIndex = metadataLookup[log.requestMetadata] {
                index = existingIndex
            } else {
                try metadataContainer.encode(log.requestMetadata)
                let newIndex = metadataLookup.count
                metadataLookup[log.requestMetadata] = newIndex
                index = newIndex
            }

            var logContainer = logContainer.nestedContainer(keyedBy: ElementCodingKeys.self)
            try logContainer.encode(index, forKey: .metadataIndex)
            try logContainer.encode(log.timestamp, forKey: .timestamp)
        }
    }
}

extension RequestLog: Decodable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        var metadataContainer = try container.nestedUnkeyedContainer(forKey: .metadata)
        var requestMetadataStorages: [Element.Storage] = []
        if let count = metadataContainer.count {
            requestMetadataStorages.reserveCapacity(count)
        }

        while !metadataContainer.isAtEnd {
            let requestMetadata = try metadataContainer.decode(RateLimiterRequestMetadata.self)
            requestMetadataStorages.append(Element.Storage(requestMetadata: requestMetadata))
        }

        var logContainer = try container.nestedUnkeyedContainer(forKey: .log)
        var window = Deque<Element>()
        if let logCount = logContainer.count {
            window.reserveCapacity(logCount)
        }
        while !logContainer.isAtEnd {
            let elementContainer = try logContainer.nestedContainer(keyedBy: ElementCodingKeys.self)
            let storageIndex = try elementContainer.decode(Int.self, forKey: .metadataIndex)
            let timestamp = try elementContainer.decode(Date.self, forKey: .timestamp)
            window.append(.init(storage: requestMetadataStorages[storageIndex], timestamp: timestamp))
        }

        self.log = window
    }
}

extension RequestLog {
    mutating private func append(_ item: Element) {
        if let last = self.log.last {
            assert(last <= item, "Request log is not sorted by timestamp")
        }
        self.log.append(item)
    }

    mutating func append(requestMetadata: RateLimiterRequestMetadata, timestamp: Date) {
        if let existing = self.log.first(where: { $0.requestMetadata == requestMetadata }) {
            self.append(Element(storage: existing.storage, timestamp: timestamp))
        } else {
            self.append(Element(requestMetadata: requestMetadata, timestamp: timestamp))
        }
    }

    mutating func trim(before: Date) {
        while let item = self.log.first, item.timestamp < before {
            _ = self.log.popFirst()
        }
    }

    mutating func trim(now: Date, olderThan: TimeInterval) {
        self.trim(before: now - olderThan)
    }

    mutating func filterToMatches(now: Date, rateLimitConfigurations: RateLimitConfigurationSet, timeout: TimeInterval) {
        // rdar://132412091 (Introduce more aggressive rate limiter trimming)

        // This is a bit of a compromise; it is a low-risk change late in CrystalB that is
        // intended to keep the request log a manageable size given that we store the whole
        // thing. It means that when a new rate limit config comes along, we might not have
        // a history of requests to apply when computing it; that's OK. New rate limits apply
        // to the future, not the past. NB: We cannot fail to "append" these requests because
        // when a request is issued, its response may need to install a rate limit that
        // applies to it, and which we don't yet know at append-time.

        self.log.removeAll {
            let isOld = $0.timestamp < now - timeout
            let isRelevant = rateLimitConfigurations.hasMatching(now: now, $0.requestMetadata)
            return isOld && !isRelevant
        }
    }

    func count(after: Date, where predicate: @Sendable (RateLimiterRequestMetadata) -> Bool) -> UInt {
        return self.log.reduce(0) { count, item in
            if item.timestamp >= after, predicate(item.requestMetadata) {
                return count + 1
            } else {
                return count
            }
        }
    }

    func count(after: Date, filteredBy: RateLimitFilter) -> UInt {
        return self.count(after: after) { metadata in
            filteredBy.matches(metadata)
        }
    }

    func count(now: Date, newerThan: TimeInterval, filteredBy: RateLimitFilter) -> UInt {
        return self.count(after: now - newerThan, filteredBy: filteredBy)
    }

    func first(after: Date, where predicate: @Sendable (RateLimiterRequestMetadata) -> Bool) -> Element? {
        return self.log.first { item in
            return item.timestamp >= after && predicate(item.requestMetadata)
        }
    }

    func first(after: Date, filteredBy: RateLimitFilter) -> Element? {
        return self.first(after: after) { metadata in
            filteredBy.matches(metadata)
        }
    }

    func first(now: Date, newerThan: TimeInterval, filteredBy: RateLimitFilter) -> Element? {
        return self.first(after: now - newerThan, filteredBy: filteredBy)
    }
}

extension RequestLog {
    mutating func trimToMaximumTtl(now: Date, config: any Configuration) {
        return self.trim(now: now, olderThan: config[.rateLimiterMaximumRateLimitTtl])
    }
}
