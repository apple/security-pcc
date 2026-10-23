Copyright © 2026 Apple Inc. All Rights Reserved.

APPLE INC.
PRIVATE CLOUD COMPUTE SOURCE CODE INTERNAL USE LICENSE AGREEMENT
PLEASE READ THE FOLLOWING PRIVATE CLOUD COMPUTE SOURCE CODE INTERNAL USE LICENSE AGREEMENT (“AGREEMENT”) CAREFULLY BEFORE DOWNLOADING OR USING THE APPLE SOFTWARE ACCOMPANYING THIS AGREEMENT(AS DEFINED BELOW). BY DOWNLOADING OR USING THE APPLE SOFTWARE, YOU ARE AGREEING TO BE BOUND BY THE TERMS OF THIS AGREEMENT. IF YOU DO NOT AGREE TO THE TERMS OF THIS AGREEMENT, DO NOT DOWNLOAD OR USE THE APPLE SOFTWARE. THESE TERMS AND CONDITIONS CONSTITUTE A LEGAL AGREEMENT BETWEEN YOU AND APPLE.
IMPORTANT NOTE: BY DOWNLOADING OR USING THE APPLE SOFTWARE, YOU ARE AGREEING ON YOUR OWN BEHALF AND/OR ON BEHALF OF YOUR COMPANY OR ORGANIZATION TO THE TERMS OF THIS AGREEMENT.
1. As used in this Agreement, the term “Apple Software” collectively means and includes all of the Apple Private Cloud Compute materials provided by Apple here, including but not limited to the Apple Private Cloud Compute software, tools, data, files, frameworks, libraries, documentation, logs and other Apple-created materials. In consideration for your agreement to abide by the following terms, conditioned upon your compliance with these terms and subject to these terms, Apple grants you, for a period of ninety (90) days from the date you download the Apple Software, a limited, non-exclusive, non-sublicensable license under Apple’s copyrights in the Apple Software to download, install, compile and run the Apple Software internally within your organization only on a single Apple-branded computer you own or control, for the sole purpose of verifying the security and privacy characteristics of Apple Private Cloud Compute. This Agreement does not allow the Apple Software to exist on more than one Apple-branded computer at a time, and you may not distribute or make the Apple Software available over a network where it could be used by multiple devices at the same time. You may not, directly or indirectly, redistribute the Apple Software or any portions thereof. The Apple Software is only licensed and intended for use as expressly stated above and may not be used for other purposes or in other contexts without Apple's prior written permission. Except as expressly stated in this notice, no other rights or licenses, express or implied, are granted by Apple herein.
2. The Apple Software is provided by Apple on an "AS IS" basis. APPLE MAKES NO WARRANTIES, EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION THE IMPLIED WARRANTIES OF NON-INFRINGEMENT, MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE, REGARDING THE APPLE SOFTWARE OR ITS USE AND OPERATION ALONE OR IN COMBINATION WITH YOUR PRODUCTS, SYSTEMS, OR SERVICES. APPLE DOES NOT WARRANT THAT THE APPLE SOFTWARE WILL MEET YOUR REQUIREMENTS, THAT THE OPERATION OF THE APPLE SOFTWARE WILL BE UNINTERRUPTED OR ERROR-FREE, THAT DEFECTS IN THE APPLE SOFTWARE WILL BE CORRECTED, OR THAT THE APPLE SOFTWARE WILL BE COMPATIBLE WITH FUTURE APPLE PRODUCTS, SOFTWARE OR SERVICES. NO ORAL OR WRITTEN INFORMATION OR ADVICE GIVEN BY APPLE OR AN APPLE AUTHORIZED REPRESENTATIVE WILL CREATE A WARRANTY.
3. IN NO EVENT SHALL APPLE BE LIABLE FOR ANY DIRECT, SPECIAL, INDIRECT, INCIDENTAL OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) ARISING IN ANY WAY OUT OF THE USE, REPRODUCTION, COMPILATION OR OPERATION OF THE APPLE SOFTWARE, HOWEVER CAUSED AND WHETHER UNDER THEORY OF CONTRACT, TORT (INCLUDING NEGLIGENCE), STRICT LIABILITY OR OTHERWISE, EVEN IF APPLE HAS BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
4. This Agreement is effective until terminated. Your rights under this Agreement will terminate automatically without notice from Apple if you fail to comply with any term(s) of this Agreement. Upon termination, you agree to cease all use of the Apple Software and destroy all copies, full or partial, of the Apple Software. This Agreement constitutes the entire understanding of the parties with respect to the subject matter contained herein, and supersedes all prior negotiations, representations, or understandings, written or oral. This Agreement will be governed and construed in accordance with the laws of the State of California, without regard to its choice of law rules.
You may report security issues about Apple products to product-security@apple.com, as described here: https://www.apple.com/support/security/. Non-security bugs and enhancement requests can be made via https://bugreport.apple.com as described here: https://developer.apple.com/bug-reporting/
EA1937
10/02/2024

# CloudAttestation V2 Policy Architecture

## History and Retrospective.

CloudAttestation V2 will take a different approach to attestation policies than it did for PCC Classic.

Before we used Swift `@ResultBuilders` to build a DSL to express composoable policies. Policies were AND'd together within a result builder block,
and conditional logic was implemented using the standard resultBuilder `buildOptional` and `buildEither` functions. 

Each policy initially just accepted the full AttestationBundle protobuf, which worked well when each distinct policy evaluated a different area of the bundle. 
However what was quickly realized is that many policies need to evaluate data that is effectively parsed/generated from earlier policies. For example,
validating that the loaded cryptexes are correct required first validating that the SEP Attestation was correctly signed, which formed a dependency on 
`SEPAttestationPolicy` from `SEPImagePolicy`. 

The solution brought forward in a backwards compatible way (due to B&I and ABI contract constraints) was to add a dictionary of contextual data that
each policy could inject values into. The key's are strongly typed, using a combination of the Policy's swift meta-type and an arbitrary string, but the values 
are not - type erased to `Any`.

In hindsight, this architecture has a fundamental flaw: both parsing and policy were deeply intertwined. This led to deeply nested dependencies on different policies,
which builds a hidden dependency graph that isn't visible in the code structure. Knowledge of the Apple Silicon/PCC attestation flow was required to make sense of the
hidden policy dependency graph.

Another shortcoming of using result builders is that the policies aren't easily `Encodable`, which means we can't persist them to disk or load them externally: they have to be
built into CloudAttestation binary code.

## Future

For CloudAttestation V2, we are going to aim to maintain several key design objectives:

* Have clear separation between Attestation Parsing, and Policy Evaluation
* Policies should be independent and composable.
* Policies should be `Codable`

---

## Separating Parsing and Policy

Attestation validation will now be split into two stages:

1. Parse and Transform
2. Policy Evaluation

Parsing and Transform will take a collection of Attestation evidence, and recursively parse each item. Parsing will involve not only decoding the binary data, but also
checking signatures, and ensuring pointers across different data fields line up. For example, if a bundle was shipped with the command line arguments to Grub, and somewhere in that bundle
was a TDX attestation which can be resolved against a Canonical Event Log, which in turn has a hash of the command line arguments, the parser could be instructed to verify that all of these line up.

Transformation will be the "output" of the parsing process: emission of a set of strongly typed key-value data that can be stored in a single Dictionary. A registry of all known key-value types must be easy to publish and maintain. These will be referred to as "claims".

```
                                                      ┌────────────────────────────────────────────────────┐        
                                                      │Claims:                                             │        
 ┌──────────────────────┐   Parse and Transform       │"apple::pcc::nvidia-identity": "NVIDIA:GH100:E349ZN"│        
 │                      │                             │"apple::pcc::tdx-identity": "39483F3"               │        
 │                      ┼────────────────────────────►│"apple::pcc::tdx-quote-valid": true                 │        
 │  Attestation Bundle  │                             │...                                                 ┼───────┐
 │                      │                             │                                                    │       │
 │                      │                             │                                                    │       │
 └──────────────────────┘                             │                                                    │       │
                                                      │                                                    │       │
                                                      │                                                    │       │
┌─────────────────────────────────────┐               └────────────────────────────────────────────────────┘       │
│ Policy:                             │                                                                            │
│ apple::pcc:tdx-quote-valid is true  │                                                                            │
│ apple::pcc:tdx::msr::0 == HASH(...) │                                                                            │
│                                     │                                                                            │
│                                     │◄───────────────────────────────────────────────────────────────────────────┘
│                                     │                                                                             
└─────────────────────────────────────┘              
```
                                                               
## protocol ClaimsGenerator (Parse and Transform)

```swift
protocol ClaimsGenerator {
    associatedtype Input
    generateClaims(input: Input) throws -> Claims
}

protocol AsyncClaimsGenerator: ClaimsGenerator {
    associatedtype Input
    generateClaims(input: Input) async throws -> Claims
}

struct Claims {
    var claims: [Key: Value]
    
    struct Key {
        let name: String
    }
    
    enum Value {
        case int(Int)
        case bool(Bool)
        case string(String)
        case bytes([UInt8])
        case array([Value])
        case dictionary([String: Value])
    }
    
    func merge(_ other) throws -> Claims { }
}
```

## PolicyEngine (Evaluation)

```swift
protocol PolicyEngine {
    associatedtype PolicyType: Policy
    associatedtype Output: Sendable // can be boolean or struct
    func evaluate(claims: Claims, with: PolicyType) async throws -> Output
}

protocol Policy: Codable {

}
```

Engines can be anything

```swift
struct SwiftPolicyEngine: PolicyEngine {
    func evaluate(claims: Claims, with policy: Policy) async throws -> Bool {
        let results = try policy.predicates.map { try $0.evaluate(claims) }
        return results.allSatisfy { $0 == true }
    }
}

extension SwiftPolicyEngine {
    struct Policy: CloudAttestationV2.Policy {
        var predicates: [Predicate<Claims>]

        init(_ predicate: Predicate<Claims>) {
            self.predicates = [predicate]
        }

        init(_ predicates: Predicate<Claims>...) {
            self.predicates = predicates
        }
    }
}
```

or something more advanced

```swift
struct OPAEngine: PolicyEngine {
    init() { }

    func evaluate(claims: Claims, with policy: Policy) async throws -> JSONOutput {
        let opaClaims = claims.json()
        let result = try self.opa.evaluate(policy, opaClaims)
        return result
    }
}

extension OPAEngine {
    struct Policy: CloudAttestationV2.Policy  {
        init(from: OPA.Bundle) throws { }
    }
}
```
