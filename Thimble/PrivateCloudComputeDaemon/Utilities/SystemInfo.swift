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
//  SystemInfo.swift
//  PrivateCloudCompute
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

import CryptoKit
import Foundation
import MobileGestaltPrivate
import OSAnalytics
import PrivateCloudCompute

package protocol SystemInfoProtocol: Sendable {
    var bundleName: String? { get }
    var bundleVersion: String? { get }
    var bootSessionID: String { get }
    var uniqueDeviceID: String { get }
    var marketingProductName: String { get }
    var productName: String { get }
    var productVersion: String { get }
    var productType: String { get }
    var buildVersion: String { get }
    var automatedDeviceGroup: String? { get }
    var osInfo: String { get }
    var osInfoWithDeviceModel: String { get }
}

package struct SystemInfo: SystemInfoProtocol {
    package let bundleName: String?
    package let bundleVersion: String?

    package var bootSessionID: String {
        return sysctl(name: "kern.bootsessionuuid")
    }

    package var uniqueDeviceID: String

    // "macOS" / "iOS"
    package let marketingProductName: String

    package let marketingDeviceFamilyName: String

    // "macOS" / "iPhone OS"
    package let productName: String

    // "14.6" / "18.0"
    package let productVersion: String

    // "Mac15,8" / "iPhone14,5"
    package var productType: String

    // "23G42" / "22A282"
    package var buildVersion: String

    package var automatedDeviceGroup: String? {
        return OSASystemConfiguration.automatedDeviceGroup()
    }

    /// Example: `<Private> <macOS;14.4;24A281> <com.apple.privatecloudcomputed/5.504.7>`
    /// no hwModel where <Private> is because: rdar://127889821 ([Privacy] Don't expose device model and OS version to ROPES)
    package let osInfo: String

    /// Example: `<MacBookPro18,2> <macOS;14.4;24A281> <com.apple.privatecloudcomputed/5.504.7>`
    /// include hwModel here for Metrics reporting
    package let osInfoWithDeviceModel: String

    init(bundle: Bundle = .main, mobileGestalt: MobileGestalt = .current) {
        self.bundleName = bundle.bundleIdentifier
        self.bundleVersion = bundle.infoDictionary?["CFBundleVersion"] as? String

        #if os(macOS)
        // On macOS, the uniqueDeviceID exists but it does not
        // survive OS updates; however, this thing does.
        var uuid = nil_uuid_t
        var timeout: timespec = .init(tv_sec: 1, tv_nsec: 0)
        gethostuuid(&uuid, &timeout)
        self.uniqueDeviceID = UUID(uuid: uuid).uuidString
        #else
        self.uniqueDeviceID = mobileGestalt.uniqueDeviceID
        #endif

        self.marketingProductName = mobileGestalt.marketingProductName
        self.marketingDeviceFamilyName = mobileGestalt.marketingDeviceFamilyName
        self.productName = mobileGestalt.productName
        self.productVersion = mobileGestalt.productVersion
        self.productType = mobileGestalt.productType
        self.buildVersion = mobileGestalt.buildVersion

        let bundleName = self.bundleName ?? "unknown"
        let bundleVersion = self.bundleVersion ?? "unknown"

        // Only include device family name (e.g. iPad), not the whole productType (e.g. MacBookPro18,2)
        osInfo = "<\(self.marketingDeviceFamilyName)> <\(self.productName);\(self.productVersion);\(self.buildVersion)> <\(bundleName)/\(bundleVersion)>"

        // Include the whole productType (e.g. MacBookPro18,2)
        osInfoWithDeviceModel = "<\(self.productType)> <\(self.productName);\(self.productVersion);\(self.buildVersion)> <\(bundleName)/\(bundleVersion)>"
    }

    // MARK: - System Calls

    private func sysctl(name: String) -> String {
        var size = 0
        var rv = Darwin.sysctlbyname(name, nil, &size, nil, 0)
        guard rv == 0 else {
            let errstr = String(cString: strerror(errno))
            fatalError("sysctlbyname() returned \(rv): \(errstr)")
        }

        guard size > 0 else {
            fatalError("sysctlbyname() for key=\(name) returned size=\(size)")
        }

        var value: [UTF8.CodeUnit] = .init(repeating: 0, count: size)
        rv = Darwin.sysctlbyname(name, &value, &size, nil, 0)
        guard rv == 0 else {
            let errstr = String(cString: strerror(errno))
            fatalError("sysctlbyname() returned \(rv): \(errstr)")
        }

        let truncatedValue = value.prefix(while: { $0 != 0 })
        return String(decoding: truncatedValue, as: UTF8.self)
    }
}

extension SystemInfoProtocol {
    package var uniqueDeviceIDPercentile: Double {
        // There are at least two important properties of this
        // function. First, it gives a double that is uniformly
        // distributed in [0.0, 1.0). Second, it must be a pure
        // function of `uniqueDeviceID` that is stable; if it
        // changes between builds, the stability of the device
        // configuration will be compromised.

        // As a result, we only rely on things that are known
        // to be well defined and stable; such as SHA256.

        let uniqueDeviceID = self.uniqueDeviceID
        guard let uniqueDeviceIDData = uniqueDeviceID.data(using: .utf8) else {
            fatalError("uniqueDeviceIDPercentile failed to understand uniqueDeviceID utf8")
        }

        // The hash of the unique device ID gives a stable and random
        // enough 256 bits, which we truncate to build a random enough
        // Double with the desired properties. The truncation actually
        // works out to be 52 bits.
        let digest = CryptoKit.SHA256.hash(data: uniqueDeviceIDData)
        let truncated = digest.withUnsafeBytes { buf in
            assert(buf.count == 32)
            return buf.load(as: UInt64.self)
        }

        // Fun with IEEE 754! We want to build a Double out of random
        // bits with a range of width 1, so we use the range [1, 2)
        // and subtract 1. If we set the sign to +, the exponent to
        // 0, then we are left with a fractional part that is random
        // in a number of the form "1.(fractional part)".

        // clear the sign bit, and the exponent high bit
        var bits = truncated & 0x3fff_ffff_ffff_ffff
        // set the other exponent bits, so exponent = 0 (1023 biased)
        bits = bits | 0x3ff0_0000_0000_0000
        // now we have: sign = 0, exponent = 0, fraction=(bits),
        // which gives a Double of 1.(bits), uniform in [1, 2).
        let result = Double(bitPattern: bits)
        assert(result.sign == .plus)
        assert(result.exponentBitPattern == 1023)
        // subtracting 1 gives a Double uniform in [0, 1).
        return result - 1
    }
}
