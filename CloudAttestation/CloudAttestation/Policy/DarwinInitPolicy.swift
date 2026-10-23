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
//  DarwinInitPolicy.swift
//  CloudAttestation
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

import os.log

public struct DarwinInitPolicy: AttestationPolicy {
    static let logger = Logger(subsystem: "com.apple.CloudAttestation", category: "DarwinInitPolicy")

    /// The security policies that are allowed.
    public let allowedSecurityPolicies: [DarwinInit.SecureConfigSecurityPolicy]

    /// The security policies that are restricted.
    public let restrictedSecurityPolicies: [DarwinInit.SecureConfigSecurityPolicy]

    /// Creates a policy that expects the exact provided `config-security-policy` in darwin-init.
    /// - Parameter securityPolicy: The security policy to use.
    public init(securityPolicy: DarwinInit.SecureConfigSecurityPolicy) {
        self = .init(securityPolicies: [securityPolicy])
    }

    /// Creates a policy that expects any of the provided `config-security-policy` in darwin-init.
    /// - Parameter securityPolicies: The security policies to use.
    public init(securityPolicies: some Sequence<DarwinInit.SecureConfigSecurityPolicy>) {
        self.allowedSecurityPolicies = Array(securityPolicies)
        self.restrictedSecurityPolicies = []
    }

    /// Creates a policy that restricts any of the provided `config-security-policy` in darwin-init.
    /// - Parameter restrictedSecurityPolicies: The security policies to restrict.
    public init(restrictedSecurityPolicies: some Sequence<DarwinInit.SecureConfigSecurityPolicy>) {
        self.allowedSecurityPolicies = [.none]
        self.restrictedSecurityPolicies = Array(restrictedSecurityPolicies)
    }

    /// Performs the policy check.
    /// - Parameters:
    ///   - bundle: The attestation bundle.
    ///   - context: The context to use for the policy check.
    public func evaluate(bundle: AttestationBundle, context: inout AttestationPolicyContext) async throws {
        Self.logger.log(
            "Evaluating DarwinInit against allowed policies \(self.allowedSecurityPolicies, privacy: .public) and restricted policies \(self.restrictedSecurityPolicies, privacy: .public)"
        )

        var failOpen = false
        if self.allowedSecurityPolicies.contains(.none) {
            // allow no darwin-init
            Self.logger.warning("Allowing absent or invalid darwin-init since DarwinInitPolicy allows config-security-policy=none")
            failOpen = true
        }

        guard let secureConfigs = bundle.proto.secureConfigs else {
            Self.logger.error("Missing secure config in Attestation Bundle")
            if failOpen {
                return
            }
            throw Error.missingSecureConfigs
        }

        let parsed: DarwinInit
        do {
            parsed = try secureConfigs.darwinInit
        } catch DarwinInit.Error.missingDarwinInit {
            Self.logger.error("Attestation contains secure config, but none of them are darwin-init")
            if failOpen {
                return
            }
            throw Error.missingDarwinInit
        } catch DarwinInit.Error.tooManyDarwinInit {
            Self.logger.error("Attestation contains too many darwin-init secure configs")
            if failOpen {
                return
            }
            throw Error.tooManyDarwinInit
        } catch {
            throw error
        }

        context[Self.appIdentifiersKey] = parsed.appIdentifiers

        if self.restrictedSecurityPolicies.contains(parsed.securityPolicy) {
            Self.logger.error("Darwin-Init security policy \(parsed.securityPolicy.rawValue, privacy: .public) is restricted")
            throw Error.restricted(securityPolicy: parsed.securityPolicy, restricted: self.restrictedSecurityPolicies)
        }

        guard self.allowedSecurityPolicies.contains(parsed.securityPolicy) else {
            Self.logger.error(
                "Darwin-Init security policy \(parsed.securityPolicy.rawValue, privacy: .public) not in list of allowed policies: \(self.allowedSecurityPolicies, privacy: .public)"
            )
            if failOpen {
                return
            }
            throw Error.untrusted(securityPolicy: parsed.securityPolicy, allowed: self.allowedSecurityPolicies)
        }

        context[Self.validatedDarwinInitKey] = parsed

        Self.logger.log(
            "AttestationBundle passed DarwinInitPolicy: reported darwin-init config-security-policy matches allowed list: \(self.allowedSecurityPolicies, privacy: .public)"
        )
    }
}

// MARK: - Context Keys

extension DarwinInitPolicy {
    @usableFromInline
    static var validatedDarwinInitKey: AttestationPolicyContext.Key {
        .init(domain: Self.self, key: "validatedDarwinInit")
    }

    @usableFromInline
    static var appIdentifiersKey: AttestationPolicyContext.Key {
        .init(domain: Self.self, key: "appIdentifiers")
    }
}

extension AttestationPolicyContext {
    @usableFromInline
    var validatedDarwinInit: DarwinInit? {
        self[DarwinInitPolicy.validatedDarwinInitKey] as? DarwinInit
    }

    @usableFromInline
    var appIdentifiers: [String]? {
        self[DarwinInitPolicy.appIdentifiersKey] as? [String]
    }
}

// MARK: - Error
extension DarwinInitPolicy {
    enum Error: Swift.Error {
        case missingSecureConfigs
        case missingDarwinInit
        case tooManyDarwinInit
        case untrusted(securityPolicy: DarwinInit.SecureConfigSecurityPolicy, allowed: [DarwinInit.SecureConfigSecurityPolicy])
        case restricted(securityPolicy: DarwinInit.SecureConfigSecurityPolicy, restricted: [DarwinInit.SecureConfigSecurityPolicy])
    }
}
