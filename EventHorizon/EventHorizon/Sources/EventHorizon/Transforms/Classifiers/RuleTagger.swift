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

#if canImport(os)
import Foundation
import os
#endif
public final class RuleTagger: EHTransform, EHFileSubscriber {
    protocol CustomFieldMatcher {
        func getValueFromField(field: String) -> Any?
    }
    public var filePaths: [String]? {
        let paths: Set<String> = Set(
            rules
                .flatMap(\.constraints)
                .compactMap(\.requiredPaths)
                .flatMap { $0 }
        )
        return paths.isEmpty ? nil : Array(paths)
    }

    private let log = EHLog.withCategory(RuleTagger.self)

    public enum Operation: String, CaseIterable, Sendable {
        case equals
        case not_equal

        case included_in_exactly

        case substring_included_in

        case not_included_in

        case starts_with

        case ends_with

        case regex

        case no_field

        case arr_count_greater_than

        case set_includes

    }

    public enum ConstraintCriteria: Sendable, Hashable {
        case all
        case none
        case any
        case at_least(Int)
        case no_more_than(Int)
        case exactly(Int)
    }

    public init(_ rules: [Rule]) {
        self.rules = rules
        self.allConstraints = Array(Set(rules.flatMap { $0.constraints.compactMap { $0 as? Constraint } }))
    }
    public let name = "RuleTagger"
    public final class Constraint: ConstraintDefinition {
        public let stringValue: String
        public let intValue: Int?
        public let doubleValue: Double?
        public let boolValue: Bool?
        public let collectionMatchStrategy: ConstraintCriteria
        public let requiredPaths: [String]?

        public init(operation: Operation, field: String, value: any Hashable & Sendable, collectionMatchStrategy: ConstraintCriteria = .any, requiredPaths: [String]? = nil) {
            self.operation = operation
            self.field = field
            self.value = value
            self.collectionMatchStrategy = collectionMatchStrategy
            self.requiredPaths = requiredPaths
            self.stringValue = {
                if let stringValue = value as? String {
                    return stringValue
                }
                return String(describing: value)
            }()
            self.intValue = {
                if let intValue = value as? Int {
                    return intValue
                }
                return Int(String(describing: value))
            }()
            self.doubleValue = {
                if let doubleValue = value as? Double {
                    return doubleValue
                }
                return Double(String(describing: value))
            }()
            self.boolValue = {
                if let boolValue = value as? Bool {
                    return boolValue
                }
                return Bool(String(describing: value))
            }()

        }

        public static func == (lhs: RuleTagger.Constraint, rhs: RuleTagger.Constraint) -> Bool {
            lhs.hashValue == rhs.hashValue
        }

        public let operation: Operation
        public let field: String
        public let value: any Sendable & Hashable

        public func hash(into hasher: inout Hasher) {
            hasher.combine(operation)
            hasher.combine(collectionMatchStrategy)
            hasher.combine(field)
            hasher.combine(value)
            hasher.combine(requiredPaths)
        }
    }
    public protocol ConstraintDefinition: Sendable, Hashable {
        var value: any Hashable & Sendable { get }
        var stringValue: String { get }
        var intValue: Int? { get }
        var doubleValue: Double? { get }
        var boolValue: Bool? { get }
        var operation: Operation { get }
        var field: String { get }
        var collectionMatchStrategy: ConstraintCriteria { get }
        var requiredPaths: [String]? { get }
    }

    public struct Rule: Sendable {
        let constraints: [any ConstraintDefinition]
        let criteria: ConstraintCriteria
        let name: String
        let tags: Set<String>
    }

    let rules: [Rule]
    let allConstraints: [Constraint]

    private actor RuleEvaluationCache {
        var cache: [Int: Bool] = [:]
        var mirrorCache: [String: Any]?

        func handleMultiMatch<T>(destField: T, collection: [T], multiMatchStrat: ConstraintCriteria, predicate: (T) -> Bool) -> Bool {
            switch multiMatchStrat {
            case .all:
                return collection.allSatisfy(predicate)
            case .none:
                return !collection.contains(where: predicate)
            case .any:
                return collection.contains(where: predicate)
            case .at_least(let n):
                return collection.count(where: predicate) >= n
            case .no_more_than(let n):
                return collection.count(where: predicate) < n
            case .exactly(let n):
                return collection.count(where: predicate) == n
            }
        }

        func evaluate(constraint: any ConstraintDefinition, event: any EHUEFEvent) -> Bool {
            if let evaluated = cache[constraint.hashValue] {
                return evaluated
            }
            var eval = false
            var destFieldVal: Any?
            if constraint.field == "event_category" {
                destFieldVal = event.event_category.rawValue
            } else if constraint.field == "event_type" {
                destFieldVal = event.event_type
            } else if constraint.field == "tags" {
                destFieldVal = event.tags
            } else if let val = event.fields[constraint.field] {
                if let sval = val.stringValue {
                    destFieldVal = sval
                } else if let ival = val.intValue {
                    destFieldVal = ival
                } else if let ival = val.doubleValue {
                    destFieldVal = ival
                } else if let bval = val.boolValue {
                    destFieldVal = bval
                }
            } else if let customField = event as? CustomFieldMatcher, let resolved = customField.getValueFromField(field: constraint.field) {
                destFieldVal = resolved
            } else {
                if mirrorCache == nil {
                    let skipFields: Set<String> = ["fields", "tags", "event_category", "event_type"]
                    let mirror = Mirror(reflecting: event)
                    mirrorCache = mirror.children.reduce(into: [:]) { result, child in
                        if let label = child.label, !skipFields.contains(label) {
                            result[label] = child.value
                        }
                    }
                }
                if let mirrorCache, let mval = mirrorCache[constraint.field] {
                    destFieldVal = mval
                }
            }

            if let destFieldVal {
                switch constraint.operation {
                case .set_includes:
                    if let typedVal = destFieldVal as? Set<String> {
                        if let needles = constraint.value as? [String], !needles.isEmpty, self.handleMultiMatch(destField: needles.first!, collection: needles, multiMatchStrat: constraint.collectionMatchStrategy, predicate: { typedVal.contains($0) }) {
                            eval = true
                        } else if let needle = constraint.value as? String, typedVal.contains(needle) {
                            eval = true
                        }
                    }
                case .arr_count_greater_than:
                    if let typedVal = destFieldVal as? [Any], let compTypedVal = constraint.intValue, typedVal.count > compTypedVal {
                        eval = true
                    }
                case .equals:
                    if let typedVal = destFieldVal as? String, typedVal == constraint.stringValue {
                        eval = true
                    } else if let typedVal = destFieldVal as? Int, let compTypedVal = constraint.intValue, typedVal == compTypedVal {
                        eval = true
                    } else if let typedVal = destFieldVal as? Double, let compTypedVal = constraint.doubleValue, typedVal == compTypedVal {
                        eval = true
                    } else if let typedVal = destFieldVal as? Bool, let compTypedVal = constraint.boolValue, typedVal == compTypedVal {
                        eval = true
                    } else {
                    }
                case .not_equal:
                    if let typedVal = destFieldVal as? String, typedVal != constraint.stringValue {
                        eval = true
                    } else if let typedVal = destFieldVal as? Int, let compTypedVal = constraint.intValue, typedVal != compTypedVal {
                        eval = true
                    } else if let typedVal = destFieldVal as? Double, let compTypedVal = constraint.doubleValue, typedVal != compTypedVal {
                        eval = true
                    } else if let typedVal = destFieldVal as? Bool, let compTypedVal = constraint.boolValue, typedVal != compTypedVal {
                        eval = true
                    } else {
                    }
                case .regex:
                    if let typedVal = destFieldVal as? String {
                        if let needles = constraint.value as? [String] {
                            let rNeedles = needles.compactMap({ try? Regex($0) })
                            if !rNeedles.isEmpty {
                                eval = {
                                    switch constraint.collectionMatchStrategy {
                                    case .all:
                                        return rNeedles.allSatisfy({ (try? $0.firstMatch(in: typedVal)) != nil })
                                    case .none:
                                        return !rNeedles.contains(where: { (try? $0.firstMatch(in: typedVal)) != nil })
                                    case .any:
                                        return rNeedles.contains(where: { (try? $0.firstMatch(in: typedVal)) != nil })
                                    case .at_least(let n):
                                        return rNeedles.count(where: { (try? $0.firstMatch(in: typedVal)) != nil }) >= n
                                    case .no_more_than(let n):
                                        return rNeedles.count(where: { (try? $0.firstMatch(in: typedVal)) != nil }) < n
                                    case .exactly(let n):
                                        return rNeedles.count(where: { (try? $0.firstMatch(in: typedVal)) != nil }) == n
                                    }
                                }()
                            }
                        } else if let needle = constraint.value as? String, let rReg = try? Regex(needle), (try? rReg.firstMatch(in: typedVal)) != nil {
                            eval = true
                        }
                    } else {
                    }

                case .included_in_exactly:
                    if let typedVal = destFieldVal as? String, let needles = constraint.value as? [String],
                       self.handleMultiMatch(destField: typedVal, collection: needles, multiMatchStrat: constraint.collectionMatchStrategy, predicate: { $0 == typedVal }) {
                        eval = true
                    } else if let typedVal = destFieldVal as? Int, let needles = constraint.value as? [Int],
                              self.handleMultiMatch(destField: typedVal, collection: needles, multiMatchStrat: constraint.collectionMatchStrategy, predicate: { $0 == typedVal }) {
                        eval = true
                    } else if let typedVal = destFieldVal as? Double, let needles = constraint.value as? [Double],
                              self.handleMultiMatch(destField: typedVal, collection: needles, multiMatchStrat: constraint.collectionMatchStrategy, predicate: { $0 == typedVal }) {
                        eval = true
                    } else if let typedVal = destFieldVal as? Bool, let needles = constraint.value as? [Bool],
                              self.handleMultiMatch(destField: typedVal, collection: needles, multiMatchStrat: constraint.collectionMatchStrategy, predicate: { $0 == typedVal }) {
                        eval = true
                    } else {
                    }
                case .substring_included_in:
                    if let typedVal = destFieldVal as? String, let needles = constraint.value as? [String],
                       self.handleMultiMatch(destField: typedVal, collection: needles, multiMatchStrat: constraint.collectionMatchStrategy, predicate: { typedVal.contains($0) }) {
                        eval = true
                    } else {
                    }
                case .not_included_in:
                    if let typedVal = destFieldVal as? String, let needles = constraint.value as? [String],
                       !self.handleMultiMatch(destField: typedVal, collection: needles, multiMatchStrat: constraint.collectionMatchStrategy, predicate: { $0 == typedVal }) {
                        eval = true
                    } else if let typedVal = destFieldVal as? Int, let needles = constraint.value as? [Int],
                              !self.handleMultiMatch(destField: typedVal, collection: needles, multiMatchStrat: constraint.collectionMatchStrategy, predicate: { $0 == typedVal }) {
                        eval = true
                    } else if let typedVal = destFieldVal as? Double, let needles = constraint.value as? [Double],
                              !self.handleMultiMatch(destField: typedVal, collection: needles, multiMatchStrat: constraint.collectionMatchStrategy, predicate: { $0 == typedVal }) {
                        eval = true
                    } else if let typedVal = destFieldVal as? Bool, let needles = constraint.value as? [Bool],
                              !self.handleMultiMatch(destField: typedVal, collection: needles, multiMatchStrat: constraint.collectionMatchStrategy, predicate: { $0 == typedVal }) {
                        eval = true
                    } else {
                    }
                case .starts_with:
                    if let typedVal = destFieldVal as? String {
                        if let needles = constraint.value as? [String], self.handleMultiMatch(destField: typedVal, collection: needles, multiMatchStrat: constraint.collectionMatchStrategy, predicate: { typedVal.hasPrefix($0) }) {
                            eval = true
                        } else if let needle = constraint.value as? String, typedVal.hasPrefix(needle) {
                            eval = true
                        }
                    } else {
                    }
                case .ends_with:
                    if let typedVal = destFieldVal as? String {
                        if let needles = constraint.value as? [String],
                            self.handleMultiMatch(destField: typedVal, collection: needles, multiMatchStrat: constraint.collectionMatchStrategy, predicate: { typedVal.hasSuffix($0) }) {
                            eval = true
                        } else if let needle = constraint.value as? String, typedVal.hasSuffix(needle) {
                            eval = true
                        }
                    } else {
                    }
                case .no_field:
                    eval = false
                }
            } else {
                if constraint.operation == .no_field {
                    eval = true
                }
            }
            cache[constraint.hashValue] = eval
            return eval
        }
    }

    public func process(_ event: any EHUEFEvent) async -> EHTransformReturn {

        var curEvent = event
        var mutated = false
        let evalCache = RuleEvaluationCache()
        let tags_from_rules = await rules.compactMapInTasks { rule in
            var ruleHit = false
            var shortCircuit = false
            var evaluations: [Bool] = []
            evaluations.reserveCapacity(rule.constraints.count)

            for constraint in rule.constraints {
                let eval = await evalCache.evaluate(constraint: constraint, event: event)
                evaluations.append(eval)

                switch rule.criteria {
                case .all:
                    if evaluations.allSatisfy({ $0 == true }) {
                        ruleHit = true
                    } else {
                        ruleHit = false
                        shortCircuit = true
                    }
                case .any:
                    if evaluations.contains(true) {
                        ruleHit = true
                        shortCircuit = true
                    }
                case .none:
                    if evaluations.allSatisfy({ $0 == false }) {
                        ruleHit = true
                    } else {
                        ruleHit = false
                        shortCircuit = true
                    }
                case .at_least(let n):
                    if evaluations.count(where: { $0 == true }) >= n {
                        ruleHit = true
                        shortCircuit = true
                    }
                case .no_more_than(let n):
                    if evaluations.count(where: { $0 == true }) < n {
                        ruleHit = true
                    } else {
                        ruleHit = false
                        shortCircuit = true
                    }
                case .exactly(let n):
                    if evaluations.count(where: { $0 == true }) == n {
                        ruleHit = true
                    } else {
                        ruleHit = false
                    }
                }

                if shortCircuit {
                    break
                }
            }

            if ruleHit {
                return rule.tags
            }
            return nil
        }

        if !tags_from_rules.isEmpty {
            curEvent.tags.formUnion(tags_from_rules.flatMap { $0 })
            mutated = true
        }
        return (mutated ? .proceed_mutated : .proceed, [curEvent], nil, nil)
    }

    public func configure() throws {
    }
}
