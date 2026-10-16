import Foundation
import Darwin

/// One daemon-wide serialized lease. A new GUI connection cannot race an old
/// connection's disconnect, an incomplete restore or an uninstall transaction.
final class ProxyHelperCoordinator {
  private let queue = DispatchQueue(label: "com.entoma.proxy-helper.transactions")
  private let owner: OwnedNetworkSettings
  private let consoleUser: () -> uid_t?
  private var sessions: [UUID: uid_t] = [:]
  private var lease: UUID?
  private var draining = false
  private var recovered = false

  init(owner: OwnedNetworkSettings, consoleUser: @escaping () -> uid_t? = { geteuid() }) {
    self.owner = owner
    self.consoleUser = consoleUser
  }

  func recoverAtStartup() throws {
    try queue.sync { try owner.recoverJournal(); recovered = true }
  }

  func opened(_ session: UUID, user: uid_t = geteuid()) { queue.sync { sessions[session] = user } }

  func closed(_ session: UUID) {
    queue.async {
      self.sessions[session] = nil
      guard self.lease == session else { return }
      do {
        try self.owner.stop(.proxy)
        self.lease = nil
      } catch {
        // Keep the lease and durable transaction. The next request retries only
        // CAS restoration, never a new apply over an unresolved old transaction.
      }
    }
  }

  private func checkConsole(_ session: UUID) throws {
    guard let user = sessions[session], consoleUser() == user else { throw ProxyHelperFailure.identityRejected }
  }

  private func ready(_ session: UUID, requireConsole: Bool) throws {
    guard sessions[session] != nil else { throw ProxyHelperFailure.identityRejected }
    if requireConsole { try checkConsole(session) }
    if !recovered {
      do { try owner.recoverJournal(); recovered = true }
      catch { throw ProxyHelperFailure.recoveryRequired }
    }
    if let old = lease, sessions[old] == nil {
      do { try owner.stop(.proxy); lease = nil }
      catch { throw ProxyHelperFailure.restoreFailed }
    }
    guard lease == nil || lease == session else { throw ProxyHelperFailure.busy }
  }

  private func state(port: Int? = nil, bypass: [String] = []) throws -> NSDictionary {
    let observed: ObservedProxyState?
    if let port = port { observed = try owner.proxyStatus(port: port, bypass: bypass) }
    else { observed = nil }
    var result: [String: Any] = ["available": true, "protocolVersion": ProxyHelperIdentity.protocolVersion,
                               "matches": observed?.matches ?? false, "owned": owner.hasOwnedSettings,
                               "restorationPending": owner.restorationPending, "draining": draining]
    // Restore has no requested port. Its reply must not pretend to know whether
    // an external proxy still uses a particular core; query status(port:) again.
    if let observed = observed { result["usesListener"] = observed.usesListener }
    return result as NSDictionary
  }

  private func perform(_ session: UUID, requireConsole: Bool = false,
                       reply: @escaping (NSDictionary?, String?) -> Void,
                       action: @escaping () throws -> NSDictionary) {
    queue.async {
      do {
        try self.ready(session, requireConsole: requireConsole)
        reply(try action(), nil)
      } catch {
        let code: String
        switch error {
        case let value as ProxyHelperFailure: code = value.rawValue
        case NetworkSettingsFailure.invalidInput: code = ProxyHelperFailure.invalidInput.rawValue
        case NetworkSettingsFailure.journalFailed: code = ProxyHelperFailure.recoveryRequired.rawValue
        case NetworkSettingsFailure.restoreFailed: code = ProxyHelperFailure.restoreFailed.rawValue
        default: code = ProxyHelperFailure.operationUnknown.rawValue
        }
        reply(nil, code)
      }
    }
  }

  func status(session: UUID, port: Int, bypass: [String], reply: @escaping (NSDictionary?, String?) -> Void) {
    perform(session, requireConsole: true, reply: reply) {
      try ProxyHelperIdentity.validate(port: port, bypass: bypass)
      return try self.state(port: port, bypass: bypass)
    }
  }

  func apply(session: UUID, port: Int, bypass: [String], reply: @escaping (NSDictionary?, String?) -> Void) {
    perform(session, requireConsole: true, reply: reply) {
      try ProxyHelperIdentity.validate(port: port, bypass: bypass)
      guard !self.draining else { throw ProxyHelperFailure.draining }
      guard !self.owner.restorationPending else { throw ProxyHelperFailure.restoreFailed }
      // Establish lease before entering a write: even a partial failure belongs
      // to this authenticated session until restoration is proven complete.
      self.lease = session
      try self.owner.startProxy(port: port, bypass: bypass) { try self.checkConsole(session) }
      return try self.state(port: port, bypass: bypass)
    }
  }

  func restore(session: UUID, unregister: Bool = false, reply: @escaping (NSDictionary?, String?) -> Void) {
    perform(session, requireConsole: unregister, reply: reply) {
      if unregister { self.draining = true }
      try self.owner.stop(.proxy)
      guard !self.owner.hasOwnedSettings && !self.owner.restorationPending else {
        throw ProxyHelperFailure.restoreFailed
      }
      self.lease = nil
      return try self.state()
    }
  }

  func shutdown(_ completion: @escaping (Bool) -> Void) {
    queue.async {
      self.draining = true
      do {
        // A daemon terminated before the first GUI request still recovers its
        // journal; unregister/termination never silently drops recovery state.
        if !self.recovered { try self.owner.recoverJournal(); self.recovered = true }
        try self.owner.stop(.proxy)
        completion(!self.owner.hasOwnedSettings && !self.owner.restorationPending)
      } catch { completion(false) }
    }
  }
}
