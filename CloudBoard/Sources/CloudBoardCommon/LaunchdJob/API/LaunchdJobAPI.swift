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

// This file should *never* import AppServerSupport.OSLaunchdJob
// it should be kept entirely clean as the public surface of the API to
// find, create, start, monitor and control the jobs

import Foundation
import os
import System

public enum LaunchdJobFinderError: Error {
    case noAppFound
    case noApplicableApp
    case tooManyManagedJobs(app: String, count: Int)
}

/// A protocol that defines methods that can be used to interact with launchd jobs
/// where it is feasible to mock out the underlying OS interaction.
/// This *only* needs to abstract over the capabilities required for CloudBoard
public protocol LaunchdJobFinderProtocol: Sendable {
    /// find the definitions we manage, from which we can create new instances
    func getJobDefinitions(
        type: CloudBoardJobType,
        name: String?
    ) throws -> [LaunchdJobDefinitionProtocol]

    // Provides exactly one job definition for a job with the provided type and name. If none or more than one job
    // definitions are found, corresponding errors are thrown.
    func getJobDefinition(
        type: CloudBoardJobType,
        name: String
    ) throws -> (definition: LaunchdJobDefinitionProtocol, app: String)

    /// Find and terminate any jobs related to the jobhelper or cloud app
    /// This is intended for use when the cloudboard daemon restarts,
    /// any previous jobs are rendered pointless and should be terminated.
    ///
    /// Note: This could be implemented as 'clean'
    /// `findAllRunningInstances()` and then iterate over them, but it's needless complexity
    /// because there is no current need to mock this at all,
    func cleanupManagedLaunchdJobs(logger: Logger) async

    /// This covers the behaviour where launched job instances are
    /// able to discover their own UUID.
    ///
    /// Notes: you could argue this is separate from the finding of job definitions,
    /// but in all cases the mocking happens at the same point
    func currentJobUUID(logger: Logger) -> UUID?
}

/// A means to start instances of a specific job find from ``LaunchdJobFinderProtocol``
public protocol LaunchdJobDefinitionProtocol: Sendable {
    /// an abstraction over the attributes about the job that are relevant to cloudboard
    var attributes: CloudBoardJobAttributes { get }

    /// Make a separate instance which can be started/monitored but does *not* start it
    func createInstance(
        uuid: UUID
    ) -> any LaunchdJobInstanceInitiatorProtocol
}

/// A protocol that defines methods that can be used to *start and monitor* an instance of a launchd job
/// General interaction happens through the ``LaunchdJobHandleProtocol``
public protocol LaunchdJobInstanceInitiatorProtocol: Sendable {
    var uuid: UUID { get }

    /// Launchd job attributes that apply to both the base job and this specific instance
    var attributes: CloudBoardJobAttributes { get }

    /// Launchd job handle to the launchd job instance (not the base job)
    var instanceHandleIfCreated: (any LaunchdJobInstanceHandleProtocol)? { get async }

    /// This API is a little ugly, the act of *iterating* on the sequence starts the job
    /// We might change that in future
    func startAndWatch() -> any AsyncSequence<LaunchdJobEvents.State, Never>

    /// We 'link' the job helper instance to its associated cloud app
    /// by reusing the same UUID for them, since they are different job types
    /// and advertise different XPC services launchd can disambiguate them fine
    /// It means that we can easily terminate one, knowing only the other
    func findRunningLinkedInstances(
        type: CloudBoardJobType,
        logger: Logger
    ) -> [any LaunchdJobInstanceHandleProtocol]
}

/// An instance, whether initiated by us or not, which can be interacted with.
/// This is effectively an abstraction over a handle to a job instance, but written
/// in an OO style (instead of static methods which take this as a parameter)
/// so it can be easily mocked out
public protocol LaunchdJobInstanceHandleProtocol: Sendable {
    /// An abstraction over the attributes about the job that are relevant to cloudboard.
    /// These are defined on creation and do not change
    var attributes: CloudBoardJobAttributes { get }

    /// is the job considered running
    func isRunning() -> Bool

    /// Attempt to stop the job associated with this handle
    func remove(logger: Logger) throws
}
