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

/// The SearchPathDirectory is normally an ambient process wide state.
/// For normal use the default, or where desired changing the default value to a value read from preferences
/// works fine.
/// This doesn't work for unit tests.
/// ``explicit`` is used only for testing, and the abstraction needs to be explicitly plumbed into the
/// consuming code to work.
/// Any component using this should check if it is reasonable to do so or not based on SecureConfig
/// and crash if not.
package enum CustomSearchPathDirectory {
    /// leave it unchanged from how it works in regular darwin
    case systemNormal
    /// read from preferences, then set up the process wide value
    case fromPreferences
    /// state it explicitly - only reasonable if in unit tests
    /// This is deliberately designed so you don't unwittingly skip something.
    /// All entries either state exactly what to use or to use the default, any attempt to
    /// lookup something not explicitly defined results in a fatalError as a test likely needs updating
    /// A nil entry indicates to use the default
    case explicit(remap: [CustomSearchPathKey: CustomSearchPathResolution])

    /// Most tests never try daemon restarts and so just getting unique values for
    /// the known used directories will keep them isolated
    package static func explictCompleteIsolation(prefix: String = "test") -> CustomSearchPathDirectory {
        // None of these tests attempt to restart the daemon,
        // so we can make a fresh cache directory everytime for them
        let cachesUrl = try! URL(for: .cachesDirectory, in: .userDomainMask)
            .appendingPathComponent("\(prefix)-\(UUID())")
        return .explicit(remap: [
            .init(for: .cachesDirectory, in: .userDomainMask): .url(cachesUrl),
        ])
    }

    /// use this instead of ``URL(for:in:)``
    package func lookup(
        for directory: FileManager.SearchPathDirectory,
        in domain: FileManager.SearchPathDomainMask
    ) throws -> URL {
        switch self {
        case .systemNormal, .fromPreferences:
            return try URL(for: directory, in: domain)
        case .explicit(let remap):
            guard let resolution = remap[.init(for: directory, in: domain)] else {
                fatalError("Request for \(directory) \(domain) not explicitly defined")
            }
            switch resolution {
            case .url(let url):
                return url
            case .default:
                return try URL(for: directory, in: domain)
            case .error:
                throw CustomSearchPathError.disallowed(directory: directory, domain: domain)
            }
        }
    }
}

package struct CustomSearchPathKey: Hashable, Sendable {
    package var directory: FileManager.SearchPathDirectory
    package var domain: FileManager.SearchPathDomainMask

    package init(
        for directory: FileManager.SearchPathDirectory,
        in domain: FileManager.SearchPathDomainMask
    ) {
        self.directory = directory
        self.domain = domain
    }

    package func hash(into hasher: inout Hasher) {
        hasher.combine(self.directory.rawValue)
        hasher.combine(self.domain.rawValue)
    }
}

package enum CustomSearchPathResolution: Sendable {
    /// redirect to the specific URL
    case url(URL)
    /// use the default implementation
    case `default`
    /// throw an error rather than triggering a fataError
    case error
}

package enum CustomSearchPathError: Error {
    case disallowed(directory: FileManager.SearchPathDirectory, domain: FileManager.SearchPathDomainMask)
}
