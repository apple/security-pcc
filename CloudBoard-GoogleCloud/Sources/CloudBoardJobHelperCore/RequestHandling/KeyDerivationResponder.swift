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

import CloudBoardProtos
import CloudBoardUtilities
import Crypto
import Logging

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Services the cloud app's key-derivation requests on the `cb_jobhelper` side.
///
/// The cloud app sends `KeyDerivationRequest`s on the response stream. `onResponse` hands each to
/// `accept(_:)`, which enqueues it and returns immediately, so the response-reading loop never
/// blocks on derivation. `run(writingResultsInto:)` drains the queue, derives via `HKDF<SHA256>`
/// under the `"dek-derived-key"` domain-separation prefix (see `RequestSecrets`), and writes each
/// `KeyDerivationResult` into the outgoing request funnel — the single request writer — so the
/// result travels back without racing other request writes.
struct KeyDerivationResponder: Sendable {
    private static let logger = Logger(label: "cb_jobhelper.KeyDerivationResponder")

    private let requestSecrets: RequestSecrets
    private let requests: AsyncStream<Proto_CloudApp_InvokeWorkloadResponse.KeyDerivationRequest>
    private let requestsContinuation:
        AsyncStream<Proto_CloudApp_InvokeWorkloadResponse.KeyDerivationRequest>.Continuation

    init(requestSecrets: RequestSecrets) {
        self.requestSecrets = requestSecrets
        (self.requests, self.requestsContinuation) = AsyncStream.makeStream()
    }

    /// Enqueues a derivation request and returns immediately. The derivation and reply happen in
    /// `run(writingResultsInto:)`, keeping HKDF work off the response-reading loop.
    func accept(_ request: Proto_CloudApp_InvokeWorkloadResponse.KeyDerivationRequest) {
        Self.logger.info(
            "Received key derivation request from cloud app",
            metadata: [
                "derivationID": "\(request.derivationID)",
                "outputByteCount": "\(request.outputByteCount)",
            ]
        )
        self.requestsContinuation.yield(request)
    }

    /// Drains accepted requests, deriving each key and writing the `KeyDerivationResult` into
    /// `outgoing` — the single-writer request funnel. Returns once `finishAcceptingRequests()`
    /// closes the queue.
    func run(
        writingResultsInto outgoing: AsyncStream<Proto_CloudApp_InvokeWorkloadRequest>.Continuation
    ) async {
        for await request in self.requests {
            outgoing.yield(self.result(for: request))
        }
    }

    /// Stops a running `run(writingResultsInto:)` by finishing the request queue; called at RPC
    /// teardown so the drain task can complete. Safe to call more than once.
    func finishAcceptingRequests() {
        self.requestsContinuation.finish()
    }

    func result(
        for request: Proto_CloudApp_InvokeWorkloadResponse.KeyDerivationRequest
    ) -> Proto_CloudApp_InvokeWorkloadRequest {
        let derivedKey: SymmetricKey
        do {
            // `RequestSecrets.deriveKey` enforces the HKDF output-length bound and throws if the
            // request is out of range, so a bad request is reported back rather than crashing here.
            derivedKey = try self.requestSecrets.deriveKey(
                info: Data(("dek-derived-key" + request.info).utf8),
                outputByteCount: Int(request.outputByteCount)
            )
        } catch {
            Self.logger.error(
                "Rejecting key derivation request",
                metadata: [
                    "derivationID": "\(request.derivationID)",
                    "outputByteCount": "\(request.outputByteCount)",
                    "error": "\(String(reportable: error))",
                ]
            )
            return .with {
                $0.keyDerivationResult = .with {
                    $0.derivationID = request.derivationID
                    $0.error = "\(error)"
                }
            }
        }
        Self.logger.info(
            "Derived key for cloud app request",
            metadata: [
                "derivationID": "\(request.derivationID)",
                "outputByteCount": "\(request.outputByteCount)",
            ]
        )
        var result = Proto_CloudApp_InvokeWorkloadRequest.KeyDerivationResult()
        result.derivationID = request.derivationID
        result.derivedKey = derivedKey.withUnsafeBytes { Data($0) }
        return .with { $0.keyDerivationResult = result }
    }
}
