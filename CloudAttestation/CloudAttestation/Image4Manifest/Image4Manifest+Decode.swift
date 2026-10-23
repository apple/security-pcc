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
//  Image4Manifest+Decode.swift
//  CloudAttestation
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

import SwiftASN1Internal

/// Image4Manifest Decoder using SwiftASN1. Gated behind SPI to discourage use over AppleImage4.
extension Image4Manifest {
    @_spi(Private)
    public typealias Properties = [(key: String, value: Any)]

    @_spi(Private)
    public var properties: Properties {
        get throws {
            let node = try DER.parse([UInt8](self.data))
            let manifest = try Manifest(derEncoded: node)

            guard let manb = manifest.properties.first(where: { $0.tag == "MANB" }) else {
                throw ASN1Error.invalidASN1Object(reason: "missing MANB")
            }

            guard case .properties(let manbProperties) = manb.value else {
                throw ASN1Error.invalidASN1Object(reason: "MANB is not ASN.1 SET")
            }

            var out = Properties()

            for manbProp in manbProperties {
                var subProps = [(String, Any)]()
                let tag = String(bytes: manbProp.tag.bytes, encoding: .utf8)!
                guard case .properties(let props) = manbProp.value else {
                    throw ASN1Error.invalidASN1Object(reason: "unexpected value type for \(tag)")
                }
                for prop in props {
                    subProps.append((String(bytes: prop.tag.bytes, encoding: .utf8)!, prop.value.swiftRepresentation))
                }
                out.append((tag, subProps))
            }

            return out
        }
    }
}

extension Image4Manifest {
    var sepiDigest: Data? {
        guard
            let sepi =
                (try? self.properties.first { (key: String, value: Any) in
                    key == "sepi"
                }.flatMap { $0.value } as? Image4Manifest.Properties)
        else {
            return nil
        }

        guard
            let sepiDigest =
                (sepi.first(where: { (key: String, value: Any) in
                    key == "DGST"
                }).flatMap { $0.value }) as? Data
        else {
            return nil
        }

        return sepiDigest
    }

    var stg1Digest: Data? {
        guard
            let stg1 =
                (try? self.properties.first { (key: String, value: Any) in
                    key == "stg1"
                }.flatMap { $0.value } as? Image4Manifest.Properties)
        else {
            return nil
        }

        guard
            let stg1Digest =
                (stg1.first(where: { (key: String, value: Any) in
                    key == "DGST"
                }).flatMap { $0.value }) as? Data
        else {
            return nil
        }

        return stg1Digest
    }
}

extension Image4Manifest {
    public struct Manifest: DERParseable {
        let tag: ASN1IA5String
        let version: Int
        let properties: [Property]

        init(tag: ASN1IA5String, version: Int, properties: [Property]) {
            self.tag = tag
            self.version = version
            self.properties = properties
        }

        public init(derEncoded node: ASN1Node) throws(ThrownASN1Error) {
            self = try DER.sequence(node, identifier: .sequence) { nodes throws(ThrownASN1Error) in
                let tag = try ASN1IA5String(derEncoded: &nodes)
                let version = try Int(derEncoded: &nodes)
                let properties = try DER.set(of: Property.self, identifier: .set, nodes: &nodes)

                // drain signature, if present
                _ = try? ASN1Any(derEncoded: &nodes)
                // drain certificates, if present
                _ = try? ASN1Any(derEncoded: &nodes)

                return Manifest(tag: tag, version: version, properties: properties)
            }
        }
    }

    public struct Property: DERParseable {
        let tag: ASN1IA5String
        let value: Value

        enum Value: DERParseable {
            init(derEncoded node: ASN1Node) throws(ThrownASN1Error) {
                switch node.identifier {
                case .null:
                    self = .null
                case .boolean:
                    self = try .bool(.init(derEncoded: node, withIdentifier: node.identifier))
                case .integer:
                    self = try .integer(.init(derEncoded: node, withIdentifier: node.identifier))
                case .octetString:
                    self = try .octetString(.init(derEncoded: node))
                case .set:
                    self = try .properties(DER.set(of: Image4Manifest.Property.self, identifier: .set, rootNode: node))
                default:
                    throw ASN1Error.invalidASN1Object(reason: "invalid manifest dictionary property")
                }
            }

            case null
            case bool(Bool)
            case integer(UInt64)
            case octetString(ASN1OctetString)
            case properties([Property])

            var swiftRepresentation: Any {
                switch self {
                case .null:
                    return NSNull()
                case .bool(let bool):
                    return bool
                case .integer(let int):
                    return int
                case .octetString(let octetString):
                    return Data(octetString.bytes)
                case .properties(let array):
                    var dict = [String: Any?]()
                    for prop in array {
                        dict[String(bytes: prop.tag.bytes, encoding: .utf8)!] = prop.value.swiftRepresentation
                    }
                    return dict
                }
            }
        }

        init(tag: ASN1IA5String, value: Value) {
            self.tag = tag
            self.value = value
        }

        public init(derEncoded node: ASN1Node) throws(ThrownASN1Error) {
            guard node.identifier.tagClass == .private else {
                throw ASN1Error.invalidASN1Object(reason: "unexpected tag class \(node.identifier.tagClass)")
            }
            self = try DER.sequence(node, identifier: node.identifier) { nodes throws(ThrownASN1Error) in
                guard let node = nodes.next() else {
                    throw ASN1Error.invalidASN1Object(reason: "unexpected end of sequence")
                }
                return try DER.sequence(node, identifier: node.identifier) { nodes throws(ThrownASN1Error) in
                    let tag = try ASN1IA5String(derEncoded: &nodes)
                    let value = try Value(derEncoded: &nodes)
                    return Property(tag: tag, value: value)
                }
            }
        }
    }
}
