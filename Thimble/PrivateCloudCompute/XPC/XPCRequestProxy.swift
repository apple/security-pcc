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
//  XPCRequestProxy.swift
//  PrivateCloudCompute
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

import os.log

// We require that XPCRequestProxyProtocol are also Sendable because
// they are used from onCancel blocks, which are Sendable.
package protocol XPCRequestProxyProtocol: Sendable {
    func cancel()
    func close()
    func send(data: Data, isComplete: Bool) async throws
    func next() async throws -> Data?

    func send(message: XPCRequestMessage) async throws
    func next() async throws -> XPCResponseMessage?

    func createSubrequest(_ subrequest: XPCSubrequest) async throws

    func nextProgress() async throws -> PrivateCloudComputeConnection.Progress?
}

private let logger = tc2Logger(forCategory: .client)

struct XPCRequestProxy<
    Proxy: TC2XPCTrustedRequestProtocol,
    Wrapper: XPCWrapperProtocol
>: XPCRequestProxyProtocol where Wrapper.RequestProxy == Proxy {
    private let connectionID: Int
    private let proxy: Proxy
    private let wrapper: Wrapper

    init(connectionID: Int, proxy: Proxy, wrapper: Wrapper) {
        self.connectionID = connectionID
        self.proxy = proxy
        self.wrapper = wrapper
    }

    func cancel() {
        Task {
            await self.wrapper.cancel(connectionID: self.connectionID, proxy: self.proxy)
        }
    }

    func close() {
        Task {
            await self.wrapper.close(connectionID: self.connectionID, proxy: self.proxy)
        }
    }

    /// Used for non multi-turn requests.
    func send(data: Data, isComplete: Bool) async throws {
        try await self.wrapper.send(connectionID: self.connectionID, proxy: self.proxy, message: .data(data, isComplete))
    }

    /// Used for non multi-turn requests.
    func next() async throws -> Data? {
        while let message = try await self.wrapper.next(connectionID: self.connectionID, proxy: self.proxy) {
            switch message {
            case .openSubresponse, .closeSubresponse, .subresponseData:
                // These messages shouldn't be received for non multi-turn requests.
                logger.error("Unexpectedly received a multi-turn message, ignoring. message=\(String(describing: message))")
                break
            case .data(let data):
                return data
            }
        }

        return nil
    }

    func send(message: XPCRequestMessage) async throws {
        try await self.wrapper.send(connectionID: self.connectionID, proxy: self.proxy, message: message)
    }

    func createSubrequest(_ subrequest: XPCSubrequest) async throws {
        try await self.wrapper.createSubrequest(connectionID: self.connectionID, proxy: self.proxy, subrequest: subrequest)
    }

    /// Used for multi-turn requests.
    func next() async throws -> XPCResponseMessage? {
        try await self.wrapper.next(connectionID: self.connectionID, proxy: self.proxy)
    }

    func nextProgress() async throws -> PrivateCloudComputeConnection.Progress? {
        try await self.wrapper.nextProgress(connectionID: self.connectionID, proxy: self.proxy)
    }
}
