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
//  TC2DaemonProtocol.swift
//  PrivateCloudCompute
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

import Foundation

/// The protocol defining communication between the framework and the daemon.
@objc package protocol TC2DaemonProtocol: Sendable {
    func currentEnvironment(completion: @escaping @Sendable (String) -> Void)
    /// Tests connection to daemon. Should return the same string passed in.
    func echo(text: String, completion: @escaping @Sendable (String) -> Void)
    func request(
        parametersData: RequestParameters.Data,
        completion: @escaping @Sendable ((any TC2XPCTrustedRequestProtocol)?, Data?) -> Void
    )
    func prefetchRequest(workloadType: String, workloadParameters: [String: String], completion: @escaping @Sendable (Data?) -> Void)
    func prewarmRequest(parametersData: PrewarmParameters.Data, completion: @escaping @Sendable () -> Void)
    func prefetchCache(completion: @escaping @Sendable ([String]) -> Void)
    func prefetchParametersCache(completion: @escaping @Sendable ([String]) -> Void)
    func prefetchParametersCacheSavedState(completion: @escaping @Sendable ([String]) -> Void)
    func prefetchCacheReset(completion: @escaping @Sendable (Bool) -> Void)
    func knownRateLimits(bundleIdentifier: String?, featureIdentifier: String?, completion: @escaping @Sendable (Data?) -> Void)
    func listRateLimits(bundleIdentifier: String?, featureIdentifier: String?, fetch: Bool, completion: @escaping @Sendable (Data?) -> Void)
    func addRateLimit(
        source: RateLimitSource.RawValue,
        bundleIdentifier: String?,
        featureIdentifier: String?,
        workloadType: String?,
        count: UInt,
        duration: Double,
        ttl: Double,
        jitter: Double,
        completion: @escaping @Sendable () -> Void
    )
    func resetRateLimits(completion: @escaping @Sendable (Data?) -> Void)
    func fetchServerDrivenConfiguration(completion: @escaping @Sendable (Data) -> Void)
    func listServerDrivenConfiguration(completion: @escaping @Sendable (Data) -> Void)
    func setServerDrivenConfiguration(json: Data, completion: @escaping @Sendable (Data) -> Void)
}

@objc package protocol TC2XPCTrustedRequestProtocol: Sendable {
    /// Returns a JSON-encoded `RequestSetupConfiguration` with per-request
    /// settings computed by the daemon (e.g. chunk size).
    func prepare(completion: @escaping @Sendable (Data?) -> Void)

    /// Takes data to send, returns an error data blob (PrivateCloudComputeError), if an error occurs
    func send(data: XPCRequestMessage.Data, completion: @escaping @Sendable (Data?) -> Void)

    /// Asks for more response data, returns data, if successful (first response parameter). Returns an error data blob
    /// (PrivateCloudComputeError, second response parameter), if an error occurs
    func next(completion: @escaping @Sendable (XPCResponseMessage.Data?, Data?) -> Void)

    /// Cancel the running request. We need a completion handler here, since we won't receive the cancel call in the
    /// daemon otherwise.
    func cancel(completion: @escaping @Sendable () -> Void)

    /// Close the running request. We need a completion handler here, since we won't receive the cancel call in the
    /// daemon otherwise.
    func close(completion: @escaping @Sendable () -> Void)

    /// Waits until Swift Task running PCC request on the daemon side finishes and will cancel that Swift Task if it takes too long.
    func waitForRequestCompletion(completion: @escaping @Sendable () -> Void)

    /// Takes data of the XPCSubrequest, returns an error data blob (PrivateCloudComputeError), if an error occurs
    func createSubrequest(request: XPCSubrequest.Data, completion: @escaping @Sendable (Data?) -> Void)

    /// Returns next progress update for the request or nil when there will be no more updates.
    func nextProgress(completion: @escaping @Sendable (PrivateCloudComputeConnection.Progress.Data?) -> Void)
}

package func interfaceForTC2DaemonProtocol() -> NSXPCInterface {
    let ret = NSXPCInterface(with: (any TC2DaemonProtocol).self)
    ret.setInterface(
        NSXPCInterface(with: (any TC2XPCTrustedRequestProtocol).self),
        for: #selector(
            (any TC2DaemonProtocol).request(
                parametersData:completion:
            )
        ),
        argumentIndex: 0,
        ofReply: true
    )
    return ret
}
