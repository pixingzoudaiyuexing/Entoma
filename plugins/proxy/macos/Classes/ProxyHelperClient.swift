import Foundation
import ServiceManagement

private final class ProxyHelperReply {
  private let lock = NSLock()
  private let semaphore = DispatchSemaphore(value: 0)
  private var value: Result<NSDictionary, Error>?

  func complete(_ result: Result<NSDictionary, Error>) {
    lock.lock()
    guard value == nil else { lock.unlock(); return }
    value = result
    lock.unlock()
    semaphore.signal()
  }

  func wait(seconds: TimeInterval) throws -> NSDictionary {
    guard semaphore.wait(timeout: .now() + seconds) == .success else {
      throw ProxyHelperFailure.operationUnknown
    }
    lock.lock(); defer { lock.unlock() }
    guard let value = value else { throw ProxyHelperFailure.operationUnknown }
    return try value.get()
  }
}

/// Called only from ProxyPlugin's serial queue. No network writes or protected
/// registration happen on application startup or from a mere status read.
@available(macOS 13.0, *)
final class ProxyHelperClient {
  private var connection: NSXPCConnection?
  private(set) var needsRestoration = false
  private var operationTimeout: TimeInterval = 10

  init() {}

  #if ENTOMA_HELPER_TESTING
  private var fixtureMode = false
  // Anonymous, unprivileged local IPC only. Absent from the application build.
  init(fixtureConnection: NSXPCConnection, timeout: TimeInterval) {
    connection = fixtureConnection
    operationTimeout = timeout
    fixtureMode = true
  }
  #endif

  private func service() throws -> SMAppService {
    _ = try ProxyHelperIdentity.ownTeam(expectedIdentifier: ProxyHelperIdentity.appIdentifier)
    guard Bundle.main.url(forResource: "com.entoma.client.proxy-helper", withExtension: "plist",
                          subdirectory: "Contents/Library/LaunchDaemons") != nil ||
          FileManager.default.fileExists(atPath: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchDaemons/\(ProxyHelperIdentity.plistName)").path) else {
      throw ProxyHelperFailure.missing
    }
    return SMAppService.daemon(plistName: ProxyHelperIdentity.plistName)
  }

  func registrationStatus() throws -> NSDictionary {
    let service = try self.service()
    return ["available": service.status == .enabled, "registration": registrationName(service.status),
            "protocolVersion": ProxyHelperIdentity.protocolVersion]
  }

  func register() throws -> NSDictionary {
    let service = try self.service()
    if service.status == .notRegistered || service.status == .notFound { try service.register() }
    // Register returning successfully is not approval or proof of a running
    // daemon. The UI must show requiresApproval and let the user approve it.
    return try registrationStatus()
  }

  func unregister() throws -> NSDictionary {
    let service = try self.service()
    if service.status == .notRegistered {
      guard !needsRestoration else { throw ProxyHelperFailure.restoreFailed }
      return try registrationStatus()
    }
    guard service.status == .enabled else { throw ProxyHelperFailure.approvalRequired }
    let prepared = try request { $0.prepareUnregister(reply: $1) }
    guard prepared["restorationPending"] as? Bool == false,
          prepared["owned"] as? Bool == false else { throw ProxyHelperFailure.restoreFailed }
    // SMAppService.unregister can kill a daemon: restoration must have been
    // acknowledged first, and the daemon has stopped accepting new apply calls.
    needsRestoration = false
    let completion = ProxyHelperReply()
    service.unregister { error in
      if error != nil { completion.complete(.failure(ProxyHelperFailure.unavailable)) }
      else { completion.complete(.success(["protocolVersion": ProxyHelperIdentity.protocolVersion])) }
    }
    _ = try completion.wait(seconds: operationTimeout)
    connection?.invalidate(); connection = nil
    return try registrationStatus()
  }

  func status(port: Int, bypass: [String]) throws -> NSDictionary {
    try ProxyHelperIdentity.validate(port: port, bypass: bypass)
    return try request { $0.status(port: port, bypass: bypass, reply: $1) }
  }

  func apply(port: Int, bypass: [String]) throws -> NSDictionary {
    try ProxyHelperIdentity.validate(port: port, bypass: bypass)
    _ = try connected()
    needsRestoration = true
    let value = try request { $0.applyProxy(port: port, bypass: bypass, reply: $1) }
    guard value["matches"] as? Bool == true,
          value["restorationPending"] as? Bool == false else { throw ProxyHelperFailure.operationUnknown }
    return value
  }

  func restore() throws -> NSDictionary {
    let value = try request { $0.restoreProxy(reply: $1) }
    guard value["owned"] as? Bool == false,
          value["restorationPending"] as? Bool == false else { throw ProxyHelperFailure.restoreFailed }
    needsRestoration = false
    return value
  }

  private func connected() throws -> NSXPCConnection {
    #if ENTOMA_HELPER_TESTING
    if fixtureMode {
      guard let connection = connection else { throw ProxyHelperFailure.operationUnknown }
      return connection
    }
    #endif
    let service = try self.service()
    switch service.status {
    case .enabled: break
    case .requiresApproval: throw ProxyHelperFailure.approvalRequired
    case .notRegistered, .notFound: throw ProxyHelperFailure.missing
    @unknown default: throw ProxyHelperFailure.unavailable
    }
    if let value = connection { return value }
    let team = try ProxyHelperIdentity.ownTeam(expectedIdentifier: ProxyHelperIdentity.appIdentifier)
    let value = NSXPCConnection(machServiceName: ProxyHelperIdentity.serviceName, options: .privileged)
    value.remoteObjectInterface = NSXPCInterface(with: ProxyHelperProtocol.self)
    value.setCodeSigningRequirement(try ProxyHelperIdentity.requirement(identifier: ProxyHelperIdentity.helperIdentifier, team: team))
    value.resume()
    connection = value
    return value
  }

  private func request(_ call: (ProxyHelperProtocol, @escaping (NSDictionary?, String?) -> Void) -> Void) throws -> NSDictionary {
    let connection = try connected()
    let reply = ProxyHelperReply()
    guard let remote = connection.remoteObjectProxyWithErrorHandler({ _ in
      reply.complete(.failure(ProxyHelperFailure.operationUnknown))
    }) as? ProxyHelperProtocol else {
      needsRestoration = true
      connection.invalidate(); self.connection = nil
      throw ProxyHelperFailure.operationUnknown
    }
    call(remote) { value, error in
      if let code = error { reply.complete(.failure(ProxyHelperFailure(rawValue: code) ?? .unavailable)); return }
      guard let value = value,
            value["protocolVersion"] as? Int == ProxyHelperIdentity.protocolVersion else {
        reply.complete(.failure(ProxyHelperFailure.operationUnknown)); return
      }
      reply.complete(.success(value))
    }
    do { return try reply.wait(seconds: operationTimeout) }
    catch {
      if let failure = error as? ProxyHelperFailure,
         [.operationUnknown, .recoveryRequired, .restoreFailed, .unavailable].contains(failure) {
        // Even a status request can encounter an old daemon's unresolved durable
        // transaction. Once connected, an UNKNOWN cannot take the unowned no-op
        // stop path merely because this GUI has not sent a new apply request.
        needsRestoration = true
      }
      // An interrupted write may have landed. Invalidating triggers the helper's
      // session restoration; no timeout/error is translated into a false success.
      connection.invalidate()
      self.connection = nil
      throw error
    }
  }

  private func registrationName(_ status: SMAppService.Status) -> String {
    switch status {
    case .notRegistered: return "notRegistered"
    case .enabled: return "enabled"
    case .requiresApproval: return "requiresApproval"
    case .notFound: return "notFound"
    @unknown default: return "unknown"
    }
  }

  deinit { connection?.invalidate() }
}
