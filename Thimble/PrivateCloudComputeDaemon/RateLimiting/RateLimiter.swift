// Copyright © 2025 Apple Inc. All Rights Reserved.

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
//  RateLimiter.swift
//  PrivateCloudCompute
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

internal import CollectionsInternal
import Foundation
import PrivateCloudCompute
import os.log

// MARK: - RateLimiter

final actor RateLimiter: RateLimiterProtocol {

    private struct RateLimitModel: Codable {
        // The rate limiter, which is like a singleton, keeps its state in four parts:

        // This is the list of all the current rate limiting configurations that are known
        // to the system. We add and expire configs, and the set is capable of matching requests
        // as they happen.
        var rateLimitConfigurations: RateLimitConfigurationSet

        // This is the list of actual requests and their timestamps. We need to know them because
        // in order to know whether the request rate is too high, we need a window into the history
        // of requests.
        var requestLog: RequestLog

        // This is a cache (see comments in the type) of denials that we are currently enforcing
        // against incoming requests.
        var deniedLog: DeniedRequestLog

        // This is another log of requests, which tracks the "session" UUID count through the
        // session TTL window. It allows us to compute how far along we are in the session, so that
        // we can let ROPES know. We store it separately from the full request log because it is
        // implicated on every request.
        var sessionLog: SessionLog

        mutating func reset() {
            self.rateLimitConfigurations = RateLimitConfigurationSet()
            self.requestLog = RequestLog()
            self.deniedLog = DeniedRequestLog()
            self.sessionLog = SessionLog()
        }
    }

    static let filename = "ratelimitmodel_v3.plist"
    private let encoder = PropertyListEncoder()
    private let decoder = PropertyListDecoder()
    private let logger = tc2Logger(forCategory: .rateLimiter)
    private let file: URL
    private var model: RateLimitModel
    private let config: any Configuration
    private let rateLimitUnmatchedRequestStorageTimeout: TimeInterval

    init(config: any Configuration, from url: URL) {
        self.config = config
        let file = url.appending(path: Self.filename)
        self.file = file
        self.rateLimitUnmatchedRequestStorageTimeout = config[.rateLimitUnmatchedRequestStorageTimeout]

        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            logger.log("persistence does not yet exist, or unable to read persisted ratelimiter, file=\(file), error=\(error)")
            self.model = RateLimitModel(rateLimitConfigurations: RateLimitConfigurationSet(), requestLog: RequestLog(), deniedLog: DeniedRequestLog(), sessionLog: SessionLog())
            return
        }

        do {
            self.model = try decoder.decode(RateLimitModel.self, from: data)
        } catch {
            logger.error("unable to decode persisted ratelimiter, error=\(error)")
            self.model = RateLimitModel(rateLimitConfigurations: RateLimitConfigurationSet(), requestLog: RequestLog(), deniedLog: DeniedRequestLog(), sessionLog: SessionLog())
        }

        logger.debug("initialized ratelimiter, file=\(file)")
    }

    static func migrate(from source: URL, to destination: URL) {
        let sourceFile = source.appending(path: Self.filename)
        let destinationFile = destination.appending(path: Self.filename)
        moveDaemonStateFile(from: sourceFile, to: destinationFile)
    }

    // The amount of data we have to save here is bounded by the various ttl and
    // expirations; nonetheless we should consider a more resilient storage
    // strategy with more resilience, such as a SwiftData container.
    func save() async {
        let data: Data
        do {
            data = try encoder.encode(self.model)
        } catch {
            logger.error("unable to encode persisted ratelimiter, error=\(error)")
            return
        }

        do {
            try await doThrowingBlockingIOWork { try data.write(to: self.file) }
        } catch {
            logger.error("unable to write persisted ratelimiter, file=\(self.file), error=\(error)")
        }

        logger.debug("wrote persisted ratelimiter, file=\(self.file)")
    }

}

extension RateLimiter {
    // This is the test of whether a request should be denied. If so, it returns a rate limit with enough information
    // to describe why the denial happened, and what the timing concerns are. If the request can proceed, it returns
    // nil.
    func rateLimitDenialInfo(now: Date = Date.now, for requestMetadata: RateLimiterRequestMetadata, sessionID: UUID?) -> RateLimitInfo? {
        // First of all, do we know of a denial?
        if let newRateLimit = self.model.deniedLog.knownDenied(now: now, requestMetadata: requestMetadata) {
            logger.error("rate limit applied from cached denials")
            return newRateLimit
        }

        // If we have a session, get its progress--we'll need it for rate limit softening
        lazy var sessionProgress = sessionID.flatMap { self.sessionProgress(now: now, for: $0) } ?? 0

        // Since there is no record of a denial, we need to check the configs.
        // The first config we find that has been violated is what we use.
        let matchingConfigurations = self.model.rateLimitConfigurations.matching(now: now, requestMetadata)
        for config in matchingConfigurations {

            if config.timing.count == 0 {
                // This is a matching config that does not allow any requests. No
                // need to consult anything, it's a definite denial.
                logger.error("rate limit applied for rate with count=0")
                let retryAfterDate = now + config.timing.duration + config.timing.jitter * Double.random(in: 0.0..<1.0)
                let newRateLimit = RateLimitInfo(rateLimitConfig: config, retryAfterDate: retryAfterDate)
                self.model.deniedLog.append(requestMetadata: requestMetadata, rateLimitInfo: newRateLimit)
                return newRateLimit
            }

            // We have a matching config, with count > 0. We need to know whether
            // to deny the request, which is to say whether too many requests have
            // been issued so far.
            let existingRequestCount = self.model.requestLog.count(now: now, newerThan: config.timing.duration, filteredBy: config.filter)

            let shouldDeny: Bool
            if sessionProgress == 0 {
                // This is the first request in a session--measure for real.
                shouldDeny = existingRequestCount >= config.timing.count
                if shouldDeny {
                    logger.error("rate limit applied for rate with count=\(config.timing.count), duration=\(config.timing.duration)")
                }
            } else {
                assert(sessionProgress > 0)
                // The session length considered needs to be at least one (one
                // is basically how you turn this softening feature off).
                let rateLimiterSessionLengthForSoftening = UInt(max(self.config[.rateLimiterSessionLengthForSoftening], 1))
                // We are mid-session, and as a result we are willing to overlook
                // rate limiting up to a point. Note that the config value here
                // describes the longest session we need to account for, which is
                // why there is a -1 (we already ran the first request in the session).
                let extraRequests = rateLimiterSessionLengthForSoftening - 1

                switch existingRequestCount {
                case ..<config.timing.count:
                    // Within normal limits
                    shouldDeny = false
                case config.timing.count..<(config.timing.count + extraRequests):
                    // Within mid-session softened limits
                    shouldDeny = false
                    logger.info("rate limit softened for rate with count=\(config.timing.count), duration=\(config.timing.duration), sessionProgress=\(sessionProgress)")
                default:  // case (config.timing.count + extraRequests)...:
                    // Beyond all limits
                    shouldDeny = true
                    logger.error("rate limit applied for rate with count=\(config.timing.count), duration=\(config.timing.duration), sessionProgress=\(sessionProgress)")
                }
            }

            if shouldDeny {
                // uh oh!
                let firstRequest = self.model.requestLog.first(now: now, newerThan: config.timing.duration, filteredBy: config.filter)
                // Our retry-after is going to be the timestamp of this first request, plus the duration in the rate.
                // Because at that point in time, this request will fall off the log and the request will succeed (or
                // at least not fail due to this config).
                let retryAfterDate = firstRequest!.timestamp + config.timing.duration + config.timing.jitter * Double.random(in: 0.0..<1.0)
                let newRateLimit = RateLimitInfo(rateLimitConfig: config, retryAfterDate: retryAfterDate)
                self.model.deniedLog.append(requestMetadata: requestMetadata, rateLimitInfo: newRateLimit)
                return newRateLimit
            }
        }

        logger.info("no rate limit applied from among matching configurations with count=\(matchingConfigurations.count)")
        return nil
    }

    func applicableConfigs(now: Date = Date.now, bundleIdentifier: String?, featureIdentifier: String?) -> [TrustedCloudComputeRateLimit] {
        let configs = self.model.rateLimitConfigurations.applicableWhen(now: now, bundleIdentifier: bundleIdentifier, featureIdentifier: featureIdentifier)

        return configs.map { config in
            let workloadParameters = config.filter.workloadTags.map { tag in TrustedCloudComputeRateLimit.WorkloadParameter(key: tag.key, value: tag.value) }
            let loggedCountSoFar = self.model.requestLog.count(now: now, newerThan: config.timing.duration, filteredBy: config.filter)
            return TrustedCloudComputeRateLimit(
                bundleIdentifier: config.filter.bundleID,
                featureIdentifier: config.filter.featureID,
                workloadType: config.filter.workloadType,
                workloadParameters: workloadParameters,
                count: config.timing.count,
                duration: config.timing.duration,
                jitter: config.timing.jitter,
                ttlExpiration: config.timing.ttlExpiration,
                loggedCountSoFar: loggedCountSoFar)
        }
    }

    func appendSuccessfulRequest(requestMetadata: RateLimiterRequestMetadata, sessionID: UUID?, timestamp: Date) async {
        logger.debug("ratelimiter remembering completed request")
        self.model.requestLog.append(requestMetadata: requestMetadata, timestamp: timestamp)
        if let sessionID {
            self.model.sessionLog.append(session: sessionID, timestamp: timestamp, config: config)
        }
        await self.save()
    }

    func limitByConfiguration(_ config: RateLimitConfiguration) {
        logger.info("rate limit discovered for rate with count=\(config.timing.count), duration=\(config.timing.duration)")
        self.model.rateLimitConfigurations.add(config)
        self.model.deniedLog.updateWithNewConfig(config)
    }

    func sessionProgress(now: Date = Date.now, for session: UUID) -> UInt {
        return self.model.sessionLog.count(now: now, newerThan: config[.rateLimiterSessionTimeout], session: session)
    }

    func trimExpiredData(now: Date = Date.now) {
        logger.debug("ratelimiter undergoing trim")
        self.model.rateLimitConfigurations.trimExpired(now: now)
        self.model.requestLog.trimToMaximumTtl(now: now, config: config)
        self.model.requestLog.filterToMatches(now: now, rateLimitConfigurations: self.model.rateLimitConfigurations, timeout: self.rateLimitUnmatchedRequestStorageTimeout)
        self.model.sessionLog.trimToMaximumTtl(now: now, config: config)
        self.model.deniedLog.trimExpired(now: now)
    }

    func reset() async {
        logger.info("ratelimiter is being reset")
        self.model.reset()
        await self.save()
    }
}

extension RateLimitInfo {
    init(rateLimitConfig: RateLimitConfiguration, retryAfterDate: Date) {
        self.init(
            bundleID: rateLimitConfig.filter.bundleID,
            featureID: rateLimitConfig.filter.featureID,
            workloadType: rateLimitConfig.filter.workloadType,
            workloadTags: rateLimitConfig.filter.workloadTags.map { RateLimitInfo.WorkloadTag(key: $0.key, value: $0.value) },
            count: rateLimitConfig.timing.count,
            duration: rateLimitConfig.timing.duration,
            retryAfterDate: retryAfterDate)
    }
}
