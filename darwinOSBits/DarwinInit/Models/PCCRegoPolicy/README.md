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

# PCCRegoPolicy README

This directory contains Rego-based policy validation for Private Cloud Compute configurations.

## Policy Watcher Script

The `policy_watcher.sh` script automatically rebuilds OPA policy bundles when source policies change. It's integrated into the Xcode build system.

### Usage

```bash
./policy_watcher.sh              # Check for changes and rebuild if needed
./policy_watcher.sh --check      # Check and emit Xcode-compatible errors (for build system)
./policy_watcher.sh --force      # Force rebuild regardless of changes (for developers)
./policy_watcher.sh --help       # Show usage information
```

### How It Works

1. Monitors `policy/` directory for changes using file hashing
2. When changes detected, rebuilds the OPA bundle using `opa build`
3. Updates bundle contents while preserving Xcode project file references
4. Caches hash to avoid unnecessary rebuilds

## Bundle Structure

The generated bundle should have this structure:

```
DarwinInit/Models/PCCRegoPolicy/bundle/
├── .manifest
├── data.json
├── plan.json
└── policy/
    ├── carry/
    │   └── carry.rego
    ├── customer/
    │   └── customer.rego
    ├── customerProxy/
    │   └── customerProxy.rego
    └── main/
        ├── common.rego
        └── main.rego
```

## Dependencies

For manual rebuilds (`--force`), you need:
- OPA v1.4.2
- Standard Unix tools (shasum, tar)

The build system (`--check` mode) doesn't require these tools.

---

## Rego Policy Authoring Guide

This section provides guidance on the Rego language as used in this project, the conventions followed by existing policies, and how to add new rules.

### Rego Language Basics

[Rego](https://www.openpolicyagent.org/docs/latest/policy-language/) is a declarative query language used by Open Policy Agent (OPA). It is inspired by Datalog and has many behaviors that differ from imperative languages like Swift or Python.

#### Core Concepts

- **Declarative, not imperative.** Rules describe *what* constitutes a violation. The OPA engine evaluates all rules and collects results.
- **`import rego.v1`** is present in every file. This opts into OPA v1 syntax, which requires `contains` and `if` keywords for rules (instead of the legacy implicit form).
- **Every statement in a rule body is an implicit AND.** If any statement is undefined or false, the entire rule does not fire. There is no `&&` operator — just put statements on separate lines.
- **Logical OR = multiple rule definitions with the same name.** Each definition is additive (their results are unioned for sets/objects). OPA evaluates all matching definitions.

#### Operators: `:=` vs `==` vs `=`

- `:=` — **Local assignment.** Creates a new local variable. The variable must not already exist in scope, and cannot be reassigned (`x := 1; x := 2` is a compile error). Variables must be assigned before use (`x != 100; x := 1` is also a compile error).
- `==` — **Comparison.** Both sides must already be bound. Returns true/false.
- `=` — **Unification.** Combines assignment and comparison: OPA finds variable bindings that make both sides equal. Useful but less explicit; prefer `:=` and `==` for clarity.

#### Undefined (not false)

The single most important gotcha: **unmatched rules produce `undefined`, not `false`**.

- If a rule body doesn't match, the rule's value is `undefined` — it is absent from the output, not `false`.
- Referencing an undefined value yields `undefined`, not an error. This means typos in field names silently produce no results instead of failing.
- `not` applied to `undefined` yields `true`. `not undefined_rule` is true because the rule is absent.
- Comparisons with `undefined` are also `undefined`: if `v` is undefined, `v != true` is *not* true — it's undefined too.
- Use `default` to provide a fallback value when undefined is undesirable: `default allow := false`.

#### Variables and Scoping

- Variables are **local to the rule body** where they are assigned with `:=`. They shadow global rules of the same name.
- Use **`some`** to explicitly declare iteration variables. Without `some`, a variable name like `i` could accidentally capture a global rule named `i` in the same package. Always use `some` for iteration.
- **`_` (underscore)** is a special anonymous variable. Each `_` is a fresh variable — two underscores in the same expression are NOT the same variable. Use when you don't need the value.
- **Destructuring** works: `[_, _, city, country] := address` unpacks an array.

#### Existential vs Universal Quantification

Variables are **existentially quantified** by default — rule bodies express "there exists" (FOR ANY), not "for all" (FOR ALL).

A common mistake:
```rego
# WRONG: true if ANY app is not a bitcoin-miner (almost always true)
no_miners if {
    some app in apps
    app.name != "bitcoin-miner"
}
```

For "for all", use one of:
- **`every`**: `every app in apps { app.name != "bitcoin-miner" }` — the most readable option. Note: `every` over an empty domain is `true`. Negating `every` is forbidden; use `some` + `not` instead.
- **Negated helper**: define `any_miners if { some app in apps; app.name == "bitcoin-miner" }` then use `not any_miners`.
- **Comprehension + count**: `count({app | some app in apps; app.name == "bitcoin-miner"}) == 0`.

#### Sets vs Objects

- `{x, y}` is a **set**. `{x: y}` is an **object**.
- **`{}` is an empty object, not an empty set.** Use `set()` for an empty set. `count({})` returns 0 but `{} == set()` is false.

#### Membership with `in`

- `x in collection` checks **values** for arrays, sets, and objects. For objects, it checks values, not keys: `"foo" in {"foo": 1}` is **false** (1 is the value, "foo" is a key).
- Two-argument form for key/index checking: `"foo", _ in {"foo": 1}` is true.
- `in` always returns true/false, even on non-collections (returns false).
- In list contexts (inside `[...]`, `{...}`, or function args), the two-argument form needs parentheses: `[(0, 2 in [2])]`.

#### Rule Types

- **Complete rules** (`x := <value> if { ... }`) — produce a single value. If multiple definitions match with different values, OPA returns a conflict error.
- **Partial set rules** (`deny contains x if { ... }`) — each matching definition adds elements to a set. Multiple definitions with the same name are unioned.
- **Partial object rules** (`map[key] := value if { ... }`) — each matching definition adds key-value pairs. Duplicate keys with different values cause a conflict error.
- **Functions** (`f(arg) := result if { ... }`) — must resolve to exactly one output value. Cannot be overloaded by arity (different argument counts = compile error). Can be defined incrementally (different argument patterns).

#### Built-in Function Errors

By default, built-in functions that encounter runtime errors evaluate to **`undefined`** and do not halt policy evaluation. This means malformed input to `sprintf`, `json.unmarshal`, etc. silently produces no result rather than raising an error.

#### Metadata Positioning

The `# METADATA` comment block **must** start at column 1 in the file. It must be immediately above the rule head with no blank lines between the metadata and the rule. If there is a blank line, OPA treats the metadata block as finished and does not associate it with the rule.

#### The `with` Keyword

`with` allows replacing `input`, `data`, or built-in function values for a single expression. It only affects the attached expression — subsequent expressions see unmodified values. Useful for testing: `allow with input as {"user": "alice"}`.

### Policy Organization

#### Package Structure

Each `.rego` file declares a package that corresponds to its directory path under `policy/`:

| File | Package |
|---|---|
| `policy/main/main.rego` | `package policy.main` |
| `policy/main/common.rego` | `package policy.common` |
| `policy/customer/customer.rego` | `package policy.customer` |
| `policy/customerProxy/customerProxy.rego` | `package policy.customerProxy` |
| `policy/carry/carry.rego` | `package policy.carry` |

Multiple files can share the same package (e.g., `main.rego` and `common.rego` use `policy.main` and `policy.common` respectively, both under the `main/` directory).

#### Environment-Based Policy Sets

The system uses an **environment** concept to select which policy set to evaluate:

- **`customer`** -- the default and most restrictive environment (production customer workloads)
- **`customerProxy`** -- similar to `customer` but with proxy-specific requirements (e.g., `com.apple.cloudboard.isProxy` must be true)
- **`carry`** -- a relaxed environment that permits SSH access, user creation, and additional preferences

The environment is determined by `input["darwin-init"][0]["config_security_policy"]["policy"]`. The main entrypoint in `main.rego` dynamically dispatches to the appropriate environment's `deny` rules via `data.policy[environment].deny`.

#### File Roles

- **`main/main.rego`** -- Entrypoint. Defines `validate` (the OPA entrypoint), collects issues from environment-specific deny rules, separates errors from warnings based on version, and validates meta-level constraints (environment name, version conflicts).
- **`main/common.rego`** -- Shared helper functions imported by all environment policies: `has_key`, `paths`, `path_in_allowed`, and internal path-matching helpers.
- **`customer/customer.rego`**, **`customerProxy/customerProxy.rego`**, **`carry/carry.rego`** -- Environment-specific policy rules. Each defines a `deny` rule set and a `net_secure_config` merged value.

### Imports

Environment policy files import helpers from the common package (`has_key`, `paths`, `path_in_allowed`) via `import data.policy.common.<name>`. Cross-environment data access uses `data.policy[environment].deny` and `data.policy[environment].net_secure_config`.

### Common Helper Functions (common.rego)

- **`has_key(obj, key)`** -- Returns true if `obj` contains `key`. Use to check key presence without accessing the value.
- **`paths(x)`** -- Walks an object tree and returns a set of slash-separated path strings (array indices become string segments). Used by the allowlist rule to enumerate every path in a config.
- **`path_in_allowed(path, allowed_paths)`** -- Checks whether a path matches any pattern in an allowed set. Supports exact match, single-segment wildcard (`*`), multi-segment wildcard (`/**`), and implicit parent matching (a parent of an allowed pattern is also implicitly allowed).

### Rule Structure

Every deny rule follows a consistent pattern: a `# METADATA` annotation block (with `title`, `version`, and `key` fields) immediately above a `deny contains issue if { ... }` rule body. The rule body selects a config from the input array, checks a violation condition, and produces an issue object with `index`, `key`, `message`, and `version` fields. The `version` field controls error vs. warning classification (see below). See the existing rules in the environment files for examples.

Key structural patterns used across the policies:

- **Allowlist path validation** -- Each environment defines a set of allowed config paths (with `*` and `/**` wildcards). Any input path not matching the allowlist is denied.
- **Config-0-only rules** -- Some settings may only appear in config index 0. This is enforced with a pair of rules: one validates the value at index 0, the other denies the key at index > 0.
- **Secure config merging** -- Entries from `secure_config` across all configs are gathered, grouped by key, checked for conflicts, and merged into `net_secure_config`. The merged result is then validated (e.g., crash redaction enabled, log filtering enforced).
- **Preferences allowlisting** -- Two-tier validation: first by application ID, then by per-application key allowlist.

### Version-Based Error vs. Warning Classification

The `version` field in each rule's metadata is central to the error/warning system in `main.rego`:

- **`min_enforced_version`** (currently `9`) is the baseline. The actual enforced version can be overridden by the input.
- Issues with `version <= enforced_version` are **errors** (cause `is_valid` to be false).
- Issues with `version > enforced_version` are **warnings** (reported but do not block validation).

This mechanism allows gradual policy rollout: a new rule can be introduced with a version higher than the current enforced version. It will appear as a warning until the enforced version is bumped to include it.

### How to Add a New Policy Rule

1. **Determine the environment(s)** -- `customer`, `customerProxy`, `carry`, or all three. Rules must be added to each environment file individually.
2. **Choose the version number** -- Use `<= min_enforced_version` (currently `9`) to enforce immediately, or `>` to introduce as a warning first.
3. **Write the rule** -- Follow the deny rule structure used by existing rules in the target environment file. Always include the `# METADATA` annotation block with `version` and `key` fields.
4. **Update the path allowlist** -- If your rule references a config path not already in the environment's `allowed_paths` set, add it. Otherwise the allowlist rule will deny the path before your rule fires.
5. **Rebuild the bundle** -- Run `./policy_watcher.sh --force` to rebuild the OPA bundle. Commit the updated `bundle/` alongside the policy source changes.
6. **Test the rule** -- See the Testing section below.

### Differences Between Environments

The three environments share many rules but diverge in important ways:

| Aspect | customer | customerProxy | carry |
|---|---|---|---|
| SSH daemon | Denied | Denied | Allowed |
| SSH password auth | Denied | Denied | Denied |
| User creation | Not allowed | Not allowed | Allowed (with restrictions) |
| `cloudboard.isProxy` | Must be false/unset | Must be true | Not checked |
| Logging policy path | customer path only | customer path only | customer or carry path |
| Plaintext passwords | Not in allowlist | Not in allowlist | In allowlist but denied by rule |
| SSH authorized keys | Not in allowlist | Not in allowlist | In allowlist but denied by rule |
| `com.apple.security` prefs | Not in allowlist | Not in allowlist | Allowed (key-restricted) |
| `log.persist` | Must be false | Must be false | Not checked |

When adding rules, carefully consider which environments need the rule and whether the allowlist differences affect your rule.

### Testing Policies

#### Running OPA Locally

With OPA installed, evaluate policies against test input from the repository root:

```bash
opa eval -b DarwinInit/Models/PCCRegoPolicy/policy -i test_input.json 'data.policy.main.validate'
```

Test input JSON must have a top-level `darwin-init` key containing an array of config objects (with `config_security_policy`, `log`, `secure_config`, etc.) and an optional `meta` object. See the existing environment `.rego` files for the expected input shape.

To test a single environment's deny rules in isolation, replace the query with e.g. `data.policy.customer.deny`. Use `--format pretty` for readable output.

#### Automated Tests (Swift)

`DarwinInitTests/Interfaces/PCCRegoValidatorTests.swift` exercises the policies through the `PCCRegoValidator` Swift interface. When adding new Rego rules, add test cases verifying: (1) valid configs pass, (2) violating configs produce the expected error key, and (3) version-gated rules appear as warnings when below the enforced version.

```bash
xcodebuild test -scheme DarwinInit -destination 'platform=macOS' \
  -only-testing:DarwinInitTests/PCCRegoValidatorTests
```

#### Debugging Tips

- Ensure the `# METADATA` block is immediately above the rule with no blank lines — OPA associates metadata with the next rule it encounters.
- If a rule is not firing, check whether the path is in the allowlist first — the allowlist deny rule may be masking your violation.
- If a rule appears as a warning instead of an error (or vice versa), check its `version` against `min_enforced_version` in `main.rego`.
- If a rule silently produces no results, suspect **undefined propagation** — a typo in a field name (e.g., `config.lgo` instead of `config.log`) returns undefined rather than an error, causing the entire rule body to silently not match.
- Remember that `!=` against an undefined value is itself undefined, not true. To check "field is absent or not equal to X", use `not config.field == X` (which is true when `config.field` is undefined).
