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
import os

extension TransparencyLog {
    // KTInitBag provides an interface for REST client configuration API.
    //  The associated plist represents a dictionary of attributes including URL endpoints to
    //  retrieve public keys and submit log queries
    struct KTInitBag {
        private let linkBag: [String: Any]

        static let signedBagAlgo: SecKeyAlgorithm = .rsaSignatureMessagePKCS1v15SHA256

        init(
            endpoint: URL, // KTInitBag base REST endpoint
            useIdentity: Bool = false, // set x-internal header if true
            signedBag: Bool = true // request signed payload version (and verify)
        ) async throws {
            let reqParams = [
                URLQueryItem(name: "ix", value: signedBag ? "3" : "5"),
                URLQueryItem(name: "p", value: "atresearch"),
            ]
            let endpoint = endpoint.appending(path: "init/getBag").appending(queryItems: reqParams)

            let (data, _) = try await urlGet(
                url: endpoint,
                useIdentity: false, // not actually used for this call
                headers: useIdentity ? ["x-internal": "true"] : nil, // .. but indicate available
                mimeType: "application/xml"
            )

            let bagData = try TransparencyLog.KTInitBag.plistAsDict(data)

            if signedBag {
                // unpack payload of signature, (partial) cert chain, the bag itself and verify
                do {
                    self.linkBag = try TransparencyLog.KTInitBag.unpackSigned(bagData)
                } catch {
                    throw TransparencyLogError("unpack signed payload: \(error)")
                }
            } else {
                self.linkBag = bagData
            }
        }
    }
}

extension TransparencyLog.KTInitBag {
    // currently defined fields of an AT Researcher KT Init Bag
    enum Field: String {
        case atResearcherConsistencyProof = "at-researcher-consistency-proof"
        case atResearcherListTrees = "at-researcher-list-trees"
        case atResearcherLogHead = "at-researcher-log-head"
        case atResearcherLogInclusionProof = "at-researcher-log-inclusion-proof"
        case atResearcherLogLeaves = "at-researcher-log-leaves"
        case atResearcherLogLeavesForRevision = "at-researcher-log-leaves-for-revision"
        case atResearcherPublicKeys = "at-researcher-public-keys"
        case bagExpiryTimestamp = "bag-expiry-timestamp"
        case bagType = "bag-type"
        case buildVersion = "build-version"
        case platform
        case ttrEnabled = "ttr-enabled"
        case uuid
    }

    enum BagType: String {
        case standard, carry, test
    }

    // value returns a field from the currently loaded link bag as a String value;
    //  throws error if field not found
    func value(_ field: Field) -> String? {
        guard let value = linkBag[field.rawValue] else {
            return nil
        }

        switch value {
        case let value as String:
            return value
        case let value as Int64:
            return String(value)
        default: // eg, not expecting array types here
            return nil
        }
    }

    // url returns a field from the currently loaded link bag as properly-formatted URL;
    //  throws error if field not found or not formatted as a URL
    func url(_ field: Field) -> URL? {
        guard let urlStr = value(field),
              let url = URL(string: urlStr)
        else {
            return nil
        }

        return url
    }

    // expires returns Date (timestamp) of expected lifetime of currently loaded link bag (after which
    //  time another fetch() operation should be made); throws error if unable to obtain/parse expiry field
    func expires() -> Date? {
        guard let expValue = value(Field.bagExpiryTimestamp),
              let expEpoch = UInt64(expValue)
        else {
            return nil
        }

        return Date(timeIntervalSince1970: Double(expEpoch / 1000))
    }

    // bagType returns "bag-type" field enum indicating standard, carry, or test; throws error if unable to
    //  obtain bag-type field of currently loaded bag or otherwise not of pre-determined type
    func bagType() -> BagType? {
        guard let bagTypeValue = value(Field.bagType),
              let bagType = BagType(rawValue: bagTypeValue)
        else {
            return nil
        }

        return bagType
    }

    // debugDump outputs contents of KTInitBag to logger debug output
    func debugDump() {
        TransparencyLog.logger.debug("KT Init Bag contents:")
        for (k, v) in linkBag {
            TransparencyLog.logger.debug("  \(k, privacy: .public): \(v as? String ?? "<unknown>", privacy: .public)")
        }
    }

    // decodeSignedBag unpacks a signed KT Link Bag, verifies payload, and return linkBag upon success
    private static func unpackSigned(_ signedBag: [String: Any]) throws -> [String: Any] {
        guard let signature = signedBag["signature"] as? NSData else {
            throw TransparencyLogError("missing/decode 'signature' attribute")
        }

        guard let certChainEncoded = signedBag["certs"] as? [NSData] else {
            throw TransparencyLogError("missing 'certs' attribute")
        }

        var certChain: [SecCertificate] = []
        for der in certChainEncoded {
            guard let cert = SecCertificateCreateWithData(nil, der as CFData) else {
                throw TransparencyLogError("decode 'certs' attribute")
            }

            certChain.append(cert)
        }

        guard let bagEncoded = signedBag["bag"] as? NSData else {
            throw TransparencyLogError("missing/decode 'bag' attribute")
        }

        
        guard let pubkey = SecCertificateCopyKey(certChain[0]) else {
            throw TransparencyLogError("cannot extract pubkey from cert")
        }

        guard SecKeyVerifySignature(pubkey, signedBagAlgo, bagEncoded, signature, nil) else {
            throw TransparencyLogError("signature verify failed")
        }

        return try plistAsDict(bagEncoded as Data)
    }

    // returns data (containing a plist dictionary) as a swift dictionary
    private static func plistAsDict(_ data: Data) throws -> [String: Any] {
        guard let res = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw TransparencyLogError("decode plist dictionary")
        }

        return res
    }
}
