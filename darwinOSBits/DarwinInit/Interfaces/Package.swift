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

//
//  Package.swift
//  DarwinInit
//

#if os(macOS)
import PackageKit
import PackageKit_Private
import Security
import System
import os
internal import DarwinInitBridging

struct PackageInstaller {
    let url: URL

    // Package installation destination is only allowed to be "/" for now.
    // Note: the `DistributionController` expect a volume path instead of a
    // real destination for its checking. If this ever needs to be changed to
    // something more generic, the path passed to `DistributionController` needs
    // to be fixed up.
    private let destination: String = "/"
    private let installDelegate = PackageInstallDelegate()

    static let sharedLogger = Logger.package

    private func productQualifiesForInstall(_ distController: PKDistributionController) -> Bool {
        do {
            try distController.performInstallationCheckReturningError()
            try distController.performVolumeCheck(withPath: destination)
            try distController.performUpgradeCheck(withPath: destination)
            try distController.performPeripheralCheckReturningError()
        } catch let error as NSError {
            logger.error("Product does not qualify for installation: \(error)")
            return false
        }

        return true
    }

    private func evaluateDistForInstall(distController: PKDistributionController, product: PKProduct) -> Bool {
        distController.setDestinationPath(destination)
        distController.waitUntilQuiescent()

        guard let rootChoice = product.distribution.rootChoice(forInterfaceType: nil, creatingIfNeeded: false) else {
            logger.error("Malformed product package, the product is missing its root choice")
            return false
        }

        guard let _ = rootChoice.value(forKey: PKDistributionChoiceChildrenKey) as? [PKDistributionChoice] else {
            logger.error("Malformed product package, the product is missing its children under the root choice")
            return false
        }

        distController.waitUntilQuiescent()

        if !productQualifiesForInstall(distController) {
            logger.error("The product does not qualify for installation on this volume/device")
            return false
        }

        return true
    }

    private func authorizationForInstall() -> AuthorizationRef? {
        var auth: AuthorizationRef? = nil

        var status = AuthorizationCreate(nil, nil, AuthorizationFlags(), &auth)
        guard status == errAuthorizationSuccess, let auth = auth else {
            let errorStr = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
            logger.error("Failed to create AuthorizationRef: \(errorStr)")
            return nil
        }

        // We need to ensure the pointers are still valid when calling `AuthorizationCopyRights`,
        // so it's not sufficient to use the inout operator (&) since that only creates a temporary
        // pointer. Instead `withUnsafeMutablePointer` and friends is needed here
        let authName = kPKRightInstallSoftware
        authName.withCString { bytes in
            var item = AuthorizationItem(name: bytes, valueLength: 0, value: nil, flags: 0)

            withUnsafeMutablePointer(to: &item) { itemPointer in
                var rights = AuthorizationRights(count: 1, items: itemPointer)
                let flags = AuthorizationFlags.extendRights

                status = AuthorizationCopyRights(auth, &rights, nil, flags, nil)
            }
        }

        guard status == errAuthorizationSuccess else {
            let errorStr = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
            logger.error("Failed to create AuthorizationRef: \(errorStr)")
            return nil
        }

        return auth
    }

    func install() -> Bool {
        let logger = PackageInstaller.sharedLogger

        logger.log("Installing package \(url) to \(destination)")

        // initializing with the parent class PKProduct doesn't work in Swift, since we only
        // want to handle `PKArchiveProduct` here, initialize that class explicitly
        var product: PKProduct? = nil
        do {
            product = try PKArchiveProduct(byLoadingProductAt: url) as PKProduct
        } catch let error as NSError {
            logger.error("Not a valid PKArchiveProduct: \(error)")
            return false
        }

        guard let distController = PKDistributionController.init(product: product, interfaceType: nil, notify: nil) else {
            logger.error("Product does not qualify, cannot establish distribution controller")
            return false
        }

        guard evaluateDistForInstall(distController: distController, product: product!) else {
            logger.error("Installation evaluation failed")
            return false
        }

        guard let packageSpecifiers = distController.orderedPackageSpecifiersToInstall() else {
            logger.error("There are no eligible package specifiers to begin installation")
            return false
        }

        guard let request = PKInstallRequest(packages: packageSpecifiers, destination: destination) else {
            logger.error("Failed to create PKInstallRequest for packages: \(packageSpecifiers)")
            return false
        }

        guard let auth = authorizationForInstall() else {
            logger.error("Authorization failed, make sure you are running as root")
            return false
        }

        request.setAuthorization(auth)
        request.setMinimumRequiredTrustLevel(.appleSoftwareDevelopment)
        do {
            try request.evaluateTrustReturningError()
        } catch let error as NSError {
            logger.error("Package trust evaluation failed: \(error)")
            return false
        }

        do {
            try request.performPreflightCheckReturningError()
        } catch let error as NSError {
            logger.error("Package preflight check failed: \(error)")
            return false
        }

        do {
            _ = try PKInstallClient(request: request, delegate: self.installDelegate, options: .userInitiatedInstallation)
        } catch let error as NSError {
            logger.error("Package installation can't start: \(error)")
            return false
        }

        logger.log("Package installation request sent for: \(url)")

        // PackageKit dispatches events to delegate on main queue, so we must not be blocked on
        // main queue when polling for the result
        while installDelegate.installing {
            let date = Date(timeIntervalSinceNow: 0.5)
            RunLoop.main.run(until: date)
        }

        return installDelegate.error == nil
    }
}

class PackageInstallDelegate: NSObject {
    var error: NSError? = nil
    var installing: Bool = true

    override func installClientDidBegin(_ installClient: PKInstallClient) {
        PackageInstaller.sharedLogger.info("Package installation did begin")
    }

    override func installClient(_ installClient: PKInstallClient, currentState: PKInstallState, package: PKPackage?, progress: Double, timeRemaining: TimeInterval) {
        let progressDesc = String(format: "%.1f%%", progress)

        var packageDesc = ""
        if let url = package?.fileURL {
            packageDesc = "\(url)"
        }

        let statusDesc = "\(PKInstallStateHelper.localizedDescription(for: currentState))"
        PackageInstaller.sharedLogger.info("[\(progressDesc)] \(statusDesc) \(packageDesc)")
    }

    override func installClient(_ installClient: PKInstallClient, didFailWithError error: Error) {
        self.error = error as NSError
        self.installing = false

        PackageInstaller.sharedLogger.error("Package installation failed: \(self.error!)")
    }

    override func installClientDidFinish(_ installClient: PKInstallClient) {
        self.installing = false
        PackageInstaller.sharedLogger.log("Package installation done")
    }
}
#endif
