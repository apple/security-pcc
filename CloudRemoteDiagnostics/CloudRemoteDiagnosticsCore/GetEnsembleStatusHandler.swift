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
//  GetEnsembleStatusHandler.swift
//  CloudRemoteDiagnosticsCore
//
//  Created by Marc Orr on 3/6/24.
//

import Foundation
import os
#if canImport(AppleComputeEnsembler)
@_weakLinked import AppleComputeEnsembler
#endif

private let logger = Logger(subsystem: "cloudremotediagd", category: "ensembled")

// Use the same (odd) format for the results that is used by the ACDCSystemHardwareTest project.
private struct TestResult: Sendable, Codable {
    var category: String
    var name: String
    var fru: String
    var result: Bool
    var details: String
}

private func toJsonString<T: Encodable>(from: T) -> String {
    guard let jsonOutput = try? JSONEncoder().encode(from) else {
        return "error encoding \(from) to json data"
    }

    guard let jsonString = String(data: jsonOutput, encoding: .utf8) else {
        return "error converting json data to utf8 string"
    }

    return jsonString
}

private struct TestResults: Sendable, Codable {
    var failedTests: [String: [TestResult]]
    var successTests: [String: [TestResult]]
    var allFRUs: [String]

    func jsonString() -> String {
        return toJsonString(from: self)
    }
}

let kNotApplicableFRU = "NotApplicable"

let kCRDInternalErrorCategory = "CRDInternalError"
let kCRDInternalErrorName = "UnexpectedError"

let kEnsembleStatusCategory = "EnsembleStatus"
let kEnsembleStatusName = "CheckForReadyEnsembleStatus"

let kCableDiagnosticsCategory = "CableDiagnostics"
let kCableDiagnosticsName = "CheckCIOCables"
let kCIOCableFRU = "miniSAS Cables"

extension CloudRemoteDiagnosticsHandler {

    public func handleGetEnsembleStatus() -> String {
        return self.getEnsembleStatus() ?? ""
    }

    public func handleGetEnsembleHealth() -> String {
        if let health = self.getEnsembleHealth() {
            return health
        }
        return "{\"healthState\":\"unknown\"}"
    }

    private func getEnsembleStatus() -> String? {
#if canImport(AppleComputeEnsembler)
        guard #_hasSymbol(EnsemblerSession.self) else {
            return nil
        }
        var results = TestResults(failedTests: [:],
                                  successTests: [:],
                                  allFRUs: [kNotApplicableFRU, kCIOCableFRU])

        let ensembler: EnsemblerSession
        do {
            ensembler = try EnsemblerSession()
        } catch {
            results.failedTests[kCRDInternalErrorCategory] = [
                TestResult(
                    category: kCRDInternalErrorCategory,
                    name: kCRDInternalErrorName,
                    fru: kNotApplicableFRU,
                    result: false,
                    details: "error initializing EnsemblerSession(): \(error)"
                )
            ]
            return results.jsonString()
        }

        // First fetch the ensemble status from ensembled.
        let status: EnsemblerStatus
        do {
            status = try ensembler.getStatus()
        } catch {
            results.failedTests[kCRDInternalErrorCategory] = [
                TestResult(
                    category: kCRDInternalErrorCategory,
                    name: kCRDInternalErrorName,
                    fru: kNotApplicableFRU,
                    result: false,
                    details: "error fetching ensembler status: \(error)"
                )
            ]
            return results.jsonString()
        }

        if status == .ready {
            // If the status is Ready, then we're done.
            results.successTests[kEnsembleStatusCategory] = [
                TestResult(
                    category: kEnsembleStatusCategory,
                    name: kEnsembleStatusName,
                    fru: kNotApplicableFRU,
                    result: true,
                    details: ""
                )
            ]
        } else {
            // If the status is not ready, then record a failure and try to get more details.
            results.failedTests[kEnsembleStatusCategory] = [
                TestResult(
                    category: kEnsembleStatusCategory,
                    name: kEnsembleStatusName,
                    fru: kNotApplicableFRU,
                    result: false,
                    details: "Expected status to be 'ready', got \(String(describing: status))"
                )
            ]

            var cableDiagnostics: [String] = []
            do {
                cableDiagnostics = try ensembler.getCableDiagnostics()
            } catch {
                results.failedTests[kCRDInternalErrorCategory] = [
                    TestResult(
                        category: kCRDInternalErrorCategory,
                        name: kCRDInternalErrorName,
                        fru: kNotApplicableFRU,
                        result: false,
                        details: "error fetching cable diagnostics: \(error)"
                    )
                ]
                return results.jsonString()
            }

            for cableDiagnostic in cableDiagnostics {
                if results.failedTests[kCableDiagnosticsCategory] == nil {
                    results.failedTests[kCableDiagnosticsCategory] = []
                }
                results.failedTests[kCableDiagnosticsCategory]?.append(
                    TestResult(
                        category: kCableDiagnosticsCategory,
                        name: kCableDiagnosticsName,
                        fru: kCIOCableFRU,
                        result: false,
                        details: cableDiagnostic
                    )
                )
            }
        }

        return results.jsonString()
#else
        return nil
#endif
    }

    public func getEnsembleHealth() -> String? {
#if canImport(AppleComputeEnsembler)
        guard #_hasSymbol(EnsemblerSession.self) else {
            return nil
        }
        let ensembler: EnsemblerSession
        do {
            ensembler = try EnsemblerSession()
        } catch {
            // Cases where this might happen:
            //   - Somehow cloudremotediagd comes up before ensembled. (This really shouldn't
            //     happen, since they're uncorked after REM together.)
            //   - ensembled is restarting
            //
            // Clients should give the ensemble time to initialize before treating this case as
            // unhealthy.
            logger.error("Failed to create EnsemblerSession: Maybe ensembled is (re)starting: \(error)")
            let state = EnsembleHealth(healthState: .unknown,
                                       internalState: EnsemblerStatus.uninitialized)
            return toJsonString(from: state)
        }

        let health: EnsembleHealth
        do {
            health = try ensembler.getHealth()
        } catch {
            // Given a valid EnsemblerSession, ensembled's health API should really never throw an
            // exception. If it does, return unhealthy and log an error.
            logger.error("Oops, failed to retrieve ensembled health: \(error)")
            let state = EnsembleHealth(healthState: .unhealthy,
                                         internalState: EnsemblerStatus.unknown)
            return toJsonString(from: state)
        }

        return toJsonString(from: health)
#else
        return nil
#endif
    }
}
