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

import Foundation
package import CloudBoardAsyncXPC

/// Dual of ReuseTarget in the public API
/// Implementation detail: this maps to the proto ReuseConstraints
package struct ReuseTargetConstraints: Hashable, ByteBufferCodable, Sendable {
    public let ensemble: EnsembleInstanceId
    // RackId can't be conformed to ByteBufferCodable at a package level
    public let rack: String?
    public let workloadAdditions: [String: [String]]

    public init(
        ensemble: EnsembleInstanceId,
        rack: RackId? = nil,
        workloadAdditions: [String: [String]] = [:]
    ) {
        self.ensemble = ensemble
        self.rack = rack?.rackId
        self.workloadAdditions = workloadAdditions
    }

    package func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        try self.ensemble.encode(to: &buffer)
        try self.rack.encode(to: &buffer)
        try self.workloadAdditions.encode(to: &buffer)
    }

    package init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        try self.ensemble = .init(from: &buffer)
        try self.rack = .init(from: &buffer)
        try self.workloadAdditions = .init(from: &buffer)
    }
}

/// The information required when a cloud proxy app is asking  for a compute node worker to be found
/// This is used across significant API boundaries in enum cases to avoid repetitive boiler plate
package struct FindWorkerQuery: Hashable, ByteBufferCodable, Sendable {
    public var workerID: UUID
    public var serviceName: String
    public var routingParameters: [String: [String]]
    public var effort: ExpectedEffort
    public var reuseTarget: ReuseTargetConstraints?
    public var responseBypass: Bool
    public var forwardRequestChunks: Bool
    public var isFinal: Bool
    public var spanID: UInt64
    public var groupID: String?
    /// One-Time Token (OTT)
    /// - For request-level: Sourced from ROPES parameters
    /// - For subrequest-level: Sourced from OpenSubrequestPayload
    public var oneTimeToken: Data?
    public var isDiscardable: Bool

    public init(
        workerID: UUID,
        serviceName: String,
        routingParameters: [String: [String]],
        effort: ExpectedEffort?,
        reuseTarget: ReuseTargetConstraints?,
        responseBypass: Bool,
        forwardRequestChunks: Bool,
        isFinal: Bool,
        spanID: UInt64,
        groupID: String? = nil,
        oneTimeToken: Data? = nil,
        isDiscardable: Bool
    ) {
        self.workerID = workerID
        self.serviceName = serviceName
        self.routingParameters = routingParameters
        // from this point on nil verses the empty list can be considered the same
        // because the operations performed on them are per item
        self.effort = effort ?? ExpectedEffort()
        self.reuseTarget = reuseTarget
        self.responseBypass = responseBypass
        self.forwardRequestChunks = forwardRequestChunks
        self.isFinal = isFinal
        self.spanID = spanID
        self.groupID = groupID
        self.oneTimeToken = oneTimeToken
        self.isDiscardable = isDiscardable
    }

    @inlinable
    public func encode(to buffer: inout ByteBuffer) throws {
        try self.workerID.encode(to: &buffer)
        try self.serviceName.encode(to: &buffer)
        try self.routingParameters.encode(to: &buffer)
        try self.effort.encode(to: &buffer)
        try self.reuseTarget.encode(to: &buffer)
        try self.responseBypass.encode(to: &buffer)
        try self.forwardRequestChunks.encode(to: &buffer)
        try self.isFinal.encode(to: &buffer)
        try self.spanID.encode(to: &buffer)
        try self.groupID.encode(to: &buffer)
        try self.oneTimeToken.encode(to: &buffer)
        try self.isDiscardable.encode(to: &buffer)
    }

    public init(from buffer: inout ByteBuffer) throws {
        try self.init(
            workerID: UUID(from: &buffer),
            serviceName: .init(from: &buffer),
            routingParameters: .init(from: &buffer),
            effort: .init(from: &buffer),
            reuseTarget: .init(from: &buffer),
            responseBypass: .init(from: &buffer),
            forwardRequestChunks: .init(from: &buffer),
            isFinal: .init(from: &buffer),
            spanID: .init(from: &buffer),
            groupID: .init(from: &buffer),
            oneTimeToken: .init(from: &buffer),
            isDiscardable: .init(from: &buffer)
        )
    }
}

/// Ensemble selection by progressive sub selection controlling parameters
/// convention is that if a value of this is nillable then nil implies pick is forbidden at all.
/// Since this is also a convenient wire/proto mapping type it is in Domain
package struct PickOptions: ByteBufferCodable, Hashable, Sendable, CustomStringConvertible {
    /// ROPES must provide this many choices of ensemble, will be >= 1
    /// NumProvidedChoices in the negotiate setup message
    package var requiredEnsemblesFromROPES: Int
    /// The proxy will provide this many selections from the initial set, will be >= 1
    /// NumSelectedChoices in the negotiate setup message
    package var allowedEnsemblesFromProxy: Int

    package init(
        requiredEnsemblesFromROPES: Int,
        allowedEnsemblesFromProxy: Int
    ) {
        /// These numbers are driven from config, if fundamentally invalid the system is unusable
        guard requiredEnsemblesFromROPES >= 1, allowedEnsemblesFromProxy >= 1,
              requiredEnsemblesFromROPES >= allowedEnsemblesFromProxy else {
            fatalError(
                "the requiredEnsemblesFromROPES \(requiredEnsemblesFromROPES) and allowedEnsemblesFromProxy \(allowedEnsemblesFromProxy) must both be >= 1 and internally consistent"
            )
        }
        self.requiredEnsemblesFromROPES = Int(requiredEnsemblesFromROPES)
        self.allowedEnsemblesFromProxy = Int(allowedEnsemblesFromProxy)
    }

    package var description: String {
        "\(self.allowedEnsemblesFromProxy) from \(self.requiredEnsemblesFromROPES)"
    }

    package func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        buffer.writeHostInteger(self.requiredEnsemblesFromROPES)
        buffer.writeHostInteger(self.allowedEnsemblesFromProxy)
    }

    package init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        self.requiredEnsemblesFromROPES = try buffer.readHostIntegerOrThrow()
        self.allowedEnsemblesFromProxy = try buffer.readHostIntegerOrThrow()
    }
}

/// Negotiate settings for an InvokeProxyInitiate, maps to the proto NegotiateEnsembleChoice
/// Done *separately* from ``FindWorkerQuery`` because this is not known on the CloudApp side,
/// it's all dealt with in the job helper before passing it on to cloudboardd
package struct Negotiate: ByteBufferCodable, Hashable, Sendable {
    package var trustedEnsembles: EnsembleNegotiation
    package var trustedRackIds: [String]
    package var freeChoice: Bool
    package var pick: PickOptions?

    package init(
        trustedEnsembles: EnsembleNegotiation,
        trustedRackIds: [String],
        freeChoice: Bool,
        pick: PickOptions?
    ) {
        self.trustedEnsembles = trustedEnsembles
        self.trustedRackIds = trustedRackIds
        self.freeChoice = freeChoice
        self.pick = pick
    }

    package func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        try self.trustedEnsembles.encode(to: &buffer)
        try self.trustedRackIds.encode(to: &buffer)
        try self.freeChoice.encode(to: &buffer)
        try self.pick.encode(to: &buffer)
    }

    package init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        try self.trustedEnsembles = .init(from: &buffer)
        try self.trustedRackIds = .init(from: &buffer)
        try self.freeChoice = .init(from: &buffer)
        try self.pick = .init(from: &buffer)
    }

    // MARK: - helpful for tests to express specific common behaviours

    /// The old default, ROPES just chooses
    package static let justFreeChoice = Negotiate(
        trustedEnsembles: EnsembleNegotiation([]),
        trustedRackIds: [],
        freeChoice: true,
        pick: nil
    )

    /// If nothing is trusted and pick must happen,
    /// But for testing purposes this defaults to provide 2, select 1
    package static func mustPick(
        requiredEnsemblesFromROPES: Int = 2,
        allowedEnsemblesFromProxy: Int = 1
    ) -> Negotiate {
        return Negotiate(
            trustedEnsembles: EnsembleNegotiation([]),
            trustedRackIds: [],
            freeChoice: false,
            pick: PickOptions(
                requiredEnsemblesFromROPES: requiredEnsemblesFromROPES,
                allowedEnsemblesFromProxy: allowedEnsemblesFromProxy
            )
        )
    }
}
