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

import Foundation
#if canImport(os)
import os
#endif
#if canImport(MobileGestaltPrivate)
private import MobileGestaltPrivate
#else
struct MobileGestalt {
    struct Defaults {
        let signingFuse: String? = nil
        let buildVersion: String? = nil
        let releaseType: String? = nil
        let productName: String? = nil
        let hwModelStr: String? = nil
        let serialNumber: String? = nil
    }
    static let current = Defaults()
}
#endif

public final class HostInfoEnricher: EHTransform {
    public let name = "HostInfoEnricher"
    public enum Keys: String, CaseIterable, Sendable {
        case prod_fused
        case build_version
        case os_variant
        case eh_frontend
        case eh_variant
        case eh_version
        case cos_version
        case product_name
        case hw_model
        case serial
        case environment
        case observability_labels
        case boot_session
        case application_name
        case projectID
    }

    private let staticFields: [String: EHValueType]

    private let hasDynamicFrontend: Bool
    private let hasDynamicVariant: Bool
    private let hasObservabilityLabels: Bool

    private let frontendKeyString: String
    private let variantKeyString: String

    private static let cached_prefixed_observability_labels: [String: EHValueType]? = {
        guard let ol = EnvironmentResolver.observabilityLabels else {
            return nil
        }
        var prefixed: [String: EHValueType] = [:]
        for (label, value) in ol {
            prefixed["\(Keys.observability_labels.rawValue)_\(label.onlyLettersAndNumbersAndUnderscores)"] = .string(value)
        }
        return prefixed
    }()

    public init(_ only: [Keys] = [], hostRootPath: String? = nil) {
        let keys = !only.isEmpty ? only : Array(Keys.allCases)

        let metadata: [Keys: Sendable?] = [
            .prod_fused: MobileGestalt.current.signingFuse,
            .build_version: MobileGestalt.current.buildVersion,
            .os_variant: MobileGestalt.current.releaseType,
            .eh_version: EnvironmentResolver.EHVersion,
            .cos_version: EnvironmentResolver.COSBuildVersion,
            .product_name: MobileGestalt.current.productName,
            .hw_model: MobileGestalt.current.hwModelStr,
            .serial: MobileGestalt.current.serialNumber ?? Self.linuxSerialNumber(hostRootPath: hostRootPath),
            .environment: EnvironmentResolver.environment,
            .boot_session: EnvironmentResolver.bootSession,
            .application_name: EnvironmentResolver.applicationName,
            .projectID: EnvironmentResolver.projectID
        ]

        var staticFields: [String: EHValueType] = [:]
        staticFields.reserveCapacity(keys.count)

        var hasDynamicFrontend = false
        var hasDynamicVariant = false
        var hasObservabilityLabels = false

        for key in keys {
            switch key {
            case .eh_frontend:
                hasDynamicFrontend = true
            case .eh_variant:
                hasDynamicVariant = true
            case .observability_labels:
                hasObservabilityLabels = true
            default:
                if let boolValue = metadata[key] as? Bool?, let boolValue {
                    staticFields[key.rawValue] = .boolean(boolValue)
                } else if let stringValue = metadata[key] as? String?, let stringValue {
                    staticFields[key.rawValue] = .string(stringValue)
                } else if let intValue = metadata[key] as? Int?, let intValue {
                    staticFields[key.rawValue] = .int(intValue)
                }
            }
        }

        self.staticFields = staticFields
        self.hasDynamicFrontend = hasDynamicFrontend
        self.hasDynamicVariant = hasDynamicVariant
        self.hasObservabilityLabels = hasObservabilityLabels
        self.frontendKeyString = Keys.eh_frontend.rawValue
        self.variantKeyString = Keys.eh_variant.rawValue
    }

    public func process(_ event: any EHUEFEvent) async -> EHTransformReturn {
        if staticFields.isEmpty && !hasDynamicFrontend && !hasDynamicVariant && !hasObservabilityLabels {
            return (.proceed, nil, nil, nil)
        }
        var e = event

        e.metadata.mutateFields { fields in
            if !staticFields.isEmpty {
                fields.merge(staticFields) { _, new in new }
            }

            if hasDynamicFrontend {
                fields[frontendKeyString] = .string(EHInfo.shared.currentFrontend)
            }
            if hasDynamicVariant {
                fields[variantKeyString] = .string(EHInfo.shared.currentVariant)
            }
            if hasObservabilityLabels {
                fields.merge(
                    HostInfoEnricher.cached_prefixed_observability_labels ?? [:]
                ) { _, new in new }
            }
        }

        return (.proceed_mutated, [e], nil, nil)
    }

    public func configure() async throws {
    }

    static func linuxSerialNumber(hostRootPath: String? = nil) -> String? {
        #if os(Linux)
        let dmiPlaceholders: Set<String> = [
            "Not Specified",
            "To be filled by O.E.M.",
            "System Serial Number",
            "Default string",
            "None",
            "Not Applicable"
        ]
        var dmiPaths: [String] = []
        if let root = hostRootPath {
            dmiPaths.append("\(root)/sys/class/dmi/id/product_serial")
            dmiPaths.append("\(root)/sys/class/dmi/id/board_serial")
        }
        dmiPaths.append("/sys/class/dmi/id/product_serial")
        dmiPaths.append("/sys/class/dmi/id/board_serial")
        for path in dmiPaths {
            if let raw = try? String(contentsOfFile: path, encoding: .utf8) {
                let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty && !dmiPlaceholders.contains(value) {
                    return value
                }
            }
        }
        var machineIdPaths: [String] = []
        if let root = hostRootPath {
            machineIdPaths.append("\(root)/etc/machine-id")
        }
        machineIdPaths.append("/etc/machine-id")
        for path in machineIdPaths {
            if let raw = try? String(contentsOfFile: path, encoding: .utf8) {
                let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    return value
                }
            }
        }
        return nil
        #else
        return nil
        #endif
    }
}
