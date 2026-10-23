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

//  XPCArray.swift
//  XPC-swiftoverlay
//
//  Copyright © 2021 Apple. All rights reserved.

import XPC

internal struct XPCArray {
    /// Create an `XPCArray` wrapping a libxpc array object.
    ///
    /// - Parameters:
    ///  - value: The libxpc array to wrap.
    ///
    ///  - Precondition: `value` must be of type `XPC_TYPE_ARRAY`.
    internal init(_ value: xpc_object_t) {
        let type = xpc_get_type(value)
        precondition(type == XPC_TYPE_ARRAY)
        self._value = value
    }

    /// Create a new empty `XPCArray`.
    internal init() {
        if #available(macOS 11, iOS 14.0, *) {
            self._value = xpc_array_create_empty()
        } else {
            self._value = xpc_array_create(nil, 0)
        }
    }

    /// The underlying libxpc array backing this object.
    private var _value: xpc_object_t

    /// Executes `closure`, passing in this `XPCArray`'s underlying libxpc array
    /// and returning the value returned by `closure`.
    ///
    /// - Parameters:
    ///  - closure: The closure to execute with the array.
    ///
    /// - Returns: Whatever is returned by `closure`.
    ///
    /// - Throws: Whatever is thrown by `closure`.
    ///
    /// This function is "unsafe" because it is possible to perform operations
    /// on the array that will cause it to effectively cease to be wrapped by
    /// this `XPCArray` instance.
    internal func withUnsafeUnderlyingArray<ReturnType>(_ closure: (xpc_object_t) throws -> ReturnType) rethrows
    -> ReturnType {
        try closure(self._value)
    }
}

// MARK: - Integer Subscripts

extension XPCArray {
    /// Get a value in this array as an integer.
    ///
    /// - Parameters:
    ///   - index: The index at which to get the integer.
    ///   - type: The expected type of the resulting value.
    ///
    /// - Returns: An integer of type `T` or `nil` if no such integer was found
    ///		or if a conversion failed.
    ///
    /// When getting an existing value, this subscript will return any numeric
    /// value stored in `self` so long as it can be converted to `T` using
    /// `init(exactly:)`.
    ///
    /// - Note: `Bool` is not a numeric type in Swift and so is not supported by
    ///		this subscript.
    internal subscript<T: BinaryInteger>(_ index: Int, as type: T.Type = T.self) -> T? {
        guard let object = self[index, as: xpc_object_t.self] else {
            return nil
        }

        let obj_type = xpc_get_type(object)
        switch obj_type {
        case XPC_TYPE_INT64:
            return type.init(exactly: xpc_int64_get_value(object))
        case XPC_TYPE_UINT64:
            return type.init(exactly: xpc_uint64_get_value(object))
        case XPC_TYPE_DOUBLE:
            return type.init(exactly: xpc_double_get_value(object))
        default:
            return nil
        }
    }

    /// Get or set a value in this array as a signed integer.
    ///
    /// - Parameters:
    ///	  - index: The index at which to get or set the integer.
    ///
    /// - Returns: An integer of type `T` or `nil` if no such integer was found
    ///		or if a conversion failed.
    ///
    /// When getting an existing value, this subscript will return any numeric
    /// value stored in `self` so long as it can be converted to `T` using
    /// `init(exactly:)`.
    ///
    /// When setting a new value, this subscript will convert the new value to
    /// `Int64` using `init(exactly:)`. If the new value cannot be exactly
    /// represented by `Int64`, the value is instead set to `nil`.
    ///
    /// If you want different behavior such as rounding or clamping, consider
    /// using the appropriate cast to `Int64` before invoking this subscript so
    /// that the transformation you want is applied.
    ///
    /// - Note: `Bool` is not a numeric type in Swift and so is not supported by
    ///		this subscript.
    internal subscript<T: SignedInteger>(_ index: Int) -> T? {
        get {
            self[index, as: T.self]
        }
        set {
            self[index] = newValue.flatMap(Int64.init(exactly:)).map(xpc_int64_create)
        }
    }

    /// Get or set a value in this array as an unsigned integer.
    ///
    /// - Parameters:
    ///	  - index: The index at which to get or set the integer.
    ///
    /// - Returns: An integer of type `T` or `nil` if no such integer was found
    ///		or if a conversion failed.
    ///
    /// When getting an existing value, this subscript will return any numeric
    /// value stored in `self` so long as it can be converted to `T` using
    /// `init(exactly:)`.
    ///
    /// When setting a new value, this subscript will convert the new value to
    /// `UInt64` using `init(exactly:)`. If the new value cannot be exactly
    /// represented by `UInt64`, the value is instead set to `nil`.
    ///
    /// If you want different behavior such as rounding or clamping, consider
    /// using the appropriate cast to `UInt64` before invoking this subscript so
    /// that the transformation you want is applied.
    ///
    /// - Note: `Bool` is not a numeric type in Swift and so is not supported by
    ///		this subscript.
    internal subscript<T: UnsignedInteger>(_ index: Int) -> T? {
        get {
            self[index, as: T.self]
        }
        set {
            self[index] = newValue.flatMap(UInt64.init(exactly:)).map(xpc_uint64_create)
        }
    }
}

// MARK: - Floating-Point Subscripts

extension XPCArray {
    /// Get a value in this array as a floating-point number.
    ///
    /// - Parameters:
    ///	  - index: The index at which to get the floating-point number.
    ///	  - type: The expected type of the resulting value.
    ///
    /// - Returns: A number of type `T` or `nil` if no such number was found or
    ///		if a conversion failed.
    ///
    /// When getting an existing value, this subscript will return any numeric
    /// value stored in `self` so long as it can be converted to `T` using
    /// `init(exactly:)`.
    ///
    /// - Note: `Bool` is not a numeric type in Swift and so is not supported by
    ///		this subscript.
    internal subscript<T: BinaryFloatingPoint>(_ index: Int, as type: T.Type = T.self) -> T? {
        guard let object = self[index, as: xpc_object_t.self] else {
            return nil
        }

        let obj_type = xpc_get_type(object)
        switch obj_type {
        case XPC_TYPE_INT64:
            return type.init(exactly: xpc_int64_get_value(object))
        case XPC_TYPE_UINT64:
            return type.init(exactly: xpc_uint64_get_value(object))
        case XPC_TYPE_DOUBLE:
            return type.init(exactly: xpc_double_get_value(object))
        default:
            return nil
        }
    }

    /// Get or set a value in this array as a floating-point number.
    ///
    /// - Parameters:
    ///	  - index: The index at which to get or set the floating-point number.
    ///
    /// - Returns: A number of type `T` or `nil` if no such number was found or
    ///		if a conversion failed.
    ///
    /// When getting an existing value, this subscript will return any numeric
    /// value stored in `self` so long as it can be converted to `T` using
    /// `init(exactly:)`.
    ///
    /// When setting a new value, this subscript will lossily convert the new
    /// value to `Double`. Floating-point conversions almost always introduce
    /// some amount of error, so requiring exact conversions would not be
    /// pragmatic.
    ///
    /// If you want different behavior such as rounding or clamping, consider
    /// using the appropriate cast to `Double` before invoking this subscript so
    /// that the transformation you want is applied.
    ///
    /// - Note: `Bool` is not a numeric type in Swift and so is not supported by
    ///		this subscript.
    internal subscript<T: BinaryFloatingPoint>(_ index: Int) -> T? {
        get {
            self[index, as: T.self]
        }
        set {
            self[index] = newValue.map { newValue in
                xpc_double_create(Double(newValue))
            }
        }
    }

    /// Get a value in this array as a floating-point number.
    ///
    /// - Parameters:
    ///	  - index: The index at which to get the floating-point number.
    ///	  - type: The expected type of the resulting value.
    ///	  - defaultValue: The value to produce if no floating-point number is
    ///		  available at `index` or if a conversion failed.
    ///
    /// - Returns: A floating-point value of type `T`, possibly `defaultValue`.
    ///
    /// - Note: `Bool` is not a numeric type in Swift and so is not supported by
    ///		this subscript.
    internal subscript<T: BinaryFloatingPoint>(
        _ index: Int,
        as type: T.Type = T.self,
        default defaultValue: @autoclosure () -> T
    ) -> T {
        self[index, as: type] ?? defaultValue()
    }
}

// MARK: - Boolean Subscripts

extension XPCArray {
    /// Get a value in this array as a boolean.
    ///
    /// - Parameters:
    ///	  - index: The index at which to get the boolean.
    ///	  - type: The expected type of the resulting value.
    ///
    /// - Returns: A boolean value or `nil` if no such value was found.
    internal subscript(_ index: Int, as _: Bool.Type = Bool.self) -> Bool? {
        guard let object = self[index, as: XPC_TYPE_BOOL] else {
            return nil
        }

        return xpc_bool_get_value(object)
    }

    /// Get or set a value in this array as a boolean.
    ///
    /// - Parameters:
    ///	  - index: The index at which to get or set the boolean.
    ///
    /// - Returns: A boolean value or `nil` if no such value was found.
    internal subscript(_ index: Int) -> Bool? {
        get {
            self[index, as: Bool.self]
        }
        set {
            self[index] = newValue.map(xpc_bool_create)
        }
    }

    /// Get a value in this array as a boolean.
    ///
    /// - Parameters:
    ///	  - index: The intex at which to get the boolean.
    ///	  - type: The expected type of the resulting value.
    ///	  - defaultValue: The value to produce if no boolean is available at
    ///		  `index`.
    ///
    /// - Returns: A boolean value, possibly `defaultValue`.
    internal subscript(
        _ index: Int,
        as type: Bool.Type = Bool.self,
        default defaultValue: @autoclosure () -> Bool
    ) -> Bool {
        self[index, as: type] ?? defaultValue()
    }
}

// MARK: - XPCDictionary Subscripts

extension XPCArray {
    /// Get a value in this array as an XPC dictionary.
    ///
    /// - Parameters:
    ///	  - index: The index at which to get the dictionary.
    ///	  - type: The expected type of the resulting value.
    ///
    /// - Returns: A dictionary or `nil` if no such value was found.
    internal subscript(_ index: Int, as _: XPCDictionary.Type = XPCDictionary.self) -> XPCDictionary? {
        guard let dict = xpc_array_get_dictionary(self._value, index) else {
            return nil
        }

        return XPCDictionary(dict)
    }

    /// Get or set a value in this array as an XPC dictionary.
    ///
    /// - Parameters:
    ///	  - index: The index at which to get or set the dictionary.
    ///
    /// - Returns: A dictionary or `nil` if no such value was found.
    internal subscript(_ index: Int) -> XPCDictionary? {
        get {
            self[index, as: XPCDictionary.self]
        }
        set {
            xpc_array_set_value(self._value, index, newValue!._value)
        }
    }
}

// MARK: - xpc_object_t Subscripts

extension XPCArray {
    /// Get a value in this array as an `xpc_object_t`.
    ///
    /// - Parameters:
    ///	  - index: The index at which to get the object.
    ///	  - type: The expected type of the resulting value.
    ///
    /// - Returns: A previously-set object. If no object was previously set at
    ///		`index`, or if an object was assigned but its type is not `type`,
    ///		returns `nil`.
    internal subscript(_ index: Int, as _: xpc_object_t.Type = xpc_object_t.self) -> xpc_object_t? {
        xpc_array_get_value(self._value, index)
    }

    /// Get a value in this array as an `xpc_object_t`.
    ///
    /// - Parameters:
    ///	  - index: The index at which to get the object.
    ///	  - type: The expected XPC type of the resulting value.
    ///
    /// - Returns: A previously-assigned object. If no object was previously
    ///		assigned at `index`, or if an object was assigned but its type is
    ///		not `type`, returns `nil`.
    internal subscript(_ index: Int, as type: xpc_type_t) -> xpc_object_t? {
        guard let result = self[index, as: xpc_object_t.self], xpc_get_type(result) == type else {
            return nil
        }

        return result
    }

    /// Get or set a value in this array as an `xpc_object_t`.
    ///
    /// - Parameters:
    ///	  - index: The index at which to get or set the object.
    ///
    /// - Returns: A previously-set object. If no object was previously assigned
    ///		at `index`, or if an object was assigned but its type is not `type`,
    ///		returns `nil`.
    internal subscript(_ index: Int) -> xpc_object_t? {
        get {
            self[index, as: xpc_object_t.self]
        }
        set {
            guard let val = newValue else {
                return
            }

            let type = xpc_get_type(val)
            switch type {
            case XPC_TYPE_CONNECTION:
                xpc_array_set_connection(self._value, index, val)

            default:
                xpc_array_set_value(self._value, index, val)
            }
        }
    }
}

// MARK: - String Subscripts

extension XPCArray {
    /// Get a `String` value in this array.
    ///
    /// - Parameters:
    ///	  - index: The index at which to get the string.
    ///	  - type: The expected type of the resulting value.
    ///
    /// - Returns: A previously-set string value. If no string was previously
    ///		set for `key`, returns `nil`.
    ///
    /// The underlying C string is assumed to be encoded as UTF-8.
    internal subscript(_ index: Int, as _: String.Type = String.self) -> String? {
        if let cString = xpc_array_get_string(self._value, index) {
            return String(cString: cString)
        }

        return nil
    }

    /// Get or set a `String` value in this array.
    ///
    /// - Parameters:
    ///	  - index: The index at which to get or set the string.
    ///	  - type: The expected type of the resulting value.
    ///
    /// - Returns: A previously-set string value. If no string was previously
    ///		set for `key`, returns `nil`.
    ///
    /// When setting a `String` value, the string's bytes are always copied.
    ///
    /// The underlying C string is assumed to be encoded as UTF-8.
    internal subscript(_ index: Int) -> String? {
        get {
            self[index, as: String.self]
        }
        set {
            if let stringValue = newValue {
                xpc_array_set_string(self._value, index, stringValue)
            }
        }
    }
}

// MARK: - Other Members

extension XPCArray {
    internal func copy(into destination: XPCArray) {
        xpc_array_apply(self._value) { index, value in
            xpc_array_set_value(destination._value, index, value)
            return true
        }
    }

    /// Whether or not this array contains any elements.
    ///
    /// - Complexity: O(1)
    internal var isEmpty: Bool {
        xpc_array_get_count(self._value) == 0
    }

    /// The number of elements in this array.
    ///
    /// - Complexity: O(1)
    internal var count: Int {
        xpc_array_get_count(self._value)
    }

    /// Enumerate the contents of this array.
    ///
    /// - Parameters:
    ///	  - body: The closure to invoke for each index-value pair in `self`.
    ///
    /// - Returns: Whatever is returned by `closure`.
    ///
    /// - Throws: Whatever is thrown by `closure`. Enumeration stops if an error
    ///		is thrown.
    ///
    /// This function walks the contents of `self`, yielding each key and value
    /// to `body`.
    ///
    /// Because XPC arrays store all values as instances of
    /// `xpc_object_t`, all values are enumerated by this function as instances
    /// thereof even if they were originally set with other types.
    ///
    /// - Complexity: O(*n*) over the array's `count`.
    internal func forEach(_ body: (_ index: Int, _ value: xpc_object_t) throws -> Void) rethrows /* (unsafe) */ {
        // This use of `withoutActuallyEscaping(_:)` tricks the compiler into
        // thinking that only errors immediately thrown by `body` are thrown,
        // and that therefore rethrows' invariants are satisfied. Strictly
        // speaking this isn't provable because we catch and rethrow the error
        // in the body of this function (in order to interop with libxpc which
        // is throws-unaware.) I spoke to Slava Pestov and he says this trick is
        // safe for Sunriver. In SunriverE new syntax, rethrows(unsafe), will be
        // introduced to formalize these sorts of tricks.
        try withoutActuallyEscaping(body) { body in
            var thrownError: Error?
            xpc_array_apply(self._value) { index, value in
                do {
                    try body(index, value)
                    return true
                } catch {
                    thrownError = error
                    return false
                }
            }
            if let thrownError {
                throw thrownError
            }
        }
    }

    /// An index-value pair from an XPC array.
    ///
    /// Because XPC arrays store all values as instances of `xpc_object_t`, all
    /// values are exposed as instances thereof even if they were originally set
    /// with other types.
    internal typealias IndexValuePair = (index: Int, value: xpc_object_t)

    /// Enumerate the contents of this array.
    ///
    /// - Parameters:
    ///	  - body: The closure to invoke for each index-value pair in `self`.
    ///
    /// - Returns: Whatever is returned by `closure`.
    ///
    /// - Throws: Whatever is thrown by `closure`. Enumeration stops if an error
    ///		is thrown.
    ///
    /// This function walks the contents of `self`, yielding each index and
    /// value to `body` as a tuple.
    ///
    /// Because XPC arrays store all values as instances of `xpc_object_t`,
    /// all values are enumerated by this function as instances thereof even if
    /// they were originally set with other types.
    ///
    /// - Complexity: O(*n*) over the array's `count`.
    internal func forEach(_ body: (IndexValuePair) throws -> Void) rethrows {
        try self.forEach { index, value in
            try body((index, value))
        }
    }

    /// Returns an array containing the results of mapping the given closure
    /// over the array's index-value pairs.
    ///
    /// - Parameters:
    ///	  - transform: A mapping closure. `transform` accepts an index-value
    ///		  pair of this array as its parameter and returns a transformed
    ///		  value of the same or of a different type.
    ///
    /// - Returns: An array containing the transformed index-value pairs of this
    ///		array.
    ///
    /// - Throws: Whatever is thrown by `closure`. Enumeration stops if an error
    ///		is thrown.
    ///
    /// - Complexity: O(*n*) over the array's `count`.
    internal func map<ReturnType>(_ transform: (IndexValuePair) throws -> ReturnType) rethrows -> [ReturnType] {
        var result = [ReturnType]()
        result.reserveCapacity(self.count)
        try self.forEach { try result.append(transform($0)) }
        return result
    }
}

// MARK: - Equatable

extension XPCArray: Equatable {
    internal static func == (lhs: XPCArray, rhs: XPCArray) -> Bool {
        xpc_equal(lhs._value, rhs._value)
    }
}

// MARK: - Hashable

extension XPCArray: Hashable {
    internal func hash(into hasher: inout Hasher) {
        hasher.combine(xpc_hash(self._value))
    }
}

// MARK: - CustomDebugStringConvertible

extension XPCArray: CustomDebugStringConvertible {
    internal var debugDescription: String {
        let cString = xpc_copy_description(self._value)
        defer {
            free(cString)
        }
        return String(cString: cString)
    }
}
