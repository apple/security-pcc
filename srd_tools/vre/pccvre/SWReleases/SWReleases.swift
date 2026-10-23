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

//  Copyright © 2024 Apple, Inc. All rights reserved.
//

import Foundation
import os

private let fetchWindowSize: UInt64 = 100

typealias SWReleasesError = TransparencyLogError

// SWReleases is a set of Private Compute OS/TIE release bundles published to the SW Transparency log
public struct SWReleases: RandomAccessCollection {
    public var startIndex: Int { 0 }
    public var endIndex: Int { releases.count }
    public var indices: Indices { releases.indices }
    public subscript(i: Int) -> Release { releases[i] }
    public subscript(bounds: Range<Int>) -> ArraySlice<Release> { releases[bounds] }

    private var swlog: TransparencyLog
    private var releases: [Release] = []
    private(set) var skippedLeaves: [TransparencyLog.ATLeaf] = []
    var skippedIndices: [UInt64] { skippedLeaves.map { $0.index } }
    private(set) var hasMore: Bool = false
    public var count: Int { releases.count }

    static var logger: Logger { TransparencyLog.logger }
    static var traceLog: Bool { TransparencyLog.traceLog }

    init(
        environment: TransparencyLog.Environment,
        altKtInitEndpoint: URL? = nil,
        traceLog: Bool = false
    ) async throws {
        self.swlog = try await TransparencyLog(
            environment: environment,
            altKtInitEndpoint: altKtInitEndpoint,
            traceLog: traceLog
        )
    }

    @discardableResult
    mutating func fetchReleases(
        helper: PCCVREAttestationHelperResolver?, // nil = decode v1 only; v2 leaves get skipped
        reqCount: UInt, // requested number of releases
        includeAll: Bool = false, // include expired & duplicate releases
        searchRangeStart: Int64? = nil, // log index search windows
        searchRangeEnd: UInt64? = nil,
        batchSize: UInt64 = 10000,
        altEndpoint: URL? = nil
    ) async throws -> Int {
        var releases: [Release] = []
        let tree = try await swlog.fetchLogTree()
        let head = try await swlog.fetchLogHead(logTree: tree)

        let logIndexMax = head.size // last index in the log
        // searchIndexHighest/searchIndexLowest are the index limits of the Transparency Log within
        //   which the search remains.
        //   - searchIndexHighest is capped to logIndexMax
        //   - searchIndexLowest is relative to searchIndexHighest (if searchRangeStart < 0) or
        //      absolute index, with floor at 0 (start of log)
        let searchIndexHighest = UInt64(Swift.min(logIndexMax, searchRangeEnd ?? logIndexMax))
        let searchIndexLowest: UInt64
        if let searchRangeStart {
            if searchRangeStart < 0 {
                // UInt64 subtraction traps on underflow; clamp first so callers
                // can pass `-N` against logs shorter than N entries.
                let lookback = UInt64(-searchRangeStart)
                searchIndexLowest = lookback >= searchIndexHighest ? 0 : searchIndexHighest - lookback
            } else {
                searchIndexLowest = UInt64(searchRangeStart)
            }
        } else {
            searchIndexLowest = 0
        }
        guard searchIndexLowest < searchIndexHighest else {
            throw TransparencyLogError("invalid search window range")
        }

        // fetchWindowStart/Last is a sliding window (of upto batchSize) of indexes to retrieve
        //  from the server; we start the fetchWindow at searchLastIndex and work -backwards- towards
        //  searchIndexLowest, sliding the fetchWindow backwards to that point or have obtained
        //  reqCount SWReleases entries obtained.
        //
        var fetchWindowLast = searchIndexHighest
        var fetchWindowStart = Swift.max(searchIndexLowest,
                                         fetchWindowLast - Swift.min(fetchWindowLast, batchSize))

        repeat {
            // while fetchLogLeaves can batch, it moves forward; when enumerating releases,
            //  we generally want newer first, using smaller batches - additional filtering
            //  here often has us going back for more (with a new connection)
            let leaves = try await swlog.fetchLogLeaves(
                type: TransparencyLog.ATLeaf.self,
                tree: tree,
                head: head,
                start: fetchWindowStart,
                end: fetchWindowLast,
                batchSize: batchSize,
                dataType: .release,
                altEndpoint: altEndpoint
            )

            // This `where` clause can be removed once all server instances support filtering by type
            for leaf in leaves where leaf.nodeData.type == .RELEASE {
                do {
                    releases.append(try await Release(leaf: leaf, helper: helper))
                } catch {
                    skippedLeaves.append(leaf)
                }
            }

            if !includeAll {
                // trim duplicate entries (same data hash; use latest instance)
                releases = releases.sorted {
                    $0 > $1
                }.uniqued()
            }

            fetchWindowLast = Swift.max(searchIndexLowest,
                                        fetchWindowLast - Swift.min(fetchWindowLast, batchSize))
            fetchWindowStart = Swift.max(searchIndexLowest,
                                         fetchWindowStart - Swift.min(fetchWindowStart, batchSize))
        } while releases.count < reqCount && fetchWindowLast > searchIndexLowest

        self.hasMore = releases.count >= reqCount && fetchWindowLast > searchIndexLowest

        releases = releases.sorted { // final sort of the batch
            $0 > $1
        }

        self.releases = releases
        return releases.count
    }
}
