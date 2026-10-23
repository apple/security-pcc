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
import OSLog

@_spi(Private)
public final class SecureConfigDBClient {
	private let connection: NSXPCConnection

	public static let shared = SecureConfigDBClient()

	private init() {
		self.connection = NSXPCConnection(machServiceName: "com.apple.secureconfigd", options: .privileged)

		self.connection.remoteObjectInterface = NSXPCInterface(with: SecureConfigXPCProtocol.self)
		self.connection.resume()
	}
}

@_spi(Private)
extension SecureConfigDBClient {
	/// A method to register a new configuration to SEP from a file, with the option of outputting
	/// the buffer into an out parameter.
	/// The data is copied over to /var/db/secureconfig/{kern.bootsessionuuid}
	/// and ratcheted in SEP.
	///
	/// - Parameters:
	///     - path: Path to config to register and load
	///     - mimeType: Constant string representing the config type
	///
	/// - Returns:
	/// Will return 0 upon SUCCESS or the respective @link errno.  The implementation
	/// may directly return any of the following error codes:
	///     [ENOTCONN]         pipe went dead
	///     [ENOENT]           file was not found
	///     [EINVAL]           file could not be read
	public func register(fileAt path: String, mimeType: String) -> CInt {
		do {
			let fileURL = URL(fileURLWithPath: path)
			let fileContents = try Data(contentsOf: fileURL)
			return self.register(fileContents, name: path, mimeType: mimeType)
		} catch let err {
			Logger().error("File \(path) couldn't be read with error \(err.localizedDescription)")
			return EINVAL
		}
	}

	/// A method to register a new configuration to SEP from a data buffer
	/// The data is copied over to /var/db/secureconfig/{kern.bootsessionuuid}
	/// and ratcheted in SEP.
	///
	/// - Parameters:
	/// - data: A pointer to the loaded configuration information to ratched in the SEP
	/// - name: Unique name for the configuration in buff
	/// - mimeType: Type of configuration loaded in buff
	///
	/// - Returns:
	/// Will return 0 upon SUCCESS or the respective @link errno.  The implementation
	/// may directly return any of the following error codes:
	///     [ENOTCONN]         pipe went dead
	///     [EINVAL]           buffer could not be read
	public func register(_ data: Data, name: String, mimeType: String) -> CInt {
		var internalError: Int32 = -1;
		let connectionError = self.withSynchronousConnection { remoteObject in
			remoteObject.registerConfig(inputData: data, metadata: [
				"name": name,
				"mime_type": mimeType,
			]) { response in
				internalError = response
			}
		}

		guard connectionError == 0 else {
			return connectionError
		}

		return internalError
	}

	/// Register SecureConfig parameters to make them available for reading. Intended for darwin-init; can only be
	/// performed once in a given boot.
	public func registerParameters(_ data: Data, _ securityPolicy: String?) -> CInt {
		var internalError: Int32 = -1;
		let connectionError = self.withSynchronousConnection { remoteObject in
			remoteObject.registerParameters(parametersJson: data, securityPolicy: securityPolicy) { response in
				internalError = response
			}
		}

		return if connectionError != 0 {
			connectionError
		} else {
			internalError
		}
	}

	private func withSynchronousConnection(perform action: (any SecureConfigXPCProtocol) -> Void) -> CInt {
		var connectionValue: Int32 = 0
		let proxy = self.connection.synchronousRemoteObjectProxyWithErrorHandler { error in
			Logger().error("Synchronous proxy returned error: \(error)")
			connectionValue = ENOTCONN
		}

		guard let proxy = proxy as? any SecureConfigXPCProtocol else {
			Logger().fault("Synchronous proxy is invalid: does not conform to SecureConfigXPCProtocol?")
			return EINVAL
		}

		action(proxy)
		return connectionValue
	}
}

// MARK: - C Interface

@_cdecl("register_config_from_buffer")
@_spi(Private)
public func register_config_from_buffer(
	_ buff: UnsafePointer<CChar>?,
	_ buffSize: size_t,
	_ rawConfigName: UnsafePointer<CChar>?,
	_ rawMimeType: UnsafePointer<CChar>?
) -> CInt {
	guard let buff, let rawConfigName, let rawMimeType else {
		return EINVAL
	}

    let data = Data(bytes: buff, count: buffSize)
	let configName = String(cString: rawConfigName)
	let mimeType = String(cString: rawMimeType)
	return SecureConfigDBClient.shared.register(data, name: configName, mimeType: mimeType)
}

@_cdecl("register_config_from_path")
@_spi(Private)
public func register_config_from_path(
	_ rawPath: UnsafePointer<CChar>?,
	_ buff: UnsafeMutablePointer<UnsafeMutableRawPointer?>?,
	_ buff_sze: UnsafeMutablePointer<size_t>?,
	_ rawMimeType: UnsafePointer<CChar>?
) -> CInt {
	guard let rawPath, let rawMimeType else {
		return EINVAL
	}

	let path = String(cString: rawPath)
	let mimeType = String(cString: rawMimeType)
	return SecureConfigDBClient.shared.register(fileAt: path, mimeType: mimeType)
}

@_cdecl("register_config_parameters")
@_spi(Private)
public func register_config_parameters(
	_ buff: UnsafePointer<CChar>?,
	_ buffSize: size_t,
	_ rawSecurityPolicy: UnsafePointer<CChar>?
) -> CInt {
	guard let buff, let rawSecurityPolicy else {
		return EINVAL
	}

	let data = Data(bytes: buff, count: buffSize)
	let securityPolicy = String(cString: rawSecurityPolicy)
	return SecureConfigDBClient.shared.registerParameters(data, securityPolicy)
}
