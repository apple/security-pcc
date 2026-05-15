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
//  LaunchDProcessCreation.swift
//  EnsembleWarden
//
//  Created by Oliver Chick (ORAC) on 31/10/2025.
//

private import AppServerSupport.OSLaunchdJob
package import EnsemblePorter
package import EnsemblePorterCommon
package import Foundation
private import OSLog
private import System
private import XPC
private import XPCPrivate

/// Creates porter processes using launchd.
///
/// This is how we manage processes running in production.
package struct LaunchDProcessCreation: ProcessCreationProtocol, Sendable {
    private let metrics: EnsemblePorterMetrics
    private let logger = Logger(subsystem: EnsemblePorterConstants.controllerLoggerSubsystem,
                                category: "EnsemblePorterControllerProduction")

    package init(metrics: EnsemblePorterMetrics) {
        self.metrics = metrics
    }

    package func createInstance() async throws -> UUID {
        logger.log("""
            Starting new ensemblefollowerporterd.
            """)
        var instanceUUID = UUID()
        let managedJobs = try OSLaunchdJob.copyJobsManaged(by: EnsemblePorterConstants.managedByEnsemblePorterControllerLabel)
        // Only get the original launchd job, not all instances of this job
        let managedJobsWithoutInstances = managedJobs.filter { job in
            guard let jobInfo = job.getCurrentJobInfo() else {
                return false
            }
            return jobInfo.instance == nil
        }
        guard managedJobsWithoutInstances.count == 1, let job = managedJobsWithoutInstances.first else {
            logger.error("""
                Incorrect managed job count. \
                expected=\(1) \
                actual=\(managedJobs.count) \
                process_token=\(instanceUUID, privacy: .sensitive)
                """)
            metrics.instanceCreationFailure.increment()
            throw EnsemblePorterError.launchdManagedJobMismatch(expected: 1, actual: managedJobs.count)
        }
        logger.log("""
                    Creating new process instance. \
                    process_instance_uuid=\(instanceUUID, privacy: .public) \
                    existing_managed_job_instances=\(managedJobs.count) \
                    instance_uuid=\(instanceUUID, privacy: .sensitive)
                    """)
        do {
            let jobInstance = try withUnsafeMutablePointer(to: &instanceUUID) { id in
                try job.createInstance(id)
            }

            jobInstance.monitor(on: DispatchQueue.global()) { jobInfo, errno in
                self.handleJobInfoUpdate(
                    jobInfo,
                    errno: errno,
                    jobInstance: jobInstance,
                    processToken: instanceUUID
                )
            }
        } catch {
            metrics.instanceCreationFailure.increment()
            throw error
        }

        metrics.instanceCreationSuccess.increment()
        return instanceUUID
    }

    package func createProvider(instanceUUID: UUID) throws -> EnsemblePorterCryptoProviderImpl<EnsemblePorterXPCSessionClient> {
        logger.log("""
                    Creating process-isolated XPC connection. \
                    mach_service=\(EnsemblePorterConstants.xpcKeyProviderFollowerClientName, privacy: .public) \
                    instance_uuid=\(instanceUUID, privacy: .public)
                    """)
        let xpcConnection = xpc_connection_create_mach_service(EnsemblePorterConstants.xpcKeyProviderFollowerClientName, nil, 0)
        var id = instanceUUID
        withUnsafeMutablePointer(to: &id) { id in
            xpc_connection_set_oneshot_instance(xpcConnection, id)
        }

        xpc_connection_set_event_handler(xpcConnection) { event in
            // Safe to log the event description as it comes from XPC.
            self.logger.log("""
                            XPC session event. \
                            error=\(event.description, privacy: .public) \
                            instance_uuid=\(instanceUUID, privacy: .sensitive)
                            """)
        }
        xpc_connection_activate(xpcConnection)

        logger.log("Using instance to create a EnsemblePorterCryptoProviderImpl")
        let provider = try EnsemblePorterCryptoProviderImpl<EnsemblePorterXPCSessionClient>(existingConnection: xpcConnection)
        return provider
    }

    package func removeInstance(instanceUUID: UUID) async throws {
        logger.log("""
            Removing porter instance. \
            instance_uuid=\(instanceUUID, privacy: .public)
            """)

        // Get all managed jobs and find the one matching this instance UUID
        let managedJobs = try OSLaunchdJob.copyJobsManaged(by: EnsemblePorterConstants.managedByEnsemblePorterControllerLabel)

        guard let jobInstance = managedJobs.first(where: { job in
            guard let jobInfo = job.getCurrentJobInfo(),
                  let instance = jobInfo.instance else {
                return false
            }
            return instance == instanceUUID
        }) else {
            logger.error("""
                Attempted to remove unknown instance. \
                instance_uuid=\(instanceUUID, privacy: .sensitive)
                """)
            throw EnsemblePorterError.unexpectedError
        }

        do {
            jobInstance.cancelMonitor()
            try jobInstance.remove()

            logger.log("""
                Successfully removed porter instance. \
                instance_uuid=\(instanceUUID, privacy: .sensitive)
                """)
        } catch {
            logger.error("""
                Failed to remove porter instance. \
                instance_uuid=\(instanceUUID, privacy: .sensitive) \
                error=\(String(reportable: error), privacy: .public)
                """)
            throw error
        }
    }

    private func handleJobInfoUpdate(
        _ jobInfo: OSLaunchdJobInfo?,
        errno: errno_t,
        jobInstance: OSLaunchdJob,
        processToken: UUID
    ) {
        guard let jobInfo else {
            logger.error("""
                Unexpectedly received event with no jobInfo. \
                errno=\(errno) \
                process_token=\(processToken, privacy: .sensitive)
                """)
            metrics.instanceCreationFailure.increment()
            return
        }
        switch jobInfo.state {
        case .neverRan:
            logger.log("""
                ensemblefollowerporterd launchd job reported neverRan. \
                process_token=\(processToken, privacy: .sensitive)
                """)
        case .running:
            logger.log("""
                ensemblefollowerporterd launchd job running. \
                process_token=\(processToken, privacy: .sensitive)
                """)
        case .spawnFailed:
            let errNo = Errno(rawValue: jobInfo.lastSpawnError)
            logger.log("""
                ensemblefollowerporterd launchd spawn failed. \
                errno=\(errNo, privacy: .public) \
                process_token=\(processToken, privacy: .sensitive)
                """)
            metrics.instanceCreationFailure.increment()
        case .exited:
            logger.log("""
                ensemblefollowerporterd process reported exit. \
                process_token=\(processToken, privacy: .sensitive)
                """)
            jobInstance.cancelMonitor()
        }
    }
}

