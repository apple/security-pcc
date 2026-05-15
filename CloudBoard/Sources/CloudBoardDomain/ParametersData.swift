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

package import CloudBoardAsyncXPC
import Foundation

/// CloudBoard-internal parameters message sent from cb_jobhelper to the cloud app/support app
package struct ParametersData: Sendable, ByteBufferCodable, Hashable, Equatable {
    package var parametersReceived: Date
    package var plaintextMetadata: PlaintextMetadata
    package var requestBypassed: Bool
    package var traceContext: CloudBoardTraceContext
    package var nodeAppData: NodeAppData
    package var launchdJobInstanceUUID: UUID
    package var supportApps: [String]

    package init(
        parametersReceived: Date,
        plaintextMetadata: PlaintextMetadata,
        requestBypassed: Bool,
        traceContext: CloudBoardTraceContext,
        nodeAppData: NodeAppData,
        launchdJobInstanceUUID: UUID,
        supportApps: [String]
    ) {
        self.parametersReceived = parametersReceived
        self.plaintextMetadata = plaintextMetadata
        self.requestBypassed = requestBypassed
        self.traceContext = traceContext
        self.nodeAppData = nodeAppData
        self.launchdJobInstanceUUID = launchdJobInstanceUUID
        self.supportApps = supportApps
    }

    package func encode(to buffer: inout ByteBuffer) throws {
        try self.plaintextMetadata.encode(to: &buffer)
        try self.parametersReceived.encode(to: &buffer)
        try self.requestBypassed.encode(to: &buffer)
        try self.traceContext.encode(to: &buffer)
        try self.nodeAppData.encode(to: &buffer)
        try self.launchdJobInstanceUUID.encode(to: &buffer)
        try self.supportApps.encode(to: &buffer)
    }

    package init(from buffer: inout ByteBuffer) throws {
        self.plaintextMetadata = try .init(from: &buffer)
        self.parametersReceived = try .init(from: &buffer)
        self.requestBypassed = try .init(from: &buffer)
        self.traceContext = try .init(from: &buffer)
        self.nodeAppData = try .init(from: &buffer)
        self.launchdJobInstanceUUID = try .init(from: &buffer)
        self.supportApps = try .init(from: &buffer)
    }

    package struct PlaintextMetadata: ByteBufferCodable, Sendable, Hashable {
        public var bundleID: String
        public var bundleVersion: String
        public var featureID: String
        public var clientInfo: String
        public var workloadType: String
        public var workloadParameters: [String: [String]]
        public var requestID: String
        public var automatedDeviceGroup: String

        public init(
            bundleID: String,
            bundleVersion: String,
            featureID: String,
            clientInfo: String,
            workloadType: String,
            workloadParameters: [String: [String]],
            requestID: String,
            automatedDeviceGroup: String
        ) {
            self.bundleID = bundleID
            self.bundleVersion = bundleVersion
            self.featureID = featureID
            self.clientInfo = clientInfo
            self.workloadType = workloadType
            self.workloadParameters = workloadParameters
            self.requestID = requestID
            self.automatedDeviceGroup = automatedDeviceGroup
        }

        package func encode(to buffer: inout ByteBuffer) throws {
            try self.automatedDeviceGroup.encode(to: &buffer)
            try self.bundleID.encode(to: &buffer)
            try self.bundleVersion.encode(to: &buffer)
            try self.clientInfo.encode(to: &buffer)
            try self.featureID.encode(to: &buffer)
            try self.requestID.encode(to: &buffer)
            try self.workloadType.encode(to: &buffer)
            try self.workloadParameters.encode(to: &buffer)
        }

        package init(from buffer: inout ByteBuffer) throws {
            self.automatedDeviceGroup = try .init(from: &buffer)
            self.bundleID = try .init(from: &buffer)
            self.bundleVersion = try .init(from: &buffer)
            self.clientInfo = try .init(from: &buffer)
            self.featureID = try .init(from: &buffer)
            self.requestID = try .init(from: &buffer)
            self.workloadType = try .init(from: &buffer)
            self.workloadParameters = try .init(from: &buffer)
        }
    }

    package struct NodeAppData: ByteBufferCodable, Sendable, Hashable, Equatable {
        public var rackID: Data?
        public var bootID: Data?
        public var ensembleID: Data?

        public init(rackID: Data?, bootID: Data?, ensembleID: Data?) {
            self.rackID = rackID
            self.bootID = bootID
            self.ensembleID = ensembleID
        }

        package func encode(to buffer: inout ByteBuffer) throws {
            try self.rackID.encode(to: &buffer)
            try self.bootID.encode(to: &buffer)
            try self.ensembleID.encode(to: &buffer)
        }

        public init(from buffer: inout ByteBuffer) throws {
            self.rackID = try .init(from: &buffer)
            self.bootID = try .init(from: &buffer)
            self.ensembleID = try .init(from: &buffer)
        }
    }
}
