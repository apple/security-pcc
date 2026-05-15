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
//  ComponentTimeMeasurementReporter.swift
//  PrivateCloudCompute
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//

import AppleIntelligenceReporting
import Foundation
import PrivateCloudCompute
import os.log

private let logger = tc2Logger(forCategory: .metricReporter)

protocol AppleIntelligenceEventReporterProtocol: Sendable {
    func emitAppleIntelligenceStartEvent(eventInfo: AppleIntelligenceEvent) throws -> EventIdentifier
    func emitAppleIntelligenceEndEvent(eventInfo: AppleIntelligenceEvent, startEventIdentifier: EventIdentifier?) throws
}

extension EventReporter: AppleIntelligenceEventReporterProtocol {}

/// Represents the source format of a component time measurement.
enum ComponentTimeMeasurementSource: Sendable {
    /// JSON-encoded measurement from ROPES HTTP trailers
    case json(String)
    /// Protobuf measurement from CloudBoard response stream
    case proto(Proto_PrivateCloudCompute_ComponentTimeMeasurement)
}

/// Handles parsing and emission of end-to-end component time measurements.
///
/// Each component in the PCC stack (edge, ROPES, PCCagent, cloudboard, etc.) produces timing
/// metrics at its layer and sends them to the client as JSON or protobuf. The client serves as
/// the integration point that aggregates this data from all layers.
///
/// When emitted as AppleIntelligenceEvents, these metrics appear in the biome stream where they
/// can be used for diagnosing issues during bug triage.
final class ComponentTimeMeasurementReporter<Reporter: AppleIntelligenceEventReporterProtocol>: Sendable {

    /// Represents a single component time measurement.
    ///
    /// Each measurement captures timing for one operation at one hop in the PCC workflow.
    /// Multiple measurements with the same `identifier` represent the complete breakdown
    /// of time spent across all hops for a single request.
    struct Measurement: Codable, Sendable {
        /// The component/hop identifier (e.g., "iCloudEdge", "ROPES", "pccagent", "cloudboard")
        let componentName: String

        /// The operation performed at this hop (e.g., "agent", "pegasus_call", "inference")
        let operation: String

        /// Optional request identifier for correlating metrics across hops
        let identifier: String?

        /// Optional sub-request identifier for multi-turn or nested execution flows
        let subIdentifier: String?

        /// Operation start time as milliseconds since epoch
        let startTime: Int64

        /// Operation end time as milliseconds since epoch
        let endTime: Int64

        enum CodingKeys: String, CodingKey {
            case componentName = "component_name"
            case operation
            case identifier
            case subIdentifier = "sub_identifier"
            case startTime = "start_time"
            case endTime = "end_time"
        }

        init(
            componentName: String,
            operation: String,
            identifier: String?,
            subIdentifier: String?,
            startTime: Int64,
            endTime: Int64
        ) {
            self.componentName = componentName
            self.operation = operation
            self.identifier = identifier
            self.subIdentifier = subIdentifier
            self.startTime = startTime
            self.endTime = endTime
        }

        init(_ proto: Proto_PrivateCloudCompute_ComponentTimeMeasurement) {
            self.componentName = proto.componentName
            self.operation = proto.operation
            self.identifier = proto.hasIdentifier ? proto.identifier : nil
            self.subIdentifier = proto.hasSubIdentifier ? proto.subIdentifier : nil
            self.startTime = proto.startTime
            self.endTime = proto.endTime
        }

        var loggingDescription: String {
            """
            <Measurement
            componentName=\(componentName)
            operation=\(operation)
            identifier=\(identifier ?? "nil")
            subIdentifier=\(subIdentifier ?? "nil")
            startTime=\(startTime)
            endTime=\(endTime)>
            """
        }
    }

    private let decoder: JSONDecoder
    private let eventReporter: Reporter?

    init(eventReporter: Reporter?) {
        self.decoder = JSONDecoder()
        self.eventReporter = eventReporter
    }

    /// Parses and emits a component time measurement as an AppleIntelligenceReporting event.
    func process(clientRequestID: UUID, source: ComponentTimeMeasurementSource) {
        let measurement: Measurement
        switch source {
        case .json(let jsonValue):
            guard let data = jsonValue.data(using: .utf8) else {
                logger.warning("Failed to parse component time measurement: invalid UTF-8 data")
                return
            }
            do {
                measurement = try self.decoder.decode(Measurement.self, from: data)
            } catch {
                logger.warning("Failed to parse component time measurement: \(error)")
                return
            }
        case .proto(let protoValue):
            measurement = Measurement(protoValue)
        }

        logger.log("Processing component time measurement: \(measurement.loggingDescription)")
        emit(clientRequestID: clientRequestID, measurement: measurement)
    }

    private func emit(clientRequestID: UUID, measurement: Measurement) {
        let startDate = Date(timeIntervalSince1970: TimeInterval(measurement.startTime) / 1000)
        let endDate = Date(timeIntervalSince1970: TimeInterval(measurement.endTime) / 1000)

        let startEvent = AppleIntelligenceEvent.inference(
            .init(
                subsystem: measurement.componentName,
                stepIdentifier: measurement.operation,
                modelManagerRequestIdentifier: clientRequestID,
                metadata: nil,
                spanContext: nil,
                timestamp: startDate
            )
        )

        let endEvent = AppleIntelligenceEvent.inference(
            .init(
                subsystem: measurement.componentName,
                stepIdentifier: measurement.operation,
                modelManagerRequestIdentifier: clientRequestID,
                metadata: nil,
                spanContext: nil,
                timestamp: endDate
            )
        )

        guard let eventReporter else {
            logger.warning("Failed to emit component time measurement events for \(measurement.operation): eventReporter not initialized")
            return
        }

        do {
            let startEventID = try eventReporter.emitAppleIntelligenceStartEvent(eventInfo: startEvent)
            try eventReporter.emitAppleIntelligenceEndEvent(eventInfo: endEvent, startEventIdentifier: startEventID)
            logger.log("Submitted component time measurement events for \(measurement.operation)")
        } catch {
            logger.warning("Failed to emit component time measurement events for \(measurement.operation): \(error)")
        }
    }
}
