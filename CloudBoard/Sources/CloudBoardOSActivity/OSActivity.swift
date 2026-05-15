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

import Foundation
import os.activity

// rdar://50046098 (Add Swift support for os_activity_create)
private nonisolated(unsafe) let OS_ACTIVITY_CURRENT: OS_os_activity = unsafeBitCast(
    dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_os_activity_current"),
    to: (any OS_os_activity).self
)
private nonisolated(unsafe) let OS_ACTIVITY_NONE: OS_os_activity = unsafeBitCast(
    dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_os_activity_none"),
    to: (any OS_os_activity).self
)

public struct OSActivity: @unchecked Sendable {
    /// Support flags for OSActivity.
    public struct ActivityFlags: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        /// Creates a new activity and associates it as a child of any provided parent activity.
        public static let `default` = ActivityFlags(rawValue: OS_ACTIVITY_FLAG_DEFAULT.rawValue)

        /// Creates a new activity that is independent of any provided parent activity.
        ///
        /// When you set this flag when creating an activity, the system creates the activity as a new top-level
        /// activity. If you provided a parent activity, the new activity notes this fact, allowing you to see which
        /// activity triggered the new activity without actually relating the activities.
        ///
        /// Don't pass `detached` and `ifNonePresent` at the same time
        public static let detached = ActivityFlags(rawValue: OS_ACTIVITY_FLAG_DETACHED.rawValue)

        /// Creates a new activity only if one is not already present.
        ///
        /// When you include this flag when calling a function that creates an activity, if an activity already exists,
        /// the function returns that activity. Otherwise, the function creates and returns a new activity.
        public static let ifNonePresent = ActivityFlags(rawValue: OS_ACTIVITY_FLAG_IF_NONE_PRESENT.rawValue)
    }

    /// An `os_activity_t` object for the activity
    private let opaqueActivity: OS_os_activity?

    /// Creates an activity.
    /// - Parameters:
    ///   - description: The description must be a constant string within the calling executable or library.
    ///   - flags: The `ActivityFlags` to use when creating the new activity
    ///   - dso: Dynamic State Object pointer
    public init(
        _ description: StaticString,
        flags: ActivityFlags = [],
        parent: OSActivity? = nil,
        dso: UnsafeRawPointer? = #dsohandle
    ) {
        self.opaqueActivity = description.withUTF8Buffer {
            if let dso = UnsafeMutableRawPointer(mutating: dso), let address = $0.baseAddress {
                let str = UnsafeRawPointer(address).assumingMemoryBound(to: Int8.self)
                return _os_activity_create(
                    dso,
                    str,
                    parent?.opaqueActivity ?? OS_ACTIVITY_CURRENT,
                    os_activity_flag_t(rawValue: flags.rawValue)
                )
            } else {
                return nil
            }
        }
    }

    private init(_ activity: OS_os_activity) {
        self.opaqueActivity = activity
    }
}

extension OSActivity {
    /// An activity with no traits; as a parent, it is equivalent to a
    /// detached activity.
    public static var none: OSActivity {
        return OSActivity(OS_ACTIVITY_NONE)
    }

    /// The running activity.
    ///
    /// As a parent, the new activity is linked to the current activity, if one
    /// is present. If no activity is present, it behaves the same as `.none`.
    public static var current: OSActivity {
        let activity = OSActivity(OS_ACTIVITY_CURRENT)
        guard activity.identifier != OSActivity.none.identifier else {
            return .none
        }
        // This activity will never be created, _but_ the handle returned would always point to the right activity
        return OSActivity("current", flags: [.ifNonePresent], parent: activity)
    }
}

extension OSActivity {
    /// Opaque structure created by `Activity.enter()` and restored using
    /// `leave()`.
    public struct Scope {
        fileprivate var state = os_activity_scope_state_s()
        /// Pops activity state to `self`.
        public mutating func leave() {
            os_activity_scope_leave(&self.state)
        }
    }

    public func apply(execute body: @convention(block) () -> Void) {
        os_activity_apply(self.opaqueActivity ?? OS_ACTIVITY_NONE, body)
    }

    /// Executes a function body within the context of the activity.
    public func apply<Return>(execute body: () throws -> Return) rethrows -> Return {
        func runApply(execute work: () throws -> Return, recover: (Error) throws -> Return) rethrows -> Return {
            var result: Return?
            var error: Error?
            self.apply {
                do {
                    result = try work()
                } catch let e {
                    error = e
                }
            }
            if let e = error {
                return try recover(e)
            } else {
                return result!
            }
        }
        return try runApply(execute: body, recover: { throw $0 })
    }

    /// Executes a function body within the context of the activity.
    public func apply<Return>(execute body: () async throws -> Return) async rethrows -> Return {
        var state = self.enter()
        defer {
            state.leave()
        }
        return try await body()
    }

    /// Switches the current activity, saving the existing execution context.
    ///
    /// let scope = OSActivity("my new activity").enter()
    /// defer { scope.leave() }
    /// ... do some work ...
    ///
    public func enter() -> Scope {
        precondition(self.identifier != OSActivity.none.identifier, "Invalid 'none' activity")
        var scope = Scope()
        os_activity_scope_enter(self.opaqueActivity ?? OS_ACTIVITY_NONE, &scope.state)
        return scope
    }
}

@available(*, unavailable)
extension OSActivity.Scope: Sendable {}

extension OSActivity {
    public var identifier: UInt64 {
        // rdar://94845610 (os_activity_get_identifier returns different identifiers to those used by the OS logging
        // system)
        os_activity_get_identifier(self.opaqueActivity ?? OS_ACTIVITY_NONE, nil) & ~(0xFF << 56)
    }

    public var parentIdentifier: UInt64 {
        let parentIdentifierPointer = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        _ = os_activity_get_identifier(self.opaqueActivity ?? OS_ACTIVITY_NONE, parentIdentifierPointer)
        return parentIdentifierPointer.pointee & ~(0xFF << 56)
    }
}

extension OSActivity: Equatable {
    public static func == (lhs: OSActivity, rhs: OSActivity) -> Bool {
        lhs.opaqueActivity?.isEqual(rhs.opaqueActivity) ?? false
    }
}
