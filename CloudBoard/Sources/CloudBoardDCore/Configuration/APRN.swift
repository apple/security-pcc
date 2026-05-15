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

struct APRN {
    fileprivate var stringRepresentation: String

    var zone: Substring

    var domain: Substring

    var region: Substring

    var projectID: Substring

    var resourceType: Substring

    var resourceID: Substring

    init(string: String) throws {
        let components = string.utf8.split(separator: UInt8(ascii: ":"), maxSplits: 6, omittingEmptySubsequences: false)
        guard components.count == 7 else {
            throw Error.insufficientAPRNComponents
        }

        guard components[0].elementsEqual("aprn".utf8) else {
            throw Error.invalidPrefix
        }

        let zone = components[1]
        let domain = components[2]
        let region = components[3]
        let projectID = components[4]
        let resourceType = components[5]
        let resourceID = components[6]

        guard zone.count > 0, domain.count > 0, resourceType.count > 0, resourceID.count > 0 else {
            throw Error.missingMandatoryComponents
        }

        guard zone.isValidNonResourceID, domain.isValidNonResourceID, region.isValidNonResourceID,
              projectID.isValidNonResourceID, resourceType.isValidNonResourceID, resourceID.isValidResourceID else {
            throw Error.invalidAPRNComponent
        }

        self.stringRepresentation = string
        self.zone = Substring(zone)
        self.domain = Substring(domain)
        self.region = Substring(region)
        self.projectID = Substring(projectID)
        self.resourceType = Substring(resourceType)
        self.resourceID = Substring(resourceID)
    }
}

extension APRN: Hashable {
    static func == (lhs: APRN, rhs: APRN) -> Bool {
        return lhs.stringRepresentation == rhs.stringRepresentation
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(self.stringRepresentation)
    }
}

extension APRN: Sendable {}

extension APRN: ExpressibleByStringLiteral {
    init(stringLiteral value: StringLiteralType) {
        // Force unwrap is fine because this is only for string literals
        try! self.init(string: value)
    }
}

extension APRN: CustomStringConvertible {
    var description: String {
        return self.stringRepresentation
    }
}

extension String {
    init(aprn: APRN) {
        self = aprn.stringRepresentation
    }
}

extension APRN {
    enum Error: Swift.Error {
        case insufficientAPRNComponents
        case invalidPrefix
        case missingMandatoryComponents
        case invalidAPRNComponent
    }
}

extension Substring.UTF8View {
    fileprivate var isValidResourceID: Bool {
        self.allSatisfy { $0.isValidResourceIDCharacter }
    }

    fileprivate var isValidNonResourceID: Bool {
        self.allSatisfy { $0.isValidNonResourceIDCharacter }
    }
}

extension UInt8 {
    fileprivate var isValidResourceIDCharacter: Bool {
        // Valid resourceID components contain the characters in the non-resource ID set,
        // and also:
        // :ABCDEFGHIJKLMNOPQRSTUVWXYZ/%
        if self.isValidNonResourceIDCharacter { return true }

        switch self {
        case UInt8(ascii: "A") ... UInt8(ascii: "Z"),
             UInt8(ascii: ":"), UInt8(ascii: "/"), UInt8(ascii: "%"):
            return true
        default:
            return false
        }
    }

    fileprivate var isValidNonResourceIDCharacter: Bool {
        // Valid APRN components other than resource ID contain only the following characters:
        // 0123456789abcdefghijklmnopqrstuvwxyz-._
        switch self {
        case UInt8(ascii: "0") ... UInt8(ascii: "9"),
             UInt8(ascii: "a") ... UInt8(ascii: "z"),
             UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"):
            return true
        default:
            return false
        }
    }
}
