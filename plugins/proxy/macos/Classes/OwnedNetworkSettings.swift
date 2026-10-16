import Foundation

enum NetworkSettingKind: String, Hashable { case proxy, dns }

enum NetworkSettingsFailure: Error {
  case invalidInput, unavailable, changed, writeFailed, restoreFailed
  case authorizationCancelled, authorizationDenied
  case journalFailed
}

enum NetworkSettingsPhase: String { case applying, applied, restoring }

struct NetworkSettingsSnapshot {
  let service: String
  let original: NetworkProtocolState
  var applied: NetworkProtocolState
  var phase: NetworkSettingsPhase
}

/// Only the privileged proxy helper supplies a durable journal. The existing
/// in-process DNS owner intentionally retains its separate authorization scope.
protocol NetworkSettingsJournal: AnyObject {
  func load() throws -> [NetworkSettingKind: NetworkSettingsSnapshot]
  func save(_ snapshots: [NetworkSettingKind: NetworkSettingsSnapshot]) throws
}

struct ObservedProxyState {
  let matches: Bool
  let owned: Bool
  let restorationPending: Bool
  let usesListener: Bool
}

struct NetworkProtocolState: Equatable {
  let configuration: [String: Any]?
  let enabled: Bool

  static func == (lhs: NetworkProtocolState, rhs: NetworkProtocolState) -> Bool {
    guard lhs.enabled == rhs.enabled else { return false }
    switch (lhs.configuration, rhs.configuration) {
    case (nil, nil): return true
    case (let a?, let b?): return NSDictionary(dictionary: a).isEqual(to: b)
    default: return false
    }
  }
}

protocol NetworkSettingsBackend: AnyObject {
  func primaryService() throws -> String
  func read(_ kind: NetworkSettingKind, service: String) throws -> NetworkProtocolState
  func authorize() throws
  func lock() throws
  func unlock()
  func synchronize()
  func set(_ state: NetworkProtocolState, kind: NetworkSettingKind, service: String) throws
  func commit() throws
  func apply() throws
}

/// All operations run on the plugin's serial queue. Snapshots identify the exact
/// service, dictionary (including nil), and protocol enabled state we changed.
final class OwnedNetworkSettings {
  private let backend: NetworkSettingsBackend
  private let journal: NetworkSettingsJournal?
  private var snapshots: [NetworkSettingKind: NetworkSettingsSnapshot] = [:]
  private var journalFailed = false
  private var journalLoaded: Bool

  init(backend: NetworkSettingsBackend, journal: NetworkSettingsJournal? = nil) {
    self.backend = backend
    self.journal = journal
    self.journalLoaded = journal == nil
  }

  var hasOwnedSettings: Bool { !snapshots.isEmpty }
  var restorationPending: Bool {
    journalFailed || snapshots.values.contains { $0.phase != .applied }
  }

  private func persist() throws {
    guard journalLoaded else { throw NetworkSettingsFailure.journalFailed }
    do { try journal?.save(snapshots); journalFailed = false }
    catch { journalFailed = true; throw NetworkSettingsFailure.journalFailed }
  }

  /// A restarted helper must restore its previous transaction before it accepts
  /// a new owner. A corrupt/unreadable journal is an error, never an empty one.
  func recoverJournal() throws {
    guard let journal = journal else { return }
    do { snapshots = try journal.load(); journalLoaded = true; journalFailed = false }
    catch { journalLoaded = false; journalFailed = true; throw NetworkSettingsFailure.journalFailed }
    for kind in Array(snapshots.keys) { try stop(kind) }
  }

  private func proxyConfiguration(_ current: NetworkProtocolState, port: Int,
                                  bypass: [String]) throws -> NetworkProtocolState {
    guard (1024...65535).contains(port), bypass.count <= 256,
          bypass.allSatisfy({ $0.utf8.count <= 1024 && !$0.unicodeScalars.contains(where: {
            $0.value < 32 || $0.value == 127
          }) }) else { throw NetworkSettingsFailure.invalidInput }
    var next = current.configuration ?? [:]
    for prefix in ["HTTP", "HTTPS", "SOCKS"] {
      next["\(prefix)Enable"] = 1
      next["\(prefix)Proxy"] = "127.0.0.1"
      next["\(prefix)Port"] = port
    }
    next["ProxyAutoConfigEnable"] = 0
    next["ProxyAutoDiscoveryEnable"] = 0
    next["ExceptionsList"] = bypass
    return NetworkProtocolState(configuration: next, enabled: true)
  }

  func proxyStatus(port: Int, bypass: [String]) throws -> ObservedProxyState {
    // Validate before any platform read.
    _ = try proxyConfiguration(NetworkProtocolState(configuration: nil, enabled: false), port: port, bypass: bypass)
    guard journalLoaded, !journalFailed else { throw NetworkSettingsFailure.journalFailed }
    let service = try backend.primaryService()
    let current = try backend.read(.proxy, service: service)
    let desired = try proxyConfiguration(current, port: port, bypass: bypass)
    let snapshot = snapshots[.proxy]
    let owned = snapshot != nil
    let exact = snapshot.map { $0.service == service && $0.applied == current && $0.phase == .applied } ?? true
    let configuration = current.configuration ?? [:]
    let loopbacks: Set<String> = ["127.0.0.1", "localhost", "::1", "[::1]"]
    let usesListener = current.enabled && ["HTTP", "HTTPS", "SOCKS"].contains { prefix in
      guard configuration["\(prefix)Enable"] as? Int == 1,
            configuration["\(prefix)Port"] as? Int == port,
            let host = configuration["\(prefix)Proxy"] as? String else { return false }
      return loopbacks.contains(host.lowercased())
    }
    return ObservedProxyState(matches: current == desired && exact,
                              owned: owned, restorationPending: restorationPending,
                              usesListener: usesListener)
  }

  func startProxy(port: Int, bypass: [String], authorizationCheck: () throws -> Void = {}) throws {
    _ = try proxyConfiguration(NetworkProtocolState(configuration: nil, enabled: false), port: port, bypass: bypass)
    try start(.proxy, authorizationCheck: authorizationCheck) { current in
      try self.proxyConfiguration(current, port: port, bypass: bypass)
    }
  }

  func startAutoDns() throws {
    try start(.dns) { current in
      var next = current.configuration ?? [:]
      if let value = next["ServerAddresses"], !(value is [String]) {
        throw NetworkSettingsFailure.unavailable
      }
      var servers = next["ServerAddresses"] as? [String] ?? []
      // Keep the existing auto-DNS resolver and user entries. Matching settings
      // are a no-op, not proof that this application owns them.
      if servers.contains("223.5.5.5") { return nil }
      servers.append("223.5.5.5")
      next["ServerAddresses"] = servers
      return NetworkProtocolState(configuration: next, enabled: true)
    }
  }

  private func start(_ kind: NetworkSettingKind,
                     authorizationCheck: () throws -> Void = {},
                     desired: (NetworkProtocolState) throws -> NetworkProtocolState?) throws {
    guard journalLoaded, !journalFailed, snapshots[kind].map({ $0.phase == .applied }) ?? true else {
      throw NetworkSettingsFailure.restoreFailed
    }
    let service = try backend.primaryService()
    let current = try backend.read(kind, service: service)
    if let previous = snapshots[kind],
       previous.service != service || previous.applied != current {
      throw NetworkSettingsFailure.changed
    }
    guard let next = try desired(current), next != current else { return }
    if journal != nil && snapshots[kind] != nil {
      // Reconfiguration is two complete transactions: restore the old lease,
      // durably clear it, then apply a fresh lease. If publishing the next
      // journal fails after rename but before directory fsync, the OS is already
      // the original baseline, never an unrecorded old applied configuration.
      try stop(kind)
      try start(kind, authorizationCheck: authorizationCheck, desired: desired)
      return
    }
    // Interaction occurs before locking preferences. Recheck after authorization:
    // the user or another network client may have changed settings in the dialog.
    try authorizationCheck()
    try backend.authorize()
    try backend.lock()
    defer { backend.unlock() }
    guard try backend.primaryService() == service,
          try backend.read(kind, service: service) == current else { throw NetworkSettingsFailure.changed }
    try authorizationCheck()
    let previousSnapshot = snapshots[kind]
    var owned = snapshots[kind] ?? NetworkSettingsSnapshot(service: service, original: current,
                                                         applied: current, phase: .applying)
    owned.applied = next
    owned.phase = .applying
    snapshots[kind] = owned
    // Write-ahead: even a crash between commit and apply retains the exact CAS
    // operands needed to recover. No system write follows a failed journal save.
    do { try persist() }
    catch {
      // No system write occurred. Keep the last in-memory CAS operands while
      // retaining journalFailed; a possibly-published next record is safe on
      // restart because reconfiguration already restored its original baseline.
      snapshots[kind] = previousSnapshot
      throw error
    }
    try authorizationCheck()
    do {
      try backend.set(next, kind: kind, service: service)
      try backend.commit()
      try backend.apply()
      owned.phase = .applied
      snapshots[kind] = owned
      try persist()
    } catch {
      do {
        if journal != nil {
          owned.phase = .restoring
          snapshots[kind] = owned
          try persist()
        }
        try backend.set(owned.original, kind: kind, service: service)
        try backend.commit()
        owned.phase = .restoring
        snapshots[kind] = owned
        try backend.apply()
        snapshots[kind] = nil
        try persist()
      } catch {
        backend.synchronize()
      }
      throw NetworkSettingsFailure.writeFailed
    }
  }

  func stop(_ kind: NetworkSettingKind) throws {
    guard journalLoaded else { throw NetworkSettingsFailure.journalFailed }
    // Retrying a failed journal write is allowed only along the safe restoration
    // path. It cannot enable another proxy or silently forget the pending state.
    if journalFailed { try persist() }
    guard var owned = snapshots[kind] else { return }
    let current = try backend.read(kind, service: owned.service)
    if journal == nil && owned.phase == .applied && current == owned.original {
      snapshots[kind] = nil; return
    }
    // A prepared restore may have crashed either side of commit. Both exact
    // operands are safe; a third state is an external edit, and is never written.
    guard current == owned.original || current == owned.applied else {
      snapshots[kind] = nil; try persist(); return
    }
    if journal == nil && current == owned.original && owned.phase != .restoring {
      snapshots[kind] = nil; return
    }
    try backend.authorize()
    try backend.lock()
    defer { backend.unlock() }
    guard try backend.read(kind, service: owned.service) == current else {
      snapshots[kind] = nil
      try persist()
      return
    }
    do {
      owned.phase = .restoring
      snapshots[kind] = owned
      try persist()
      if current != owned.original {
        try backend.set(owned.original, kind: kind, service: owned.service)
        try backend.commit()
      }
      try backend.apply()
      snapshots[kind] = nil
      try persist()
    } catch {
      backend.synchronize()
      throw NetworkSettingsFailure.restoreFailed
    }
  }
}
