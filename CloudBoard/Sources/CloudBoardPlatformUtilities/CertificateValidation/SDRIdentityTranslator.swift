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

import os
import SwiftASN1
import X509

/// Translates SDR identities into APRNs.
package enum SDRIdentityTranslator {
    private static let logger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "SDRIdentityTranslator"
    )

    package static let rootCAPEM: String = """
    -----BEGIN CERTIFICATE-----
    MIICVzCCAd2gAwIBAgIQEym78b3A3yxs2v+i106aQTAKBggqhkjOPQQDAzBtMSsw
    KQYKCZImiZPyLGQBAQwbaWRlbnRpdHk6aWRtcy5ncm91cC4xNDA1MzIzMRYwFAYD
    VQQDDA1JU1MgUm9vdCBDQSA2MSYwJAYDVQQLDB1tYW5hZ2VtZW50OmlkbXMuZ3Jv
    dXAuMTM5OTY0NDAeFw0xOTA0MTcyMjE4MzVaFw0zOTA0MTMwMDAwMDBaMG0xKzAp
    BgoJkiaJk/IsZAEBDBtpZGVudGl0eTppZG1zLmdyb3VwLjE0MDUzMjMxFjAUBgNV
    BAMMDUlTUyBSb290IENBIDYxJjAkBgNVBAsMHW1hbmFnZW1lbnQ6aWRtcy5ncm91
    cC4xMzk5NjQ0MHYwEAYHKoZIzj0CAQYFK4EEACIDYgAEv9ttN3/hhucfZb0ns6/j
    pttSODmQ40XgsssT4BPYB4mKKM8YYqs4qPzIk3fD+JHxAwO5KnbMWlN5LIMGrQF2
    wNvpSRJUu7sIuN/1ydexHGbsEPpHaXOj1t5ULtjGGSxLo0IwQDAPBgNVHRMBAf8E
    BTADAQH/MB0GA1UdDgQWBBSdrMWqMawHF0shqF7QUhZLlaeVhDAOBgNVHQ8BAf8E
    BAMCAQYwCgYIKoZIzj0EAwMDaAAwZQIwKK8QPSGaotUN6nleiJYGxWBXEgHVycYB
    O/VAr+XJEV3IkDk4+svj93kzaQnyBz8pAjEAqDHeq2PUEpIXKI6iWk1JINLrWUmQ
    mFcyaUxaGuBZuxmVB6LAxvuhRa4lkMm9MsFS
    -----END CERTIFICATE-----
    """

    private static let rootCACert: Certificate = try! Certificate(pemEncoded: rootCAPEM)

    private static func aprnPrefix(root: Certificate) -> String? {
        switch root {
        case self.rootCACert:
            return "aprn:apple:sdr:1399644"
        default:
            return nil
        }
    }

    // UTF8String with the value "Application Authority"
    private static let appAuthorityRequiredValue: ArraySlice<UInt8> = [
        0x0C, 0x15, 0x41, 0x70, 0x70, 0x6C, 0x69, 0x63, 0x61, 0x74, 0x69, 0x6F,
        0x6E, 0x20, 0x41, 0x75, 0x74, 0x68, 0x6F, 0x72, 0x69, 0x74, 0x79,
    ]

    package static func validateChainAndComputeAPRN(trustedCertChain certs: [Certificate]) throws -> APRN {
        self.logger.debug("Computing APRN for certs")

        guard certs.count == 4 else {
            self.logger.error("Invalid identity, chain length != 4: \(certs, privacy: .public)")
            throw IdentityTranslationError.invalidChainLength
        }

        let leaf = certs[0]
        let issuer = certs[1]
        let root = certs[3]

        guard let aprnPrefix = Self.aprnPrefix(root: root) else {
            Self.logger.error("Invalid identity, root cert not in acceptable set. Root: \(root, privacy: .public)")
            throw IdentityTranslationError.invalidRoot
        }

        guard let appAuthorityExtension = issuer.extensions[oid: .SDROID.appAuthority],
              appAuthorityExtension.value == Self.appAuthorityRequiredValue else {
            Self.logger
                .error(
                    "Invalid identity, root cert has missing or invalid app ID extension. Root: \(root, privacy: .public)"
                )
            throw IdentityTranslationError.missingAppID
        }

        var appDSID: Substring?
        var namespaceDSID: Substring?

        for rdn in leaf.subject {
            for ava in rdn {
                switch ava.type {
                case .SDROID.uid:
                    if let value = String(ava.value),
                       value.utf8.starts(with: "identity:idms.group.".utf8) {
                        appDSID = Substring(value.utf8.dropFirst("identity:idms.group.".utf8.count))
                    }
                case .RDNAttributeType.organizationalUnitName:
                    if let value = String(ava.value),
                       value.utf8.starts(with: "management:idms.group.".utf8) {
                        namespaceDSID = Substring(value.utf8.dropFirst("management:idms.group.".utf8.count))
                    }
                default:
                    // Skip these, they don't contribute to the APRN.
                    ()
                }
            }
        }

        let aprnString: String
        if let appDSID, let namespaceDSID, appDSID.isAllASCIINumeric, namespaceDSID.isAllASCIINumeric {
            aprnString = "\(aprnPrefix)::app-v2:/mg/\(namespaceDSID)/ig/\(appDSID)"
        } else if let fqan = try? leaf.extensions.subjectAlternativeNames?.fqan {
            aprnString = "\(aprnPrefix)::fqan:\(fqan)"
        } else {
            Self.logger
                .error("Invalid identity, leaf has no valid DSIDs and no valid FQAN. Leaf: \(leaf, privacy: .public)")
            throw IdentityTranslationError.missingFQANAndDSIDs
        }

        Self.logger.info("Produced APRN string \(aprnString, privacy: .public)")
        return try APRN(string: aprnString)
    }
}

extension Substring {
    package var isAllASCIINumeric: Bool {
        self.utf8.allSatisfy {
            (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains($0)
        }
    }
}

extension SubjectAlternativeNames {
    package var fqan: String? {
        for name in self {
            if let fqan = name.dnsNameString {
                return fqan
            }
        }

        return nil
    }
}

extension GeneralName {
    package var dnsNameString: String? {
        if case .dnsName(let name) = self {
            return name
        } else {
            return nil
        }
    }
}

extension ASN1ObjectIdentifier {
    enum SDROID {
        static let appAuthority: ASN1ObjectIdentifier = [1, 2, 840, 113_635, 100, 6, 26, 4]
        static let uid: ASN1ObjectIdentifier = [0, 9, 2342, 19_200_300, 100, 1, 1]
    }
}

package enum IdentityTranslationError: Error {
    case invalidChainLength
    case invalidRoot
    case missingAppID
    case missingFQANAndDSIDs
}
