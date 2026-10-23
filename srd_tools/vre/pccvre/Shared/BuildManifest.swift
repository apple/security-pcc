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
import Foundation

struct BuildManifest {
    typealias TagName = String
    typealias ManifestDict = [TagName: Any]

    enum ParseError: Swift.Error, CustomStringConvertible {
        case deserialize
        case noBuildIdentities
        case noManifest
        case loadFile

        var description: String {
            switch self {
                case .deserialize: "could not parse plist file"
                case .noBuildIdentities: "no BuildIdentities section"
                case .noManifest: "no Manifest section"
                case .loadFile: "could not load file"
            }
        }
    }

    let loaded: ManifestDict
    var buildIdentities: [BuildManifest.BuildIdentity]? {
        if let buildIdentitiesDict = loaded["BuildIdentities"] as? [ManifestDict] {
            return buildIdentitiesDict.compactMap { try? BuildManifest.BuildIdentity($0) }
        }

        return nil
    }

    // init loads a BuildManifest.plist at the given path -- ensure it contains expected "BuildIdentities"
    //  (and other descendant) structs
    init(_ plistPath: URL) throws {
        let data: Data
        do {
            data = try Data(contentsOf: plistPath)
        } catch {
            throw ParseError.loadFile
        }

        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? ManifestDict else {
            throw ParseError.deserialize
        }

        self.loaded = plist
        guard let _ = buildIdentities else {
            throw ParseError.noBuildIdentities
        }
    }

    // pickBuildIdentities returns BuildIdentity entries matching ticket platform constraints where present:
    //   (BORD/ApBoardID, CHIP/ApChipID, SDOM/ApSecurityDomain, clas/Cryptex1,ProductClass,
    //    fchp: Cryptex1,ChipID, type/Cryptex1,Type, styp: Cryptex1,SubType)
    func pickBuildIdentities(constraints: Image4Manifest.Properties) -> [BuildManifest.BuildIdentity]? {
        guard let buildIdentities else {
            return nil
        }

        return buildIdentities.filter { bid in
            // return BuildIdentities[] with matching (available) tags in constraints (MANP from a ticket)
            for (manbTag, manbVal) in constraints where ["BORD", "CHIP", "SDOM",
                                                         "clas", "fchp", "styp", "type"].contains(manbTag)
            {
                guard let bidVal = BuildManifest.value(manbTag, dict: bid.loaded),
                      propEqual(manbVal, bidVal)
                else {
                    return false
                }

                return true
            }

            return false
        }
    }

    // value returns a the value from a BuildManifest.BuildIdentity.Manifest section by either
    //  short (4cc) tag or manifest tag name; nil if not found
    static func value(_ fourcc: TagName, dict: ManifestDict) -> Any? {
        if let tag = dict[fourcc] {
            return tag
        }

        guard let tag = Image4Manifest.tagOf(fourcc: fourcc) else {
            return nil
        }

        return dict[tag]
    }

    // propEqual compares two property values of various types -- in particular, values represented as
    //  strings may need to be converted to Numeric (including those represented as 0xHexString in a
    //  BuildManifest but stored as UInt64 in a Ticket)
    private func propEqual(_ a: Any, _ b: Any) -> Bool {
        // comparing UInt against String representation (often hex)
        if let a = a as? any UnsignedInteger,
           let b = b as? String
        {
            if b.hasPrefix("0x") {
                if let b = UInt64(b.trimPrefix("0x"), radix: 16) {
                    return UInt64(a) == b
                }

                return false
            }

            guard let b = UInt64(b) else {
                return false
            }

            return UInt64(a) == b
        }

        // otherwise, compare any Hashable type
        if let a = a as? AnyHashable,
           let b = b as? AnyHashable
        {
            return a == b
        }

        return false
    }
}

extension BuildManifest {
    // BuildManifest.BuildIdentity encapsulates the manifest of a build target -- cryptexes typically
    //  contain a fully-populated set of BuildIdentities, even if the image itself only contains one
    struct BuildIdentity {
        let loaded: ManifestDict
        var info: ManifestDict? { loaded["Info"] as? ManifestDict }

        var manifest: Manifest? {
            if let manifest = loaded["Manifest"] as? ManifestDict {
                return Manifest(manifest)
            }

            return nil
        }

        // isOSImage returns true if BuildIdentity pertains to an OS image
        var isOSImage: Bool {
            guard let info else {
                return false
            }

            if let osdmgsize = info["OSDiskImageSize"] as? UInt {
                return osdmgsize > 0
            }
            if let osvarsize = info["OSVarContentSize"] as? UInt {
                return osvarsize > 0
            }

            return false
        }

        // isDataOnly returns true if BuildIdentity pertains to a data-only cryptex
        //  (containing no code the target platform (PCC) is able to execute)
        var isDataOnly: Bool {
            if let dataonly = loaded["Cryptex1,DataOnly"] as? Bool {
                return dataonly
            }

            return false
        }

        init(_ data: ManifestDict) throws {
            self.loaded = data
            guard let _ = manifest else {
                throw ParseError.noManifest
            }
        }
    }
}

extension BuildManifest.BuildIdentity {
    // BuildManifest.BuildIdentity.Manifest contains the Manifest/BOM for the specific BuildIdentity,
    //  in particular, pathnames (relative to self.contentDir) and their digest
    struct Manifest {
        typealias TagName = BuildManifest.TagName
        typealias ManifestDict = BuildManifest.ManifestDict

        var loaded: ManifestDict
        var tags: [TagName] { Array(loaded.keys) }

        init(_ data: ManifestDict) {
            self.loaded = data
        }

        // value returns a the value from a BuildManifest.BuildIdentity.Manifest section by either
        //  short (4cc) tag or manifest tag name; nil if not found
        func value(_ tag: TagName) -> ManifestDict? {
            return BuildManifest.value(tag, dict: loaded) as? ManifestDict
        }

        // digest returns the "Digest" entry of a BuildManifest.BuildIdentity.Manifest entry (indexed
        //  either by short (4cc) tag or manifest tag name), in raw Data form -- an additional step
        //  is required to identify by what digest algorithm output the value represents
        func digest(_ tag: TagName) -> Data? {
            return value(tag)?["Digest"] as? Data
        }

        // digestType attempts to determine the digest algorithm associated with a
        //  BuildManifest.BuildIdentity.Manifest (indexed either by short (4cc) tag or manifest tag name),
        //  either by .Info.HashMethod (if available) or by count of digest bytes (which is assumed to be
        //  either sha2-256 or sha2-384); nil if unable to determine
        func digestType(_ tag: TagName) -> (any CryptoKit.HashFunction.Type)? {
            if let def = value(tag) {
                if let info = def["Info"] as? ManifestDict {
                    if let hashMethod = info["HashMethod"] as? String {
                        switch hashMethod.lowercased() {
                            case "sha2-256": return SHA256.self
                            case "sha2-384": return SHA384.self
                            case "sha2-512": return SHA512.self
                            default: break
                        }
                    }
                }
            }

            if let hash = digest(tag) {
                switch hash.count {
                    case 32: return SHA256.self
                    case 48: return SHA384.self
                    case 64: return SHA512.self
                    default: break
                }
            }

            return nil
        }

        // path returns the (relative) pathname the BuildManifest.BuildIdentity.Manifest
        //  entry represents (indexed either by short (4cc) tag or manifest tag name)
        func path(_ tag: TagName) -> String? {
            if let def = value(tag) {
                if let info = def["Info"] as? ManifestDict {
                    return info["Path"] as? String
                }
            }

            return nil
        }
    }
}
