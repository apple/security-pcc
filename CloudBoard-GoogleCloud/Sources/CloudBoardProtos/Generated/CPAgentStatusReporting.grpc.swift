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

///*
/// CloudBoard Status Reporting API
///
/// Defines the interface for CloudBoard to report status of its component
/// tree to the on-node control plane agent via gRPC.
///
/// The node is modeled as a tree of components, each with its own lifecycle
/// state. Each update carries the full system status — the control plane
/// agent always has a consistent, complete view.

// DO NOT EDIT.
// swift-format-ignore-file
// swiftlint:disable all
//
// Generated by the gRPC Swift generator plugin for the protocol buffer compiler.
// Source: CPAgentStatusReporting.proto
//
// For information on using the generated types, please see the documentation:
//   https://github.com/grpc/grpc-swift

import GRPCCore
import GRPCProtobuf

// MARK: - com.apple.cpagent.status.v1.StatusReporter

/// Namespace containing generated types for the "com.apple.cpagent.status.v1.StatusReporter" service.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
package enum Proto_CPAgentStatus_StatusReporter: Sendable {
    /// Service descriptor for the "com.apple.cpagent.status.v1.StatusReporter" service.
    package static let descriptor = GRPCCore.ServiceDescriptor(fullyQualifiedService: "com.apple.cpagent.status.v1.StatusReporter")
    /// Namespace for method metadata.
    package enum Method: Sendable {
        /// Namespace for "ReportStatus" metadata.
        package enum ReportStatus: Sendable {
            /// Request type for "ReportStatus".
            package typealias Input = Proto_CPAgentStatus_StatusReport
            /// Response type for "ReportStatus".
            package typealias Output = Proto_CPAgentStatus_StatusResponse
            /// Descriptor for "ReportStatus".
            package static let descriptor = GRPCCore.MethodDescriptor(
                service: GRPCCore.ServiceDescriptor(fullyQualifiedService: "com.apple.cpagent.status.v1.StatusReporter"),
                method: "ReportStatus",
                type: .clientStreaming
            )
        }
        /// Descriptors for all methods in the "com.apple.cpagent.status.v1.StatusReporter" service.
        package static let descriptors: [GRPCCore.MethodDescriptor] = [
            ReportStatus.descriptor
        ]
    }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension GRPCCore.ServiceDescriptor {
    /// Service descriptor for the "com.apple.cpagent.status.v1.StatusReporter" service.
    package static let proto_cpagentStatus_StatusReporter = GRPCCore.ServiceDescriptor(fullyQualifiedService: "com.apple.cpagent.status.v1.StatusReporter")
}

// MARK: com.apple.cpagent.status.v1.StatusReporter (server)

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension Proto_CPAgentStatus_StatusReporter {
    /// Streaming variant of the service protocol for the "com.apple.cpagent.status.v1.StatusReporter" service.
    ///
    /// This protocol is the lowest-level of the service protocols generated for this service
    /// giving you the most flexibility over the implementation of your service. This comes at
    /// the cost of more verbose and less strict APIs. Each RPC requires you to implement it in
    /// terms of a request stream and response stream. Where only a single request or response
    /// message is expected, you are responsible for enforcing this invariant is maintained.
    ///
    /// Where possible, prefer using the stricter, less-verbose ``ServiceProtocol``
    /// or ``SimpleServiceProtocol`` instead.
    package protocol StreamingServiceProtocol: GRPCCore.RegistrableRPCService {
        /// Handle the "ReportStatus" method.
        ///
        /// > Source IDL Documentation:
        /// >
        /// > CloudBoard opens a long-lived stream and pushes the full system status.
        ///
        /// - Parameters:
        ///   - request: A streaming request of `Proto_CPAgentStatus_StatusReport` messages.
        ///   - context: Context providing information about the RPC.
        /// - Throws: Any error which occurred during the processing of the request. Thrown errors
        ///     of type `RPCError` are mapped to appropriate statuses. All other errors are converted
        ///     to an internal error.
        /// - Returns: A streaming response of `Proto_CPAgentStatus_StatusResponse` messages.
        func reportStatus(
            request: GRPCCore.StreamingServerRequest<Proto_CPAgentStatus_StatusReport>,
            context: GRPCCore.ServerContext
        ) async throws -> GRPCCore.StreamingServerResponse<Proto_CPAgentStatus_StatusResponse>
    }

    /// Service protocol for the "com.apple.cpagent.status.v1.StatusReporter" service.
    ///
    /// This protocol is higher level than ``StreamingServiceProtocol`` but lower level than
    /// the ``SimpleServiceProtocol``, it provides access to request and response metadata and
    /// trailing response metadata. If you don't need these then consider using
    /// the ``SimpleServiceProtocol``. If you need fine grained control over your RPCs then
    /// use ``StreamingServiceProtocol``.
    package protocol ServiceProtocol: Proto_CPAgentStatus_StatusReporter.StreamingServiceProtocol {
        /// Handle the "ReportStatus" method.
        ///
        /// > Source IDL Documentation:
        /// >
        /// > CloudBoard opens a long-lived stream and pushes the full system status.
        ///
        /// - Parameters:
        ///   - request: A streaming request of `Proto_CPAgentStatus_StatusReport` messages.
        ///   - context: Context providing information about the RPC.
        /// - Throws: Any error which occurred during the processing of the request. Thrown errors
        ///     of type `RPCError` are mapped to appropriate statuses. All other errors are converted
        ///     to an internal error.
        /// - Returns: A response containing a single `Proto_CPAgentStatus_StatusResponse` message.
        func reportStatus(
            request: GRPCCore.StreamingServerRequest<Proto_CPAgentStatus_StatusReport>,
            context: GRPCCore.ServerContext
        ) async throws -> GRPCCore.ServerResponse<Proto_CPAgentStatus_StatusResponse>
    }

    /// Simple service protocol for the "com.apple.cpagent.status.v1.StatusReporter" service.
    ///
    /// This is the highest level protocol for the service. The API is the easiest to use but
    /// doesn't provide access to request or response metadata. If you need access to these
    /// then use ``ServiceProtocol`` instead.
    package protocol SimpleServiceProtocol: Proto_CPAgentStatus_StatusReporter.ServiceProtocol {
        /// Handle the "ReportStatus" method.
        ///
        /// > Source IDL Documentation:
        /// >
        /// > CloudBoard opens a long-lived stream and pushes the full system status.
        ///
        /// - Parameters:
        ///   - request: A stream of `Proto_CPAgentStatus_StatusReport` messages.
        ///   - context: Context providing information about the RPC.
        /// - Throws: Any error which occurred during the processing of the request. Thrown errors
        ///     of type `RPCError` are mapped to appropriate statuses. All other errors are converted
        ///     to an internal error.
        /// - Returns: A `Proto_CPAgentStatus_StatusResponse` to respond with.
        func reportStatus(
            request: GRPCCore.RPCAsyncSequence<Proto_CPAgentStatus_StatusReport, any Swift.Error>,
            context: GRPCCore.ServerContext
        ) async throws -> Proto_CPAgentStatus_StatusResponse
    }
}

// Default implementation of 'registerMethods(with:)'.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension Proto_CPAgentStatus_StatusReporter.StreamingServiceProtocol {
    package func registerMethods<Transport>(with router: inout GRPCCore.RPCRouter<Transport>) where Transport: GRPCCore.ServerTransport {
        router.registerHandler(
            forMethod: Proto_CPAgentStatus_StatusReporter.Method.ReportStatus.descriptor,
            deserializer: GRPCProtobuf.ProtobufDeserializer<Proto_CPAgentStatus_StatusReport>(),
            serializer: GRPCProtobuf.ProtobufSerializer<Proto_CPAgentStatus_StatusResponse>(),
            handler: { request, context in
                try await self.reportStatus(
                    request: request,
                    context: context
                )
            }
        )
    }
}

// Default implementation of streaming methods from 'StreamingServiceProtocol'.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension Proto_CPAgentStatus_StatusReporter.ServiceProtocol {
    package func reportStatus(
        request: GRPCCore.StreamingServerRequest<Proto_CPAgentStatus_StatusReport>,
        context: GRPCCore.ServerContext
    ) async throws -> GRPCCore.StreamingServerResponse<Proto_CPAgentStatus_StatusResponse> {
        let response = try await self.reportStatus(
            request: request,
            context: context
        )
        return GRPCCore.StreamingServerResponse(single: response)
    }
}

// Default implementation of methods from 'ServiceProtocol'.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension Proto_CPAgentStatus_StatusReporter.SimpleServiceProtocol {
    package func reportStatus(
        request: GRPCCore.StreamingServerRequest<Proto_CPAgentStatus_StatusReport>,
        context: GRPCCore.ServerContext
    ) async throws -> GRPCCore.ServerResponse<Proto_CPAgentStatus_StatusResponse> {
        return GRPCCore.ServerResponse<Proto_CPAgentStatus_StatusResponse>(
            message: try await self.reportStatus(
                request: request.messages,
                context: context
            ),
            metadata: [:]
        )
    }
}

// MARK: com.apple.cpagent.status.v1.StatusReporter (client)

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension Proto_CPAgentStatus_StatusReporter {
    /// Generated client protocol for the "com.apple.cpagent.status.v1.StatusReporter" service.
    ///
    /// You don't need to implement this protocol directly, use the generated
    /// implementation, ``Client``.
    package protocol ClientProtocol: Sendable {
        /// Call the "ReportStatus" method.
        ///
        /// > Source IDL Documentation:
        /// >
        /// > CloudBoard opens a long-lived stream and pushes the full system status.
        ///
        /// - Parameters:
        ///   - request: A streaming request producing `Proto_CPAgentStatus_StatusReport` messages.
        ///   - serializer: A serializer for `Proto_CPAgentStatus_StatusReport` messages.
        ///   - deserializer: A deserializer for `Proto_CPAgentStatus_StatusResponse` messages.
        ///   - options: Options to apply to this RPC.
        ///   - handleResponse: A closure which handles the response, the result of which is
        ///       returned to the caller. Returning from the closure will cancel the RPC if it
        ///       hasn't already finished.
        /// - Returns: The result of `handleResponse`.
        func reportStatus<Result>(
            request: GRPCCore.StreamingClientRequest<Proto_CPAgentStatus_StatusReport>,
            serializer: some GRPCCore.MessageSerializer<Proto_CPAgentStatus_StatusReport>,
            deserializer: some GRPCCore.MessageDeserializer<Proto_CPAgentStatus_StatusResponse>,
            options: GRPCCore.CallOptions,
            onResponse handleResponse: @Sendable @escaping (GRPCCore.ClientResponse<Proto_CPAgentStatus_StatusResponse>) async throws -> Result
        ) async throws -> Result where Result: Sendable
    }

    /// Generated client for the "com.apple.cpagent.status.v1.StatusReporter" service.
    ///
    /// The ``Client`` provides an implementation of ``ClientProtocol`` which wraps
    /// a `GRPCCore.GRPCCClient`. The underlying `GRPCClient` provides the long-lived
    /// means of communication with the remote peer.
    package struct Client<Transport>: ClientProtocol where Transport: GRPCCore.ClientTransport {
        private let client: GRPCCore.GRPCClient<Transport>

        /// Creates a new client wrapping the provided `GRPCCore.GRPCClient`.
        ///
        /// - Parameters:
        ///   - client: A `GRPCCore.GRPCClient` providing a communication channel to the service.
        package init(wrapping client: GRPCCore.GRPCClient<Transport>) {
            self.client = client
        }

        /// Call the "ReportStatus" method.
        ///
        /// > Source IDL Documentation:
        /// >
        /// > CloudBoard opens a long-lived stream and pushes the full system status.
        ///
        /// - Parameters:
        ///   - request: A streaming request producing `Proto_CPAgentStatus_StatusReport` messages.
        ///   - serializer: A serializer for `Proto_CPAgentStatus_StatusReport` messages.
        ///   - deserializer: A deserializer for `Proto_CPAgentStatus_StatusResponse` messages.
        ///   - options: Options to apply to this RPC.
        ///   - handleResponse: A closure which handles the response, the result of which is
        ///       returned to the caller. Returning from the closure will cancel the RPC if it
        ///       hasn't already finished.
        /// - Returns: The result of `handleResponse`.
        package func reportStatus<Result>(
            request: GRPCCore.StreamingClientRequest<Proto_CPAgentStatus_StatusReport>,
            serializer: some GRPCCore.MessageSerializer<Proto_CPAgentStatus_StatusReport>,
            deserializer: some GRPCCore.MessageDeserializer<Proto_CPAgentStatus_StatusResponse>,
            options: GRPCCore.CallOptions = .defaults,
            onResponse handleResponse: @Sendable @escaping (GRPCCore.ClientResponse<Proto_CPAgentStatus_StatusResponse>) async throws -> Result = { response in
                try response.message
            }
        ) async throws -> Result where Result: Sendable {
            try await self.client.clientStreaming(
                request: request,
                descriptor: Proto_CPAgentStatus_StatusReporter.Method.ReportStatus.descriptor,
                serializer: serializer,
                deserializer: deserializer,
                options: options,
                onResponse: handleResponse
            )
        }
    }
}

// Helpers providing default arguments to 'ClientProtocol' methods.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension Proto_CPAgentStatus_StatusReporter.ClientProtocol {
    /// Call the "ReportStatus" method.
    ///
    /// > Source IDL Documentation:
    /// >
    /// > CloudBoard opens a long-lived stream and pushes the full system status.
    ///
    /// - Parameters:
    ///   - request: A streaming request producing `Proto_CPAgentStatus_StatusReport` messages.
    ///   - options: Options to apply to this RPC.
    ///   - handleResponse: A closure which handles the response, the result of which is
    ///       returned to the caller. Returning from the closure will cancel the RPC if it
    ///       hasn't already finished.
    /// - Returns: The result of `handleResponse`.
    package func reportStatus<Result>(
        request: GRPCCore.StreamingClientRequest<Proto_CPAgentStatus_StatusReport>,
        options: GRPCCore.CallOptions = .defaults,
        onResponse handleResponse: @Sendable @escaping (GRPCCore.ClientResponse<Proto_CPAgentStatus_StatusResponse>) async throws -> Result = { response in
            try response.message
        }
    ) async throws -> Result where Result: Sendable {
        try await self.reportStatus(
            request: request,
            serializer: GRPCProtobuf.ProtobufSerializer<Proto_CPAgentStatus_StatusReport>(),
            deserializer: GRPCProtobuf.ProtobufDeserializer<Proto_CPAgentStatus_StatusResponse>(),
            options: options,
            onResponse: handleResponse
        )
    }
}

// Helpers providing sugared APIs for 'ClientProtocol' methods.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension Proto_CPAgentStatus_StatusReporter.ClientProtocol {
    /// Call the "ReportStatus" method.
    ///
    /// > Source IDL Documentation:
    /// >
    /// > CloudBoard opens a long-lived stream and pushes the full system status.
    ///
    /// - Parameters:
    ///   - metadata: Additional metadata to send, defaults to empty.
    ///   - options: Options to apply to this RPC, defaults to `.defaults`.
    ///   - producer: A closure producing request messages to send to the server. The request
    ///       stream is closed when the closure returns.
    ///   - handleResponse: A closure which handles the response, the result of which is
    ///       returned to the caller. Returning from the closure will cancel the RPC if it
    ///       hasn't already finished.
    /// - Returns: The result of `handleResponse`.
    package func reportStatus<Result>(
        metadata: GRPCCore.Metadata = [:],
        options: GRPCCore.CallOptions = .defaults,
        requestProducer producer: @Sendable @escaping (GRPCCore.RPCWriter<Proto_CPAgentStatus_StatusReport>) async throws -> Void,
        onResponse handleResponse: @Sendable @escaping (GRPCCore.ClientResponse<Proto_CPAgentStatus_StatusResponse>) async throws -> Result = { response in
            try response.message
        }
    ) async throws -> Result where Result: Sendable {
        let request = GRPCCore.StreamingClientRequest<Proto_CPAgentStatus_StatusReport>(
            metadata: metadata,
            producer: producer
        )
        return try await self.reportStatus(
            request: request,
            options: options,
            onResponse: handleResponse
        )
    }
}