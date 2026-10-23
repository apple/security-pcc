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
//  IOSurface+Extensions.swift
//  EnsembleWarden
//
//  Created by Oliver Chick (ORAC) on 24/01/2025.
//

package import Foundation
package import IOSurface

extension IOSurface {

    package convenience init?(string: String) throws {
        try self.init(data: string.data(using: .utf8)!)
    }

    package convenience init?(data: Data) throws {
        self.init(properties: [
            .width: data.count,
            .height: 1,
            .bytesPerElement: 1,
            .bytesPerRow: data.count
        ])

        _ = try data.withUnsafeBytes { (dataBuffer: UnsafeRawBufferPointer) in
            guard let dataPtr = dataBuffer.baseAddress else {
                throw EnsembleWardenError.failedToAccessDataPointer
            }

            self.baseAddress.copyMemory(from: dataPtr, byteCount: data.count)
        }

    }

    package convenience init?(size: Int) throws {
        self.init(properties: [
            .width: size,
            .height: 1,
            .bytesPerElement: 1,
            .bytesPerRow: size
        ])
    }

    package convenience init?(testBytesCount count: Int) throws {
        var dataBytes = Array<UInt8>(repeating: 0, count: count)
        let a = Character("a").asciiValue!
        let divisor = Int(Character("z").asciiValue! - a) + 1
        for byte in 0..<count {
            dataBytes[byte] = UInt8(Int(a) + byte % divisor)
        }
        try self.init(data: Data(dataBytes))
    }

    package convenience init?(randomBytesCount count: Int) throws {
        var dataBytes = Array<UInt8>(repeating: 0, count: count)
        let result = SecRandomCopyBytes(kSecRandomDefault, count, &dataBytes)
        guard result == errSecSuccess else {
            throw EnsembleWardenError.failedToGenerateRandomBytes
        }
        try self.init(data: Data(dataBytes))
    }

    package convenience init?(
        from inSurface: IOSurface,
        at range: ClosedRange<Int>
    ) throws {
        guard range.lowerBound >= 0, range.lowerBound < inSurface.count,
              range.upperBound >= 0, range.upperBound < inSurface.count else {
            throw EnsembleWardenError.invalidIOSurfaceRange
        }

        try self.init(size: range.count)

        self.baseAddress.copyMemory(
            from: inSurface.baseAddress + range.lowerBound,
            byteCount: range.count)
    }

    package static func == (lhs: IOSurface, rhs: IOSurface) -> Bool {
        if lhs === rhs { return true }
        if IOSurfaceGetWidth(lhs) != IOSurfaceGetWidth(rhs) { return false }
        if IOSurfaceGetHeight(lhs) != IOSurfaceGetHeight(rhs) { return false }
        if IOSurfaceGetBytesPerElement(lhs) !=
            IOSurfaceGetBytesPerElement(rhs) { return false }
        if IOSurfaceGetBytesPerRow(lhs) !=
            IOSurfaceGetBytesPerRow(rhs) { return false }
        return memcmp(lhs.baseAddress, rhs.baseAddress, lhs.bytesPerRow) == 0
    }

    package static func != (lhs: IOSurface, rhs: IOSurface) -> Bool {
        !(lhs == rhs)
    }

    /// Size of the IOSurface data
    package var count: Int {
        IOSurfaceGetWidth(self) *
        IOSurfaceGetHeight(self) *
        IOSurfaceGetBytesPerElement(self)
    }

    /// Hexadecimal string representation of the IOSurface data
    package var hexString: String {
        Data(ioSurface: self).hexString
    }

    package func takeOwnership() throws {
        var taskIDToken = mach_port_t(MACH_PORT_NULL)

        let kr1 = task_create_identity_token(mach_task_self_, &taskIDToken)
        guard kr1 == KERN_SUCCESS else {
            throw EnsembleWardenError.failedToTakeOwnership(kr1)
        }
        defer {
            mach_port_deallocate(mach_task_self_, taskIDToken)
        }

        let kr2 = IOSurfaceSetOwnershipIdentity(
            self, taskIDToken, VM_LEDGER_TAG_UNCHANGED, 0)
        guard kr2 == KERN_SUCCESS else {
            throw EnsembleWardenError.failedToTakeOwnership(kr2)
        }
    }

    package func prefault() throws {
        guard madvise(self.baseAddress, self.count, MADV_WILLNEED) == 0  else {
            throw EnsembleWardenError.failedToPrefaultIOSurface
        }
    }
}

extension String {
    package init(ioSurface: IOSurface) {
        let data = Data(ioSurface: ioSurface)
        self = String(decoding: data, as: UTF8.self)
    }
}

extension Data {
    package init(ioSurface: IOSurface) {
        self = Data(
            bytesNoCopy: ioSurface.baseAddress,
            count: ioSurface.count,
            deallocator: .none)
    }

    /// Hexadecimal string representation of the data
    package var hexString: String {
        self.map { String(format: "%02hhx", $0) }.joined()
    }
}
