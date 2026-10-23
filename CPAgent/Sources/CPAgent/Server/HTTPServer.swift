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
import Logging
import NIOCore
import NIOHTTP1
import ServiceLifecycle
import AppleCertificates
import X509
import NIOSSL

let trustedAPRNs: TrustedAPRNSet = .allow(aprns: [
    try! .init(string: "aprn:apple:certmgr:::group-v2:/ig/16382947/uv/"), // mirkwood-fleet-manager-cm-qa
    try! .init(string: "aprn:apple:certmgr:::group-v2:/ig/17985399/uv/"), // mirkwood-fleet-manager-cm-prod
    /*
    Narrative iCloud domain APRNs
    ------------------------------
    `aprn:apple:icloud:::service:<product-group>/<service-name>/<environment>`

    The <product-group> is usually the team name, but could also be a logical product grouping.
    as that already exists.

        * `prod`
        * `non-prod`
    */
    try! .init(string: "aprn:apple:icloud:::service:pcc-control-plane/mirkwood-fleet-manager/prod"),
    try! .init(string: "aprn:apple:icloud:::service:pcc-control-plane/mirkwood-fleet-manager/non-prod"),
])

// Root CAs: https://narrative.apple.com/accepting-narrative-identities/certificate-validation/verify-root-trust.html#root-cas
/*
Root CA	                    Public Key Type
Apple Corporate Root CA     RSA (2048 bit)
https://certificatemanager.apple.com/certs/apple_corporate_root_ca.pem
*/
let appleCorpCA = try! Certificate(pemEncoded: """
    -----BEGIN CERTIFICATE-----
    MIIDsTCCApmgAwIBAgIIFJlrSmrkQKAwDQYJKoZIhvcNAQELBQAwZjEgMB4GA1UE
    AwwXQXBwbGUgQ29ycG9yYXRlIFJvb3QgQ0ExIDAeBgNVBAsMF0NlcnRpZmljYXRp
    b24gQXV0aG9yaXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzAe
    Fw0xMzA3MTYxOTIwNDVaFw0yOTA3MTcxOTIwNDVaMGYxIDAeBgNVBAMMF0FwcGxl
    IENvcnBvcmF0ZSBSb290IENBMSAwHgYDVQQLDBdDZXJ0aWZpY2F0aW9uIEF1dGhv
    cml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwggEiMA0GCSqG
    SIb3DQEBAQUAA4IBDwAwggEKAoIBAQC1O+Ofah0ORlEe0LUXawZLkq84ECWh7h5O
    7xngc7U3M3IhIctiSj2paNgHtOuNCtswMyEvb9P3Xc4gCgTb/791CEI/PtjI76T4
    VnsTZGvzojgQ+u6dg5Md++8TbDhJ3etxppJYBN4BQSuZXr0kP2moRPKqAXi5OAYQ
    dzb48qM+2V/q9Ytqpl/mUdCbUKAe9YWeSVBKYXjaKaczcouD7nuneU6OAm+dJZcm
    hgyCxYwWfklh/f8aoA0o4Wj1roVy86vgdHXMV2Q8LFUFyY2qs+zIYogVKsRZYDfB
    7WvO6cqvsKVFuv8WMqqShtm5oRN1lZuXXC21EspraznWm0s0R6s1AgMBAAGjYzBh
    MB0GA1UdDgQWBBQ1ICbOhb5JJiAB3cju/z1oyNDf9TAPBgNVHRMBAf8EBTADAQH/
    MB8GA1UdIwQYMBaAFDUgJs6FvkkmIAHdyO7/PWjI0N/1MA4GA1UdDwEB/wQEAwIB
    BjANBgkqhkiG9w0BAQsFAAOCAQEAcwJKpncCp+HLUpediRGgj7zzjxQBKfOlRRcG
    +ATybdXDd7gAwgoaCTI2NmnBKvBEN7x+XxX3CJwZJx1wT9wXlDy7JLTm/HGa1M8s
    Errwto94maqMF36UDGo3WzWRUvpkozM0mTcAPLRObmPtwx03W0W034LN/qqSZMgv
    1i0use1qBPHCSI1LtIQ5ozFN9mO0w26hpS/SHrDGDNEEOjG8h0n4JgvTDAgpu59N
    CPCcEdOlLI2YsRuxV9Nprp4t1WQ4WMmyhASrEB3Kaymlq8z+u3T0NQOPZSoLu8cX
    akk0gzCSjdeuldDXI6fjKQmhsTTDlUnDpPE2AAnTpAmt8lyXsg==
    -----END CERTIFICATE-----
    """
);
/*
Root CA	                    Public Key Type
Apple Corporate Root CA 2   ECC (384 bit)
https://certificatemanager.apple.com/certs/apple_corporate_root_ca_2.pem
*/
let appleCorpCA2 = try! Certificate(pemEncoded: """
    -----BEGIN CERTIFICATE-----
    MIICRTCCAcugAwIBAgIIE0aVDhdcN/0wCgYIKoZIzj0EAwMwaDEiMCAGA1UEAwwZ
    QXBwbGUgQ29ycG9yYXRlIFJvb3QgQ0EgMjEgMB4GA1UECwwXQ2VydGlmaWNhdGlv
    biBBdXRob3JpdHkxEzARBgNVBAoMCkFwcGxlIEluYy4xCzAJBgNVBAYTAlVTMB4X
    DTE2MDgxNzAxMjgwMVoXDTM2MDgxNDAxMjgwMVowaDEiMCAGA1UEAwwZQXBwbGUg
    Q29ycG9yYXRlIFJvb3QgQ0EgMjEgMB4GA1UECwwXQ2VydGlmaWNhdGlvbiBBdXRo
    b3JpdHkxEzARBgNVBAoMCkFwcGxlIEluYy4xCzAJBgNVBAYTAlVTMHYwEAYHKoZI
    zj0CAQYFK4EEACIDYgAE6ROVmqXFAFCLpuLD3loNJwfuxX++VMPgK5QmsUuMmjGE
    /3NWOUGitN7kNqfq62ebPFUqC1jUZ3QzyDt3i104cP5Z5jTC6Js4ZQxquyzTNZiO
    emYPrMuIRYHBBG8hFGQxo0IwQDAdBgNVHQ4EFgQU1u/BzWSVD2tJ2l3nRQrweevi
    XV8wDwYDVR0TAQH/BAUwAwEB/zAOBgNVHQ8BAf8EBAMCAQYwCgYIKoZIzj0EAwMD
    aAAwZQIxAKJCrFQynH90VBbOcS8KvF1MFX5SaMIVJtFxmcJIYQkPacZIXSwdHAff
    i3+/qT+DhgIwSoUnYDwzNc4iHL30kyRzAeVK1zOUhH/cuUAw/AbOV8KDNULKW1Nc
    xW6AdqJp2u2a
    -----END CERTIFICATE-----
    """
);
/*
Root CA	                        Public Key Type
Apple Corporate RSA Root CA 3	RSA (4096 bit)
https://certificatemanager.apple.com/certs/apple_corporate_rsa_root_ca_3.pem
*/
let appleCorpRsaCA3 = try! Certificate(pemEncoded: """
    -----BEGIN CERTIFICATE-----
    MIIFhTCCA22gAwIBAgIUcq4V0xpX0K4oAn9EyM6pTpuoKwswDQYJKoZIhvcNAQEM
    BQAwSjELMAkGA1UEBhMCVVMxEzARBgNVBAoTCkFwcGxlIEluYy4xJjAkBgNVBAMT
    HUFwcGxlIENvcnBvcmF0ZSBSU0EgUm9vdCBDQSAzMB4XDTIxMDIxNzE5MzAzMVoX
    DTQxMDIxMzAwMDAwMFowSjELMAkGA1UEBhMCVVMxEzARBgNVBAoTCkFwcGxlIElu
    Yy4xJjAkBgNVBAMTHUFwcGxlIENvcnBvcmF0ZSBSU0EgUm9vdCBDQSAzMIICIjAN
    BgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAwLsOaWB6T5qq58bICdbu6HBXPx9t
    Y0M2i6V8xtLQbJQqM8gGALEsPyvUhOBACmPCoaafeKjx4++IjHi4Hn+j14OFg7J8
    w6yr2f8mW7d47LoIkOt9OeqGhdZi/VU38oJd7qEye7hk6kCFhagOzBNJ1DILHPb4
    04C2XGat4tUMFGzUlmQ3wsJIINIpq9jevasz+uA29GGPTgVMkWlqwNtxw74GoqF4
    jnNmno5/W8M6cyzjh3AGZU3DWHfr3ZvACUVftJsm/htsoCNm0sr5t/iXClu6+STO
    nmR3Leiq1w40kSFnD9obTs884U+iq49kr2tteSSvZV53YHuxkaBIG92wGOMyYhZ9
    q3AluVokLHjOGW6tN/seFP0b51gOl/p+mDDLA3fSG5RuuMqjvHQXiSiBu5OTCtCd
    8cbyPhiSAvYl0rhsWeYItcwWflVCUB7HAy/qlwicNo9aE0aSaN/3qmU4TzXW8H70
    lbh6A2cKxGr9+y479d/DLGfcFj89wvmrhHrW3mZIgVwVjV49BfLed1Swihezit/a
    CPQ0WF17FfqxIedVPusdjcfeT6BCU/X/+cq0sv06CiFZ4KNmDOn2XLii82xfMcj1
    xWE+HufMWDuwS5DHJt0ttbknD1togzPBxaEu1/nIqZ5kYVUkCi+YXJQihaX+F5aJ
    kacwlGPAmIBrMLcCAwEAAaNjMGEwDwYDVR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAW
    gBSNX/LRHQdiX1xtg8SPTXcr6sPmqjAdBgNVHQ4EFgQUjV/y0R0HYl9cbYPEj013
    K+rD5qowDgYDVR0PAQH/BAQDAgEGMA0GCSqGSIb3DQEBDAUAA4ICAQAOvvN+Prwt
    KG2fROheiSw4scNk0WXcczWpUvYQKtMw5FzYofA28AYoE/HT2qQXFldMq+FlJ0v/
    sWVkXWB3X9RQltUXZ0RLVdw7/ZGXzUZh7ui2VXMRFv8wAgO8FwMzOTheZYeVB6gq
    fJ0jYkCA4CjAmCuGPieZMmNENI/Nup0W6P1bPO5xOxre787BpXQrqXZ/VpLauGqC
    YX17rkpJG4w+4zFEl1Ex5K74gp+VQnrC7+WGgwd996gFRPURQL5oJC/1ofnhQedo
    kdTbwPyeqK94WRhYihe3uq7B8rAsxoxPTY3oxEfN0oSuP9IEgoUZBhee9HeDMCjS
    fbiL/JW/w1VjXyuufkfQbuvx122GZFCAFBej2DAGXWZKghOG7XxyPYYlam7A5eBQ
    DIJ+nY4hRh9r01A0LszRA5oQXs3nhUqWymbiR2gXMGrumsC0tGB45FKX3xWKBg+a
    iQ3bdfyLcLgM0c2eXgQRvX1k89D5El/byushVTWSjUgf/4UwgxfvzmvAiZm8KSGb
    Jd7SSZPCQmVwNbq/RlwVt4QIMv1lHXnvklc8ZQKmdNRHo/sICl00jGCq4ahpLcul
    WeRrAdvaWk/fatr0ywplIByHtvntZnLQ06GSWu+1cRP4TmLxblJrnRj2oq26QN70
    yhWSKDdj61wiTWzsGel3LblgJGdr2QtmZA==
    -----END CERTIFICATE-----
    """
);

final class HTTPServer: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    let healthMonitor: HealthMonitor
    let drainService: DrainService?
    let attestationClient: AttestationClient
    private let insecure: Bool
    private let logger = Logger(label: "CPAgent.HTTPServer")
    private var requestHead: HTTPRequestHead?
    private var requestBody: ByteBuffer?

    init(healthMonitor: HealthMonitor, drainService: DrainService?, attestationClient: AttestationClient, insecure: Bool = false) {
        self.healthMonitor = healthMonitor
        self.drainService = drainService
        self.attestationClient = attestationClient
        self.insecure = insecure
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let reqPart = self.unwrapInboundIn(data)

        switch reqPart {
        case .head(let head):
            self.requestHead = head
            self.requestBody = nil

        case .body(let buffer):
            if self.requestBody == nil {
                self.requestBody = buffer
            } else {
                self.requestBody!.writeImmutableBuffer(buffer)
            }

        case .end:
            guard let head = self.requestHead else {
                context.close(promise: nil)
                return
            }

            self.handleRequest(context: context, head: head, body: self.requestBody)
            self.requestHead = nil
            self.requestBody = nil
        }
    }

    private func handleRequest(
        context: ChannelHandlerContext, head: HTTPRequestHead, body: ByteBuffer?
    ) {
        logger.info(
            "Received request.", metadata: ["method": "\(head.method)", "uri": "\(head.uri)"])

        // Route to appropriate handler
        if head.uri == "/health" && head.method == .GET {
            handleHealthCheck(context: context, head: head)
            return
        } else if head.uri == "/health/gpu/start" && head.method == .GET {
            guard validateClientCertificateChain(context: context) else {
                sendResponse(context: context, head: head, response: (.forbidden, Data("{\"error\":\"Client certificate required\"}".utf8)))
                return
            }
            let response = startGpuCheck()
            sendResponse(context: context, head: head, response: response)
        } else if head.uri == "/drain" && head.method == .POST {
            guard validateClientCertificateChain(context: context) else {
                sendResponse(context: context, head: head, response: (.forbidden, Data("{\"error\":\"Client certificate required\"}".utf8)))
                return
            }
            handleDrainRequest(context: context, head: head, body: body)
        } else if head.uri == "/drain/status" && head.method == .GET {
            guard validateClientCertificateChain(context: context) else {
                sendResponse(context: context, head: head, response: (.forbidden, Data("{\"error\":\"Client certificate required\"}".utf8)))
                return
            }
            handleDrainStatus(context: context, head: head)
        } else if URLComponents(string: head.uri)?.path == "/attestation-data" && head.method == .GET {
            guard validateClientCertificateChain(context: context) else {
                sendResponse(context: context, head: head, response: (.forbidden, Data("{\"error\":\"Client certificate required\"}".utf8)))
                return
            }
            handleGetAttestationData(context: context, head: head)
        } else {
            sendResponse(
                context: context, head: head, response: (.notFound, Data("{\"error\":\"Not Found\"}".utf8)))
        }
    }

    private func handleHealthCheck(context: ChannelHandlerContext, head: HTTPRequestHead) {
        let eventLoop = context.eventLoop
        let drainService = self.drainService

        eventLoop.makeFutureWithTask {
            // This will return immediately even if Cloudboard hasn't subscribed yet
            await drainService?.hasActiveSubscriber ?? false
        }.whenComplete { result in
            let connected = (try? result.get()) ?? false
            let body = "{\"status\":\"healthy\",\"cloudboardConnected\":\(connected)}"
            self.sendResponse(context: context, head: head, response: (.ok, Data(body.utf8)))
        }
    }

    private func startGpuCheck() -> (status: HTTPResponseStatus, body: Data) {
        healthMonitor.scheduleComprehensiveGpuCheck()
        return (.ok, Data("{}".utf8))
    }

    private func handleDrainRequest(
        context: ChannelHandlerContext, head: HTTPRequestHead, body: ByteBuffer?
    ) {
        guard let drainService = drainService else {
            sendResponse(
                context: context, head: head,
                response: (.serviceUnavailable, Data("{\"error\":\"Drain service is disabled\"}".utf8)))
            return
        }

        var gracePeriodSeconds = 120  // default

        if let body = body,
            let data = body.getData(at: body.readerIndex, length: body.readableBytes)
        {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let period = json["gracePeriodSeconds"] as? Int
            {
                gracePeriodSeconds = period
            }
        }

        Task {
            await drainService.startDrain(gracePeriodSeconds: gracePeriodSeconds)
        }

        sendResponse(
            context: context, head: head, response: (.accepted, Data("{\"status\":\"DRAINING\"}".utf8)))
    }

    private func handleDrainStatus(context: ChannelHandlerContext, head: HTTPRequestHead) {
        guard let drainService = self.drainService else {
            sendResponse(
                context: context, head: head,
                response: (.serviceUnavailable, Data("{\"error\":\"Drain service is disabled\"}".utf8)))
            return
        }

        // We need to read the status from the actor, but we're in a non-async context.
        // Use NIO's event loop to bridge async/sync.
        let eventLoop = context.eventLoop

        eventLoop.makeFutureWithTask {
            await drainService.getStatus()
        }.whenComplete { result in
            let status: String
            switch result {
            case .success(let drainStatus):
                status = drainStatus.rawValue
            case .failure:
                status = DrainService.Status.notDraining.rawValue
            }
            let response = (HTTPResponseStatus.ok, Data("{\"status\":\"\(status)\"}".utf8))
            self.sendResponse(context: context, head: head, response: response)
        }
        return
    }

    private func handleGetAttestationData(context: ChannelHandlerContext, head: HTTPRequestHead) {
        let components = URLComponents(string: head.uri)
        guard let nonce = components?.queryItems?.first(where: { $0.name == "nonce" })?.value else {
            self.sendResponse(context: context, head: head, response: (status: .badRequest, body: Data("Missing required parameter 'nonce'".utf8)))
            return
        }
    
        let eventLoop = context.eventLoop
        eventLoop.makeFutureWithTask {
            try await self.attestationClient.getAttestationData(nonce: nonce)
        }
        .whenComplete { result in
            switch result {
            case .success(let data):
                self.sendResponse(context: context, head: head, response: (status: .ok, body: data))
            case .failure(let err as AttestationError):
                self.sendResponse(context: context, head: head, response: (status: err.responseCode, body: Data(err.message.utf8)))
            case .failure(let err):
                self.sendResponse(context: context, head: head, response: (status: .serviceUnavailable, body: Data("An unexpected error occurred: \(err)".utf8)))
            }
        }
    }

    private func validateClientCertificateChain(context: ChannelHandlerContext) -> Bool {
        if insecure {
            return true
        }
        if let sslHandler = try? context.pipeline.syncOperations.handler(type: NIOSSLServerHandler.self) {
            if let peerChain = sslHandler.peerValidatedCertificateChain {
                guard var verifier = try? Verifier(
                    rootCertificates: CertificateStore([appleCorpCA, appleCorpCA2, appleCorpRsaCA3]),
                    policy: {
                        try CMVerifier.verifyingCMClientCertsExpectingAPRNs(trustedAPRNs)
                    }
                ) else {
                    logger.info("Failed to validate client certificate: cannot create verifier")
                    return false
                }

                guard let first = peerChain.first else {
                    logger.info("Failed to validate client certificate: empty chain")
                    return false
                }

                let leaf: Certificate
                var intermediates = CertificateStore()

                do {
                    leaf = try niosslToX509Certificate(first)
                    for cert in peerChain[1...] {
                        intermediates.append(try niosslToX509Certificate(cert))
                    }
                } catch {
                    logger.info("Failed to validate client certificate: invalid certificate in a chain")
                    return false
                }

                // We're running in a syncronous context but have to run async certificate verifier.
                // This should not be block since all certificates are immediately available.
                let semaphore = DispatchSemaphore(value: 0)
                class Box: @unchecked Sendable { var result:  CertificateValidationResult? }
                let box = Box()

                Task {
                    box.result = await verifier.validate(leaf: leaf, intermediates: intermediates)
                    semaphore.signal()
                }
                semaphore.wait()

                guard let result = box.result else {
                    // This should never happen.
                    logger.info("Failed to validate client certificate")
                    return false
                }

                switch result {
                case .validCertificate(_):
                    return true
                case .couldNotValidate(_):
                    logger.info("Failed to validate client certificate")
                    return false
                }
            } else {
                logger.info("Failed to validate client certificate: no client certificate presented")
                return false
            }
        }

        logger.info("Failed to validate client certificate: not a TLS connection")
        return false
    }

    private func niosslToX509Certificate(_ cert: NIOSSLCertificate) throws -> X509.Certificate {
        return try X509.Certificate(derEncoded: cert.toDERBytes())
    }

    private func sendResponse(
        context: ChannelHandlerContext,
        head: HTTPRequestHead,
        response: (status: HTTPResponseStatus, body: Data)
    ) {
        // Create response headers
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        headers.add(name: "Content-Length", value: String(response.body.count))

        // Send response head
        let responseHead = HTTPResponseHead(
            version: head.version,
            status: response.status,
            headers: headers
        )
        context.write(self.wrapOutboundOut(.head(responseHead)), promise: nil)

        // Send response body
        var buffer = context.channel.allocator.buffer(capacity: response.body.count)
        buffer.writeData(response.body)
        context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)

        // Send end and flush
        context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        context.flush()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.error("Error in HTTPServer.", metadata: ["error": "\(String(reportable: error))"])
        context.close(promise: nil)
    }
}
