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
//  CorporateRoot.swift
//  DarwinInit
//

import Foundation
import Security_Private

struct Certificate {
    var cert: SecCertificate
    var label: String

    init(base64Encoded certString: String, label: String) {
        let certData = Data(base64Encoded: certString)! as CFData
        self.cert = SecCertificateCreateWithData(nil, certData)!
        self.label = label
    }
}

/// This is temporary
/// rdar://93920588 (Accessing Corp cert from DarwinOS customer build.)
enum CorporateRoot {

    static func apply() -> Bool {
        let corpCerts = [
            Certificate(base64Encoded: """
                MIIDsTCCApmgAwIBAgIIFJlrSmrkQKAwDQYJKoZIhvcNAQELBQAwZjEgMB4GA1UEAwwXQXBwbGUgQ29ycG9yYXRlIF\
                Jvb3QgQ0ExIDAeBgNVBAsMF0NlcnRpZmljYXRpb24gQXV0aG9yaXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYD\
                VQQGEwJVUzAeFw0xMzA3MTYxOTIwNDVaFw0yOTA3MTcxOTIwNDVaMGYxIDAeBgNVBAMMF0FwcGxlIENvcnBvcmF0ZS\
                BSb290IENBMSAwHgYDVQQLDBdDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkG\
                A1UEBhMCVVMwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQC1O+Ofah0ORlEe0LUXawZLkq84ECWh7h5O7x\
                ngc7U3M3IhIctiSj2paNgHtOuNCtswMyEvb9P3Xc4gCgTb/791CEI/PtjI76T4VnsTZGvzojgQ+u6dg5Md++8TbDhJ\
                3etxppJYBN4BQSuZXr0kP2moRPKqAXi5OAYQdzb48qM+2V/q9Ytqpl/mUdCbUKAe9YWeSVBKYXjaKaczcouD7nuneU\
                6OAm+dJZcmhgyCxYwWfklh/f8aoA0o4Wj1roVy86vgdHXMV2Q8LFUFyY2qs+zIYogVKsRZYDfB7WvO6cqvsKVFuv8W\
                MqqShtm5oRN1lZuXXC21EspraznWm0s0R6s1AgMBAAGjYzBhMB0GA1UdDgQWBBQ1ICbOhb5JJiAB3cju/z1oyNDf9T\
                APBgNVHRMBAf8EBTADAQH/MB8GA1UdIwQYMBaAFDUgJs6FvkkmIAHdyO7/PWjI0N/1MA4GA1UdDwEB/wQEAwIBBjAN\
                BgkqhkiG9w0BAQsFAAOCAQEAcwJKpncCp+HLUpediRGgj7zzjxQBKfOlRRcG+ATybdXDd7gAwgoaCTI2NmnBKvBEN7\
                x+XxX3CJwZJx1wT9wXlDy7JLTm/HGa1M8sErrwto94maqMF36UDGo3WzWRUvpkozM0mTcAPLRObmPtwx03W0W034LN\
                /qqSZMgv1i0use1qBPHCSI1LtIQ5ozFN9mO0w26hpS/SHrDGDNEEOjG8h0n4JgvTDAgpu59NCPCcEdOlLI2YsRuxV9\
                Nprp4t1WQ4WMmyhASrEB3Kaymlq8z+u3T0NQOPZSoLu8cXakk0gzCSjdeuldDXI6fjKQmhsTTDlUnDpPE2AAnTpAmt\
                8lyXsg==
                """, label: "Apple Corporate Root CA"),
            Certificate(base64Encoded: """
                MIICRTCCAcugAwIBAgIIE0aVDhdcN/0wCgYIKoZIzj0EAwMwaDEiMCAGA1UEAwwZQXBwbGUgQ29ycG9yYXRlIFJvb3\
                QgQ0EgMjEgMB4GA1UECwwXQ2VydGlmaWNhdGlvbiBBdXRob3JpdHkxEzARBgNVBAoMCkFwcGxlIEluYy4xCzAJBgNV\
                BAYTAlVTMB4XDTE2MDgxNzAxMjgwMVoXDTM2MDgxNDAxMjgwMVowaDEiMCAGA1UEAwwZQXBwbGUgQ29ycG9yYXRlIF\
                Jvb3QgQ0EgMjEgMB4GA1UECwwXQ2VydGlmaWNhdGlvbiBBdXRob3JpdHkxEzARBgNVBAoMCkFwcGxlIEluYy4xCzAJ\
                BgNVBAYTAlVTMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAE6ROVmqXFAFCLpuLD3loNJwfuxX++VMPgK5QmsUuMmjGE/3\
                NWOUGitN7kNqfq62ebPFUqC1jUZ3QzyDt3i104cP5Z5jTC6Js4ZQxquyzTNZiOemYPrMuIRYHBBG8hFGQxo0IwQDAd\
                BgNVHQ4EFgQU1u/BzWSVD2tJ2l3nRQrweeviXV8wDwYDVR0TAQH/BAUwAwEB/zAOBgNVHQ8BAf8EBAMCAQYwCgYIKo\
                ZIzj0EAwMDaAAwZQIxAKJCrFQynH90VBbOcS8KvF1MFX5SaMIVJtFxmcJIYQkPacZIXSwdHAffi3+/qT+DhgIwSoUn\
                YDwzNc4iHL30kyRzAeVK1zOUhH/cuUAw/AbOV8KDNULKW1NcxW6AdqJp2u2a
                """, label: "Apple Corporate Root CA 2"),
            Certificate(base64Encoded: """
                MIIFhTCCA22gAwIBAgIUcq4V0xpX0K4oAn9EyM6pTpuoKwswDQYJKoZIhvcNAQEMBQAwSjELMAkGA1UEBhMCVVMxEz\
                ARBgNVBAoTCkFwcGxlIEluYy4xJjAkBgNVBAMTHUFwcGxlIENvcnBvcmF0ZSBSU0EgUm9vdCBDQSAzMB4XDTIxMDIx\
                NzE5MzAzMVoXDTQxMDIxMzAwMDAwMFowSjELMAkGA1UEBhMCVVMxEzARBgNVBAoTCkFwcGxlIEluYy4xJjAkBgNVBA\
                MTHUFwcGxlIENvcnBvcmF0ZSBSU0EgUm9vdCBDQSAzMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAwLsO\
                aWB6T5qq58bICdbu6HBXPx9tY0M2i6V8xtLQbJQqM8gGALEsPyvUhOBACmPCoaafeKjx4++IjHi4Hn+j14OFg7J8w6\
                yr2f8mW7d47LoIkOt9OeqGhdZi/VU38oJd7qEye7hk6kCFhagOzBNJ1DILHPb404C2XGat4tUMFGzUlmQ3wsJIINIp\
                q9jevasz+uA29GGPTgVMkWlqwNtxw74GoqF4jnNmno5/W8M6cyzjh3AGZU3DWHfr3ZvACUVftJsm/htsoCNm0sr5t/\
                iXClu6+STOnmR3Leiq1w40kSFnD9obTs884U+iq49kr2tteSSvZV53YHuxkaBIG92wGOMyYhZ9q3AluVokLHjOGW6t\
                N/seFP0b51gOl/p+mDDLA3fSG5RuuMqjvHQXiSiBu5OTCtCd8cbyPhiSAvYl0rhsWeYItcwWflVCUB7HAy/qlwicNo\
                9aE0aSaN/3qmU4TzXW8H70lbh6A2cKxGr9+y479d/DLGfcFj89wvmrhHrW3mZIgVwVjV49BfLed1Swihezit/aCPQ0\
                WF17FfqxIedVPusdjcfeT6BCU/X/+cq0sv06CiFZ4KNmDOn2XLii82xfMcj1xWE+HufMWDuwS5DHJt0ttbknD1togz\
                PBxaEu1/nIqZ5kYVUkCi+YXJQihaX+F5aJkacwlGPAmIBrMLcCAwEAAaNjMGEwDwYDVR0TAQH/BAUwAwEB/zAfBgNV\
                HSMEGDAWgBSNX/LRHQdiX1xtg8SPTXcr6sPmqjAdBgNVHQ4EFgQUjV/y0R0HYl9cbYPEj013K+rD5qowDgYDVR0PAQ\
                H/BAQDAgEGMA0GCSqGSIb3DQEBDAUAA4ICAQAOvvN+PrwtKG2fROheiSw4scNk0WXcczWpUvYQKtMw5FzYofA28AYo\
                E/HT2qQXFldMq+FlJ0v/sWVkXWB3X9RQltUXZ0RLVdw7/ZGXzUZh7ui2VXMRFv8wAgO8FwMzOTheZYeVB6gqfJ0jYk\
                CA4CjAmCuGPieZMmNENI/Nup0W6P1bPO5xOxre787BpXQrqXZ/VpLauGqCYX17rkpJG4w+4zFEl1Ex5K74gp+VQnrC\
                7+WGgwd996gFRPURQL5oJC/1ofnhQedokdTbwPyeqK94WRhYihe3uq7B8rAsxoxPTY3oxEfN0oSuP9IEgoUZBhee9H\
                eDMCjSfbiL/JW/w1VjXyuufkfQbuvx122GZFCAFBej2DAGXWZKghOG7XxyPYYlam7A5eBQDIJ+nY4hRh9r01A0LszR\
                A5oQXs3nhUqWymbiR2gXMGrumsC0tGB45FKX3xWKBg+aiQ3bdfyLcLgM0c2eXgQRvX1k89D5El/byushVTWSjUgf/4\
                UwgxfvzmvAiZm8KSGbJd7SSZPCQmVwNbq/RlwVt4QIMv1lHXnvklc8ZQKmdNRHo/sICl00jGCq4ahpLculWeRrAdva\
                Wk/fatr0ywplIByHtvntZnLQ06GSWu+1cRP4TmLxblJrnRj2oq26QN70yhWSKDdj61wiTWzsGel3LblgJGdr2QtmZA\
                ==
                """, label: "Apple Corporate RSA Root CA 3")
        ]

        logger.info("Installing Corporate Root CAs")

        for corpCert in corpCerts {
            logger.info("Installing \(corpCert.label)")
            let addquery = [
                kSecClass as String: kSecClassCertificate,
                kSecValueRef as String: corpCert.cert,
                kSecAttrLabel as String: corpCert.label
            ] as [String : Any] as CFDictionary

            var osstatus = SecItemAdd(addquery, nil)

            switch osstatus {
            case errSecSuccess:
                logger.info("Added \(corpCert.label) to keychain")
            case errSecDuplicateItem:
                logger.warning("\(corpCert.label) already present in keychain")
            default:
                let message = (SecCopyErrorMessageString(osstatus, nil) ?? "OSStatus \(osstatus)" as CFString)
                logger.error("Failed to add \(corpCert.label) to keychain: \(message)")
                return false
            }

            // Adding a certificate to the keychain allows it to be found when trust evaluation builds a certificate chain,
            // but just being in the keychain does not by itself cause a certificate to be trusted.
            // Trust must be added explicitly, and trusting in the admin domain means trusted for all users (uids) on the system.
    #if os(macOS)
            osstatus = SecTrustSettingsSetTrustSettings(corpCert.cert, .admin, nil)
            guard osstatus == errSecSuccess else {
                let message = (SecCopyErrorMessageString(osstatus, nil) ?? "OSStatus \(osstatus)" as CFString)
                logger.error("Failed to trust \(corpCert.label): \(message)")
                return false
            }

    #else
            // On embedded, we need to fetch the user domain instead. User trust store is for all users on iOS
            guard let store = SecTrustStoreForDomain(SecTrustStoreDomain(kSecTrustStoreDomainUser)) else {
                logger.error("Failed to retrieve user trust store")
                return false
            }
            osstatus = SecTrustStoreSetTrustSettings(store, corpCert.cert, nil)
            guard osstatus == errSecSuccess else {
                let message = (SecCopyErrorMessageString(osstatus, nil) ?? "OSStatus \(osstatus)" as CFString)
                logger.error("Failed to add \(corpCert.label) to trust store: \(message)")
                return false
            }
    #endif

            logger.log("Installed \(corpCert.label) successfully")
        }

        logger.log("Corporate Root CAs installed successfully")
        return true
    }
}
