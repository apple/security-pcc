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
import InternalSwiftProtobuf
import os

extension PersistentClientHelperManager {
    /// Map a Service Discovery instance to the *units* it advertises.
    ///
    /// One `InstanceInfo` may serve many units (sharded filters and/or
    /// multi-filter nodes), so this returns a Set rather than a single
    /// ID. The mapping is read from the typed
    /// `meta["persistent-service"].fields["capabilities"]` JSON-string
    /// published by `ServiceDiscoveryPublisher`. Each entry maps an
    /// capability (e.g. filterID) to per-capability info containing an opaque
    /// `shardID` string.
    ///
    /// **Backwards compatibility:** when `capabilities` is absent (pre-rollout
    /// instance), the method returns a single implicit unit named after
    /// the service. Same fallback when the field is malformed or empty —
    /// don't break SD reconciliation on a parse error. Per-capability
    /// entries that are individually malformed are logged and dropped;
    /// healthy siblings are preserved.
    ///
    /// **Block-list:** capabilities in `blockedCapabilities` are dropped. An
    /// instance that advertised capabilities but has them *all* blocked yields
    /// an empty set (the instance is excluded from routing), rather than the
    /// whole-service fallback — the fallback is reserved for instances that
    /// advertised no parseable `capabilities` field at all.
    static func unitIDs(
        for instance: InstanceInfo,
        serviceName: String,
        blockedCapabilities: Set<String> = []
    ) -> Set<PersistentServiceUnitID> {
        var out: Set<PersistentServiceUnitID> = []
        let scan = Self.forEachCapability(
            in: instance,
            serviceName: serviceName,
            blockedCapabilities: blockedCapabilities,
            body: { capability, info in
                let shardID = (info["shardID"] as? String) ?? ""
                out.insert(PersistentServiceUnitID(capability: capability, shardID: shardID))
            }
        )
        guard scan.parsedCapabilities else {
            // Pre-rollout instance (no `capabilities` field) or unparseable
            // payload: assume it serves the whole service (legacy implicit unit).
            return [PersistentServiceUnitID(capability: serviceName, shardID: "")]
        }
        if out.isEmpty {
            // The instance advertised capabilities but yielded no units. If at
            // least one was dropped by the block-list, exclude the instance
            // entirely (empty set) so the router never establishes quorum for or
            // routes to it. Otherwise (an empty or all-malformed map) preserve
            // the legacy whole-service fallback.
            return scan.blockedAnyCapability ? [] : [PersistentServiceUnitID(capability: serviceName, shardID: "")]
        }
        return out
    }

    /// Parse the per-instance "what does this capability look like?" view.
    ///
    /// For every capability advertised by this instance, returns the full set
    /// of `PersistentServiceUnitID`s the capability is split into — derived
    /// from the capability's `allShardIDs` field. Lets the manager track each
    /// distinct configuration advertised across instances for an capability,
    /// so it can decide coverage without requiring all instances to agree
    /// during a rolling reconfiguration.
    ///
    /// - For sharded capabilities (`allShardIDs` non-empty): the unit set is
    ///   one unit per `shardID` in `allShardIDs`.
    /// - For unsharded capabilities (`allShardIDs` absent or empty): the unit
    ///   set is a single unit with an empty `shardID`.
    /// - When the `capabilities` field itself is absent or malformed, returns
    ///   an empty map (no per-capability tracking — preserves pre-rollout
    ///   behaviour). Per-capability entries that are individually
    ///   malformed are logged and dropped; healthy siblings are preserved.
    static func capabilityConfigurations(
        for instance: InstanceInfo,
        serviceName: String,
        blockedCapabilities: Set<String> = []
    ) -> [String: Set<PersistentServiceUnitID>] {
        var out: [String: Set<PersistentServiceUnitID>] = [:]
        let scan = Self.forEachCapability(
            in: instance,
            serviceName: serviceName,
            blockedCapabilities: blockedCapabilities,
            body: { capability, info in
                var units: Set<PersistentServiceUnitID> = []
                if let allShardIDs = info["allShardIDs"] as? [String], !allShardIDs.isEmpty {
                    for shardID in allShardIDs {
                        units.insert(PersistentServiceUnitID(capability: capability, shardID: shardID))
                    }
                } else {
                    units.insert(PersistentServiceUnitID(capability: capability, shardID: ""))
                }
                out[capability] = units
            }
        )
        guard scan.parsedCapabilities else {
            return [:]
        }
        return out
    }

    /// Iterates the parsed `meta["persistent-service"].fields["capabilities"]`
    /// JSON map, invoking `body` for every well-formed `(capability, info)`
    /// pair. Per-capability entries with an unexpected value type are
    /// logged ("Dropping malformed capability...") and skipped, so a
    /// single bad sibling never voids the whole map.
    ///
    /// Returns `false` when the meta field is absent or the JSON payload
    /// is empty / malformed — caller applies its own absent/malformed
    /// fallback (an implicit-unit set for `unitIDs`, an empty map for
    /// `capabilityConfigurations`). Returns `true` once iteration is done,
    /// regardless of whether every entry was dropped.
    /// Outcome of scanning an instance's advertised capabilities.
    private struct CapabilityScan {
        /// The `capabilities` meta field was present and parsed to a JSON
        /// object. When false, the caller applies its pre-rollout /
        /// parse-error fallback.
        var parsedCapabilities: Bool
        /// At least one advertised capability was dropped because it is in the
        /// block-list. Lets `unitIDs` distinguish "empty because everything was
        /// blocked" (exclude the instance) from "empty / all-malformed map"
        /// (legacy whole-service fallback).
        var blockedAnyCapability: Bool
    }

    private static func forEachCapability(
        in instance: InstanceInfo,
        serviceName: String,
        blockedCapabilities: Set<String>,
        body: (_ capability: String, _ info: [String: Any]) -> Void
    ) -> CapabilityScan {
        guard let psMeta = instance.meta["persistent-service"],
              let capabilitiesField = psMeta.fields["capabilities"] else {
            return CapabilityScan(parsedCapabilities: false, blockedAnyCapability: false)
        }
        let json = capabilitiesField.stringValue
        // Outer cast is `[String: Any]` rather than `[String: [String: Any]]`
        // so a single capability with an unexpected value type doesn't
        // void the whole map and silently drop healthy siblings.
        guard !json.isEmpty,
              let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return CapabilityScan(parsedCapabilities: false, blockedAnyCapability: false)
        }
        var blockedAnyCapability = false
        for (capability, infoAny) in parsed {
            // Blocked capabilities are discarded before any parsing so the
            // router never learns of them (no quorum, no routing).
            if blockedCapabilities.contains(capability) {
                blockedAnyCapability = true
                continue
            }
            guard let info = infoAny as? [String: Any] else {
                Self.logger.error(
                    "Dropping malformed capability '\(capability, privacy: .public)' for service '\(serviceName, privacy: .public)': expected dict, got \(type(of: infoAny), privacy: .public)"
                )
                continue
            }
            body(capability, info)
        }
        return CapabilityScan(parsedCapabilities: true, blockedAnyCapability: blockedAnyCapability)
    }
}
