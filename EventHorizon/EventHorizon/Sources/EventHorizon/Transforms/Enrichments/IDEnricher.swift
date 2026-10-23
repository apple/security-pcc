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


import Foundation
#if canImport(os)
import os
#endif


private struct NameCacheEntry: Sendable {
    let name: String
    let expirationTime: Date

    var isExpired: Bool {
        Date() > expirationTime
    }
}

private actor NameCache {
    private let cache: LRUCache<UInt32, NameCacheEntry>
    private let cacheDuration: TimeInterval
    private let maxCacheSize: Int

    init(cacheDuration: TimeInterval = 300, maxCacheSize: Int = 1000) {
        self.cacheDuration = cacheDuration
        self.maxCacheSize = maxCacheSize
        self.cache = LRUCache<UInt32, NameCacheEntry>(totalCount: maxCacheSize)
    }

    func get(_ id: UInt32) -> String? {
        guard let entry = cache[id] else {
            return nil
        }

        if entry.isExpired {
            cache[id] = nil
            return nil
        }

        return entry.name
    }

    func set(_ id: UInt32, name: String) {
        let expirationTime = Date().addingTimeInterval(cacheDuration)
        let entry = NameCacheEntry(name: name, expirationTime: expirationTime)
        cache[id] = entry
    }

    func clear() {
        cache.removeAll()
    }

    func pruneExpired() {
        let expiredKeys = cache.compactMap { key, entry in
            entry.isExpired ? key : nil
        }

        for key in expiredKeys {
            cache[key] = nil
        }
    }

    var count: Int {
        cache.count
    }
}


private final class IDNameEnricher: Sendable {
    typealias ResolverFunction = @Sendable (UInt32) -> String?
    typealias PropertiesExtractor = @Sendable (any EHUEFEvent) -> ([String]?, [String]?)?

    private let cache: NameCache
    private let resolver: ResolverFunction
    private let propertiesExtractor: PropertiesExtractor
    private let log: EHLog.EHLoggerType
    private let enricherName: String

    init(
        cacheDuration: TimeInterval,
        maxCacheSize: Int,
        enricherName: String,
        log: EHLog.EHLoggerType,
        resolver: @escaping ResolverFunction,
        propertiesExtractor: @escaping PropertiesExtractor
    ) {
        self.cache = NameCache(cacheDuration: cacheDuration, maxCacheSize: maxCacheSize)
        self.resolver = resolver
        self.propertiesExtractor = propertiesExtractor
        self.log = log
        self.enricherName = enricherName
    }

    func process(_ event: any EHUEFEvent) async -> EHTransformReturn {
        guard let (id_fields, id_properties) = propertiesExtractor(event) else {
            return (.proceed, nil, nil, nil)
        }

        var mutatedEvent = event
        var wasModified = false

        if let idFields = id_fields {
            for fieldName in idFields {
                if let fieldValue = event.fields[fieldName],
                   let id = extractID(from: fieldValue),
                   let name = await lookupName(for: id) {
                    mutatedEvent.fields["\(fieldName)_name"] = .string(name)
                    wasModified = true
                }
            }
        }

        if let idProperties = id_properties {
            for propertyName in idProperties {
                if let id = extractPropertyValue(from: event, propertyName: propertyName),
                   let name = await lookupName(for: id) {
                    mutatedEvent.fields["\(propertyName)_name"] = .string(name)
                    wasModified = true
                }
            }
        }

        return wasModified ? (.proceed_mutated, [mutatedEvent], nil, nil) : (.proceed, nil, nil, nil)
    }


    private func extractID(from value: EHValueType) -> UInt32? {
        switch value {
        case .int(let intValue):
            return UInt32(exactly: intValue)
        default:
            return nil
        }
    }

    private func extractPropertyValue(from event: any EHUEFEvent, propertyName: String) -> UInt32? {
        if let extractable = event as? EHFieldExtractable,
           let value = extractable.fieldValue(for: propertyName) {
            return convertToUInt32(value)
        }
        let mirror = Mirror(reflecting: event)

        for child in mirror.children where child.label == propertyName {
            return convertToUInt32(child.value)
        }

        return nil
    }

    private func convertToUInt32(_ value: Any) -> UInt32? {
        if let id = value as? UInt32 {
            return id
        }
        if let intValue = value as? Int,
           let id = UInt32(exactly: intValue) {
            return id
        }
        if let int64Value = value as? Int64,
           let id = UInt32(exactly: int64Value) {
            return id
        }
        return nil
    }

    private func lookupName(for id: UInt32) async -> String? {
        if let cachedName = await cache.get(id) {
            return cachedName
        }

        guard let name = resolver(id) else {
            return nil
        }

        await cache.set(id, name: name)

        return name
    }
}


public final class UsernameEnricher: EHTransform {
    public protocol UsernameEnrichable {
        func uid_properties() -> ([String]?, [String]?)
    }

    public let name = "UsernameEnricher"
    private let log = EHLog.withCategory(UsernameEnricher.self)
    private let enricher: IDNameEnricher

    public init(cacheDuration: TimeInterval = 300, maxCacheSize: Int = 1000) {
        self.enricher = IDNameEnricher(
            cacheDuration: cacheDuration,
            maxCacheSize: maxCacheSize,
            enricherName: "UsernameEnricher",
            log: log,
            resolver: Self.resolveUsername,
            propertiesExtractor: { event in
                (event as? UsernameEnrichable)?.uid_properties()
            }
        )
    }

    public func process(_ event: any EHUEFEvent) async -> EHTransformReturn {
        await enricher.process(event)
    }

    public func configure() async throws {
    }

    private static func resolveUsername(for uid: UInt32) -> String? {
        var pwd = passwd()
        var result: UnsafeMutablePointer<passwd>?

        #if os(Linux)
        let sysconfSize = sysconf(Int32(_SC_GETPW_R_SIZE_MAX))
        #else
        let sysconfSize = sysconf(_SC_GETPW_R_SIZE_MAX)
        #endif
        let bufferSize = sysconfSize > 0 ? Int(sysconfSize) : 16384
        let buffer = UnsafeMutablePointer<Int8>.allocate(capacity: bufferSize)
        defer {
            buffer.deallocate()
        }

        let status = getpwuid_r(uid, &pwd, buffer, bufferSize, &result)

        guard status == 0, let validResult = result else {
            return nil
        }

        return String(cString: validResult.pointee.pw_name)
    }
}


public final class GroupnameEnricher: EHTransform {
    public protocol GroupnameEnrichable {
        func gid_properties() -> ([String]?, [String]?)
    }

    public let name = "GroupnameEnricher"
    private let log = EHLog.withCategory(GroupnameEnricher.self)
    private let enricher: IDNameEnricher

    public init(cacheDuration: TimeInterval = 300, maxCacheSize: Int = 1000) {
        self.enricher = IDNameEnricher(
            cacheDuration: cacheDuration,
            maxCacheSize: maxCacheSize,
            enricherName: "GroupnameEnricher",
            log: log,
            resolver: Self.resolveGroupname,
            propertiesExtractor: { event in
                (event as? GroupnameEnrichable)?.gid_properties()
            }
        )
    }

    public func process(_ event: any EHUEFEvent) async -> EHTransformReturn {
        await enricher.process(event)
    }

    public func configure() async throws {
    }

    private static func resolveGroupname(for gid: UInt32) -> String? {
        var grp = group()
        var result: UnsafeMutablePointer<group>?

        #if os(Linux)
        let sysconfSize = sysconf(Int32(_SC_GETGR_R_SIZE_MAX))
        #else
        let sysconfSize = sysconf(_SC_GETGR_R_SIZE_MAX)
        #endif
        let bufferSize = sysconfSize > 0 ? Int(sysconfSize) : 16384
        let buffer = UnsafeMutablePointer<Int8>.allocate(capacity: bufferSize)
        defer {
            buffer.deallocate()
        }

        let status = getgrgid_r(gid, &grp, buffer, bufferSize, &result)

        guard status == 0, let validResult = result else {
            return nil
        }

        return String(cString: validResult.pointee.gr_name)
    }
}
