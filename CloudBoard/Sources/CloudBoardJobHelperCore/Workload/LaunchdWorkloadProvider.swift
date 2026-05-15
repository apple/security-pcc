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

import CloudBoardAsyncXPC
import CloudBoardAttestationDAPI
import CloudBoardCommon
import CloudBoardJobAPI
import CloudBoardJobAuthDAPI
import CloudBoardJobHelperAPI
import CloudBoardMetrics
import Foundation
import os

// This is used by the cloudboard-cli to launch cloudapps in tests
// This means it has quite strict dependency requirements for builds
// which might be surprising.
package struct LaunchdWorkloadProvider: CloudBoardJobHelperWorkloadProvider {
    let launchdJobFinder: any LaunchdJobFinderProtocol
    let metrics: any MetricsSystem
    let cloudAppClientFactory: any ManagedAppXPCClientFactoryProtocol
    let supportAppClientFactory: any ManagedAppXPCClientFactoryProtocol

    public init(
        launchdJobFinder: any LaunchdJobFinderProtocol,
        metrics: any MetricsSystem
    ) {
        self.init(
            launchdJobFinder: launchdJobFinder,
            cloudAppClientFactory: ManagedAppXPCClientFactory(),
            supportAppClientFactory: ManagedAppXPCClientFactory(),
            metrics: metrics
        )
    }

    internal init(
        launchdJobFinder: any LaunchdJobFinderProtocol,
        cloudAppClientFactory: any ManagedAppXPCClientFactoryProtocol,
        supportAppClientFactory: any ManagedAppXPCClientFactoryProtocol,
        metrics: any MetricsSystem
    ) {
        self.launchdJobFinder = launchdJobFinder
        self.metrics = metrics
        self.cloudAppClientFactory = cloudAppClientFactory
        self.supportAppClientFactory = supportAppClientFactory
    }

    @available(*, deprecated, message: "use getCloudApp and provide requestSecrets and ensembleKeyDistributor")
    package func getCloudApp(
        cloudAppName: String,
        jobUUID: UUID,
        cbJobHelperLogMetadata: CloudBoardJobHelperLogMetadata
    ) throws -> ManagedCloudAppProtocol {
        try self.getCloudApp(
            cloudAppName: cloudAppName,
            requestSecrets: RequestSecrets(),
            ensembleKeyDistributor: EnsembleKeyDistributor(),
            pirHelper: NoOpPIRHelper(),
            jobUUID: jobUUID,
            cbJobHelperLogMetadata: cbJobHelperLogMetadata
        )
    }

    package func getCloudApp(
        cloudAppName: String,
        requestSecrets: RequestSecrets,
        ensembleKeyDistributor: EnsembleKeyDistributorProtocol,
        pirHelper: PIRHelperProtocol,
        jobUUID: UUID,
        cbJobHelperLogMetadata: CloudBoardJobHelperLogMetadata
    ) throws -> ManagedCloudAppProtocol {
        do {
            let (definition, appName) = try self.launchdJobFinder.getJobDefinition(
                type: .cloudBoardApp,
                name: cloudAppName
            )
            CloudBoardJobHelper.logger.log("Using app \(appName, privacy: .public)")
            return try ManagedCloudApp(
                cloudAppName: cloudAppName,
                definition: definition,
                xpcClientFactory: self.cloudAppClientFactory,
                requestSecrets: requestSecrets,
                ensembleKeyDistributor: ensembleKeyDistributor,
                pirHelper: pirHelper,
                metrics: self.metrics,
                jobUUID: jobUUID,
                spanID: cbJobHelperLogMetadata.spanID
            )
        } catch let error as LaunchdJobFinderError {
            switch error {
            case .noAppFound:
                CloudboardJobHelperCheckpoint(
                    logMetadata: cbJobHelperLogMetadata,
                    message: "Failed to discover any managed cloud apps"
                ).log(forCloudApp: cloudAppName, to: CloudBoardJobHelper.tracingLogger, level: .error)
                fatalError("Failed to discover any managed cloud apps")
            case .noApplicableApp:
                CloudboardJobHelperCheckpoint(
                    logMetadata: cbJobHelperLogMetadata,
                    message: "No matching cloud app found"
                ).log(forCloudApp: cloudAppName, to: CloudBoardJobHelper.tracingLogger, level: .error)
                fatalError("No matching cloud app found")
            case .tooManyManagedJobs(app: let app, count: let count):
                CloudBoardJobHelper.logger.error(
                    "Found \(count, privacy: .public) instances of \(app, privacy: .public)"
                )
                fatalError("Found too many instance of a cloud app")
            }
        }
    }

    package func getSupportApp(
        forCloudApp cloudApp: String,
        name: String,
        requestSecrets: RequestSecrets,
        jobUUID: UUID,
        cbJobHelperLogMetadata: CloudBoardJobHelperLogMetadata,
        terminationHandler: @Sendable @escaping (_ cleanTermination: Bool) async -> Void
    ) throws -> ManagedSupportAppProtocol {
        do {
            let (definition, appName) = try self.launchdJobFinder.getJobDefinition(
                type: .cloudBoardSupportApp,
                name: name
            )
            CloudBoardJobHelper.logger.log("Using support app \(appName, privacy: .public)")
            return try ManagedSupportApp(
                definition: definition,
                xpcClientFactory: self.supportAppClientFactory,
                requestSecrets: requestSecrets,
                metrics: self.metrics,
                jobUUID: jobUUID,
                terminationHandler: terminationHandler,
                spanID: cbJobHelperLogMetadata.spanID
            )
        } catch let error as LaunchdJobFinderError {
            switch error {
            case .noAppFound:
                CloudboardJobHelperCheckpoint(
                    logMetadata: cbJobHelperLogMetadata,
                    message: "Failed to discover any managed support apps"
                ).log(forCloudApp: cloudApp, forSupportApp: name, to: CloudBoardJobHelper.logger, level: .error)
                fatalError("Failed to discover any managed support apps")
            case .noApplicableApp:
                CloudboardJobHelperCheckpoint(
                    logMetadata: cbJobHelperLogMetadata,
                    message: "No matching support app found"
                ).log(forCloudApp: cloudApp, forSupportApp: name, to: CloudBoardJobHelper.logger, level: .error)
                fatalError("No matching support app found")
            case .tooManyManagedJobs(app: let app, count: let count):
                CloudBoardJobHelper.logger.error(
                    "Found \(count, privacy: .public) instances of \(app, privacy: .public)"
                )
                fatalError("Found too many instance of a support app")
            }
        }
    }
}
