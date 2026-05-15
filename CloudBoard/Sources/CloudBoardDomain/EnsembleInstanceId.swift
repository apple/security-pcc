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

package import CloudBoardAsyncXPC

// An identity for an ensemble's life within one reboot cycle.
// Since EphemeralDataMode means any stored state will be lost on reboot and ensemble_id may be retained
// across reboots we need a means to identify that instance of it.
// This is opaque outside CloudBoardCommon, but has the means to be encoded to, and decoded from, a string
// Notes:
// This is very intentionally opaque, to everyone outside cloudboard, the contents may be changed without
// notice to allow it to handle the intended use securely and efficiently.
// If something else wanted to use the components of this for their own ends they should get it themselves.
// from elsewhere or ask for that aspect to be made available directly via an explicit, and documented
// public API.
public struct EnsembleInstanceId: Sendable, Hashable, CustomStringConvertible {
    // never write a long term format without a version header
    private static let version = 1

    // not 100% certain this will be used, verses hostname or even just not used at all
    // it is _really_ useful for debugging though.
    package let ensembleId: String
    // in future this may be directly provided by CloudAttestation, for now it will be internally sourced
    // and maintained within cb_attestationd via a file with a uuid in it.
    package let bootId: String

    /// Construct from the identifiers directly
    /// the only rule is that none may contain the character ":" as it is used in the simple encoding format
    /// to split the values and remain a simpler string that will inline directly into things like JSON fields/
    /// command lines/loggs without further escaping
    /// If something violates this rule we will crash loop till someone deals with it, but it is not viewed as
    /// problematic since the ensembleId format never includes it, and we (currently) control the bootId
    package init(ensembleId: String, bootId: String) {
        func disallowSplitCharacter(_ s: String, character: Character = ":") -> String {
            guard !s.contains(character) else {
                fatalError("\(s) contains \(character) which is not valid within an EnsembleInstanceId")
            }
            return s
        }

        self.ensembleId = disallowSplitCharacter(ensembleId)
        self.bootId = disallowSplitCharacter(bootId)
    }

    /// parses the output from ``description``
    public init?(parseFrom: String) {
        let parts = parseFrom.split(separator: ":")
        guard parts.count == 3 else {
            return nil
        }
        // if we add more versions we can be backwardly compatible where possible/desired
        guard parts[0] == "\(Self.version)" else {
            return nil
        }
        self.ensembleId = String(parts[1])
        self.bootId = String(parts[2])
    }

    /// Provides a short, round tripable string encoding of this instance.
    /// This must be parsed back via ``init(parseFrom:)``
    /// We could get fancy if needed, but this encoding is simple and will transit through JSON or similar easily
    public var description: String {
        "\(Self.version):\(self.ensembleId):\(self.bootId)"
    }

    /// Allows customer code to write tests that don't expose the semantics too much
    public init(testingMachineId: String, testingBootId: String) {
        self.init(ensembleId: testingMachineId, bootId: testingBootId)
    }

    // MARK: ByteBufferCodable without declaration

    package func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        try self.ensembleId.encode(to: &buffer)
        try self.bootId.encode(to: &buffer)
    }

    package init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        self.ensembleId = try .init(from: &buffer)
        self.bootId = try .init(from: &buffer)
    }
}

/// Exists solely to have a ByteBufferCodable form to put into messages easily
/// the wrap/unwrap is cheap enough the simplicity of use is worth it
package struct EnsembleNegotiation: Sendable, Hashable, CustomStringConvertible, ByteBufferCodable {
    package var ensembles: [EnsembleInstanceId]

    package init(_ ensembles: [EnsembleInstanceId]) {
        self.ensembles = ensembles
    }

    package var description: String {
        return "\(self.ensembles)"
    }

    // This duplicates the Array extension implementation

    @inlinable
    package func encode(to buffer: inout ByteBuffer) throws {
        buffer.writeInteger(self.ensembles.count)
        for value in self.ensembles {
            try value.encode(to: &buffer)
        }
    }

    package init(from buffer: inout ByteBuffer) throws {
        guard let count: Int = buffer.readInteger() else {
            throw DecodingError.valueNotFound(
                Self.self,
                .init(
                    codingPath: [ByteBufferCodingKey(Self.self)],
                    debugDescription: "no expected item count"
                )
            )
        }
        self.ensembles = .init()
        self.ensembles.reserveCapacity(count)
        for _ in 0 ..< count {
            try self.ensembles.append(.init(from: &buffer))
        }
    }
}
