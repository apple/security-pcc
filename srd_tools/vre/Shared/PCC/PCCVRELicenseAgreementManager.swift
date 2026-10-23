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

import CoreAnalytics
import CryptoKit
import Foundation

class LicenseAgreementMetadata: NSObject, Decodable, Encodable {
    var version: String
    init(version: String) {
        self.version = version
    }
}

class PCCVRELicenseAgreementManager {
    static let licenseAgreementPrefFileName = "SecurityResearchVMLicenseAgreementPref.plist"
    let licenseAgreementPath: URL
    let licenseAgreementPreferencePath: URL
    let licenseAgreementHash: String

    init(licenseAgreementPath: URL, licenseAgreementPreferenceBaseLocation: URL, licenseAgreementHash: String) {
        self.licenseAgreementPath = licenseAgreementPath

        licenseAgreementPreferencePath = licenseAgreementPreferenceBaseLocation.appending(path: PCCVRELicenseAgreementManager.licenseAgreementPrefFileName, directoryHint: .notDirectory)
        self.licenseAgreementHash = licenseAgreementHash
    }

    private func licenseAgreementAccepted() -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false

        guard fm.fileExists(atPath: licenseAgreementPreferencePath.path(), isDirectory: &isDir) && !isDir.boolValue else {
            if isDir.boolValue {
                do {
                    try fm.removeItem(at: licenseAgreementPreferencePath)
                } catch {
                    print("Failed to remove license agreement metadata at \(licenseAgreementPreferencePath)")
                }
            }
            return false
        }

        let data = fm.contents(atPath: licenseAgreementPreferencePath.path())
        guard let data = data else {
            return false
        }

        do {
            let decoder = PropertyListDecoder()
            let metadata = try decoder.decode(LicenseAgreementMetadata.self, from: data)
            guard metadata.version == licenseAgreementHash else {
                return false
            }
        } catch {
            print("Error when reading contents from \(licenseAgreementPreferencePath), attempting to gracefully continue")
            try? fm.removeItem(at: licenseAgreementPreferencePath)
            return false
        }

        return true
    }

    func showLicenseAgreement() throws {
        let fm = FileManager.default
        let textutil = Process()
        textutil.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        textutil.arguments = ["-cat", "txt", licenseAgreementPath.path(), "-stdout"]
        guard fm.fileExists(atPath: textutil.executableURL!.path, isDirectory: nil) else {
            throw PCCVREError("/usr/bin/textutil does not exist.")
        }

        textutil.standardOutput = FileHandle(fileDescriptor: STDOUT_FILENO)
        textutil.standardError = FileHandle(fileDescriptor: STDERR_FILENO)
        textutil.launch()
        textutil.waitUntilExit()

        if textutil.terminationReason == .uncaughtSignal || textutil.terminationStatus != 0 {
            throw PCCVREError("textutil exited unexpectedly.")
        }
    }

    @discardableResult
    func triggerLicenseAgreementAcceptanceFlow(force: Bool) throws -> Bool {
        let alreadyAccepted = licenseAgreementAccepted()
        guard !alreadyAccepted || force else {
            return false
        }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: licenseAgreementPath.path(), isDirectory: &isDir) && !isDir.boolValue else {
            throw PCCVREError("License agreement is not present at \(licenseAgreementPath.path()) or is not a file")
        }

        let licenseData = fm.contents(atPath: licenseAgreementPath.path())
        guard let licenseData = licenseData else {
            throw PCCVREError("Failed to get contents of license agreement at \(licenseAgreementPath.path())")
        }

        let hash = SHA256.hash(data: licenseData)
        let hashString = hash.compactMap { String(format: "%02x", $0) }.joined()
        guard hashString == licenseAgreementHash else {
            throw PCCVREError("The license agreement at \(licenseAgreementPath) has been modified, unable to accept")
        }

        if !alreadyAccepted {
            print("You have not agreed to the research program license. You must agree to the license below in order to use this tool.\n")
        }

        print("Press enter to display the license:\n")
        _ = readLine()

        try showLicenseAgreement()

        print("\n")

        guard geteuid() == 0 else {
            throw PCCVREError("Agreeing to this license requires admin privileges, please run this tool as the root user.")
        }

        print("By typing 'agree' you are agreeing to the terms of the software license agreements. Any other response will cancel. [agree, cancel]\n")

        let userInput = readLine()
        let agreed = (userInput == "agree")

        if !alreadyAccepted {
            AnalyticsSendEventLazy("com.apple.securityresearch.pccvre.licenseaccepted") {
                [
                    "accepted": agreed as NSNumber,
                ]
            }
        }

        guard agreed || os_variant_allows_internal_security_policies(applicationName) else {
            throw PCCVREError("User decided not to agree to this software license.")
        }

        let metadata = LicenseAgreementMetadata(version: licenseAgreementHash)

        let encoder = PropertyListEncoder()
        let dataToStore = try encoder.encode(metadata)
        try dataToStore.write(to: licenseAgreementPreferencePath, options: .atomic)

        print("You can review the license at: \(licenseAgreementPath.path())")
        return true
    }
}
