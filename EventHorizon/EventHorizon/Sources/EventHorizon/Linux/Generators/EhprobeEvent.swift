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

#if os(Linux)
import Cehprobe
import Foundation

public enum EHProbeParameter: Sendable {
    case none
    case u32(UInt32)
    case u64(UInt64)
    case s32(Int32)
    case s64(Int64)
    case string(String)
    case bytebuf(Data)

    init(from param: ehprobe_param_t) {
        switch param.type {
        case EHPROBE_PARAM_U32:
            self = .u32(param.value.u32)
        case EHPROBE_PARAM_U64:
            self = .u64(param.value.u64)
        case EHPROBE_PARAM_S32:
            self = .s32(param.value.s32)
        case EHPROBE_PARAM_S64:
            self = .s64(param.value.s64)
        case EHPROBE_PARAM_STRING:
            if let str = param.value.str {
                self = .string(String(cString: str))
            } else {
                self = .string("")
            }
        case EHPROBE_PARAM_BYTEBUF:
            if let bytebuf = param.value.bytebuf, param.length > 0 {
                self = .bytebuf(Data(bytes: bytebuf, count: Int(param.length)))
            } else {
                self = .bytebuf(Data())
            }
        default:
            self = .none
        }
    }


    public var asUInt64: UInt64 {
        switch self {
        case .u32(let v): return UInt64(v)
        case .u64(let v): return v
        case .s32(let v): return UInt64(v)
        case .s64(let v): return UInt64(v)
        default: return 0
        }
    }

    public var asUInt32: UInt32 {
        switch self {
        case .u32(let v): return v
        case .u64(let v): return UInt32(v)
        case .s32(let v): return UInt32(v)
        case .s64(let v): return UInt32(v)
        default: return 0
        }
    }

    public var asInt64: Int64 {
        switch self {
        case .u32(let v): return Int64(v)
        case .u64(let v): return Int64(v)
        case .s32(let v): return Int64(v)
        case .s64(let v): return v
        default: return 0
        }
    }

    public var asInt32: Int32 {
        switch self {
        case .u32(let v): return Int32(v)
        case .u64(let v): return Int32(v)
        case .s32(let v): return v
        case .s64(let v): return Int32(v)
        default: return 0
        }
    }

    public var asUInt8: UInt8 {
        switch self {
        case .u32(let v): return UInt8(v & 0xFF)
        case .u64(let v): return UInt8(v & 0xFF)
        case .s32(let v): return UInt8(v & 0xFF)
        case .s64(let v): return UInt8(v & 0xFF)
        default: return 0
        }
    }

    public var asBool: Bool {
        return asUInt8 != 0
    }

    public var asString: String {
        switch self {
        case .string(let v):
            return v
        case .u32(let v):
            return String(v)
        case .u64(let v):
            return String(v)
        case .s32(let v):
            return String(v)
        case .s64(let v):
            return String(v)
        case .bytebuf(let data):
            return String(data: data, encoding: .utf8) ?? ""
        case .none:
            return ""
        }
    }

    public var asData: Data {
        switch self {
        case .bytebuf(let v): return v
        default: return Data()
        }
    }

    public var asHexString: String {
        switch self {
        case .bytebuf(let data):
            return data.map { String(format: "%02x", $0) }.joined()
        default:
            return ""
        }
    }

    public var asMultiString: [String] {
        switch self {
        case .bytebuf(let data):
            guard !data.isEmpty else {
                return []
            }

            var result: [String] = []
            var currentStart = 0

            for i in 0..<data.count where data[i] == 0 {
                if i > currentStart {
                    let stringData = data[currentStart..<i]
                    if let str = String(data: stringData, encoding: .utf8), !str.isEmpty {
                        result.append(str)
                    }
                }
                currentStart = i + 1
            }

            return result
        default:
            return []
        }
    }
}

public struct EHProbeEvent: Sendable {
    public let timestampNs: UInt64

    public let pid: UInt32

    public let eventType: ehprobe_event_type_t

    public let parameters: [EHProbeParameter]

    public init?(from original: ehprobe_event_t) {
        guard original.raw_data != nil else {
            return nil
        }

        self.timestampNs = original.timestamp_ns
        self.pid = original.pid
        self.eventType = original.event_type

        var params: [EHProbeParameter] = []
        params.reserveCapacity(Int(original.param_count))

        var mutableEvent = original

        for i in 0..<original.param_count {
            var param = ehprobe_param_t()
            if ehprobe_get_param(&mutableEvent, i, &param) == 0 {
                params.append(EHProbeParameter(from: param))
            } else {
                params.append(.none)
            }
        }

        self.parameters = params
    }


    public subscript(_ index: Int) -> EHProbeParameter {
        guard index >= 0 && index < parameters.count else {
            return .none
        }
        return parameters[index]
    }

    public subscript(_ index: UInt16) -> EHProbeParameter {
        return self[Int(index)]
    }
}


extension EHProbeEvent {
    public static func ttyDevicePath(from encodedDevice: UInt32) -> String {
        guard encodedDevice != 0 else {
            return ""
        }


        let major = (encodedDevice >> 8) & 0xFFF

        let minorLow = encodedDevice & 0xFF
        let minorHigh = (encodedDevice >> 12) & 0xFFF00
        let minor = minorLow | minorHigh

        switch major {
        case 136:
            return "/dev/pts/\(minor)"
        case 4:
            if minor < 64 {
                return "/dev/tty\(minor)"
            } else {
                return "/dev/ttyS\(minor - 64)"
            }
        case 5:
            switch minor {
            case 0: return "/dev/tty"
            case 1: return "/dev/console"
            case 2: return "/dev/ptmx"
            default: return "/dev/tty\(minor)"
            }
        default:
            return ""
        }
    }
}


extension EHProbeParameter {
    public func asIPAddress(family: UInt32) -> String? {
        guard case .bytebuf(let data) = self else {
            return nil
        }

        switch family {
        case 2:
            guard data.count >= 4 else {
                return nil
            }
            return "\(data[0]).\(data[1]).\(data[2]).\(data[3])"

        case 10:
            guard data.count >= 16 else {
                return nil
            }

            var groups: [UInt16] = []
            for i in stride(from: 0, to: 16, by: 2) {
                let value = (UInt16(data[i]) << 8) | UInt16(data[i + 1])
                groups.append(value)
            }

            var longestStart = -1
            var longestLen = 0
            var currentStart = -1
            var currentLen = 0

            for i in 0..<8 {
                if groups[i] == 0 {
                    if currentStart == -1 {
                        currentStart = i
                        currentLen = 1
                    } else {
                        currentLen += 1
                    }
                } else {
                    if currentLen > longestLen && currentLen > 1 {
                        longestStart = currentStart
                        longestLen = currentLen
                    }
                    currentStart = -1
                    currentLen = 0
                }
            }
            if currentLen > longestLen && currentLen > 1 {
                longestStart = currentStart
                longestLen = currentLen
            }

            var result = ""
            var i = 0
            while i < 8 {
                if i == longestStart {
                    result += i == 0 ? "::" : ":"
                    i += longestLen
                } else {
                    if i > 0 && i != longestStart + longestLen {
                        result += ":"
                    }
                    result += String(format: "%x", groups[i])
                    i += 1
                }
            }

            return result

        default:
            return nil
        }
    }
}

#endif
