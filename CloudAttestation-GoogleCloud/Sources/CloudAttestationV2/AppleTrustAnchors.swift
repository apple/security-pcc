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
//  AppleTrustAnchors.swift
//  CloudAttestationV2
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//

import Foundation
import X509

/// Trust anchors for platform-certificate chain verification.
///
/// ## Division of labour with policy
///
/// This type answers a purely *cryptographic* question — "does the chain verify
/// to a root Apple actually operates?" — and deliberately does **not** encode
/// which of those roots is acceptable in a given environment. That is an
/// authorization decision, and it lives in one place: the
/// `gcpv1.platformcertificate` Rego module, which pins root SubjectDN → SHA-384
/// per environment (see `platformcertificate.rego`).
///
/// Keeping the anchor set environment-independent means policy is always the
/// *tightening* layer: anything policy admits, the verifier already admitted, so
/// every rejection is attributable to the policy and its violation message.
/// Making this type environment-aware too would reintroduce two sources of truth
/// that can disagree — a bundle passing the crypto check but failing policy for
/// reasons neither layer explains on its own.
///
/// Note what is *not* here: the self-signed `CloudAttestationV2 Dev CA`. Its
/// private key is a checked-in test fixture, so anyone can mint a chain rooted
/// there; it is not a root this library recognizes at any privilege level.
/// Development chains are exercised by injecting a verifier directly (see
/// `GCPv1Claims.Generator.init(transparencyVerifier:certificateVerifier:)`),
/// never by widening this set.
public enum AppleTrustAnchors {
    /// Every Apple Data Center Attestation root this library recognizes, in every
    /// environment. Which of them is *acceptable* is decided by policy.
    public static let recognized: [X509.Certificate] = [Self.testRootCA, Self.productionRootCA]
}

// MARK: - Roots

extension AppleTrustAnchors {
    /// Apple's DCA *test* root. Recognized here; admitted by policy only in `development`.
    static let testRootCA: X509.Certificate =
        try! X509.Certificate(
            pemEncoded: """
                -----BEGIN CERTIFICATE-----
                MIICYzCCAemgAwIBAgIQQcaqfsAv+rqfSH3psDU3vDAKBggqhkjOPQQDAzByMTkw
                NwYDVQQDDDBUZXN0IERhdGEgQ2VudGVyIEF0dGVzdGF0aW9uIE9ubGluZSBSb290
                IENBIC0gRzMxEzARBgNVBAoMCkFwcGxlIEluYy4xEzARBgNVBAgMCkNhbGlmb3Ju
                aWExCzAJBgNVBAYTAlVTMCAXDTI2MDQwNjE3NTAzMFoYDzIwNTEwMzMxMTc1MDI5
                WjByMTkwNwYDVQQDDDBUZXN0IERhdGEgQ2VudGVyIEF0dGVzdGF0aW9uIE9ubGlu
                ZSBSb290IENBIC0gRzMxEzARBgNVBAoMCkFwcGxlIEluYy4xEzARBgNVBAgMCkNh
                bGlmb3JuaWExCzAJBgNVBAYTAlVTMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAEAAh4
                fgQ6LmkkUuoT+SijctSwRVByc0kgBFQNz+UGYe84RAWcSHTIhFfcyO77QffpCsUv
                tJ6F/9xij7D0fwjf4Ew2En0nMFcUITxGJjj2SqpKpEtMFWUxBa0D1WHmX649o0Iw
                QDAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBRJmyE+SIcWrMFd7NWDLgLFsi+c
                9zAOBgNVHQ8BAf8EBAMCAQYwCgYIKoZIzj0EAwMDaAAwZQIwR/M6GiP1pPFTA2PV
                HUR/21A+oxOBbnYy2tylHtnGfGapT3jjMVT2B58285x/6vk9AjEArsKemh9aBWs7
                RQL3WMMP9XTaa9AQuP8JlZbl3fqy5HZeCRsVTgVO9rfLfgE183mN
                -----END CERTIFICATE-----
                """
        )

    /// Apple's production DCA root. The only root policy admits in `qa` and `production`.
    static let productionRootCA: X509.Certificate =
        try! X509.Certificate(
            pemEncoded: """
                -----BEGIN CERTIFICATE-----
                MIICWTCCAd+gAwIBAgIQD5F3FC9qPQ1W1NA1rz2GrDAKBggqhkjOPQQDAzBtMTQw
                MgYDVQQDDCtEYXRhIENlbnRlciBBdHRlc3RhdGlvbiBPbmxpbmUgUm9vdCBDQSAt
                IEczMRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQIDApDYWxpZm9ybmlhMQsw
                CQYDVQQGEwJVUzAgFw0yNjA1MTUyMDMxMDJaGA8yMDUxMDUwOTIwMzEwMVowbTE0
                MDIGA1UEAwwrRGF0YSBDZW50ZXIgQXR0ZXN0YXRpb24gT25saW5lIFJvb3QgQ0Eg
                LSBHMzETMBEGA1UECgwKQXBwbGUgSW5jLjETMBEGA1UECAwKQ2FsaWZvcm5pYTEL
                MAkGA1UEBhMCVVMwdjAQBgcqhkjOPQIBBgUrgQQAIgNiAASPfPvsRiqAq2qwjsLv
                CeLiJTMvfDcQ/8xCw7/drW88aTUv+IvR/uFIVFhXPoer+P6M/BtOzu+/jCw3JEHB
                jrhzzyZVjAUMwR/rahadbzQDrjheuSd01Ui4fnaB1xY87XqjQjBAMA8GA1UdEwEB
                /wQFMAMBAf8wHQYDVR0OBBYEFJxsE+ikbMQeIAlCImSfEQZvXteHMA4GA1UdDwEB
                /wQEAwIBBjAKBggqhkjOPQQDAwNoADBlAjEA8hdkwWuVJQklKqH2Moxp5n3e+pKW
                CxQZVW7jgHbbIR941UeouTkwGcpiXWUc7flBAjBbsjwafud4MGSL7AV9H1nl8+ac
                pnY78ukW7G1jYQ/SIfVUTSw1d7VFXKnchUBsCdk=
                -----END CERTIFICATE-----
                """
        )
}
