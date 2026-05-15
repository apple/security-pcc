// Copyright © 2025 Apple Inc. All Rights Reserved.

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
//  Constants.swift
//  CloudAttestation
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

import Foundation
import FeatureFlags

let cryptexSignatureSealedHashSalt: [UInt8] = [
    0x99, 0xf2, 0xf6, 0xdd, 0x4f, 0xa2, 0x46, 0x8d,
    0x84, 0x37, 0xc5, 0xb0, 0x0c, 0x01, 0x62, 0xd6,
]

let secureConfigSlotUUID = UUID(uuidString: "FB8BBEC2-BCC6-4ECC-964A-7BEB0C26674A")!
let cryptexSlotUUID = UUID(uuidString: "5C210D03-972B-433A-AEF7-E68A0249915B")!
let apCryptexSlotUUID = UUID(uuidString: "C7D3A072-B217-4920-A022-47818D05B1CB")!

let testProvisioningRootCAData = Data(
    base64Encoded:
        "MIICUTCCAdegAwIBAgIQSi5RuPJ0iVqG3frASM2jSjAKBggqhkjOPQQDAzBqMTEwLwYDVQQDDChUZXN0IERhdGEgQ2VudGVyIEF0dGVzdGF0aW9uIE9ubGluZSBSb290MRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQIDApDYWxpZm9ybmlhMQswCQYDVQQGEwJVUzAeFw0yNDAyMDkxNzQ4NThaFw00OTAyMDIxNzQ4NTdaMGoxMTAvBgNVBAMMKFRlc3QgRGF0YSBDZW50ZXIgQXR0ZXN0YXRpb24gT25saW5lIFJvb3QxEzARBgNVBAoMCkFwcGxlIEluYy4xEzARBgNVBAgMCkNhbGlmb3JuaWExCzAJBgNVBAYTAlVTMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAEIXfCt9w/RL2ktL2xxJyFaju4kE+jMHNE4w53GPOs9EJUVVKGnEGCmBnyGCsfmyMv9TtiCM0VnC+f3yI/8pipnXLJ2t0sP08LpjWRrS330z8pXL3Gf2o5NtPWXwYEhDTxo0IwQDAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBRuBgQiv4uC0Pt8cQW27CBMN41ljTAOBgNVHQ8BAf8EBAMCAQYwCgYIKoZIzj0EAwMDaAAwZQIxANp7xPKVuV+kJYuAlTBiqHRrwgBgnxHkZCLAszV1LaP/b6e4yW0m71pf15as2ovejwIwQFumtEr8XW3DiQoEAiAw6ljfNkjuLjukkbCWvAqihAT2O+EBK1VodWIiXjHdof2+"
)!

let productionProvisioningRootCAData = Data(
    base64Encoded:
        "MIICSTCCAc+gAwIBAgIQFWHuWdy1oSD2UDkBanlRATAKBggqhkjOPQQDAzBmMS0wKwYDVQQDDCREYXRhIENlbnRlciBBdHRlc3RhdGlvbiBSb290IENBIC0gRzIxEzARBgNVBAoMCkFwcGxlIEluYy4xEzARBgNVBAgMCkNhbGlmb3JuaWExCzAJBgNVBAYTAlVTMB4XDTI0MDczMTIxMjc1OFoXDTQ5MDcyNTIxMjc1N1owZjEtMCsGA1UEAwwkRGF0YSBDZW50ZXIgQXR0ZXN0YXRpb24gUm9vdCBDQSAtIEcyMRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQIDApDYWxpZm9ybmlhMQswCQYDVQQGEwJVUzB2MBAGByqGSM49AgEGBSuBBAAiA2IABCkeSUWZ3YfTi9rG9PF4qfljMI1wUvTbZAjRGlBJsrkGRTaWivZB8yWwazoUhxsmG8VBSfiCNBbvczJcGRQCdZnzU9pqnUlPPa70dVUdI98IEnHq7O6KCNs2zlshQApBeqNCMEAwDwYDVR0TAQH/BAUwAwEB/zAdBgNVHQ4EFgQU/u8RHTmJaLaDQzmKBdtctZ8gThkwDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMDA2gAMGUCMFlR1J7jG1qo4zhue+x84CaRQfjUHvBAOq4BwQShRKVNt0luhOEWIHrJ3ytA3WJ9jgIxAKrhOP/wp7grFfQLz3CcSB9KBLOGOLZNzYxAzUuTmh4m/QS2L9z1yvnmGg5MFnnZtg=="
)!
