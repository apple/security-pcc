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
//  RIMParser.swift
//  CloudAttestationV2
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//

import Common
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

final class RIMXMLParser: NSObject, XMLParserDelegate, @unchecked Sendable {
    /// A parsed SWID tag.
    struct Parsed {
        let entity: Entity
        let meta: Meta
        let measurements: [Measurement]
        /// The `<SoftwareIdentity version>` attribute. For the Google Platforms RIMs in a host
        /// firmware SBOM this is a SHA-256 hex string identifying the firmware build. NVIDIA RIMs
        /// put the SWID tag's own version here (`1.0`), not a firmware version, so it is only
        /// meaningful for the Google RIMs. `nil` when the tag omits it.
        let softwareVersion: String?
    }

    /// When `true`, tolerates RIMs that omit the fields NVIDIA RIMs always carry:
    /// `Meta` may lack `product`/`colloquialVersion` (default to `""`) and a measurement
    /// `Resource` may omit `index` (assigned sequentially). Used for the Google Platforms
    /// SWID RIMs in the host firmware SBOM, which are looked up by measurement `name`.
    private let lenient: Bool
    private var entity: Entity?
    private var meta: Meta?
    private var measurements: [Measurement] = []
    private var softwareVersion: String?
    private var parseError: (any Error)?

    init(lenient: Bool = false) {
        self.lenient = lenient
        super.init()
    }

    func parse(_ data: Data) throws -> Parsed {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else {
            if let parseError {
                throw parseError
            }
            throw RIMError.xmlParsingFailed(parser.parserError?.localizedDescription ?? "unknown error")
        }
        guard let entity else {
            throw RIMError.missingElement("Entity")
        }
        guard let meta else {
            throw RIMError.missingElement("Meta")
        }
        return Parsed(entity: entity, meta: meta, measurements: measurements, softwareVersion: softwareVersion)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes: [String: String]
    ) {
        let localName = elementName.components(separatedBy: ":").last ?? elementName
        switch localName {
        case "SoftwareIdentity":
            softwareVersion = attributes["version"]

        case "Entity":
            guard let name = attributes["name"] else {
                self.parseError = RIMError.missingElement("Entity name")
                parser.abortParsing()
                return
            }
            entity = Entity(
                name: name,
                role: attributes["role"] ?? ""
            )

        case "Meta":
            let product: String
            let colloquialVersion: String
            if lenient {
                product = attributes["product"] ?? ""
                colloquialVersion = attributes["colloquialVersion"] ?? ""
            } else {
                guard let requiredProduct = attributes["product"] else {
                    self.parseError = RIMError.missingElement("Meta product")
                    parser.abortParsing()
                    return
                }
                guard let requiredColloquialVersion = attributes["colloquialVersion"] else {
                    self.parseError = RIMError.missingElement("Meta colloquialVersion")
                    parser.abortParsing()
                    return
                }
                product = requiredProduct
                colloquialVersion = requiredColloquialVersion
            }
            meta = Meta(
                product: product,
                colloquialVersion: colloquialVersion,
                edition: attributes["edition"] ?? "",
                bindingSpec: findAttribute(attributes, suffix: "BindingSpec") ?? "",
                bindingSpecVersion: findAttribute(attributes, suffix: "BindingSpecVersion") ?? "",
                platformManufacturerStr: findAttribute(attributes, suffix: "PlatformManufacturerStr") ?? "",
                platformModel: findAttribute(attributes, suffix: "PlatformModel") ?? ""
            )

        case "Resource":
            guard attributes["type"] == "Measurement" else { return }
            let index: Int
            if let indexStr = attributes["index"] {
                guard let parsed = Int(indexStr) else {
                    self.parseError = RIMError.missingElement("Resource index (invalid integer: \(indexStr))")
                    parser.abortParsing()
                    return
                }
                index = parsed
            } else if lenient {
                index = measurements.count
            } else {
                self.parseError = RIMError.missingElement("Resource index")
                parser.abortParsing()
                return
            }
            let active = attributes["active"] == "True"
            let name = attributes["name"] ?? ""
            var alternatives: [[UInt8]] = []
            for (key, value) in attributes.sorted(by: { $0.key < $1.key }) {
                let attrLocal = key.components(separatedBy: ":").last ?? key
                // NVIDIA RIMs use `HashN` alternatives; Google SWID RIMs use a namespaced
                // `SHA256:hash` (local name `hash`).
                guard attrLocal.hasPrefix("Hash") || attrLocal.caseInsensitiveCompare("hash") == .orderedSame else { continue }
                if let data = Data(hexString: value) {
                    alternatives.append(data.byteArray)
                }
            }
            measurements.append(
                Measurement(index: index, name: name, active: active, alternatives: alternatives)
            )

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: any Error) {
        self.parseError = parseError
    }

    private func findAttribute(_ attributes: [String: String], suffix: String) -> String? {
        for (key, value) in attributes {
            let local = key.components(separatedBy: ":").last ?? key
            if local == suffix { return value }
        }
        return nil
    }
}
