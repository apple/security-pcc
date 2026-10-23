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
import Darwin.POSIX

/// Key-value configuration set via darwin-init config. darwin-init and users of these APIs are responsible
/// for validating the configuration against security and privacy policy which is included in the attestation
/// bundle. The configuration is guaranteed to be immutable during a boot.
///
/// ### darwin-init config
///
/// Parameters are set in darwin-init config using the following syntax:
/// ```
/// {
///   secure-config: {
///     <com.apple.myapp.key>: <value>
///   },
///   config-security-policy: <policy>
/// }
/// ```
/// Keys need to be in reverse-DNS notation to avoid collisions. Values of string, bool, number, array, and
/// dictionary types are supported. Arrays and dictionaries can be nested.
///
/// `config-security-policy` is an optional property with a string value matching
/// ``SecureConfigSecurityPolicy``. If unset, ``SecureConfigSecurityPolicy/none``
/// value is used. The value of this property indicates that darwin-init should enforce that the configuration
/// is aproproate for handling the type of data matching the policy name.
///
/// These parameters are only set when applying system darwin-init config at boot, and not during
/// subsequent `darwin-init apply` invocations.
///
/// ### Reading parameters
///
/// Parameters fall into two buckets:
///
/// * Known to darwin-init and SecureConfig. Known parameters are exposed as typed named fields and
/// have keys listed under ``Keys``. These have been validated by darwin-init against
/// ``securityPolicy``.
///
/// * Unknown to darwin-init and SecureConfig. These can be accessed using
/// ``unvalidatedParameter(_:)`` and related APIs. The caller must treat these inputs as
/// unvalidated and hostile. It must validate them against ``securityPolicy`` or ensure that hostile
/// inputs cannot impact security or privacy of customer data.
///
/// This allows making the following privacy and security claim:
///
/// **
/// Software on the device validated its configuration (`secure-config`) and guarantees secure and
/// private handling of user data suitable for `securityPolicy` such as `customer` or `carry`.
/// **
@objc(_SecureConfigParameters)
public class SecureConfigParameters: NSObject, Codable {

	/// Keys for a JSON version of the config.
	public enum Keys: String, CaseIterable {
		case logPolicyPath = "com.apple.logging.policyPath"
		case metricsFilteringEnforced = "com.apple.logging.metricsFilteringEnforced"
		case logFilteringEnforced = "com.apple.logging.logFilteringEnforced"
		case crashRedactionEnabled = "com.apple.logging.crashRedactionEnabled"
		case internalRequestOptionsAllowed = "com.apple.tie.internalRequestOptionsAllowed"
		case tie_allowNonProdExceptionOptions = "com.apple.tie.allowNonProdExceptionOptions"
		case cloudboard_isProxy = "com.apple.cloudboard.isProxy"
		case cryptexAppIdentifiers = "com.apple.libcryptex.appIdentifiers"
		case cloudAttestationRoutingHint = "com.apple.CloudAttestation.routingHint"
		case cloudAttestationRackId = "com.apple.CloudAttestation.rackId"

		//Research keys
		case research_disableAppleInfrastrucutureEnforcement = "com.apple.pcc.research.disableAppleInfrastrucutureEnforcement"
	}

	/// Policy for security and privacy validation of the parameters. Callers of
	/// ``unvalidatedParameter(_:)`` are responsible for validating obtained values against this
	/// ``securityPolicy``. Parameters exposed as fields of this class (have ``Keys``) have been
	/// validated already.
	@objc
	public let securityPolicy: SecureConfigSecurityPolicy

	/// Parameter for ``Keys.logPolicyPath`` key.
	@objc
	public let logPolicyPath: String?

	/// Parameter for ``Keys.metricsFilteringEnforced`` key.
	public let metricsFilteringEnforced: Bool?

	/// Parameter for ``Keys.logFilteringEnforced`` key.
	public let logFilteringEnforced: Bool?

	/// Parameter for ``Keys.crashRedactionEnabled`` key.
	public let crashRedactionEnabled: Bool?

	/// Parameter for ``Keys.internalRequestOptionsAllowed`` key.
	@available(*, deprecated)
	public let internalRequestOptionsAllowed: Bool?

	/// Parameter for ``Keys.tie_allowNonProdExceptionOptions`` key.
	public let tie_allowNonProdExceptionOptions: Bool?

	/// Parameter for ``Keys.cloudboard_isProxy`` key.
	public let cloudboard_isProxy: Bool?

	/// Parameter for ``Keys.cloudAttestationRoutingHint`` key.
	public let cloudAttestationRoutingHint: String?

	/// Parameter for ``Keys.cloudAttestationRackId`` key.
	public let cloudAttestationRackId: String?

	/// Parameter for ``Keys.research_disableAppleInfrastrucutureEnforcement`` key.
	public let research_disableAppleInfrastrucutureEnforcement: Bool?

	/// Parameter for ``Keys.cryptexAppIdentifiers`` key.
	@objc
	public let cryptexAppIdentifiers: [String]?

	@objc(logFilteringEnforced)
	public var cf_logFilteringEnforced: CFBoolean? {
		if let logFilteringEnforced {
			return logFilteringEnforced as CFBoolean
		}
		return nil
	}

	@objc(research_disableAppleInfrastructureEnforcement)
	public var cf_research_disableAppleInfrastructureEnforcement: CFBoolean? {
		if let research_disableAppleInfrastrucutureEnforcement {
			return research_disableAppleInfrastrucutureEnforcement as CFBoolean
		}
		return nil
	}

	/// Returns the value of a given parameter. The caller must treat these inputs as unvalidated and hostile.
	/// It must validate them against ``securityPolicy`` or ensure that hostile inputs cannot impact
	/// security or privacy of customer data.
	///
	/// Returns `nil` if key isn't present, throws if the value cannot be decoded as the requested result
	/// type.
	public func unvalidatedParameter<Result>(_ key: String) throws -> Result? {
		try parameters.get(key)
	}

	/// ObjC version of ``unvalidatedParameter(_:)`` for parameters with string values. Sets
	/// error out if key isn't present or cannot be decoded.
	@objc
	public func unvalidatedStringParameter(_ key: String) throws -> String {
		try parameters.getNonnull(key)
	}

	/// ObjC version of ``unvalidatedParameter(_:)`` for parameters with boolean values. Sets
	/// error out if key isn't present or cannot be decoded.
	@objc
	public func unvalidatedBooleanParameter(_ key: String) throws -> CFBoolean {
		try parameters.getNonnull(key)
	}

	/// ObjC version of ``unvalidatedParameter(_:)`` for parameters with number values. Sets
	/// error out if key isn't present or cannot be decoded.
	@objc
	public func unvalidatedNumberParameter(_ key: String) throws -> CFNumber {
		try parameters.getNonnull(key)
	}

	/// Loads parameters.
	///
	/// - Throws If the device hasn't completed initialization yet, or if the invoking process doesn't have
	/// privileges to access the parameters. Crash is the correct way to handle all cases.
	@objc
	public static func loadContents() throws -> SecureConfigParameters {
		let data = try Data(contentsOf: try Self.paramsURL())
		return try JSONDecoder().decode(SecureConfigParameters.self, from: data)
	}

	// MARK: Internal

	enum CodingKeys: String, CodingKey {
		case parameters
		case securityPolicy
	}

	let parameters: SecureConfigRawParameters

	init(parameters: SecureConfigRawParameters, securityPolicy: SecureConfigSecurityPolicy) throws {
		self.parameters = parameters
		self.securityPolicy = securityPolicy

		self.logPolicyPath = try parameters.get(Keys.logPolicyPath.rawValue)
		self.metricsFilteringEnforced = try parameters.get(Keys.metricsFilteringEnforced.rawValue)
		self.logFilteringEnforced = try parameters.get(Keys.logFilteringEnforced.rawValue)
		self.crashRedactionEnabled = try parameters.get(Keys.crashRedactionEnabled.rawValue)
		self.internalRequestOptionsAllowed = try parameters.get(Keys.internalRequestOptionsAllowed.rawValue)
		self.tie_allowNonProdExceptionOptions = try parameters.get(Keys.tie_allowNonProdExceptionOptions.rawValue)
		self.cloudboard_isProxy = try parameters.get(Keys.cloudboard_isProxy.rawValue)
		self.cloudAttestationRoutingHint = try parameters.get(Keys.cloudAttestationRoutingHint.rawValue)
		self.cloudAttestationRackId = try parameters.get(Keys.cloudAttestationRackId.rawValue)
		self.research_disableAppleInfrastrucutureEnforcement = try parameters.get(Keys.research_disableAppleInfrastrucutureEnforcement.rawValue)
		self.cryptexAppIdentifiers = try parameters.get(Keys.cryptexAppIdentifiers.rawValue)
	}

	public required convenience init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)

		let parameters = try container.decode(SecureConfigRawParameters.self, forKey: .parameters)
		let securityPolicy = try container.decode(SecureConfigSecurityPolicy.self, forKey: .securityPolicy)

		try self.init(parameters: parameters, securityPolicy: securityPolicy)
	}

	public func encode(to encoder: any Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(parameters, forKey: .parameters)
		try container.encode(securityPolicy, forKey: .securityPolicy)
	}

	override public var debugDescription: String {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
		do {
			let data = try encoder.encode(self)
			return String(decoding: data, as: UTF8.self)
		} catch {
			return "SecureConfigParameters(\(error))"
		}
	}
}

@objc
public enum SecureConfigSecurityPolicy: Int, Codable, CaseIterable {
	/// No privacy / security validation of the config is necessary.
	case none = 0
	/// Parameters must be validated to ensure secure and private handling of **customer** data.
	case customer
	/// Parameters must be validated to ensure secure and private handling of **customerProxy** data.
	case customerProxy
	/// Parameters must be validated to ensure secure and private handling of **internal carry / live-on** data.
	case carry

	public init(stringValue: String?) throws {
		let policy = Self.allCases.first { $0.stringValue == stringValue }
		guard let policy else {
			throw RuntimeError("Unknown SecureConfigSecurityPolicy: \(String(describing: stringValue))")
		}
		self = policy
	}

	var stringValue: String? {
		switch self {
		case .none: return nil
		case .customer: return "customer"
		case .customerProxy: return "customerProxy"
		case .carry: return "carry"
		}
	}
}


@_spi(Private)
extension SecureConfigParameters {

	public func write() throws {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
		let data = try encoder.encode(self)
		
		let dvURL = try Self.datavaultURL()
		let manager = FileManager.default
		try manager.createDirectory(at: dvURL, withIntermediateDirectories: true)
		try data.write(to: try Self.paramsURL(), options: [.withoutOverwriting])
	}

	public static func decode(parametersJson: Data,
			securityPolicy: String?) throws -> SecureConfigParameters {
		let policy = try SecureConfigSecurityPolicy(stringValue: securityPolicy)
		let rawParameters = try JSONDecoder().decode(
				SecureConfigRawParameters.self, from: parametersJson)
		return try SecureConfigParameters(parameters: rawParameters,
				securityPolicy: policy)
	}

	static func datavaultURL() throws -> URL {
		let bootsessionuuid = try readBootSessionUUID()
		let dbURL = URL(fileURLWithPath: "/var/db/secureconfig")
		return dbURL.appending(components: bootsessionuuid, "datavault")
	}
	
	static func paramsURL() throws -> URL {
		let dvURL = try Self.datavaultURL()
		return dvURL.appending(component: "parameters.json")
	}
}

struct RuntimeError: Error, CustomStringConvertible {
	var description: String

	init(_ description: String) {
		self.description = description
	}
}
