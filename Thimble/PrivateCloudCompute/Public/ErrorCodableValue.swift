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
//  ErrorCodableValue.swift
//  PrivateCloudCompute
//
//  Copyright © 2025 Apple Inc. All rights reserved.
//

import Foundation
import Network

// The purpose of this type is to give a class of well-known
// errors Codable (with fallback to every Error through NSError).
// Please note that these things are NOT themselves Error, and
// they should not be conformed to Error in the future. If you
// want Errors, use the underlying values.

// Were we to try to make these look like Error (don't!), they
// would gain the runtime ability to convert to NSError, and
// without extra care that would be very messy. In particular,
// CustomNSError is impossible to use here because the domain
// is not static.

package enum ErrorCodableValue: Sendable, Codable {
    case network(NWErrorCodableValue)
    case cancellation(CancellationCodableValue)
    case other(NSErrorCodableValue)

    package init<E: Error>(error: E) {
        switch error {
        case let nwError as NWError:
            if let codable = NWErrorCodableValue(error: nwError) {
                self = .network(codable)
                return
            }
        case let cancellationError as CancellationError:
            let codable = CancellationCodableValue(error: cancellationError)
            self = .cancellation(codable)
            return
        default:
            break
        }

        let codable = NSErrorCodableValue(error: error)
        self = .other(codable)
    }

    package func unwrap() -> any Error {
        switch self {
        case .network(let codable):
            return NWError(codableValue: codable)
        case .cancellation(let codable):
            return CancellationError(codableValue: codable)
        case .other(let codable):
            return NSError(codableValue: codable)
        }
    }
}

// MARK: NWError

extension ErrorCodableValue {
    package enum NWErrorCodableValue: Sendable, Codable {
        case posix(Int32)
        case dns(DNSServiceErrorType)
        case tls(OSStatus)
        case wifiAware(Int32)

        package init?(error: NWError) {
            switch error {
            case .posix(let code): self = .posix(code.rawValue)
            case .dns(let code): self = .dns(code)
            case .tls(let code): self = .tls(code)
            case .wifiAware(let code): self = .wifiAware(code)
            @unknown default: return nil
            }
        }
    }
}

extension NWError {
    package init(codableValue: ErrorCodableValue.NWErrorCodableValue) {
        switch codableValue {
        case .posix(let rawValue):
            let code = POSIXErrorCode(rawValue: rawValue) ?? .EPERM
            self = .posix(code)
        case .dns(let code): self = .dns(code)
        case .tls(let code): self = .tls(code)
        case .wifiAware(let code): self = .wifiAware(code)
        }
    }
}

// MARK: CancellationError

extension ErrorCodableValue {
    package struct CancellationCodableValue: Sendable, Codable {
        package init(error: CancellationError) {
        }
    }
}

extension CancellationError {
    package init(codableValue: ErrorCodableValue.CancellationCodableValue) {
        self.init()
    }
}

// MARK: NSError

extension ErrorCodableValue {
    package struct NSErrorCodableValue: Sendable, Codable {
        package var domain: String
        package var code: Int
        package var userInfo: [String: String]
        package var underlyingErrors: [ErrorCodableValue]

        package init<E: Error>(error: E) {
            let nsError = error as NSError
            self.domain = nsError.domain
            self.code = nsError.code
            self.userInfo = nsError.userInfo.filter { (key, _) in
                key != NSUnderlyingErrorKey && key != NSMultipleUnderlyingErrorsKey
            }.mapValues { value in
                (value as? String) ?? "\(value)"
            }
            self.underlyingErrors = nsError.userInfo.filter { (key, value) in
                key == NSUnderlyingErrorKey || key == NSMultipleUnderlyingErrorsKey
            }.flatMap { (key, value) in
                if key == NSUnderlyingErrorKey, let value = value as? any Error {
                    return [ErrorCodableValue(error: value)]
                } else if key == NSMultipleUnderlyingErrorsKey, let values = value as? [any Error] {
                    return values.map { ErrorCodableValue(error: $0) }
                } else {
                    return []
                }
            }
        }
    }
}

extension NSError {
    package convenience init(codableValue: ErrorCodableValue.NSErrorCodableValue) {
        var userInfo: [String: Any] = codableValue.userInfo
        let underlyingErrors = codableValue.underlyingErrors
        if underlyingErrors.count == 1, let value = underlyingErrors.first {
            userInfo[NSUnderlyingErrorKey] = value.unwrap()
        } else if underlyingErrors.count > 1 {
            userInfo[NSMultipleUnderlyingErrorsKey] = underlyingErrors.map { value in
                value.unwrap()
            }
        }

        self.init(
            domain: codableValue.domain,
            code: codableValue.code,
            userInfo: userInfo
        )
    }
}
