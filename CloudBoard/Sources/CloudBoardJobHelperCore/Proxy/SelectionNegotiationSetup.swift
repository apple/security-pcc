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

/// Rules on selecting a worker for a specific sub-request
/// This is, in part, closely aligned with the `NegotiateEnsembleChoice` proto
/// since that message is an expression of what is allowed
///

import CloudBoardCommon
import CloudBoardDomain
import os

/// Immutable rules and config that will control an entire requests transitive trust enforcement
internal enum SelectionNegotiationSetup {
    internal static let logger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "SelectionNegotiationSetup"
    )

    /// The scale factor the proxy advertises by default: ROPES may scale the announced ratio up to
    /// this multiple. This is the policy default applied to every pick unless overridden by config.
    internal static let defaultPickRatioCanScaleTo = 2

    /// The largest scale factor permitted under Apple infrastructure (customer) policy. Config may
    /// not raise the advertised value above this; attempts to do so are clamped with a warning.
    internal static let maxPickRatioCanScaleToUnderCustomerPolicy = 3

    /// Specific modes of operation that are fundamentally driven by the business feature
    /// being used.
    /// Some may have external behaviours (outside of PCC) that mean specific measures must be taken
    /// by the proxy to preserve the privacy goals
    internal enum OperatingMode: String, Sendable, CustomStringConvertible {
        var description: String {
            return self.rawValue
        }

        /// "not a proxy" any attempt at all to use this results in a fatal error
        case disallowed
        /// This reflects the behaviour before the negotiation phases were introduced
        /// When testing it can be useful to force all requests to use free choice but
        /// this mode may not be not allowed in production or carry for certain apps
        case alwaysFreeChoice

        /// In many cases the initial request is not targetable as no identifying information
        /// exists thanks to OHTTP. This means the first worker session is also not targetable
        /// (because the proxy apps are written to not leak any information before/when requesting
        /// the worker). The slight additional wrinkle indicated in the name is that, for a split FT/ET
        /// computation the first FT node does not leak anything concerning targetability, therefore the first
        /// ET node for that same group may also use free choice if the FT node did.
        ///
        /// To avoid any mistakes we implement a simple rule when using this, this only applies to the first
        /// two sessions in the group regardless of how big it is. Also any use of a _different_
        /// group before it is sufficient to block free choice.
        case firstGroupIsFreeChoiceIfNoReuse

        /// Something makes the request potentially targetable from the outset, this essentially means all
        /// worker sessions must be previously trusted, or done via the pick negotiation
        case assumeTargetable
    }

    /// These are the immutable rules that apply to an entire request
    internal struct Rules: Sendable {
        /// This does not cover things like split FT/ET, it's multiple invoke proxy initiates
        /// with different groupIds being supported
        internal var multiGroup: Bool

        /// IFF pick is used, this is the settings to use for it
        internal var pick: PickOptions?

        /// Only relevant outside customer!
        /// IFF pick is used, and IFF the request is identified as being in a restricted subset
        /// this is the settings to use for it
        internal var pickWhenRestricted: PickOptions?

        /// Hard limit on the number of different ensemble instances we will rewrap the DEK for
        /// Rewrapping for a new attestation on the same instance (not rebooted) does not count, rewrapping
        /// after reboot does
        internal var maxTrustedEnsembleInstances: Int

        /// Operating rules which are defined by what the request is for/doing whose value are defined
        /// elsewhere (likely through some static config)
        internal var operatingMode: OperatingMode

        /// We only trust an ensemble is the selection was deemed untargetable, therefore when needed,
        /// we also trust the rack.
        /// This applies only if the Rack is relevant (likely due to reuse)
        internal var trustingEnsembleImpliesTrustingRack: Bool

        internal init(
            operatingMode: OperatingMode,
            multiGroup: Bool,
            pick: PickOptions?,
            pickWhenRestricted: PickOptions?,
            maxTrustedEnsembleInstances: Int,
            trustingEnsembleImpliesTrustingRack: Bool
        ) {
            self.operatingMode = operatingMode
            self.pick = pick
            self.pickWhenRestricted = pickWhenRestricted
            self.multiGroup = multiGroup
            self.maxTrustedEnsembleInstances = maxTrustedEnsembleInstances
            self.trustingEnsembleImpliesTrustingRack = trustingEnsembleImpliesTrustingRack
        }

        // Use for compute nodes, or testing when transitive trust is irrelevant
        internal static let disallowed: Rules = SelectionNegotiationSetup.Rules(
            operatingMode: .disallowed,
            multiGroup: false,
            pick: nil,
            pickWhenRestricted: nil,
            maxTrustedEnsembleInstances: 0,
            trustingEnsembleImpliesTrustingRack: false
        )

        // Represents the rules that applied before negotiate was created
        internal static let justFreeChoice: Rules = SelectionNegotiationSetup.Rules(
            operatingMode: .alwaysFreeChoice,
            multiGroup: false,
            pick: nil,
            pickWhenRestricted: nil,
            maxTrustedEnsembleInstances: .max,
            trustingEnsembleImpliesTrustingRack: false
        )
    }

    /// These are fine defaults for use in VRE/ephemeral
    private static let noSecurityRules = SelectionNegotiationSetup.Rules(
        operatingMode: .alwaysFreeChoice,
        // if someone wants to mess with an existing cloud app flow we let them
        multiGroup: true,
        /// if ROPES triggers pick even though we allow free choice this will function correctly,
        /// we have absolutely no constraints and will accept a single option.
        pick: PickOptions(
            requiredEnsemblesFromROPES: 1,
            allowedEnsemblesFromProxy: 1,
            ratioCanScaleTo: Self.defaultPickRatioCanScaleTo
        ),
        // it's irrelevant - the normal pick is as relaxed as possible
        pickWhenRestricted: nil,
        // This is not a security rule, it's just preventing a runaway system causing issues
        maxTrustedEnsembleInstances: 100,
        /// This results in more code paths being used which is desirable
        trustingEnsembleImpliesTrustingRack: true
    )

    private static let forcePickInEphemeralSecurityRules = SelectionNegotiationSetup.Rules(
        operatingMode: .assumeTargetable,
        // allow this
        multiGroup: true,
        /// minimum to properly do the pick
        pick: PickOptions(
            requiredEnsemblesFromROPES: 2,
            allowedEnsemblesFromProxy: 1,
            ratioCanScaleTo: Self.defaultPickRatioCanScaleTo
        ),
        // We deliberately do not loosen this, since almost all ephemeral use is "restricted"
        // and the intention of this setup bundle is to force a non trivial pick
        pickWhenRestricted: nil,
        // force rapidly hitting the boundary
        maxTrustedEnsembleInstances: 3,
        /// we don't want the node we happen to end up on to matter
        trustingEnsembleImpliesTrustingRack: false
    )

    /// Cloud apps have to have rules that are enforced and where changes to those rules would be visible
    /// in the transparency log. Therfore they cannot simply be config - even Secureconfig - since each
    /// separate configuration value would have to be linked into the attestation
    /// While this is _possible_ it is not desirable as it would be significant complexity to manage
    /// This then provides that visible location, and the enforcement of the policy constraints.
    ///
    /// This has to happen after the SecureConfig is parsed and constructed because we don't know the cloudApp
    /// until warmup.
    ///
    /// Changes to this function, and those is calls should be extremely carefully reviewed
    internal static func cloudAppSelectionNegotiationRules(
        cloudAppName: String,
        secureConfig: SecureConfig
    ) throws(SelectionNegotiationError) -> SelectionNegotiationSetup.Rules {
        guard secureConfig.isProxy else {
            return SelectionNegotiationSetup.Rules.disallowed
        }
        let cloudAppConfig = try! secureConfig.cloudAppConfig(cloudApp: cloudAppName).transitiveTrust
        let policyRules: SelectionNegotiationSetup.Rules
        switch secureConfig.securityPolicy {
        case .none:
            /// For testing anything goes, sadly the lowest common denominator is someone with a single
            /// instance of compute in their own Routing Group Alias so any form of restriction would mean
            /// their testing fails, so - by default - even if high fidelity was possible we have to disable
            /// everything
            policyRules = Self.noSecurityRules
        // If wanting to test negotiation locally with ROPES the easiest solution is to:
        // return Self.forcePickInEphemeralSecurityRules
        case .carry:
            // These values are smaller to reflect the reduced capacity such that production
            // expectations would result in significant failure rates under load.
            // We *MUST* exercise the same code paths as production, simply with reduced limits
            // This is not providing privacy protections, only to follow production code paths to ensure
            // that failures are not found only in production
            // As a result of sizing considerations for some use cases which share proxy nodes with others
            // we need a limit which allows anything to function by default.
            // We only want to apply this to those use cases that require it though.
            // 1 of 1 means everything functions upstream, but still exercises the protocol.
            // These magic number can be changed without approval from Privacy
            let pick = PickOptions(
                // This is deliberately left at 1 now so that increasing this number can be
                // driven in the workload by SRE
                requiredEnsemblesFromROPES: 1,
                allowedEnsemblesFromProxy: 1,
                ratioCanScaleTo: Self.defaultPickRatioCanScaleTo
            )
            // We don't provide a means for configuring this.
            // There is no intent to use antyhing higher than this and it solves having to check if it is
            // being weakened or not for little benefit.
            let pickWhenRestricted = PickOptions(
                requiredEnsemblesFromROPES: 1,
                allowedEnsemblesFromProxy: 1,
                ratioCanScaleTo: Self.defaultPickRatioCanScaleTo
            )
            policyRules = Self.cloudAppSpecificSelectionNegotiationRules(
                cloudAppName: cloudAppName, pick: pick, pickWhenRestricted: pickWhenRestricted,
            )
        case .customer:
            // The magic numbers here may NOT be changed without approval from Privacy
            let pick = PickOptions(
                requiredEnsemblesFromROPES: 15,
                allowedEnsemblesFromProxy: 1,
                ratioCanScaleTo: Self.defaultPickRatioCanScaleTo
            )
            policyRules = Self.cloudAppSpecificSelectionNegotiationRules(
                cloudAppName: cloudAppName, pick: pick, pickWhenRestricted: nil
            )
        }

        return try self.applyConfigOverrides(
            secureConfig: secureConfig,
            cloudAppName: cloudAppName,
            cloudAppConfig: cloudAppConfig,
            policyRules: policyRules
        )
    }

    /// This defines *policy* rules that may not (except in very specific cases) be changed
    /// This can assume carry/production policy is in effect. The variable nature of
    /// pick in those scenarios means those are provided but everything else should be consistent
    private static func cloudAppSpecificSelectionNegotiationRules(
        cloudAppName: String,
        pick: PickOptions,
        pickWhenRestricted: PickOptions?
    ) -> SelectionNegotiationSetup.Rules {
        // The cloudAppName is baked into other aspects of the TL entry (entitlements, the Launchd agents
        // etc.), so simply switching one cloud app to have the name of another one in config won't actually
        // result in a usable system. Therefore we can trust the names are coherent
        switch cloudAppName {
        case "PCCAgentApp":
            return SelectionNegotiationSetup.Rules(
                // All current uses of this app make no callouts on the client in advance that would enable timing
                // attacks. Therefore, by default, they are considered untargetable for the first compute group.
                // However, if the agent were to attempt to reuse on the first compute group, this implies some form of
                // linkability between separate requests.
                operatingMode: .firstGroupIsFreeChoiceIfNoReuse,
                multiGroup: true,
                pick: pick,
                pickWhenRestricted: pickWhenRestricted,
                // This is under the control of the agent, but it is not allowed to be unbounded such that
                // it would cycle through all of the fleet in some error condition
                maxTrustedEnsembleInstances: 100,
                // In some scenarios, network proximity enables additional capabilities.
                trustingEnsembleImpliesTrustingRack: true
            )
        case "TIEProxyApp":
            return SelectionNegotiationSetup.Rules(
                // All current uses of this app are considered untargetable, they have no prior
                // state and make no callouts on the client in advance that would enable timing attacks
                operatingMode: .alwaysFreeChoice,
                multiGroup: false,
                pick: pick,
                pickWhenRestricted: pickWhenRestricted,
                // either FT_ET or FT then ET, no other callouts occur
                maxTrustedEnsembleInstances: 2,
                trustingEnsembleImpliesTrustingRack: false
            )
        case "NullCloudApp":
            // During testing this might be used in many different modes but that is covered
            // by the .none security policy already.
            // In production/carry this cannot be used in proxy mode
            return SelectionNegotiationSetup.Rules(
                // Null app cannot run as a proxy in production
                // so these settings work well for testing
                operatingMode: .disallowed,
                multiGroup: false,
                pick: pick,
                pickWhenRestricted: pickWhenRestricted,
                maxTrustedEnsembleInstances: 0,
                trustingEnsembleImpliesTrustingRack: false
            )
        // This is not a privacy risk. TestProxyApp and variants are only used in MockIntegrationTests
        // and do not exist in customer builds. Secureconfig in production would never contain
        // this cloudapp name - it would fail validation
        case "TestProxyApp":
            return SelectionNegotiationSetup.Rules(
                operatingMode: .assumeTargetable,
                multiGroup: false,
                pick: pick,
                pickWhenRestricted: pickWhenRestricted,
                maxTrustedEnsembleInstances: 2,
                trustingEnsembleImpliesTrustingRack: false
            )
        /// Configuration designed to allow testing of the trust/rack trust
        /// The first free choice is designed to make it simple to establish
        /// a trust state, then iterate from there.
        /// Disabling all pick makes the state management simpler
        case "TestProxyApp_RackTrust":
            return SelectionNegotiationSetup.Rules(
                operatingMode: .firstGroupIsFreeChoiceIfNoReuse,
                multiGroup: false,
                pick: .none,
                pickWhenRestricted: .none,
                maxTrustedEnsembleInstances: .max,
                trustingEnsembleImpliesTrustingRack: true
            )
        case "TrampolineProxyApp":
            // We currently have one use case of trampoline which is not targetable,
            // Before we add any other use case to the trampoline we must first allow setting
            // NegotiationRules per service on the Proxy App.
            return SelectionNegotiationSetup.Rules(
                operatingMode: .alwaysFreeChoice,
                multiGroup: false,
                pick: pick,
                pickWhenRestricted: pickWhenRestricted,
                maxTrustedEnsembleInstances: 1,
                trustingEnsembleImpliesTrustingRack: false
            )
        default:
            // This provides reasonable safe defaults for anything operating as a trampoline
            // so they need not define anything
            self.logger.info("cloud app \(cloudAppName, privacy: .public) gets the default trampoline negotiate rules")
            return SelectionNegotiationSetup.Rules(
                operatingMode: .assumeTargetable,
                multiGroup: false,
                pick: pick,
                pickWhenRestricted: pickWhenRestricted,
                maxTrustedEnsembleInstances: 1,
                trustingEnsembleImpliesTrustingRack: false
            )
        }
    }

    fileprivate static func applyConfigOverrides(
        secureConfig: SecureConfig,
        cloudAppName: String,
        cloudAppConfig: SecureConfig.TransitiveTrustCloudAppConfig,
        policyRules: SelectionNegotiationSetup.Rules
    ) throws(SelectionNegotiationError) -> SelectionNegotiationSetup.Rules {
        // When using VREs you almost certainly don't have a fleet that would allow the policy
        // controlled defaults.
        // Let the config override anything, but still use the policy defaults so the failure
        // cases can be checked cleanly
        // if the values are equal this is a no-op
        func onOverride<T: CustomStringConvertible & Equatable>(
            _ key: String,
            original: inout T,
            replacement: T,
            // If isWeakened(original, replacement) returns true it is disallowed (if policy requires it)
            isWeakened: (T, T) -> Bool
        ) throws(SelectionNegotiationError) {
            guard original != replacement else {
                return
            }
            let weaker = isWeakened(original, replacement)
            let originalCopy = original
            if weaker {
                if secureConfig.shouldEnforceAppleInfrastructureSecurityConfig {
                    throw SelectionNegotiationError.rulesTooWeakForPolicy(
                        """
                        Configuration for \(cloudAppName) is \(cloudAppConfig) which weakens \
                        \(key) from policy controlled \(originalCopy) to \(replacement). \
                        Policy is \(secureConfig.securityPolicy)
                        """
                    )
                }
                self.logger.notice(
                    """
                    Allowing weakening overide from config for \(key, privacy: .public) \
                    from \(originalCopy, privacy: .public) to \(replacement, privacy: .public).
                    """
                )
            } else {
                self.logger.info(
                    """
                    Allowing safe override config for \(key, privacy: .public) \
                    from \(originalCopy, privacy: .public) to \(replacement, privacy: .public).
                    """
                )
            }
            original = replacement
        }
        // Companion to `onOverride` for numeric values where *raising* the configured value is not a
        // policy weakening (so it is never rejected), but the value must still be capped under Apple
        // infrastructure (customer) policy. The cap is applied with a warning rather than a throw.
        // Returns whether the effective value ended up different from `original`.
        func onBoundedOverride(
            _ key: String,
            original: inout Int,
            replacement: Int?,
            maxUnderEnforcedPolicy: Int
        ) -> Bool {
            let originalValue = original
            if let replacement, replacement != original {
                self.logger.info(
                    """
                    Allowing override config for \(key, privacy: .public) \
                    from \(originalValue, privacy: .public) to \(replacement, privacy: .public).
                    """
                )
                original = replacement
            }
            if secureConfig.shouldEnforceAppleInfrastructureSecurityConfig, original > maxUnderEnforcedPolicy {
                let beforeClamp = original
                self.logger.warning(
                    """
                    Bounding \(key, privacy: .public) from \(beforeClamp, privacy: .public) to \
                    \(maxUnderEnforcedPolicy, privacy: .public) under policy \
                    \(secureConfig.securityPolicy, privacy: .public).
                    """
                )
                original = maxUnderEnforcedPolicy
            }
            return original != originalValue
        }
        var policyRules = policyRules
        if let replacement = cloudAppConfig.maxTrustedEnsembleInstances {
            try onOverride(
                "maxTrustedEnsembleInstances",
                original: &policyRules.maxTrustedEnsembleInstances,
                replacement: replacement,
                isWeakened: <
            )
        }
        if let replacement = cloudAppConfig.multiGroup {
            try onOverride(
                "multiGroup",
                original: &policyRules.multiGroup,
                replacement: replacement,
                // multi group is weaker than not (it allows more actions with more available context/side channel
                isWeakened: { _, replacement in replacement }
            )
        }
        if let replacement = cloudAppConfig.trustingEnsembleImpliesTrustingRack {
            try onOverride(
                "trustingEnsembleImpliesTrustingRack",
                original: &policyRules.trustingEnsembleImpliesTrustingRack,
                replacement: replacement,
                /// trusting racks if not previously allowed definitely weakened
                /// Disallowing it is strengthening
                isWeakened: { original, replacement in !original && replacement }
            )
        }
        if let replacement = cloudAppConfig.operatingMode {
            guard let replacementMode = OperatingMode(rawValue: replacement) else {
                fatalError("\(cloudAppName) config \(cloudAppConfig) had unknown operating mode \(replacement)")
            }
            try onOverride(
                "operatingMode",
                original: &policyRules.operatingMode,
                replacement: replacementMode,
                /// This is deliberately not too general, it would make it a complex moving target which
                /// might be missed  when modes are changed.
                /// Therefore there are only specific well defined transitions which are considered okay
                isWeakened: { original, replacement in
                    // Removes free choice entirely
                    if original == .alwaysFreeChoice || original == .firstGroupIsFreeChoiceIfNoReuse,
                       replacement == .assumeTargetable {
                        return false
                    }
                    // Total disablement - not clear why you would but definitively not weakening
                    if replacement == .disallowed {
                        return false
                    }
                    return true
                }
            )
        }
        // We do *not* get fancy on Pick, saying "2 from 30" is okay if it was "1 from 15"
        // simple local decisions on pick, but we do do them together in case the transient state is illegal
        // We rely 0 being illegal values for either value in pickOptions
        var requiredEnsemblesFromROPES = policyRules.pick?.requiredEnsemblesFromROPES ?? 0
        var changedRequiredEnsemblesFromROPES = false
        if let replacement = cloudAppConfig.pickRequiredEnsemblesFromROPES {
            try onOverride(
                "requiredEnsemblesFromROPES",
                original: &requiredEnsemblesFromROPES,
                replacement: replacement,
                isWeakened: { original, replacement in
                    changedRequiredEnsemblesFromROPES = true
                    if original == 0 {
                        // confusing, but if no pick was possible at all then anything is technically weaking
                        return true
                    }
                    if replacement == 0 {
                        // This turns off pick, which is not weaking
                        return false
                    }
                    // requiring fewer input choices is always weakening
                    return original > replacement
                }
            )
        }
        var allowedEnsemblesFromProxy = policyRules.pick?.allowedEnsemblesFromProxy ?? 0
        var changedAllowedEnsemblesFromProxy = false
        if let replacement = cloudAppConfig.pickAllowedEnsemblesFromProxy {
            try onOverride(
                "allowedEnsemblesFromProxy",
                original: &allowedEnsemblesFromProxy,
                replacement: replacement,
                isWeakened: { original, replacement in
                    changedAllowedEnsemblesFromProxy = true
                    // as for requiredEnsemblesFromROPES
                    if original == 0 {
                        return true
                    }
                    if replacement == 0 {
                        // This turns off pick, which is not weaking
                        return false
                    }
                    // presenting more to chooose from is alweaking
                    return original < replacement
                }
            )
        }
        // ROPES may scale the announced ratio up to this factor. Raising it is *not* a privacy
        // weakening (the ratio is preserved), so config may raise it freely outside customer; under
        // customer policy it is capped via onBoundedOverride rather than rejected. The fallback
        // matches the policy default so a pick enabled purely via config gets the same default scaling
        // as a policy-defined pick. Whether a pick exists at all is decided by the required/allowed
        // counts below, so this value is only consumed when those are non-zero.
        var ratioCanScaleTo = policyRules.pick?.ratioCanScaleTo ?? Self.defaultPickRatioCanScaleTo
        var changedRatioCanScaleTo = false
        if requiredEnsemblesFromROPES != 0, allowedEnsemblesFromProxy != 0 {
            changedRatioCanScaleTo = onBoundedOverride(
                "ratioCanScaleTo",
                original: &ratioCanScaleTo,
                replacement: cloudAppConfig.pickRatioCanScaleTo,
                maxUnderEnforcedPolicy: Self.maxPickRatioCanScaleToUnderCustomerPolicy
            )
        }
        // We rely 0 being illegal values for either value in pickOptions
        // this is tricky - it's possible to shoot yourself in the foot only chaning one
        // if that happenes we want to tell you it happened nicely
        if changedRequiredEnsemblesFromROPES || changedAllowedEnsemblesFromProxy || changedRatioCanScaleTo {
            let originalPickDescription = policyRules.pick.map { $0.description } ?? "disabled"
            // this is tricky - it's possible to shoot yourself in the foot only chaning one
            // if that happenes we want to tell you it happened nicely
            if allowedEnsemblesFromProxy == 0 || requiredEnsemblesFromROPES == 0 {
                guard allowedEnsemblesFromProxy == 0, requiredEnsemblesFromROPES == 0 else {
                    // This is just inconsistent, we know making a PickOptions will fatal - do it nicer here
                    fatalError(
                        """
                        Attempt to change \(cloudAppName) config via \(cloudAppConfig) for pick of \
                        \(originalPickDescription) results in pick \
                        \(allowedEnsemblesFromProxy) from \(requiredEnsemblesFromROPES). \
                        If the intent was to disable pick both must become zero
                        """
                    )
                }
                self.logger.notice("Changing pick from \(originalPickDescription, privacy: .public) to disabled")
                policyRules.pick = nil
            } else {
                // if this is now inconsistent the attempt will fatal, log things first
                self.logger
                    .notice(
                        "Changing pick from \(originalPickDescription, privacy: .public) to \(allowedEnsemblesFromProxy) from \(requiredEnsemblesFromROPES)"
                    )
                policyRules.pick = PickOptions(
                    requiredEnsemblesFromROPES: requiredEnsemblesFromROPES,
                    allowedEnsemblesFromProxy: allowedEnsemblesFromProxy,
                    ratioCanScaleTo: ratioCanScaleTo
                )
            }
        }
        return policyRules
    }
}
