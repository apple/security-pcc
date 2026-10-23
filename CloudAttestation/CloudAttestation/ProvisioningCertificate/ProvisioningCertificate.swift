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
//  ProvisioningCertificate.swift
//  CloudAttestation
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

@preconcurrency import Security
import SwiftASN1Internal
import CryptoKit
import Security_Private.SecCertificatePriv

/// A device provisioning certificate.
public struct ProvisioningCertificate: Sendable {
    let certificate: SecCertificate

    // TODO: Remove when Security adopts Swift Concurrency
    private let _publicKey: SecKey
    /// The public key.
    public var publicKey: SecKey {
        _publicKey
    }
    /// The chassis ID.
    public let chassisID: ChassisID?
    /// The device identity.
    public let deviceIdentity: DeviceIdentity?
    /// The raw X.509 certificate data.
    public var data: Data {
        SecCertificateCopyData(certificate) as Data
    }

    /// Creates a new device provisioning certificate.
    /// - Parameter certificate: The X.509 certificate.
    public init(from certificate: SecCertificate) throws {
        guard let publicKey = SecCertificateCopyKey(certificate) else {
            throw Error.missingPublicKey
        }

        self.certificate = certificate
        self._publicKey = publicKey

        var critical: Bool = false
        if let chassisIDValue = SecCertificateCopyExtensionValue(certificate, ChassisID.objectIdentifier.description as CFString, &critical) as? Data {
            do {
                self.chassisID = try ChassisID(extensionValue: chassisIDValue)
            } catch let error as ASN1Error {
                throw Error.extensionError(error)
            } catch {
                throw Error.unknown(error)
            }
        } else {
            self.chassisID = nil
        }

        if let deviceIdentityValue = SecCertificateCopyExtensionValue(certificate, DeviceIdentity.objectIdentifier.description as CFString, &critical) as? Data {
            do {
                self.deviceIdentity = try DeviceIdentity(extensionValue: deviceIdentityValue)
            } catch let error as ASN1Error {
                throw Error.extensionError(error)
            } catch {
                throw Error.unknown(error)
            }
        } else {
            self.deviceIdentity = nil
        }
    }

    /// Creates a new device provisioning certificate.
    /// - Parameter data: The raw X.509 certificate data.
    public init(data: some DataProtocol) throws {

        guard let parsed = SecCertificateCreateWithData(nil, Data(data) as CFData) else {
            throw Error.invalidCertificate
        }

        self = try .init(from: parsed)
    }

    /// Returns the certificate's fingerprint.
    /// - Parameter hashFunction: The hash function to use. Defaults to ``CryptoKit/SHA256``
    public func fingerprint<Hash: HashFunction>(using hashFunction: Hash.Type = SHA256.self) -> Hash.Digest {
        hashFunction.hash(data: data)
    }
}
