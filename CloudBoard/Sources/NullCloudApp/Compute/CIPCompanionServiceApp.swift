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

import CloudBoardCommon
internal import CloudBoardDomain
import CloudBoardJob
import Foundation
import os

/// Compute app that makes requests to CIPCompanionService
struct CIPCompanionServiceApp: NullAppRole {
    static var serviceName: NullAppServiceName { NullAppServiceName.cipCompanionServiceApp }
    private let log: Logger

    init(log: Logger) {
        self.log = log
    }

    func run(
        input: InputData,
        responder: ResponseWriter,
        environment: CloudAppEnvironment,
        spanID _: UInt64
    ) async throws {
        for try await data in input {
            self.log.log("""
            request.uuid=\(environment.plaintextMetadata.requestID, privacy: .public)
            message=CIPCompanionService message received: \(data.count) bytes
            """)
            do {
                var requestType = "verifyImage"
                let decodedData = try? JSONDecoder().decode([String: String].self, from: data)
                if let value = decodedData?["requestType"] {
                    requestType = value
                }

                switch requestType {
                case "verifyImage":
                    let encodedResponse = try await self.makeCIPCompanionServiceVerifyImageRequest(
                        cipCompanionServiceClient: environment.cipCompanionServiceClient,
                        decodedData: decodedData
                    )
                    try await responder.write(encodedResponse)
                default:
                    self.log.log("Invalid requestType. Skipping!!")
                    try await responder.write(Data("Invalid requestType received. Skipping!!".utf8))
                    continue
                }
            } catch {
                self.log.error("""
                request.uuid=\(environment.plaintextMetadata.requestID, privacy: .public)
                message=Error sending cip companion service request: \(error)
                """)
                try await responder.write(Data("Error sending CIPCompanionService request: \(error)".utf8))
            }
        }

        try responder.finish()
    }

    private func makeCIPCompanionServiceVerifyImageRequest(
        cipCompanionServiceClient: CIPCompanionServiceClient,
        decodedData: [String: String]?
    ) async throws -> Data {
        var imageID = Data(repeating: 0x01, count: 32)
        if let value = decodedData?["imageID"] {
            imageID = Data(value.utf8)
        }

        var sensorID = Data(repeating: 0x02, count: 32)
        if let value = decodedData?["sensorID"] {
            sensorID = Data(value.utf8)
        }

        var imageHash = Data(repeating: 0x03, count: 32)
        if let value = decodedData?["imageHash"] {
            imageHash = Data(value.utf8)
        }

        var developmentTime = Date()
        if let value = decodedData?["developmentTime"] {
            developmentTime = try Date(value, strategy: .iso8601)
        }

        var imageFraudScore = 42
        if let value = decodedData?["imageFraudScore"] {
            imageFraudScore = Int(value) ?? 0
        }

        var uniqueCameraModel = "test_camera"
        if let value = decodedData?["uniqueCameraModel"] {
            uniqueCameraModel = value
        }

        var pccAppVersion = "1.0"
        if let value = decodedData?["pccAppVersion"] {
            pccAppVersion = value
        }

        var fraudModelVersion = "1.0"
        if let value = decodedData?["fraudModelVersion"] {
            fraudModelVersion = value
        }

        var isoSpeedRatings = 100
        if let value = decodedData?["isoSpeedRatings"] {
            isoSpeedRatings = Int(value) ?? 100
        }

        var exposureTime: Float = 1.0 / 60.0
        if let value = decodedData?["exposureTime"] {
            exposureTime = Float(value) ?? 1.0 / 60.0
        }

        var captureTimestamp = ISO8601DateFormatter().string(from: Date())
        if let value = decodedData?["captureTimestamp"] {
            captureTimestamp = value
        }

        var metadataFraudScore = imageFraudScore
        if let value = decodedData?["metadataFraudScore"] {
            metadataFraudScore = Int(value) ?? imageFraudScore
        }

        var confidenceScore = 0
        if let value = decodedData?["confidenceScore"] {
            confidenceScore = Int(value) ?? 0
        }

        var tracer1FraudScore = 0
        if let value = decodedData?["tracer1FraudScore"] {
            tracer1FraudScore = Int(value) ?? 0
        }

        var tracer1ConfidenceScore = 0
        if let value = decodedData?["tracer1ConfidenceScore"] {
            tracer1ConfidenceScore = Int(value) ?? 0
        }

        var tracer2FraudScore = 0
        if let value = decodedData?["tracer2FraudScore"] {
            tracer2FraudScore = Int(value) ?? 0
        }

        var tracer2ConfidenceScore = 0
        if let value = decodedData?["tracer2ConfidenceScore"] {
            tracer2ConfidenceScore = Int(value) ?? 0
        }

        // asShotNeutral and perChannelAvgIntensityMap are fixed-size float arrays that
        // can't be ergonomically expressed in the flat [String: String] input format.
        let imageMetadata = CIPCompanionServiceImageMetadata(
            imageMetadataV1: CIPCompanionServiceImageMetadataV1(
                uniqueCameraModel: uniqueCameraModel,
                pccAppVersion: pccAppVersion,
                fraudModelVersion: fraudModelVersion,
                isoSpeedRatings: isoSpeedRatings,
                exposureTime: exposureTime,
                asShotNeutral: [1.0, 1.0, 1.0],
                captureTimestamp: captureTimestamp,
                perChannelAvgIntensityMap: [
                    [[0.5, 0.5, 0.5], [0.5, 0.5, 0.5], [0.5, 0.5, 0.5]],
                    [[0.5, 0.5, 0.5], [0.5, 0.5, 0.5], [0.5, 0.5, 0.5]],
                    [[0.5, 0.5, 0.5], [0.5, 0.5, 0.5], [0.5, 0.5, 0.5]],
                ],
                fraudScore: metadataFraudScore,
                confidenceScore: confidenceScore,
                tracer1FraudScore: tracer1FraudScore,
                tracer1ConfidenceScore: tracer1ConfidenceScore,
                tracer2FraudScore: tracer2FraudScore,
                tracer2ConfidenceScore: tracer2ConfidenceScore
            )
        )

        self.log.log("Making CIPCompanionService VerifyImage request")
        let response = try await cipCompanionServiceClient.makeCIPCompanionServiceVerifyImageRequest(
            request: CIPCompanionServiceVerifyImageRequest(
                imageID: imageID,
                sensorID: sensorID,
                imageHash: imageHash,
                developmentTime: developmentTime,
                imageFraudScore: imageFraudScore,
                imageMetadata: imageMetadata
            ),
            configuration: CIPCompanionServiceConfiguration(spanID: nil)
        )
        self.log.log("CIPCompanionService VerifyImage request completed")
        return try JSONEncoder().encode(response)
    }
}
