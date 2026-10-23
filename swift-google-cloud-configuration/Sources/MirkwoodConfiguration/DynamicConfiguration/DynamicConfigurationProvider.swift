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

public import Configuration
internal import SystemPackage
private import Synchronization
internal import SwiftProtobuf
package import MirkwoodDynamicConfiguration
package import GRPCCore
public import ServiceLifecycle
package import GRPCInProcessTransport
public import GRPCNIOTransportHTTP2
internal import NIOPosix

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// A config provider that interfaces with the Mirkwood control plane to provide
/// dynamically-updated configuration values.
///
/// > Important: This provider must be run as part of a `ServiceGroup` for the periodic polling to work.
///
/// ## Usage
///
/// The provider requires two explicit parameters: A unique identifier for the
/// client application, and the TLS configuration.
///
/// The TLS configuration consists of credentials that you either load at runtime from your deployment
/// provider, or you create manually for local testing.
///
/// ### Instantiate using explicitly provided parameters
///
/// The first way to create a Whisper provider is by passing the required parameters explicitly:
///
/// ```swift
/// import Configuration
/// import MirkwoodConfiguration
/// internal import GRPCNIOTransportHTTP2Posix
///
/// let dynamicProvider = try await DynamicConfigurationProvider(
///   applicationID: "com.apple.test-app-id",
///   uri: URL(string: "https://0.0.0.0:50051")!,
///   transportSecurity: .mTLS(
///     certificateChain: [
///       .file(path: "/certs/cert.pem", format: .pem)
///     ],
///     privateKey: .file(path: "/certs/key.pem", format: .pem)
///   )
/// )
/// let config = ConfigReader(provider: dynamicProvider)
/// ```
///
/// ## Running the provider in a service group
///
/// The dynamic configuration provider subscribes to the control plane agent to
/// fetch any changed config values, ensuring that it always has a reasonably
/// up-to-date snapshot.
///
/// The provider then needs to be added to a service group from Swift Service Lifecycle:
///
/// ```swift
/// let serviceGroup = ServiceGroup(
///     services: [dynamicProvider],
///     logger: ...
/// )
/// try await serviceGroup.run()
/// ```
public final class DynamicConfigurationProvider: Sendable {
  /// Common provider settings.
  private let settings: DynamicConfigurationProvider.Settings

  package enum Client {
    case local(Config_ConfigService.Client<InProcessTransport.Client>)
    case remote(Config_ConfigService.Client<HTTP2ClientTransport.Posix>)
  }
  private let client: Client

  private struct Storage {
    /// The current snapshot.
    var snapshot: DynamicConfigurationProvider.Snapshot

    /// The active watchers of values, keyed by name.
    var valueWatchers: [String: [UUID: AsyncStream<ValueUpdate>.Continuation]]

    /// The active watchers of snapshots.
    var snapshotWatchers: [UUID: AsyncStream<DynamicConfigurationProvider.Snapshot>.Continuation]
  }
  private let storage: Mutex<Storage>

  package init(
    applicationID: String,
    client: DynamicConfigurationProvider.Client,
    initialValue: InitialValue? = nil,
  ) async throws {
    let providerName = "DynamicConfigurationProvider"
    let settings = DynamicConfigurationProvider.Settings(
      providerName: providerName,
      applicationID: applicationID,
    )

    let initialSnapshot = DynamicConfigurationProvider.Snapshot(
      settings: settings,
      properties: try .with {
        if let initialValue {
          $0.fields = [
            initialValue.key: try .init(jsonString: initialValue.value)
          ]
        }
      }
    )

    self.settings = settings
    self.client = client
    self.storage = Mutex(
      Storage(
        snapshot: initialSnapshot,
        valueWatchers: [:],
        snapshotWatchers: [:]
      )
    )
  }
}

extension DynamicConfigurationProvider {
  public struct InitialValue: Sendable, Equatable {
    public var key: String
    public var value: String
  }

  public convenience init(
    applicationID: String,
    initialValue: InitialValue? = nil,
  ) async throws {
    let transport = try HTTP2ClientTransport.Posix(
      target: .unixDomainSocket(path: Self.socketPath()),
      transportSecurity: .plaintext
    )
    let grpc = GRPCClient(transport: transport)
    let client = Config_ConfigService.Client<HTTP2ClientTransport.Posix>(wrapping: grpc)

    Task.detached {
      try await grpc.runConnections()
    }

    try await self.init(
      applicationID: applicationID,
      client: .remote(client),
      initialValue: initialValue,
    )
  }

  private static func socketPath() -> String {
    return "/etc/config/local/dynamic-config.sock"
  }
}

extension DynamicConfigurationProvider {
  /// A container for a property value update.
  private struct ValueUpdate {
    /// The new value, after the reload.
    var newValue: Google_Protobuf_Value?

    /// Whether this is the first update emitted for the initial value.
    var isInitialUpdate: Bool
  }
}

extension DynamicConfigurationProvider: CustomStringConvertible {
  public var description: String {
    "DynamicConfigurationProvider[\(self.storage.withLock { $0.snapshot.properties.fields.count }) values]"
  }
}

extension DynamicConfigurationProvider: CustomDebugStringConvertible {
  public var debugDescription: String {
    let prettyValues = self.storage.withLock {
      $0.snapshot
        .properties
        .fields
        .sorted { $0.key < $1.key }
        .map { "\($0.key)=\($0.value)" }
        .joined(separator: ", ")
    }
    return "DynamicConfigurationProvider[\(self.storage.withLock { $0.snapshot.properties.fields.count }) values: \(prettyValues)]"
  }
}

extension DynamicConfigurationProvider: ConfigProvider {
  public var providerName: String {
    settings.providerName
  }

  public func value(
    forKey key: AbsoluteConfigKey,
    type: ConfigType
  ) throws -> LookupResult {
    try self.storage.withLock { storage in
      try storage.snapshot.value(
        forKey: key,
        type: type
      )
    }
  }

  public func fetchValue(
    forKey key: AbsoluteConfigKey,
    type: ConfigType
  ) async throws -> LookupResult {
    try value(forKey: key, type: type)
  }

  private struct CustomLookupResult: Equatable {
    var result: Result<LookupResult, any Swift.Error>
    static func == (lhs: CustomLookupResult, rhs: CustomLookupResult) -> Bool {
      switch (lhs.result, rhs.result) {
      case (.success(let lhs), .success(let rhs)):
        return lhs == rhs
      case (.failure, .failure):
        return true
      default:
        return false
      }
    }
  }

  public func watchValue<Return: ~Copyable>(
    forKey key: AbsoluteConfigKey,
    type: ConfigType,
    updatesHandler handler: (ConfigUpdatesAsyncSequence<Result<LookupResult, any Swift.Error>, Never>) async throws ->
    Return
  ) async throws -> Return {
    let (stream, continuation) = AsyncStream<ValueUpdate>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let id = UUID()
    let basePropertyKey = settings.keyEncoder(key)
    addValueContinuation(continuation, id: id, forName: basePropertyKey)
    defer {
      removeValueContinuation(id: id, forName: basePropertyKey)
    }
    @Sendable func contentResult(_ value: Google_Protobuf_Value?) -> CustomLookupResult {
      .init(
        result: Result {
          guard let value else {
            return .init(encodedKey: basePropertyKey, value: nil)
          }
          return try DynamicConfigurationProvider.Snapshot.parseContent(
            value,
            key: key,
            basePropertyKey: basePropertyKey,
            type: type,
            settings: settings
          )
        }
      )
    }
    return try await handler(
      ConfigUpdatesAsyncSequence(
        stream
          .compactMap { value in
            return contentResult(value.newValue).result
          }
      )
    )
  }

  public func snapshot() -> any ConfigSnapshot {
    self.storage.withLock { $0.snapshot }
  }

  public func watchSnapshot<Return: ~Copyable>(
    updatesHandler: (ConfigUpdatesAsyncSequence<any ConfigSnapshot, Never>) async throws -> Return
  )
    async throws -> Return
  {
    let (stream, continuation) = AsyncStream<DynamicConfigurationProvider.Snapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let id = UUID()
    addSnapshotContinuation(continuation, id: id)
    defer {
      removeSnapshotContinuation(id: id)
    }
    return try await updatesHandler(.init(stream.map { $0 }))
  }
}

extension DynamicConfigurationProvider: Service {
  public func run() async throws {
    var request = Config_SubscribeRequest()
    request.clientName = self.settings.applicationID
    try await self.client.subscribe(request) { response in
      for try await update in response.messages.cancelOnGracefulShutdown() {
        let newSnapshot = DynamicConfigurationProvider.Snapshot(
          settings: self.settings,
          properties: update.config
        )
        self.storage.withLock { storage in
          storage.snapshot = newSnapshot

          for (name, watchers) in storage.valueWatchers {
            guard let config = update.config[name] else {
              continue
            }
            for (_, watcher) in watchers {
              watcher.yield(.init(newValue: config, isInitialUpdate: false))
            }
          }

          for (_, watcher) in storage.snapshotWatchers {
            watcher.yield(storage.snapshot)
          }
        }
      }
    }
  }
}

extension DynamicConfigurationProvider {
  /// Adds a continuation that gets notified of new values for the provided key.
  /// - Parameters:
  ///   - continuation: The stream continuation for sending value updates.
  ///   - id: The unique identifier of the continuation.
  ///   - name: The encoded config key to watch for updates.
  private func addValueContinuation(
    _ continuation: AsyncStream<ValueUpdate>.Continuation,
    id: UUID,
    forName name: String
  ) {
    let initialValue = storage.withLock { storage in
      storage.valueWatchers[name, default: [:]][id] = continuation
      return storage.snapshot.properties[name]
    }
    continuation.yield(.init(newValue: initialValue, isInitialUpdate: true))
  }

  /// Removes the stored continuation for the provided identifier and config key.
  /// - Parameters:
  ///   - id: The unique identifier of the continuation.
  ///   - name: The encoded config key.
  internal func removeValueContinuation(id: UUID, forName name: String) {
    storage.withLock { state in
      state.valueWatchers[name]?[id] = nil
    }
  }

  /// Adds a continuation that gets notified of new snapshots.
  /// - Parameters:
  ///   - continuation: The stream continuation for sending snapshot updates.
  ///   - id: The unique identifier of the continuation.
  private func addSnapshotContinuation(
    _ continuation: AsyncStream<DynamicConfigurationProvider.Snapshot>.Continuation,
    id: UUID
  ) {
    let initialValue = storage.withLock { storage in
      storage.snapshotWatchers[id] = continuation
      return storage.snapshot
    }
    continuation.yield(initialValue)
  }

  /// Removes the stored continuation for the provided identifier.
  /// - Parameter id: The unique identifier of the continuation.
  private func removeSnapshotContinuation(id: UUID) {
    storage.withLock { state in
      state.snapshotWatchers[id] = nil
    }
  }
}

extension DynamicConfigurationProvider.Client {
  /// Call the "Subscribe" method.
  ///
  /// > Source IDL Documentation:
  /// >
  /// > Subscribe to configuration updates for a named client
  /// > Client provides its identifier and receives a stream of config updates
  ///
  /// - Parameters:
  ///   - message: request message to send.
  ///   - metadata: Additional metadata to send, defaults to empty.
  ///   - options: Options to apply to this RPC, defaults to `.defaults`.
  ///   - handleResponse: A closure which handles the response, the result of which is
  ///       returned to the caller. Returning from the closure will cancel the RPC if it
  ///       hasn't already finished.
  /// - Returns: The result of `handleResponse`.
  package func subscribe<Result>(
    _ message: Config_SubscribeRequest,
    metadata: GRPCCore.Metadata = [:],
    options: GRPCCore.CallOptions = .defaults,
    onResponse handleResponse: @Sendable @escaping (GRPCCore.StreamingClientResponse<Config_ConfigUpdate>) async throws -> Result
  ) async throws -> Result where Result: Sendable {
    let request = GRPCCore.ClientRequest<Config_SubscribeRequest>(
      message: message,
      metadata: metadata
    )
    switch self {
    case .local(let local):
      return try await local.subscribe(
        request: request,
        options: options,
        onResponse: handleResponse
      )
    case .remote(let remote):
      return try await remote.subscribe(
        request: request,
        options: options,
        onResponse: handleResponse
      )
    }
  }
}
