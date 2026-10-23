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

//  Copyright © 2024-2025 Apple, Inc. All rights reserved.
//

import Foundation

// DarwinInit.Cryptex provides a structured definition of a cryptex entry of a darwin-init config

struct Cryptex {
    let variant: String
    let url: String
}

extension Cryptex: Decodable {
}

extension DarwinInitHelper {
    func cryptexes() throws -> [Cryptex] {
        try read {
            try $0.listCryptexes()
        } v1Fallback: {
            $0.cryptexes
        }
    }

    /// lookupCryptex returns cryptex entry matching variant (nil if not found)
    func lookupCryptex(variant: String) throws -> Cryptex? {
        try cryptexes().first { $0.variant == variant }
    }

    /// addCryptex replaces existing (with matching variant) or otherwise introduces new cryptex entry
    mutating func addCryptex(_ new: Cryptex) throws {
        try modify {
            try $0.addCryptex(new)
        } v1Fallback: {
            $0.addCryptex(new)
        }
    }

    /// removeCryptex deletes existing cryptex entry with matching variant; returns true if updated
    @discardableResult
    mutating func removeCryptex(variant: String) throws -> Bool {
        let before = try lookupCryptex(variant: variant) != nil
        try modify {
            try $0.removeCryptex(variant: variant)
        } v1Fallback: {
            $0.removeCryptex(variant: variant)
        }
        let after = try lookupCryptex(variant: variant) != nil
        return before != after
    }

    // updateLocalURLs updates cryptex locations (url) with httpServer endpoint (bindAddr/bindPort) --
    //  only entries that are not already in URL form are updated. Returns true if any changes applied,
    //  otherwise false.
    //
    // Example:
    //      "cryptex": [
    //          {
    //              "url": "PlatinumLining3A501_PrivateCloud_Support.aar",
    //              "variant": "PrivateCloud Support"
    //          }, ...
    //       ]
    //   is updated to:
    //      "cryptex": [
    //          {
    //              "url": "http://192.168.64.1:53423/PlatinumLining3A501_PrivateCloud_Support.tar.gz",
    //              "variant": "PrivateCloud Support"
    //          }, ...
    //       ]
    //   (where httpServer.bindAddr == 192.168.64.1 / .bindPort == 53423)
    //
    @discardableResult
    mutating func updateLocalCryptexURLs(httpServer: HTTPServer) throws -> Bool {
        var updated = false

        for cryptex in try cryptexes() {
            if let qurl = httpServer.makeURL(path: cryptex.url),
               qurl.absoluteString != cryptex.url
            {
                let newcryptex = Cryptex(variant: cryptex.variant, url: qurl.absoluteString)
                try addCryptex(newcryptex)
                updated = true
                DarwinInitHelper.logger.log("update cryptex: \(cryptex.url, privacy: .public) -> \(newcryptex.url, privacy: .public)")
            }
        }

        return updated
    }

    //  populateReleaseCryptexes fills in cryptex entries of darwinInit from releaseAssets provided.
    //  Cryptex entries in darwinInit whose -variant- name matches AssetType (ASSET_TYPE_XX) in
    //  releaseMeta are substituted in.
    //
    //  The path location inserted is just the last component (base filename) which will later be
    //  qualified to reference the local HTTP service when the VRE is started.
    //
    //  Example:
    //    darwin-init contains the following stanza:
    //      "cryptex": [
    //          {
    //            "variant": "ASSET_TYPE_PCS",
    //            "url": "/"
    //          },
    //          {
    //            "variant": "ASSET_TYPE_MODEL",
    //            "url": "/"
    //          },
    //          ...
    //      ]
    //
    //   Assets associated with ASSET_TYPE_PCS and ASSET_TYPE_MODEL in the metadata will be filled
    //   into the corresponding entry (variant and url), as well as link/copied into the instance
    //   folder alongside the final darwin-init.json file.
    //
    mutating func populateReleaseCryptexes(
        assets: [CryptexSpec]
    ) throws {
        // As we are populating cryptexes, the variant changes. We need to preserve the order and don't have a way to
        // update a cryptex while changing the variant. So we remove all cryptexes, building up the populated list, and
        // then re-add them.
        var populatedCryptexes = [Cryptex]()
        while let cryptex = try cryptexes().first {
            try removeCryptex(variant: cryptex.variant)

            guard let asset = findAsset(label: cryptex.variant, assets: assets) else {
                populatedCryptexes.append(cryptex)
                continue
            }

            let assetVariant = asset.variant
            guard let assetBasename = asset.path.lastComponent?.string else {
                throw DarwinInitHelperError("derive basename from asset path: \(asset.path)")
            }

            populatedCryptexes.append(Cryptex(
                variant: assetVariant,
                url: assetBasename
            ))
        }
        for cryptex in populatedCryptexes {
            try addCryptex(cryptex)
        }
    }

    func findAsset(label: String, assets: [CryptexSpec]) -> CryptexSpec? {
        // If the label is a known AssetType, try matching by assetType first
        if let _ = SWReleaseMetadata.AssetType(label: label) {
            let assetsOfType = assets.filter { $0.assetType == label }
            if assetsOfType.count == 1 {
                return assetsOfType[0]
            }
        }
        // Fall back to matching by variant name (supports multiple same-type assets
        // whose darwin-init entries use the actual variant as the placeholder)
        let assetsByVariant = assets.filter { $0.variant == label }
        if assetsByVariant.count == 1 {
            return assetsByVariant[0]
        }
        AssetHelper.logger.error("'\(label, privacy: .public)' from darwin-init: no unique match in release assets")
        return nil
    }
}

extension Cryptex {
    init(json: DarwinInitConfigV1.JSONDict) throws {
        guard
            let variant = json["variant"] as? String,
            let url = json["url"] as? String
        else {
            throw DarwinInitHelperError("Cryptex dictionary is missing variant or url: \(json)")
        }
        self.init(variant: variant, url: url)
    }

    var json: DarwinInitConfigV1.JSONDict {
        [
            "variant": variant,
            "url": url
        ]
    }
}

extension DarwinInitConfigV1 {
    // retrieve and store ["cryptex"] block as [DarwinInit.Cryptex]
    var cryptexes: [Cryptex] {
        get {
            var _cryptexes: [Cryptex] = []
            if let cryptexArray = getSection(Section.cryptex) as? [JSONDict] {
                for c in cryptexArray {
                    guard let cryptex = try? Cryptex(json: c) else {
                        continue
                    }

                    _cryptexes.append(cryptex)
                }
            }

            return _cryptexes
        }

        set(newValue) {
            var _new: [JSONDict] = []
            for c in newValue {
                _new.append(c.json)
            }

            setSection(Section.cryptex, value: _new)
        }
    }

    // addCryptex replaces existing (with matching variant) or otherwise introduces new cryptex entry
    mutating func addCryptex(_ new: Cryptex) {
        // preserve the order of cryptexes if replacing
        var replaced = false
        let updatedCryptexes = cryptexes.map {
            if $0.variant == new.variant {
                replaced = true
                return new
            } else {
                return $0
            }
        }
        if replaced {
            cryptexes = updatedCryptexes
            DarwinInitHelper.logger.log("replaced cryptex '\(new.variant, privacy: .public)' (\(new.url, privacy: .public))")
        } else {
            cryptexes.append(new)
            DarwinInitHelper.logger.log("added cryptex '\(new.variant, privacy: .public)' (\(new.url, privacy: .public))")
        }
    }

    // removeCryptex deletes existing cryptex entry with matching variant; returns true if updated
    @discardableResult
    mutating func removeCryptex(variant: String) -> Bool {
        var updated = false
        var loaded = cryptexes

        loaded = loaded.filter {
            if $0.variant == variant {
                updated = true
                return false
            }

            return true
        }

        if updated {
            cryptexes = loaded
            DarwinInitHelper.logger.log("removed cryptex variant '\(variant, privacy: .public)'")
        }

        return updated
    }
}
