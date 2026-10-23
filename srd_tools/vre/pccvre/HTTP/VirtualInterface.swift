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

// Copyright © 2025 Apple, Inc. All rights reserved.

@preconcurrency import vmnet
import Network

/// An address and port assigned by the virtual vmnet subsystem.
struct VirtualInterface: HTTPServer.Interface, @unchecked Sendable {
    var host: NWEndpoint.Host

    private var interface: interface_ref
    private var parameters: xpc_object_t
    private var queue: DispatchQueue
    
    init(configuration: HTTPServer.Configuration.Virtual) async throws {
        let queue = DispatchQueue(label: "com.apple.security-research.pccvre.vmebridge")
        (self.interface, self.parameters) = try await configuration.start(on: queue)
        self.queue = queue
        guard
            let startAddress = xpc_dictionary_get_string(self.parameters, vmnet_start_address_key),
            let address = IPv4Address(String(cString: startAddress))
        else {
            throw VirtualInterface.Error.missingAddress
        }
        self.host = .ipv4(address)
    }
}

extension VirtualInterface {
    consuming func shutdown() throws {
        let ret = vmnet_stop_interface(self.interface, self.queue, { _ in })
        if let error = VirtualInterface.Error(vmnetError: ret) {
            throw error
        }
    }
}

extension VirtualInterface {
    enum Error: Swift.Error {
        // General failure.
        case genericFailure
        
        // Memory allocation failure.
        case memoryAllocationFailed
        
        // Invalid argument specified.
        case invalidArgument
        
        // Interface setup is not complete.
        case setupIncomplete
        
        // Permission denied.
        case invalidAccess
        
        // Packet size larger than MTU.
        case packetTooBig
        
        // Buffers exhausted in kernel.
        case bufferExhausted
        
        //  Packet count exceeds limit.
        case tooManyPackets
        
        // Vmnet Interface cannot be started as conflicting sharing service is in use.
        case sharingServiceBusy
        
        // The operation could not be completed due to missing authorization.
        case notAuthorized
        
        case missingAddress
        case missingInterface
        case missingInterfaceParameters

        /// Converts a `vmnet_return_t` value into a
        /// ``VirtualAddressProvider/Error`` value, returning `nil` if no error
        /// occurred.
        init?(vmnetError: vmnet_return_t) {
            switch vmnetError {
            case .VMNET_SUCCESS:
                return nil
            case .VMNET_FAILURE:
                self = .genericFailure
            case .VMNET_MEM_FAILURE:
                self = .memoryAllocationFailed
            case .VMNET_INVALID_ARGUMENT:
                self = .invalidArgument
            case .VMNET_SETUP_INCOMPLETE:
                self = .setupIncomplete
            case .VMNET_INVALID_ACCESS:
                self = .invalidAccess
            case .VMNET_PACKET_TOO_BIG:
                self = .packetTooBig
            case .VMNET_BUFFER_EXHAUSTED:
                self = .bufferExhausted
            case .VMNET_TOO_MANY_PACKETS:
                self = .tooManyPackets
            case .VMNET_SHARING_SERVICE_BUSY:
                self = .sharingServiceBusy
            case .VMNET_NOT_AUTHORIZED:
                self = .notAuthorized
            default:
                self = .genericFailure
            }
        }
    }
}

extension HTTPServer.Configuration.Virtual {
    func start(on queue: DispatchQueue) async throws -> (interface_ref, xpc_object_t) {
        var interface: interface_ref? = nil
        let parameters: xpc_object_t = try await withCheckedThrowingContinuation { continuation in
            interface = vmnet_start_interface(self.interfaceDescription, queue) { ret, params in
                if let error = VirtualInterface.Error(vmnetError: ret) {
                    return continuation.resume(throwing: error)
                }
                
                guard let params else {
                    return continuation.resume(throwing: VirtualInterface.Error.missingInterfaceParameters)
                }
                
                continuation.resume(returning: params)
            }
        }
        
        guard let interface else {
            throw VirtualInterface.Error.missingInterface
        }
        return (interface, parameters)
    }
    
    var interfaceDescription: xpc_object_t {
        let interfaceDescription = xpc_dictionary_create_empty()
        xpc_dictionary_set_uint64(interfaceDescription,
                                  vmnet_operation_mode_key,
                                  UInt64(self.mode.modeValue))
        
        // must explicitly set vmnet_enable_isolation_key for nat, otherwise new bridge/subnet alloc'd each start
        if self.mode == .nat {
            xpc_dictionary_set_bool(interfaceDescription, vmnet_enable_isolation_key, true)
        }
        return interfaceDescription
    }
}

extension HTTPServer.Configuration.Virtual.NetworkMode {
    var modeValue: UInt32 {
        return switch self {
        case .nat: vmnet.operating_modes_t.VMNET_SHARED_MODE.rawValue
        case .hostOnly: vmnet.operating_modes_t.VMNET_HOST_MODE.rawValue
        }
    }
}
