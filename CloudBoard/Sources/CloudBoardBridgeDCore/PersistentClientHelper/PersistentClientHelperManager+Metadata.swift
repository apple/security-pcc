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

import CloudBoardCommon
import Foundation
import InternalSwiftProtobuf
import os
import PersistentServiceBridgeRouterAPI

extension PersistentClientHelperManager {
    /// Identity key for a node (ip:port).
    static func nodeAddress(from instance: InstanceInfo) -> String {
        "\(instance.address.ip):\(instance.address.port)"
    }

    /// Extracts the cell ID from an InstanceInfo's `meta` map.
    ///
    /// Published by the server at `meta["description"].fields["cellId"].string_value`.
    /// Returns `nil` when the field is absent or empty.
    static func parseCellID(from instance: InstanceInfo) -> String? {
        Self.metaStringField(category: "description", key: "cellId", in: instance)
    }

    /// Extracts the isolation domain from an InstanceInfo's `meta` map.
    ///
    /// Published at `meta["persistent-service"].fields["isolationDomain"].string_value`.
    /// Returns `"default"` when the field is absent or empty.
    static func parseIsolationDomain(from instance: InstanceInfo) -> String {
        Self.metaStringField(category: "persistent-service", key: "isolationDomain", in: instance)
            ?? "default"
    }

    /// Extracts raw serviceDefinedMetadata JSON from an InstanceInfo's `meta` map.
    ///
    /// The metadata is published by PrivateFilterController under:
    /// `meta["persistent-service"].fields["serviceDefinedMetadata"].string_value`
    ///
    /// Returns the raw JSON as `Data` without parsing — the Router is responsible
    /// for decoding it.
    static func extractServiceDefinedMetadata(from instance: InstanceInfo) -> Data? {
        Self.metaStringField(category: "persistent-service", key: "serviceDefinedMetadata", in: instance)
            .map { Data($0.utf8) }
    }

    /// Reads the publisher-declared transport security from an
    /// InstanceInfo's `meta` map.
    ///
    /// Published at
    /// `meta["persistent-service"].fields["transportSecurity"].string_value`
    /// as the lowercase rawValue of `PersistentServiceTransportSecurity`.
    ///
    /// Always returns a value. The `nil`-vs-non-nil "is it allowed?"
    /// question is handled separately by
    /// `isTransportSecurityAllowed(_:address:requireMTLS:)` so the two
    /// concerns (what the publisher said / whether policy permits it)
    /// are independently testable.
    ///
    /// - Absent field → `.mtls`. Matches today's first-attempt
    ///   behaviour, so old publishers that don't yet emit the field
    ///   are treated as they always have been (mTLS).
    /// - Unknown string value → `.mtls` with a `.warning` log so
    ///   future schema additions don't crash older bridges.
    static func inferTransportSecurity(from instance: InstanceInfo) -> PersistentServiceTransportSecurity {
        guard let raw = Self.metaStringField(category: "persistent-service", key: "transportSecurity", in: instance)
        else {
            return .mtls
        }
        if let known = PersistentServiceTransportSecurity(rawValue: raw) {
            return known
        }
        let address = Self.nodeAddress(from: instance)
        Self.logger.warning(
            "Unknown transportSecurity value '\(raw, privacy: .public)' for \(address, privacy: .public); defaulting to mtls"
        )
        return .mtls
    }

    /// Decides whether a publisher-declared `transportSecurity` is
    /// admitted under the operator's policy gate.
    ///
    /// When `requireMTLS` is true (production / customer profile
    /// without research bypass), only `.mtls` is admitted; anything
    /// else is rejected with an `.error` log naming the offending
    /// address, and the caller drops the node. When `requireMTLS` is
    /// false (carry, none, research bypass), every transport is
    /// admitted — operators in those environments can deploy
    /// plaintext or tls servers.
    static func isTransportSecurityAllowed(
        _ transport: PersistentServiceTransportSecurity,
        address: String,
        requireMTLS: Bool
    ) -> Bool {
        if requireMTLS, transport != .mtls {
            Self.logger.error(
                "Refusing node \(address, privacy: .public) with non-mTLS transport ('\(transport.rawValue, privacy: .public)') under enforced security policy"
            )
            return false
        }
        return true
    }

    /// Reads `instance.meta[category].fields[key].stringValue`, returning
    /// `nil` if the category or key is absent OR the stringValue is empty.
    /// Centralises the absent/empty-string fallback that `parseCellID`,
    /// `parseIsolationDomain`, `extractServiceDefinedMetadata`, and
    /// `inferTransportSecurity` all need to apply identically.
    private static func metaStringField(
        category: String,
        key: String,
        in instance: InstanceInfo
    ) -> String? {
        guard let categoryMeta = instance.meta[category],
              let field = categoryMeta.fields[key] else {
            return nil
        }
        let value = field.stringValue
        return value.isEmpty ? nil : value
    }
}
