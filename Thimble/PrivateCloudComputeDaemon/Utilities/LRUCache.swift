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
//  LRUCache.swift
//  PrivateCloudCompute
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

import Foundation
import PrivateCloudCompute
import Synchronization
import os.log

private let logger = Logger(for: .daemon)

// This type is responsible for remembering the `maxCount` most recent elements
// across restarts. It is used by the background prefetch activity to know which
// workloads to prefetch for. `maxAge` specifies a TimeInterval beyond which
// elements should be expired and discarded, which is accomplished by `trim`.

private let oldWorkloadCacheFilename = "lrucache3.plist"
let workloadCacheFilename = "workloadcache_v2.plist"

protocol LRUCacheProtocol<Value>: Sendable {
    associatedtype Value: Hashable & Sendable & Codable
    mutating func addToCache(now: Date, value: Value) -> Bool
    func getCachedEntries(now: Date) -> [Value]
    func saveState(now: Date)
    mutating func loadState(now: Date)
    func deleteSavedState()
    func statistics(now: Date) -> (count: Int, oldestAgeInDays: Int)
}

package final class LRUCache<Value: Hashable & Sendable & Codable>: LRUCacheProtocol {
    private let maxCount: Int
    private let maxAge: TimeInterval
    private let storeURL: URL?
    private let encoder = PropertyListEncoder()
    private let decoder = PropertyListDecoder()

    private struct DatedValue: Hashable & Sendable & Codable {
        var date: Date
        var value: Value
    }

    private struct State {
        var memCache: [DatedValue] = []
    }

    private let state: Mutex<State>

    package init(maxCount: Int, maxAge: TimeInterval, storeURL: URL?) {
        self.maxCount = maxCount
        self.maxAge = maxAge
        encoder.outputFormat = .binary
        if let storeURL {
            self.storeURL = storeURL.appending(path: workloadCacheFilename)
            removeDaemonStateFile(url: storeURL.appending(path: oldWorkloadCacheFilename))
        } else {
            self.storeURL = nil
        }

        self.state = Mutex(State())

        logger.debug("initialized workloadcache, file=\(self.storeURL?.absoluteString ?? "")")
    }

    private func trim(_ state: inout State, now: Date) {
        state.memCache.removeAll { $0.date < now - maxAge }
    }

    /// Returns true if an entry existed in the cache for the given key
    package func addToCache(now: Date = Date.now, value: Value) -> Bool {
        let exists = state.withLock { [maxCount] state in
            self.trim(&state, now: now)
            if let index = state.memCache.firstIndex(where: { $0.value == value }) {
                state.memCache.remove(at: index)
                state.memCache.append(DatedValue(date: now, value: value))
                return true
            } else {
                let count = state.memCache.count
                if count >= maxCount {
                    state.memCache.removeFirst(count - maxCount + 1)
                }
                state.memCache.append(DatedValue(date: now, value: value))
                return false
            }
        }

        saveState(now: now)
        return exists
    }

    /// Ordered by least recently used element being at the beginning, and most recently used element being at the end.
    package func getCachedEntries(now: Date = Date.now) -> [Value] {
        let cachedValue = state.withLock { state in
            self.trim(&state, now: now)
            return state.memCache.map { $0.value }
        }
        return cachedValue
    }

    package func saveState(now: Date = Date.now) {
        guard let storeURL else {
            logger.info("declining to persist lrucache without location")
            return
        }

        state.withLock { state in
            self.trim(&state, now: now)
            do {
                let serialized = try encoder.encode(state.memCache)
                try serialized.write(to: storeURL)
            } catch {
                logger.error("failed to archive LRUCache: \(error)")
            }
        }
    }

    package func loadState(now: Date = Date.now) {
        guard let storeURL else {
            return
        }

        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            return
        }

        do {
            let serialized = try Data(contentsOf: storeURL)
            var cachedValues = try decoder.decode([DatedValue].self, from: serialized)
            if cachedValues.count > self.maxCount {
                logger.log("trimming archive, count=\(cachedValues.count), maxCount=\(self.maxCount)")
                cachedValues = cachedValues.suffix(self.maxCount)
            }

            state.withLock { [cachedValues] state in
                state.memCache = cachedValues
                self.trim(&state, now: now)
            }
        } catch {
            logger.error("failed to unarchive LRUCache: \(error)")
            deleteSavedState()
        }
    }

    package func deleteSavedState() {
        guard let storeURL else {
            return
        }

        if FileManager.default.fileExists(atPath: storeURL.path) {
            do {
                try FileManager.default.removeItem(at: storeURL)
            } catch {
                logger.log("failed to delete archive")
            }
        }
    }

    /// The "day" in `oldestAgeInDays` is defined as 24 hours interval. Device's timezone doesn't make any difference.
    /// The value is rounded down. E.g. if the oldest value in cache is 23 hours old, it will be reported as 0 days old. If it's
    /// 25 hours old - it will be reported as 1 day old.
    /// We use "days" to avoid a possibility of correlating the age with user behavior.
    package func statistics(now: Date) -> (count: Int, oldestAgeInDays: Int) {
        state.withLock { state in
            self.trim(&state, now: now)
            let count = state.memCache.count
            if let oldest = state.memCache.min(by: { $0.date < $1.date })?.date {
                let oldestAgeInDays = Int(now.timeIntervalSince(oldest) / .hours(24))
                return (count, oldestAgeInDays)
            }
            return (count, 0)
        }
    }
}

typealias WorkloadLRUCache = LRUCache<Workload>
