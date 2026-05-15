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

import NIOHPACK
import Tracing

extension SpanAttributes {
    /// Attributes included in CloudBoard request summaries
    var requestSummary: RequestSummaryAttributes {
        get {
            .init(attributes: self)
        }
        set {
            self = newValue.attributes
        }
    }
}

/// Attributes included in CloudBoard request summaries
@dynamicMemberLookup
struct RequestSummaryAttributes: SpanAttributeNamespace {
    var attributes: SpanAttributes

    init(attributes: SpanAttributes) {
        self.attributes = attributes
    }

    // MARK: - Top-level

    struct NestedSpanAttributes: NestedSpanAttributesProtocol {
        init() {}
    }

    var invocationAttributes: InvocationAttributes {
        get {
            .init(attributes: self.attributes)
        }
        set {
            self.attributes = newValue.attributes
        }
    }

    struct InvocationAttributes: SpanAttributeNamespace {
        var attributes: SpanAttributes

        struct NestedSpanAttributes: NestedSpanAttributesProtocol {
            init() {}

            var invocationRequestHeaders: Key<HPACKHeaders> { "cloudboardd.requestSummary.invocation_request_headers" }

            var connectionCancelled: Key<Bool> { "cloudboardd.requestSummary.connection.cancelled" }

            var spanID: Key<UInt64> { "cloudboardd.requestSummary.span_id" }

            var parentSpanID: Key<UInt64> { "cloudboardd.requestSummary.parent_span_id" }
        }
    }

    // MARK: - Request chunk

    var workloadRequestAttributes: WorkloadRequestAttributes {
        get {
            .init(attributes: self.attributes)
        }
        set {
            self.attributes = newValue.attributes
        }
    }

    /// Semantic conventions for HTTP requests.
    struct WorkloadRequestAttributes: SpanAttributeNamespace {
        var attributes: SpanAttributes

        struct NestedSpanAttributes: NestedSpanAttributesProtocol {
            init() {}

            var chunkSize: Key<Int> { "cloudboardd.requestSummary.request_chunk.size" }

            var isFinal: Key<Bool> { "cloudboardd.requestSummary.request_chunk.is_final" }

            var receivedSetup: Key<Bool> { "cloudboardd.requestSummary.request_chunk.received_setup" }

            var receivedParameters: Key<Bool> { "cloudboardd.requestSummary.request_chunk.received_parameters" }

            var workload: Key<String> { "cloudboardd.requestSummary.workload" }

            var bundleID: Key<String> { "cloudboardd.requestSummary.bundle_id" }

            var featureID: Key<String> { "cloudboardd.requestSummary.feature_id" }

            var keyID: Key<String> {
                "cloudboardd.requestSummary.key_id"
            }

            var automatedDeviceGroup: Key<String> { "cloudboardd.requestSummary.automated_device_group" }

            var ropesTerminationCode: Key<Int> { "cloudboardd.requestSummary.connection.termination_code" }

            var ropesTerminationReason: Key<String> { "cloudboardd.requestSummary.connection.termination_reason" }

            var spanID: Key<UInt64> { "cloudboardd.requestSummary.span_id" }

            var parentSpanID: Key<UInt64> { "cloudboardd.requestSummary.parent_span_id" }

            var isNack: Key<Bool> { "cloudboardd.requestSummary.is_nack" }
        }
    }

    // MARK: - Response chunk

    var responseChunkAttributes: ResponseChunkAttributes {
        get {
            .init(attributes: self.attributes)
        }
        set {
            self.attributes = newValue.attributes
        }
    }

    struct ResponseChunkAttributes: SpanAttributeNamespace {
        var attributes: SpanAttributes

        struct NestedSpanAttributes: NestedSpanAttributesProtocol {
            init() {}

            var chunksCount: Key<Int> { "cloudboardd.requestSummary.response_chunks.count" }

            var isFinal: Key<Bool> { "cloudboardd.requestSummary.response_chunk.is_final" }

            var spanID: Key<UInt64> { "cloudboardd.requestSummary.span_id" }

            var parentSpanID: Key<UInt64> { "cloudboardd.requestSummary.parent_span_id" }
        }
    }

    // MARK: - RequestExecutionError

    var requestExecutionErrorAttributes: RequestExecutionErrorAttributes {
        get {
            .init(attributes: self.attributes)
        }
        set {
            self.attributes = newValue.attributes
        }
    }

    struct RequestExecutionErrorAttributes: SpanAttributeNamespace {
        var attributes: SpanAttributes

        struct NestedSpanAttributes: NestedSpanAttributesProtocol {
            init() {}

            var errorMessage: Key<String> { "cloudboardd.requestSummary.request_execution_error" }
        }
    }

    // MARK: - Client request

    var clientRequestAttributes: ClientRequestAttributes {
        get {
            .init(attributes: self.attributes)
        }
        set {
            self.attributes = newValue.attributes
        }
    }

    struct ClientRequestAttributes: SpanAttributeNamespace {
        var attributes: SpanAttributes

        struct NestedSpanAttributes: NestedSpanAttributesProtocol {
            init() {}

            var jobHelperPID: Key<Int> { "cloudboardd.requestSummary.client_request.job_helper_pid" }

            var jobID: Key<String> { "cloudboardd.requestSummary.client_request.job_id" }
        }
    }
}

extension HPACKHeaders: @retroactive SpanAttributeConvertible {
    public func toSpanAttribute() -> Tracing.SpanAttribute {
        Tracing.SpanAttribute.stringConvertible(self)
    }
}

extension UInt64: @retroactive SpanAttributeConvertible {
    public func toSpanAttribute() -> SpanAttribute {
        Tracing.SpanAttribute.stringConvertible(self)
    }
}
