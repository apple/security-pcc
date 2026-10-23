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
//  DistinguishedName+CanonicalString.swift
//  CloudAttestationV2
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//

import Foundation
import SwiftASN1
import X509

extension DistinguishedName {
    /// Stable, RFC 4514-shaped string representation of this distinguished name.
    ///
    /// Owned by this module so that policy comparisons and transparency-log
    /// claims do not depend on ``CustomStringConvertible`` of swift-certificates,
    /// whose format is not part of any public contract.
    ///
    /// Format:
    /// - RDNs are joined with `,` in most-specific-first order (i.e. the
    ///   reversed DER order, matching RFC 4514).
    /// - Attributes within an RDN are rendered, then joined with `+` in
    ///   lexicographic order of their rendered form.
    /// - Each attribute is `<key>=<escaped-value>`. The key is taken from a
    ///   frozen short-name table (CN, C, L, ST, O, OU, STREET, DC, E) with a
    ///   dotted-OID fallback.
    /// - Printable/UTF-8/IA5 string values are escaped per RFC 4514 §2.4
    ///   (`,+"\<>;`, leading `#`/space, trailing space). All other ASN.1
    ///   types are emitted as `#<hex of DER bytes>`.
    var canonicalString: String {
        self.reversed().map { $0.canonicalString }.joined(separator: ",")
    }
}

extension RelativeDistinguishedName {
    var canonicalString: String {
        self.map { $0.canonicalString }.sorted().joined(separator: "+")
    }
}

extension RelativeDistinguishedName.Attribute {
    var canonicalString: String {
        let key = Self.shortName(for: self.type) ?? Self.dottedOID(self.type)
        return "\(key)=\(self.canonicalValueString)"
    }

    private static func shortName(for oid: ASN1ObjectIdentifier) -> String? {
        switch oid {
        case .RDNAttributeType.commonName: return "CN"
        case .RDNAttributeType.countryName: return "C"
        case .RDNAttributeType.localityName: return "L"
        case .RDNAttributeType.stateOrProvinceName: return "ST"
        case .RDNAttributeType.organizationName: return "O"
        case .RDNAttributeType.organizationalUnitName: return "OU"
        case .RDNAttributeType.streetAddress: return "STREET"
        case .RDNAttributeType.domainComponent: return "DC"
        case .RDNAttributeType.emailAddress: return "E"
        default: return nil
        }
    }

    private static func dottedOID(_ oid: ASN1ObjectIdentifier) -> String {
        oid.oidComponents.map { String($0) }.joined(separator: ".")
    }

    private var canonicalValueString: String {
        if let string = String(self.value) {
            return Self.escape(string)
        }
        var serializer = DER.Serializer()
        try? ASN1Any(self.value).serialize(into: &serializer)
        let hex = serializer.serializedBytes.map { String(format: "%02x", $0) }.joined()
        return "#" + hex
    }

    private static func escape(_ string: String) -> String {
        let needsEscape: Set<Character> = [",", "+", "\"", "\\", "<", ">", ";"]
        let characters = Array(string)
        var escaped = ""
        escaped.reserveCapacity(characters.count)
        for (index, character) in characters.enumerated() {
            let isLeading = index == 0 && (character == " " || character == "#")
            let isTrailing = index == characters.count - 1 && character == " "
            if isLeading || isTrailing || needsEscape.contains(character) {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return escaped
    }
}
