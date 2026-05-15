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

internal import CloudBoardDomain
import CloudBoardJob
import CloudBoardLogging
import Foundation
import os

struct TestApp: NullAppRole {
    static var serviceName: NullAppServiceName { .testApp }

    private let log: Logger

    internal init(log: Logger) {
        self.log = log
    }

    func run(
        input: CloudBoardJobCore.InputData,
        responder: CloudBoardJobCore.ResponseWriter,
        environment: CloudBoardJobCore.CloudAppEnvironment,
        spanID _: UInt64
    ) async throws {
        let requestID = environment.plaintextMetadata.requestID
        self.log.log("""
        request.uuid=\(requestID, privacy: .public)
        message=Hello from NullCloudApp: test flavour
        """)
        let clock = ContinuousClock()
        for try await data in input {
            // We assume the first chunk has the full encoded input.
            let parameters = try JSONDecoder().decode(Input.self, from: data)

            if let crashBeforeFirstResponseToken = parameters.crashBeforeFirstResponseToken,
               crashBeforeFirstResponseToken {
                self.log.log("""
                request.uuid=\(requestID, privacy: .public)
                message=Crashing as instructed before first token
                """)
                if parameters.crashWithFatalError ?? false {
                    fatalError("Crashing as instructed before first token")
                } else {
                    throw RequestedCrashError.crashBeforeFirstResponseToken
                }
            }

            let responseToken = Data(repeating: UInt8(ascii: "x"), count: parameters.responseTokenSize)

            for tokenNumber in 0 ..< parameters.responseTokenCount {
                if tokenNumber == 0 {
                    self.log.log("""
                    request.uuid=\(requestID, privacy: .public)
                    message=Sleeping for first token
                    """)
                    try await clock.sleep(for: .milliseconds(parameters.timeToFirstTokenMilliseconds))
                } else {
                    // fairly arbitrary sampling of logs - too high a frequency of events causes the process
                    // to be quarantined by libtrace.
                    if tokenNumber % 100 == 0 {
                        self.log.log("""
                        request.uuid=\(requestID, privacy: .public)
                        message=Sleeping for token number \(tokenNumber)
                        """)
                    }
                    try await clock.sleep(for: .milliseconds(parameters.timeBetweenSubsequentTokensMilliseconds))
                }
                if let crashOnResponseToken = parameters.crashOnResponseToken,
                   tokenNumber == crashOnResponseToken {
                    self.log.log("""
                    request.uuid=\(requestID, privacy: .public)
                    message=Crashing as instructed on token number \(tokenNumber)
                    """)
                    if parameters.crashWithFatalError ?? false {
                        fatalError("Crashing as instructed on token number \(tokenNumber)")
                    } else {
                        throw RequestedCrashError.crashOnResponseToken(tokenNumber)
                    }
                }
                if tokenNumber % 100 == 0 {
                    self.log.log("""
                    request.uuid=\(requestID, privacy: .public)
                    message=Sending token number \(tokenNumber)
                    """)
                }
                try await responder.write(responseToken)
            }

            self.log.log("""
            request.uuid=\(requestID, privacy: .public)
            message=Tokens complete, terminating stream.
            """)
            if let cloudAppRequestExecutionErrorFlag = parameters.sendCloudAppRequestExecutionError,
               cloudAppRequestExecutionErrorFlag {
                await responder.finish(.init(
                    errorSource: CloudAppRequestExecutionErrorSource.cloudApp,
                    errorMessage: "CloudApp reportable error",
                    errorCode: 2000,
                ))
                return
            } else {
                try responder.finish()
            }

            if parameters.crashOnResponseToken != nil {
                self.log.log("""
                request.uuid=\(requestID, privacy: .public)
                message=Crashing after completing response stream.
                """)
                if parameters.crashWithFatalError ?? false {
                    fatalError("Crashing after completing response stream.")
                } else {
                    throw RequestedCrashError.crashOnResponse
                }
            }
            self.log.log("""
            request.uuid=\(requestID, privacy: .public)
            message=TestApp data finished
            """)
        }
        self.log.log("""
        request.uuid=\(requestID, privacy: .public)
        message=TestApp finished
        """)
    }
}

internal struct Input: Codable {
    var responseTokenCount: Int
    var responseTokenSize: Int
    var timeToFirstTokenMilliseconds: Int
    var timeBetweenSubsequentTokensMilliseconds: Int
    var crashBeforeFirstResponseToken: Bool?
    var crashOnResponseToken: Int?
    var crashWithFatalError: Bool?
    var sendCloudAppRequestExecutionError: Bool?
    var proxySendCloudAppRequestExecutionError: Bool?
}

enum RequestedCrashError: ReportableError {
    case crashBeforeFirstResponseToken
    case crashOnResponseToken(Int)
    case crashOnResponse

    public var publicDescription: String {
        switch self {
        case .crashBeforeFirstResponseToken:
            return "crashBeforeFirstResponseToken"
        case .crashOnResponseToken(let token):
            return "crashOnResponseToken \(token)"
        case .crashOnResponse:
            return "crashOnResponse"
        }
    }
}
