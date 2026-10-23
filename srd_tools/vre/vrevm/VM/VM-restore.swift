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

//  Copyright © 2024 Apple, Inc. All rights reserved.
//

import Foundation
import Virtualization

extension VM {
    // RestoreOptions are the parameters used to setup restore operation
    struct RestoreOptions: Codable {
        let restoreImage: String // path to os image (dmg or ipsw)
        let restoreVariant: String // variant name
        var timeoutSec: UInt = 120 // bail operation if takes longer
        var shutdownSec: UInt = 30 // bail if post-restore shutdown takes longer
        var kernelcacheOverride: String? = nil // pathnames
        var sptmOverride: String? = nil
        var txmOverride: String? = nil
        var prkitPath: String? = nil
    }

    // RestoreContext is passed into deviceConnectedCallback
    struct RestoreContext {
        let ecid: UInt64
        let restoreConfig: [String: Any]
        var logDir: VMBundle.Logs? = nil
        let completion: DispatchSemaphore
        var status: RestoreResult = .init()
    }

    struct RestoreResult {
        enum State: String {
            case notstarted, started, success, failed
        }

        var state: State = .notstarted
        var errReason: String? = nil

        mutating func setResult(state: State, errReason: String? = nil) {
            self.state = state
            self.errReason = errReason
        }
    }

    class RestoreContextWrapper {
        var context: RestoreContext
        init(context: RestoreContext) {
            self.context = context
        }
    }

    // restore performs an OS "restore" operation on a VM in "DFU" mode (identified by self.ecid) using
    //  low-level AMRestorable
    func restore(_ restoreOptions: RestoreOptions) async throws {
        let logDir: VMBundle.Logs
        do {
            logDir = try VMBundle.Logs(topdir: bundle.logsPath, folder: "restore", includeTimestamp: true)
        } catch {
            throw VMError("create logdir for \(name): \(error)")
        }

        try run(dfuMode: true)

        var restoreConfig: [String: Any]
        if let prkitPath = restoreOptions.prkitPath {
            let prkitURL = URL(filePath: prkitPath) as CFURL
            guard let copiedDict = AMRestorableDeviceCopyRestoreOptionsFromDocument(prkitURL, nil) else {
                throw VMError("failed to load restore options from PRKit: \(prkitPath)")
            }
            restoreConfig = CFDictionaryCreateMutableCopy(nil, 0, copiedDict) as! [String: Any]
        } else {
            restoreConfig = AMRestorableDeviceCopyDefaultRestoreOptions() as! [String: Any]
        }
        if let bootArgs = restoreConfig[kAMRestoreOptionsRestoreBootArgs] as? String {
            restoreConfig[kAMRestoreOptionsRestoreBootArgs] = bootArgs + " serial=3"
        } else {
            restoreConfig[kAMRestoreOptionsRestoreBootArgs] =
                "rd=md0 nand-enable-reformat=1 -progress -restore serial=3"
        }

        restoreConfig[kAMRestoreOptionsPostRestoreAction] = kAMRestorePostRestoreShutdown
        restoreConfig[kAMRestorableRestoreOptionWaitForDeviceConnectionToFinishStateMachine] = false

        var bundleOverrides: [String: String] = [:]
        if let kernelcacheOverride = restoreOptions.kernelcacheOverride {
            let kernelCachePath = URL(filePath: kernelcacheOverride)
            bundleOverrides["KernelCache"] = kernelCachePath.absoluteString
        }

        if let sptmOverride = restoreOptions.sptmOverride {
            let sptmPath = URL(filePath: sptmOverride)
            bundleOverrides["Ap,SecurePageTableMonitor"] = sptmPath.absoluteString
        }

        if let txmOverride = restoreOptions.txmOverride {
            let txmPath = URL(filePath: txmOverride)
            bundleOverrides["Ap,TrustedExecutionMonitor"] = txmPath.absoluteString
        }

        if !bundleOverrides.isEmpty {
            restoreConfig[kAMRestoreOptionsBundleOverrides] = bundleOverrides
        }

        // setup new default boot args (vm config settings applied at Run())
        restoreConfig[kAMRestoreOptionsPersistentBootArgModifications] = [
            [kAMRestoreBootArgsAdd, "debug", "0x104c04"],
            [kAMRestoreBootArgsAdd, "serial", "3"],
        ]

        restoreConfig[kAMRestoreOptionsRestoreBundlePath] = restoreOptions.restoreImage
        restoreConfig[kAMRestoreOptionsAuthInstallVariant] = restoreOptions.restoreVariant

        var restoreContext = RestoreContext(
            ecid: ecid,
            restoreConfig: restoreConfig,
            logDir: logDir,
            completion: DispatchSemaphore(value: 0)
        )

        let loginfo = "\(restoreOptions.restoreImage) (variant: \"\(restoreOptions.restoreVariant)\")"
        VM.logger.log("restore: \(loginfo, privacy: .public)")

        try performRestore(restoreContext: &restoreContext, timeoutSec: restoreOptions.timeoutSec)

        // VM still in process of shutting down
        try await awaitShutdown(timeout: TimeInterval(restoreOptions.shutdownSec))
    }

    // performRestore configures and initiates callback chain to perform the restore for instance VM; it
    //  awaits on semaphore passed in via restoreContext (which also contains the result of the operation).
    //  Error is thrown if unable to initiate or deadline reached awaiting completion.
    private func performRestore(restoreContext: inout RestoreContext,
                                timeoutSec: UInt) throws
    {
        let contextWrapper = RestoreContextWrapper(context: restoreContext)
        let contextWrapperRaw = Unmanaged<RestoreContextWrapper>.passRetained(contextWrapper)
        defer {
            contextWrapperRaw.release()
        }

        var resErr: Unmanaged<CFError>?
        let clientID = AMRestorableDeviceRegisterForNotifications(
            deviceConnectedCallback,
            contextWrapperRaw.toOpaque(),
            &resErr
        )
        defer {
            if clientID != kAMRestorableInvalidClientID {
                AMRestorableDeviceUnregisterForNotifications(clientID)
            }
        }

        if let resErr = resErr?.takeUnretainedValue() {
            let errReason = CFErrorCopyDescription(resErr) as? String ?? "unspecified reason"
            contextWrapper.context.status.setResult(state: .failed,
                                                    errReason: "failed to initiate: \(errReason)")
            throw VMError("failed to initiate restore: \(errReason)")
        }

        // update context (with results)
        defer { restoreContext = contextWrapper.context }

        // await upto maxRestoreSeconds for restoreProgressCallback to complete/exit
        let deadline = DispatchTime.now() + Double(timeoutSec)
        guard contextWrapper.context.completion.wait(timeout: deadline) == .success else {
            contextWrapper.context.status.setResult(state: .failed, errReason: "completion timeout")
            throw VMError("timeout waiting for completion")
        }

        guard contextWrapper.context.status.state == .success else {
            throw VMError("restore failed: \(restoreContext.status.errReason ?? "unspecified reason")")
        }
    }
}

// deviceConnectedCallback serves as the callback for AMRestorableDeviceRegisterForNotifications(),
//  which configures the completion callback and initiates the restore before returning - if
//  RestoreContext.logDir is set, log output files are setup for host/device/serial streams (in
//  addition to stdout)
private func deviceConnectedCallback(
    _ deviceRef: AMRestorableDevice?,
    _ event: AMRestorableDeviceEvent,
    _ context: UnsafeMutableRawPointer? // &RestoreContext
) {
    let deviceRef = deviceRef!
    let contextRef = Unmanaged<VM.RestoreContextWrapper>
        .fromOpaque(context!)
        .takeUnretainedValue()

    guard contextRef.context.status.state == .notstarted else {
        return
    }

    let reqECID = contextRef.context.ecid
    let devECID = AMRestorableDeviceGetECID(deviceRef)
    guard reqECID == devECID else {
        return
    }

    VM.logger.log("restore: connected to VM")
    if getAMRDeviceState(deviceRef) == kAMRestorableDeviceStateBootedOS {
        let amDeviceRef = AMRestorableDeviceCopyAMDevice(deviceRef)
        let error: AMDError = AMDeviceEnterRecovery(amDeviceRef)
        if error != 0 {
            let errStr = AMDCopyErrorText(error).takeRetainedValue() as String? ?? "Error code: \(error)"
            contextRef.context.status.setResult(state: .failed,
                                                errReason: "failed to enter recovery mode: \(errStr)")
            return
        }
    }

    guard getAMRDeviceState(deviceRef) == kAMRestorableDeviceStateDFU else {
        let devState = getAMRDeviceState(deviceRef).description
        contextRef.context.status.setResult(state: .failed,
                                            errReason: "VM not in DFU mode (curstate = \(devState))")
        return
    }

    VM.logger.info("restore: begin")
    let logDir = contextRef.context.logDir
    if let logDir {
        if let logDir = try? logDir.file(name: "host") {
            AMRestorableDeviceSetLogFileURL(
                deviceRef,
                logDir as CFURL,
                "HostLogType" as CFString
            )
        }

        if let logFile = try? logDir.file(name: "device") {
            AMRestorableDeviceSetLogFileURL(
                deviceRef,
                logFile as CFURL,
                "DeviceLogType" as CFString
            )
        }

        if let logFile = try? logDir.file(name: "serial") {
            AMRestorableDeviceSetLogFileURL(
                deviceRef,
                logFile as CFURL,
                "SerialLogType" as CFString
            )

            AMRestorableDeviceStartWatchingSerialLog(deviceRef)
        }

        print("Restore: logs available under \(logDir.folder.path)")
    }

    let restoreConfig = contextRef.context.restoreConfig as CFDictionary
    contextRef.context.status.state = .started

    AMRestorableDeviceRestore(
        deviceRef,
        restoreConfig,
        restoreProgressCallback,
        context
    )

    if event == kAMRestorableDeviceEventDisappeared {
        contextRef.context.status.setResult(state: .failed,
                                            errReason: "disconnected from VM")
    }
}

// restoreProgressCallback serves as the callback for AMRestorableDeviceRestore, called throughout
//  the restore process and upon completion (successfull or otherwise); RestoreContext.status is
//  set with the result and .completion semaphore - during the operation, progress is output to stdout
private func restoreProgressCallback(
    _ deviceRef: AMRestorableDevice?,
    _ restoreInfo: CFDictionary?,
    _ context: UnsafeMutableRawPointer? // &RestoreContext
) {
    let restoreInfo = restoreInfo! as! [String: Any]
    let contextRef = Unmanaged<VM.RestoreContextWrapper>
        .fromOpaque(context!)
        .takeUnretainedValue()

    // print the progress if needed
    if let progress = restoreInfo[kAMRestorableDeviceInfoKeyOverallProgress as String] {
        if (progress as! Int32) >= 0 {
            let printStr = String(format: "%3d", progress as! Int32)
            print("[Restore] Progress: \(printStr)%", terminator: "\r")
            fflush(stdout)
        } else {
            print("[Restore] Waiting...", terminator: "\r")
            fflush(stdout)
        }
    }

    let status = restoreInfo[kAMRestorableDeviceInfoKeyStatus as String]
    guard let status = status as? String else {
        return
    }

    // return if still restoring
    if status == (kAMRestorableDeviceStatusRestoring as String) {
        return
    }

    print()

    // stop streaming serial logs
    AMRestorableDeviceStopWatchingSerialLog(deviceRef)

    // record result in context
    if status == (kAMRestorableDeviceStatusSuccessful as String) {
        contextRef.context.status.setResult(state: .success)
        VM.logger.log("restore: completed")
        print("[Restore] Completed")
    } else {
        var errReason = "no reason provided"
        if let error = restoreInfo[kAMRestorableDeviceInfoKeyError as String] {
            errReason = (error as! CFError).localizedDescription
        }

        contextRef.context.status.setResult(state: .failed, errReason: errReason)
    }

    contextRef.context.completion.signal()
}

private func getAMRDeviceState(_ deviceRef: AMRestorableDevice) -> AMRestorableDeviceState {
    return AMRestorableDeviceGetStateWithVersion(deviceRef,
                                                 OpaquePointer(getAMRestorableDeviceStateVersion2()))
}
