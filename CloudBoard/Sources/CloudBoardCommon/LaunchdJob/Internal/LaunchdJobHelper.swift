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

internal import AppServerSupport.OSLaunchdJob
import CloudBoardLogging
import Foundation
import os
import System

/// A very limited wrapper on the underly job handles to retain the parsed out
/// attributes we care about. At this level we are not enforcing the sort of
/// handle (defiEnition, instance) in our type system, though that is purely a
/// historic decision
internal struct ManagedLaunchdJob {
    public let jobHandle: OSLaunchdJob
    public let jobAttributes: CloudBoardJobAttributes
}

internal enum LaunchdJobHelper {
    private static func getLaunchdJobAttributes(
        fromJob launchdJob: OSLaunchdJob,
        withState state: OSLaunchdJobState? = nil,
        ofType type: CloudBoardJobType? = nil,
        withName name: String? = nil,
        skippingInstances: Bool = false,
        logger: Logger
    ) -> CloudBoardJobAttributes? {
        guard let currentJobInfo = launchdJob.getCurrentJobInfo() else {
            logger.error("ignoring discovered launchd job due to missing CurrentJobInfo")
            return nil
        }

        // If skippingInstances is set, we only return base job handles
        if skippingInstances, let instanceUUID = currentJobInfo.instance {
            logger.debug("skipping job instance with UUID: \(instanceUUID.uuidString, privacy: .public)")
            return nil
        }

        if let state, state != currentJobInfo.state {
            logger.debug("ignoring discovered launchd job due to state not being the same as requested")
            return nil
        }

        guard let additionalProperties = currentJobInfo.additionalPropertiesDictionary else {
            logger.error("ignoring discovered launchd job due to missing _AdditionalProperties dictionary")
            return nil
        }

        guard let jobTypeString = XPCDictionary(additionalProperties)[LaunchdPropertyKeys.jobType] as String? else {
            logger.error("discovered launchd job missing \(LaunchdPropertyKeys.jobType, privacy: .public)")
            return nil
        }
        guard let jobType = CloudBoardJobType(rawValue: jobTypeString) else {
            logger.error("invalid job type specified in launchd plist \(jobTypeString, privacy: .public)")
            return nil
        }

        // If we are looking for a specific job type, return here if the type doesn't match
        if let type, type != jobType {
            return nil
        }

        guard let jobName = XPCDictionary(additionalProperties)[LaunchdPropertyKeys.jobName] as String? else {
            logger.error("discovered job missing \(LaunchdPropertyKeys.jobName, privacy: .public)")
            return nil
        }
        guard !jobName.isEmpty else {
            logger.error("discovered job has empty \(LaunchdPropertyKeys.jobName, privacy: .public) value")
            return nil
        }

        // If we are looking for a specific job name, return here if the name doesn't match
        if let name, name != jobName {
            return nil
        }

        guard let machServiceName = XPCDictionary(additionalProperties)[LaunchdPropertyKeys.machServiceName] as String?
        else {
            logger.error("discovered job missing \(LaunchdPropertyKeys.machServiceName, privacy: .public)")
            return nil
        }
        guard !machServiceName.isEmpty else {
            logger.error("discovered job has empty \(LaunchdPropertyKeys.machServiceName, privacy: .public) value")
            return nil
        }

        return CloudBoardJobAttributes(
            cloudBoardJobType: jobType,
            initMachServiceName: machServiceName,
            cloudBoardJobName: jobName
        )
    }

    // Fetches the jobs that cloudboardd manages from launchd and returns the jobs of the matching type
    // (all types if none was specified).
    internal static func findManagedLaunchdJobs(
        type: CloudBoardJobType,
        name: String? = nil,
        state: OSLaunchdJobState? = nil,
        skippingInstances: Bool = false
    ) throws -> [ManagedLaunchdJob] {
        let managerName = type.launchdManagerName
        let managedJobs = try OSLaunchdJob.copyJobsManaged(by: managerName)
        var launchdJobs = [ManagedLaunchdJob]()
        for launchdJob in managedJobs {
            if let jobAttributes = getLaunchdJobAttributes(
                fromJob: launchdJob,
                withState: state,
                ofType: type,
                withName: name,
                skippingInstances: skippingInstances,
                logger: logger
            ) {
                launchdJobs.append(ManagedLaunchdJob(jobHandle: launchdJob, jobAttributes: jobAttributes))
            }
        }

        return launchdJobs
    }

    // Fetches the jobs that cloudboardd manages from launchd and returns the jobs of the matching type (all types if
    // none was specified).
    // Returns an array of (LaunchdJob, AdditionalPropertiesDict) (as defined in the AdditionalProperties dictionary)
    internal static func fetchManagedLaunchdJobs(
        type: CloudBoardJobType,
        state: OSLaunchdJobState? = nil,
        skippingInstances: Bool = false,
        logger: Logger
    ) -> [ManagedLaunchdJob] {
        var launchdJobs = [ManagedLaunchdJob]()

        let managedJobs: [OSLaunchdJob]?
        do {
            let managerName = type.launchdManagerName
            try managedJobs = OSLaunchdJob.copyJobsManaged(by: managerName)
        } catch {
            logger.error("failed to query outstanding managed jobs")
            return launchdJobs
        }
        guard let managedJobs, managedJobs.count > 0 else {
            return launchdJobs
        }

        for launchdJob in managedJobs {
            if let jobAttributes = getLaunchdJobAttributes(
                fromJob: launchdJob,
                withState: state,
                ofType: type,
                skippingInstances: skippingInstances,
                logger: logger
            ) {
                launchdJobs.append(ManagedLaunchdJob(jobHandle: launchdJob, jobAttributes: jobAttributes))
            }
        }

        return launchdJobs
    }

    internal static func fetchManagedLaunchdJobs(
        withUUID uuid: UUID, logger: Logger
    ) -> (OSLaunchdJob?, OSLaunchdJob?) {
        let helperJob = Self.fetchManagedLaunchdJobs(
            type: .cbJobHelper, logger: logger
        ).first {
            $0.jobHandle.getCurrentJobInfo()?.instance == uuid
        }
        let appJob = Self.fetchManagedLaunchdJobs(
            type: .cloudBoardApp, logger: logger
        ).first {
            $0.jobHandle.getCurrentJobInfo()?.instance == uuid
        }

        return (helperJob?.jobHandle, appJob?.jobHandle)
    }

    public static func cleanupManagedLaunchdJobs(logger: Logger) async {
        var jobs: [ManagedLaunchdJob] = []
        // .cbPClientHelper instances are owned by cb_bridged, not cloudboardd
        let jobTypes: [CloudBoardJobType] = [.cbJobHelper, .cloudBoardApp, .cbPServerHelper]

        for jobType in jobTypes {
            jobs += self.fetchManagedLaunchdJobs(type: jobType, logger: logger)
        }

        jobs = jobs.filter { job in
            guard let jobInfo = job.jobHandle.getCurrentJobInfo() else {
                return false
            }
            return jobInfo.instance != nil
        }

        guard jobs.count > 0 else {
            return
        }

        let s = jobs.count == 1 ? "" : "s"
        logger.info("Found \(jobs.count, privacy: .public) managed job\(s, privacy: .public) from previous session")

        await withTaskGroup(of: Void.self) { group in
            for job in jobs {
                group.addTask {
                    await Self.cleanupManagedLaunchdJob(job: job, logger: logger)
                }
            }
            await group.waitForAll()
        }
    }

    private static func cleanupManagedLaunchdJob(
        job: ManagedLaunchdJob,
        logger: Logger
    ) async {
        do {
            try self.removeManagedLaunchdJob(job: job.jobHandle, logger: logger)
        } catch {
            logger.error(
                "Remove failed on job \(job.jobHandle.handle, privacy: .public): \(String(reportable: error), privacy: .public) (\(error))"
            )
            return
        }

        let startTime = DispatchTime.now()
        let timeout = 60.0
        while DispatchTime.now() < startTime + timeout {
            if let jobInfo = job.jobHandle.getCurrentJobInfo() {
                if jobInfo.state == .running {
                    do {
                        try await Task.sleep(for: .seconds(1))
                        continue
                    } catch {
                        break
                    }
                }
            }

            logger.info("Removed job \(job.jobHandle.handle, privacy: .public)")
            return
        }

        logger.error(
            "Unable to remove job \(job.jobHandle.handle, privacy: .public)"
        )
    }

    internal static func removeManagedLaunchdJob(
        job: OSLaunchdJob,
        logger: Logger
    ) throws {
        var pidStr = "<unknown PID>"
        var uuidStr = "<unknown UUID>"
        if let info = job.getCurrentJobInfo() {
            pidStr = String(info.pid)
            if let instance = info.instance {
                uuidStr = instance.uuidString
            }
        }
        logger.info("Removing job \(uuidStr, privacy: .public) (PID \(pidStr, privacy: .public))")
        do {
            try job.remove()
        } catch let error as NSError {
            if error.domain == "OSLaunchdErrorDomain",
               error.code == EINPROGRESS {
                logger.info("""
                Removal in progress on job \(uuidStr, privacy: .public) \
                (PID \(pidStr, privacy: .public))
                """)
            } else if error.domain == "OSLaunchdErrorDomain",
                      error.code == ESRCH {
                logger.info("""
                Job already exited \(uuidStr, privacy: .public) \
                (PID \(pidStr, privacy: .public))
                """)
            } else {
                logger.error("""
                Remove failed on job \(uuidStr, privacy: .public) \
                (PID \(pidStr, privacy: .public)): \(String(reportable: error), privacy: .public) (\(error))
                """)
                throw error
            }
        }
    }

    internal static func currentJob(logger: Logger) -> OSLaunchdJob? {
        let pid = getpid()
        guard let job = OSLaunchdJob.copy(withPid: pid) else {
            logger.error(
                "Unable to get OSLaunchdJob for current process \(pid, privacy: .public)"
            )
            return nil
        }
        return job
    }

    public static func currentJobUUID(logger: Logger) -> UUID? {
        guard let job = currentJob(logger: logger) else {
            return nil
        }
        guard let info = job.getCurrentJobInfo() else {
            logger.error("Unable to get launchd job info for current process")
            return nil
        }
        return info.instance as UUID?
    }
}
