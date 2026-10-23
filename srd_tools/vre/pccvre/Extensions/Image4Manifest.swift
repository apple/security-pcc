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

@_spi(Private) import CloudAttestation
import CryptoKit

extension Image4Manifest {
    // name returns ticket digest as simple hex string (unlike description, doesn't include digest algo)
    var name: String { self.digest().bytes.hexString }

    // platformProps returns set of manifest platform properties (MANP 4cc) or nil if unable to extract
    func platformProps() -> Image4Manifest.Properties? {
        return try? self.properties.first(where: { $0.key == "MANP" })?.value as? Image4Manifest.Properties
    }

    // isDataOnly returns true if manifest ticket pertains to a cryptex containing no code
    //  the target platform (PCC) is able to execute
    func isDataOnly() -> Bool {
        if let platformProps = self.platformProps() {
            for prop in platformProps where prop.key == "data" {
                if let value = prop.value as? Bool {
                    return value
                }
            }
        }

        return false
    }

    // digests returns a dictionary of manifest 4cc and associated Data representing a digest.
    //  No hints as to the type of digest other than length - presently SHA2 type (sha2-384).
    //  If there was an error in parsing, nil is returned - an empty map implies no digests were found.
    func digests() -> [String: Data]? {
        var digestEntries: [String: Data] = [:]
        guard let manProps = try? self.properties else {
            return nil
        }

        for prop in manProps {
            guard let subProperties = prop.value as? Image4Manifest.Properties else {
                return nil
            }

            for subProp in subProperties where subProp.key == "DGST" {
                guard let hashData = subProp.value as? Data else {
                    return nil
                }

                digestEntries[prop.key] = hashData
            }
        }

        return digestEntries
    }

    // isRestore4cc returns true if the 4cc identifier is associated with a RestoreOS environment
    static func isRestore4cc(_ fourcc: String) -> Bool {
        if ["rfta", "rfts"].contains(fourcc) {
            return true
        }

        if let tag = Image4Manifest.tagOf(fourcc: fourcc) {
            return self.isRestoreTag(tag)
        }

        return false
    }

    // isRestoreTag returns true if the (BuildManifest) tag is associated with a RestoreOS environment
    static func isRestoreTag(_ tag: String) -> Bool {
        return tag.hasPrefix("Restore") || tag.contains(",Restore")
    }

    // tagOf returns the tag name (used in BuildManifest.plist) corresponding to the 4cc identifier
    //  (used in tickets) -- returns nil, if no mapping found
    static func tagOf(fourcc: String) -> String? {
        for element in Mirror(reflecting: kImg4Types).children.map({ $0.value as! Img4Types }) {
            if element.fileType.takeRetainedValue() as String == fourcc {
                return element.requestName.takeRetainedValue() as String
            }
        }

        let miscTags: [String: String] = [
            // libcryptex/asset.c
            "ginf": "Cryptex1,CryptexInfoPlist",
            "gtcd": "Cryptex1,GenericTrustCache",
            "gtgv": "Cryptex1,GenericVolume",
            "c411": "Ap,CryptexInfoPlist",
            "pdmg": "PersonalizedDMG",

            // misc tags not centralized
            "ftap": "ftap",
            "ftsp": "ftsp",
            "isys": "SystemVolume",
            "msys": "Ap,SystemVolumeCanonicalMetadata",
            "rosi": "OS",
            "rspt": "Ap,RestoreSecurePageTableMonitor",
            "rfta": "rfta",
            "rfts": "rfts",
            "rtrx": "Ap,RestoreTrustedExecutionMonitor",
            "sptm": "Ap,SecurePageTableMonitor",
            "trxm": "Ap,TrustedExecutionMonitor",
            "BORD": "ApBoardID",
            "CHIP": "ApChipID",
            "SDOM": "ApSecurityDomain"
        ]

        return miscTags[fourcc]
    }
}
