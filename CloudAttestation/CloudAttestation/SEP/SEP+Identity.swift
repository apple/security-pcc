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
//  SEP+Identity.swift
//  CloudAttestation
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

extension SEP {
    /// Collates the various bits from a SEP Attestation that represent Chip Identity.
    public struct Identity: Hashable, Sendable {
        /// The Chip ID.
        public let chipID: UInt32
        /// The ECID
        public let ecid: UInt64
        /// The Architecture Bits
        public let archBits: ArchBits
        /// The SW Seed
        public let swSeed: UInt32

        /// A bitfield representing the Chip's Architecture Bits.
        public struct ArchBits: Hashable, Sendable, RawRepresentable {
            /// The production status fuse.
            public let productionStatus: Bool
            /// The security mode fuse.
            public let securityMode: Bool
            /// The security domain.
            public let securityDomain: SecurityDomain

            /// The raw value of the bitfield.
            public var rawValue: UInt8 {
                (securityDomain.rawValue & 0b11) | (securityMode ? 1 : 0) << 2 | (productionStatus ? 1 : 0) << 3
            }

            /// An enum representing the Chip's Security Domain.
            public enum SecurityDomain: UInt8, RawRepresentable, Sendable {
                case zero
                case one
                case two
                case three
            }

            /// Creates a new instance from the raw value.
            /// - Parameter rawValue: The raw value.
            public init(rawValue: UInt8) {
                self.productionStatus = rawValue.bit(at: 3)
                self.securityMode = rawValue.bit(at: 2)
                self.securityDomain = SecurityDomain(rawValue: rawValue.bits(at: 0, count: 2))!
            }

            init(
                productionStatus: Bool,
                securityMode: Bool,
                securityDomain: SecurityDomain
            ) {
                self.productionStatus = productionStatus
                self.securityMode = securityMode
                self.securityDomain = securityDomain
            }
        }

        /// Creates a new instance.
        /// - Parameters:
        ///   - chipID: The chip ID.
        ///   - ecid: The ECID.
        ///   - archBits: The architecture bits.
        ///   - swSeed: The SW seed.
        public init(chipID: UInt32, ecid: UInt64, archBits: ArchBits, swSeed: UInt32) {
            self.chipID = chipID
            self.ecid = ecid
            self.archBits = archBits
            self.swSeed = swSeed
        }

        /// Creates a new instance from the given string data.
        /// - Parameter data: The string in data form.
        public init?(data: Data) {
            guard let string = String(data: data, encoding: .utf8) else {
                return nil
            }

            guard let id = Self.init(string: string) else {
                return nil
            }

            self = id
        }

        /// Creates a new instance from the given string.
        /// - Parameter string: The string.
        public init?(string: String) {
            let pieces = string.split(separator: "-", maxSplits: 4, omittingEmptySubsequences: true)
            guard pieces.count == 4 else {
                return nil
            }

            guard let chipID = UInt32(pieces[0], radix: 16) else {
                return nil
            }

            guard let ecid = UInt64(pieces[1], radix: 16) else {
                return nil
            }

            guard let archBits = UInt8(pieces[2], radix: 16) else {
                return nil
            }

            guard let swSeed = UInt32(pieces[3], radix: 16) else {
                return nil
            }

            self.chipID = chipID
            self.ecid = ecid
            self.archBits = ArchBits(rawValue: archBits)
            self.swSeed = swSeed
        }

        /// The dash separated string representation.
        public var string: String {
            return String(format: "%x-%llx-%x-%x", chipID, ecid, archBits.rawValue, swSeed)
        }

        /// The unique device identifier.
        public var udid: String {
            return String(format: "%08X-%016llX", chipID, ecid)
        }
    }
}
