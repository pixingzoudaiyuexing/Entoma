import Foundation

private enum TestFailure: Error { case assertion(String), injected }
private func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
  if try !value() { throw TestFailure.assertion(message) }
}
private func expectFailure(_ action: () throws -> Void) throws {
  do { try action() } catch { return }
  throw TestFailure.assertion("expected failure")
}

private final class FakeNetwork: NetworkSettingsBackend {
  var primary = "primary-service"
  var committed: [String: NetworkProtocolState] = [:]
  var staged: [String: NetworkProtocolState] = [:]
  var effective: [String: NetworkProtocolState] = [:]
  var locked = false
  var authorizations = 0
  var locks = 0
  var writes = 0
  var commits = 0
  var applies = 0
  var failAuthorization = false
  var failLock = false
  var failCommits: Set<Int> = []
  var failApplies: Set<Int> = []
  var failWrites: Set<Int> = []
  var onAuthorization: (() -> Void)?
  var onLock: (() -> Void)?

  init(_ initial: NetworkProtocolState, kind: NetworkSettingKind = .proxy) {
    external(initial, kind: kind, service: primary)
  }
  private func key(_ kind: NetworkSettingKind, _ service: String) -> String { "\(service):\(kind.rawValue)" }
  func external(_ state: NetworkProtocolState, kind: NetworkSettingKind, service: String) {
    committed[key(kind, service)] = state
    effective[key(kind, service)] = state
  }
  func current(_ kind: NetworkSettingKind = .proxy, service: String? = nil) throws -> NetworkProtocolState {
    guard let state = committed[key(kind, service ?? primary)] else { throw TestFailure.injected }
    return state
  }
  func active(_ kind: NetworkSettingKind = .proxy) -> NetworkProtocolState? { effective[key(kind, primary)] }
  func primaryService() throws -> String { primary }
  func read(_ kind: NetworkSettingKind, service: String) throws -> NetworkProtocolState {
    guard let state = (locked ? staged : committed)[key(kind, service)] else { throw TestFailure.injected }
    return state
  }
  func authorize() throws {
    authorizations += 1
    if failAuthorization { throw NetworkSettingsFailure.authorizationCancelled }
    onAuthorization?()
  }
  func lock() throws {
    locks += 1
    if failLock { throw TestFailure.injected }
    onLock?()
    staged = committed
    locked = true
  }
  func unlock() { locked = false; staged = committed }
  func synchronize() { staged = committed }
  func set(_ state: NetworkProtocolState, kind: NetworkSettingKind, service: String) throws {
    writes += 1
    try expect(locked, "write requires lock")
    if failWrites.contains(writes) { throw TestFailure.injected }
    staged[key(kind, service)] = state
  }
  func commit() throws {
    commits += 1
    if failCommits.contains(commits) { throw TestFailure.injected }
    committed = staged
  }
  func apply() throws {
    applies += 1
    if failApplies.contains(applies) { throw TestFailure.injected }
    effective = committed
  }
}

@main
private enum NetworkOwnershipTests {
  static func main() throws {
    let tests: [(String, () throws -> Void)] = [
      ("nullable and disabled protocol restoration", {
        for configuration: [String: Any]? in [nil, [:], ["HTTPEnable": 0, "Custom": "preserved"]] {
          for enabled in [true, false] {
            let original = NetworkProtocolState(configuration: configuration, enabled: enabled)
            let backend = FakeNetwork(original)
            let owner = OwnedNetworkSettings(backend: backend)
            try owner.startProxy(port: 17890, bypass: ["localhost"])
            try owner.stop(.proxy)
            try expect(try backend.current() == original && backend.active() == original, "exact baseline")
          }
        }
      }),
      ("matching proxy and unowned stop never authorize or acquire ownership", {
        let source = FakeNetwork(NetworkProtocolState(configuration: nil, enabled: false))
        try OwnedNetworkSettings(backend: source).startProxy(port: 17890, bypass: [])
        let matching = try source.current()
        let backend = FakeNetwork(matching)
        let owner = OwnedNetworkSettings(backend: backend)
        try owner.startProxy(port: 17890, bypass: [])
        try owner.stop(.proxy)
        try owner.stop(.dns)
        try expect(backend.authorizations == 0 && backend.locks == 0 && backend.writes == 0, "no-op has no writes")
        try expect(try backend.current() == matching, "unowned settings preserved")
      }),
      ("external dictionary or enabled-only edits are preserved", {
        for enabledOnly in [true, false] {
          let backend = FakeNetwork(NetworkProtocolState(configuration: [:], enabled: true))
          let owner = OwnedNetworkSettings(backend: backend)
          try owner.startProxy(port: 17890, bypass: [])
          let applied = try backend.current()
          var dictionary = applied.configuration!
          if !enabledOnly { dictionary["HTTPPort"] = 19000 }
          let external = NetworkProtocolState(configuration: dictionary, enabled: !enabledOnly)
          backend.external(external, kind: .proxy, service: backend.primary)
          try owner.stop(.proxy)
          try expect(try backend.current() == external && backend.authorizations == 1, "external edit preserved without authorization")
        }
      }),
      ("repeated start keeps first baseline and skips identical writes", {
        let original = NetworkProtocolState(configuration: ["HTTPEnable": 0], enabled: false)
        let backend = FakeNetwork(original)
        let owner = OwnedNetworkSettings(backend: backend)
        try owner.startProxy(port: 17890, bypass: [])
        try owner.startProxy(port: 17890, bypass: [])
        try expect(backend.authorizations == 1 && backend.writes == 1, "repeat is no-op")
        try owner.startProxy(port: 17891, bypass: [])
        try owner.stop(.proxy)
        try expect(try backend.current() == original, "first baseline restored")
      }),
      ("authorization dialog config and service races never write", {
        for serviceChange in [true, false] {
          let original = NetworkProtocolState(configuration: [:], enabled: true)
          let backend = FakeNetwork(original)
          let owner = OwnedNetworkSettings(backend: backend)
          backend.onAuthorization = {
            if serviceChange { backend.primary = "new-service"; backend.external(original, kind: .proxy, service: backend.primary) }
            else { backend.external(NetworkProtocolState(configuration: ["HTTPPort": 19000], enabled: true), kind: .proxy, service: backend.primary) }
          }
          try expectFailure { try owner.startProxy(port: 17890, bypass: []) }
          try expect(backend.writes == 0, "authorization race rejected")
          try owner.stop(.proxy)
          try expect(backend.authorizations == 1, "race did not acquire ownership")
        }
      }),
      ("authorization cancel and lock failure leave baseline untouched", {
        for cancellation in [true, false] {
          let original = NetworkProtocolState(configuration: nil, enabled: false)
          let backend = FakeNetwork(original)
          backend.failAuthorization = cancellation
          backend.failLock = !cancellation
          let owner = OwnedNetworkSettings(backend: backend)
          try expectFailure { try owner.startProxy(port: 17890, bypass: []) }
          try owner.stop(.proxy)
          try expect(try backend.current() == original && backend.writes == 0, "failed authorization has no writes")
        }
      }),
      ("restore rechecks ownership after authorization", {
        let backend = FakeNetwork(NetworkProtocolState(configuration: [:], enabled: true))
        let owner = OwnedNetworkSettings(backend: backend)
        try owner.startProxy(port: 17890, bypass: [])
        let external = NetworkProtocolState(configuration: ["HTTPPort": 19000], enabled: false)
        backend.onAuthorization = { backend.external(external, kind: .proxy, service: backend.primary) }
        try owner.stop(.proxy)
        try expect(try backend.current() == external && backend.writes == 1, "post-dialog external state preserved")
      }),
      ("network switch restores original service only", {
        let original = NetworkProtocolState(configuration: nil, enabled: false)
        let backend = FakeNetwork(original)
        let service = backend.primary
        let owner = OwnedNetworkSettings(backend: backend)
        try owner.startProxy(port: 17890, bypass: [])
        backend.primary = "new-service"
        let other = NetworkProtocolState(configuration: ["HTTPPort": 19000], enabled: true)
        backend.external(other, kind: .proxy, service: backend.primary)
        try expectFailure { try owner.startProxy(port: 17891, bypass: []) }
        try owner.stop(.proxy)
        try expect(try backend.current(service: service) == original && backend.current() == other, "network switch isolation")
      }),
      ("restore apply failure retries even when committed state is original", {
        let original = NetworkProtocolState(configuration: nil, enabled: false)
        let backend = FakeNetwork(original)
        let owner = OwnedNetworkSettings(backend: backend)
        try owner.startProxy(port: 17890, bypass: [])
        backend.failApplies = [2]
        try expectFailure { try owner.stop(.proxy) }
        try expect(try backend.current() == original && backend.active() != original, "pending effective restore retained")
        try owner.stop(.proxy)
        try expect(backend.applies == 3 && backend.commits == 2 && backend.active() == original, "retry applies without another commit")
      }),
      ("failed start rollback retains pending apply for stop", {
        let original = NetworkProtocolState(configuration: [:], enabled: true)
        let backend = FakeNetwork(original)
        backend.failApplies = [1, 2]
        let owner = OwnedNetworkSettings(backend: backend)
        try expectFailure { try owner.startProxy(port: 17890, bypass: []) }
        try expectFailure { try owner.startProxy(port: 17890, bypass: []) }
        try owner.stop(.proxy)
        try expect(backend.applies == 3 && backend.active() == original, "pending rollback retried")
      }),
      ("restore commit failure retains owned state for retry", {
        let original = NetworkProtocolState(configuration: [:], enabled: true)
        let backend = FakeNetwork(original)
        let owner = OwnedNetworkSettings(backend: backend)
        try owner.startProxy(port: 17890, bypass: [])
        backend.failCommits = [2]
        try expectFailure { try owner.stop(.proxy) }
        try owner.stop(.proxy)
        try expect(try backend.current() == original && backend.active() == original, "failed commit retry")
      }),
      ("failed start with rollback set failure remains restorable", {
        let original = NetworkProtocolState(configuration: nil, enabled: false)
        let backend = FakeNetwork(original)
        backend.failApplies = [1]
        backend.failWrites = [2]
        let owner = OwnedNetworkSettings(backend: backend)
        try expectFailure { try owner.startProxy(port: 17890, bypass: []) }
        try expect(try backend.current() != original, "failed rollback retains committed ownership")
        try owner.stop(.proxy)
        try expect(try backend.current() == original && backend.active() == original, "partial rollback retry")
      }),
      ("failed commits do not claim settings that never changed", {
        let original = NetworkProtocolState(configuration: [:], enabled: false)
        let backend = FakeNetwork(original)
        backend.failCommits = [1, 2]
        let owner = OwnedNetworkSettings(backend: backend)
        try expectFailure { try owner.startProxy(port: 17890, bypass: []) }
        let authorizations = backend.authorizations
        try owner.stop(.proxy)
        try expect(try backend.current() == original && backend.active() == original, "uncommitted settings unchanged")
        try expect(backend.authorizations == authorizations, "unchanged baseline stop is no-op")
      }),
      ("restore authorization cancellation is retryable", {
        let original = NetworkProtocolState(configuration: [:], enabled: false)
        let backend = FakeNetwork(original)
        let owner = OwnedNetworkSettings(backend: backend)
        try owner.startProxy(port: 17890, bypass: [])
        backend.failAuthorization = true
        try expectFailure { try owner.stop(.proxy) }
        backend.failAuthorization = false
        try owner.stop(.proxy)
        try expect(try backend.current() == original, "authorization retry preserves snapshot")
      }),
      ("DNS preserves fields nil and disabled baseline without claiming preexisting resolver", {
        let matching = NetworkProtocolState(configuration: ["ServerAddresses": ["223.5.5.5"], "SearchDomains": ["local"]], enabled: false)
        let existing = FakeNetwork(matching, kind: .dns)
        let unowned = OwnedNetworkSettings(backend: existing)
        try unowned.startAutoDns()
        try unowned.stop(.dns)
        try expect(existing.authorizations == 0 && existing.writes == 0, "preexisting resolver untouched")
        for dictionary: [String: Any]? in [nil, [:], ["ServerAddresses": ["192.0.2.1"], "SearchDomains": ["local"]]] {
          let original = NetworkProtocolState(configuration: dictionary, enabled: false)
          let backend = FakeNetwork(original, kind: .dns)
          let owner = OwnedNetworkSettings(backend: backend)
          try owner.startAutoDns()
          try owner.stop(.dns)
          try expect(try backend.current(.dns) == original && backend.active(.dns) == original, "DNS exact restore")
        }
      }),
      ("proxy and DNS snapshots stay independent", {
        let originalProxy = NetworkProtocolState(configuration: nil, enabled: false)
        let originalDns = NetworkProtocolState(configuration: ["ServerAddresses": ["192.0.2.1"]], enabled: true)
        let backend = FakeNetwork(originalProxy)
        backend.external(originalDns, kind: .dns, service: backend.primary)
        let owner = OwnedNetworkSettings(backend: backend)
        try owner.startProxy(port: 17890, bypass: [])
        try owner.startAutoDns()
        let external = NetworkProtocolState(configuration: ["ServerAddresses": ["192.0.2.2"]], enabled: true)
        backend.external(external, kind: .dns, service: backend.primary)
        try owner.stop(.dns)
        try owner.stop(.proxy)
        try expect(try backend.current(.dns) == external && backend.current(.proxy) == originalProxy, "independent restore ownership")
      }),
      ("input validation does not read or authorize", {
        let backend = FakeNetwork(NetworkProtocolState(configuration: nil, enabled: false))
        let owner = OwnedNetworkSettings(backend: backend)
        try expectFailure { try owner.startProxy(port: 80, bypass: []) }
        try expectFailure { try owner.startProxy(port: 17890, bypass: ["bad\nentry"]) }
        try expect(backend.authorizations == 0 && backend.writes == 0, "invalid input no side effects")
      }),
    ]
    for (name, run) in tests { try run(); print("PASS: \(name)") }
    print("macOS ownership: \(tests.count) tests passed (in-memory backend; no OS settings changed)")
  }
}
