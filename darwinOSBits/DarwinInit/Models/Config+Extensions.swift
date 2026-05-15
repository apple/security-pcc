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
//  Config+Extensions.swift
//  darwinOSBits
//
//

import Foundation

extension Config {

    /// Get the `meta.applyTimeout` value as `Duration`, if set.
    var applyTimeout: Duration? {
        guard let str = meta?.applyTimeout else {
            return nil
        }
        return Duration(argument: str)
    }

}

extension Config.Cryptex {

    enum DepsolvError: Error {
        case dependencyMissing(String)
        case cycleDetected(Set<String>)
    }

    /// Sort the cryptexes according to their dependencies.
    ///
    /// Tries to topological sort the dependency graph of cryptexes into a
    /// list of cryptex identifiers so that all dependencies of each cryptex
    /// appear before itself in the list.
    ///
    /// This can fail if 1) there is a depdendency totally missing or
    /// 2) if the graph cannot be flattened because there is a cycle in it.
    ///
    /// - Throws: `DepsolvError.dependencyMissing` if any dependency is missing.
    /// - Throws: `DepsolvError.cycleDetected` if there is a cycle in the dependency graph.
    /// - Returns: List of sorted cryptex indentifiers.
    func depsolvCryptexes() throws -> [String] {
        guard let cryptexes else { return [] }

        var result: [String] = []
        var todo = Array(cryptexes.keys)

        // Invariant: Either we make progress, i.e. the todo is shrinking
        // or we have a cycle and throw.
        while !todo.isEmpty {
            let before = todo.count

            for (i, identifier) in todo.enumerated() {
                guard let single = cryptexes[identifier] else { continue }
                if let deps = single.dependencies {
                    // Check if any dependencies are missing
                    let missing = try deps.first {
                        if result.contains($0) {
                            return false
                        }
                        // Not in result, _must_ be in todo, or we miss it
                        guard todo.contains($0) else {
                            throw DepsolvError.dependencyMissing($0)
                        }
                        return true
                    }

                    // Missing dependencies, need to try again
                    guard missing == nil else {
                        continue
                    }
                }

                // no dependencies or all depenendcies in result
                todo[i] = ""
                result.append(identifier)
            }

            todo = todo.filter {  $0 != "" }
            if todo.count == before {
                throw DepsolvError.cycleDetected(Set(todo))
            }
        }
        return result
    }

}

extension Config.Cryptex.DepsolvError: CustomStringConvertible {
    var description: String {
        switch self {
        case .cycleDetected(let ids):
            "Cycle detected between \(ids)"

        case .dependencyMissing(let missing):
            "Dependencies missing: \(missing)"
        }
    }
}

extension Config.Cryptex.Cryptex {
    // v2:
    //  input:  "/cryptex/cryptexes/com.apple.foo/url"
    //  output: "/cryptex/cryptexes/com.apple.foo"
    // v1:
    //  input:  "/cryptex/0/url"
    //  output: "/cryptex/0"
    var jsonPointer: JSONPointer {
        let count = self.$url.codingPath.count
        let codingKeys = Array(self.$url.codingPath[0...count-2])
        return JSONPointer(codingKeys: codingKeys)
    }
}

extension Config.User {
    // v2:
    //  input:  "/users/local/uid"
    //  output: "/users/local"
    // v1:
    //  input:  "/user/uid/"
    //  output: "/user"
    var jsonPointer: JSONPointer {
        let count = self.$uid.codingPath.count
        let codingKeys = Array(self.$uid.codingPath[0...count-2])
        return JSONPointer(codingKeys: codingKeys)
    }
}

extension Array where Element == Config {

    func jsonString(prettyPrinted: Bool = true, redacted: Bool = true, origin: Bool = false) throws -> String {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            if prettyPrinted {
                encoder.outputFormatting.insert(.prettyPrinted)
            }
            if !redacted {
                encoder.userInfo[CredentialString.redactionOverrideKey] = true
            }

            if origin {
                let originArray = self.map(\.origin?.source)
                let data = try encoder.encode(originArray)
                return String(decoding: data, as: UTF8.self)
            }

            let data = try encoder.encode(self)
            return String(decoding: data, as: UTF8.self)
        } catch {
            throw DInitError.unableToSerializeConfig(self, error)
        }
    }

}

extension Config {

    func jsonString(prettyPrinted: Bool = true, redacted: Bool = true, origin: Bool = false) throws -> String {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            if prettyPrinted {
                encoder.outputFormatting.insert(.prettyPrinted)
            }
            if !redacted {
                encoder.userInfo[CredentialString.redactionOverrideKey] = true
            }
            let config: Encodable = if origin, let origin = self.origin {
                origin.source
            } else {
                self
            }
            let data = try encoder.encode(config)
            return String(decoding: data, as: UTF8.self)
        } catch {
            throw DInitError.unableToSerializeConfig([self], error)
        }
    }

}
