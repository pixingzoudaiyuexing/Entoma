import Foundation
import Darwin
import Security

private enum Failure: Error { case assertion(String), injected }
private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
  if try !condition() { throw Failure.assertion(message) }
}
private func fails(_ action: () throws -> Void) throws {
  do { try action() } catch { return }
  throw Failure.assertion("expected failure")
}

private final class Journal: NetworkSettingsJournal {
  var records: [NetworkSettingKind: NetworkSettingsSnapshot] = [:]
  var failRead = false
  var failWrite = false
  var failSaves = Set<Int>()
  var failAfterPublish = Set<Int>()
  var onSave: (() -> Void)?
  var saves = 0
  func load() throws -> [NetworkSettingKind: NetworkSettingsSnapshot] {
    if failRead { throw Failure.injected }
    return records
  }
  func save(_ snapshots: [NetworkSettingKind: NetworkSettingsSnapshot]) throws {
    saves += 1
    if failWrite || failSaves.contains(saves) { throw Failure.injected }
    records = snapshots
    onSave?()
    if failAfterPublish.contains(saves) { throw Failure.injected }
  }
}

private final class Network: NetworkSettingsBackend {
  var primary = "primary-service"
  var committed: [String: NetworkProtocolState] = [:]
  var staged: [String: NetworkProtocolState] = [:]
  var effective: [String: NetworkProtocolState] = [:]
  var locked = false
  var writes = 0
  var commits = 0
  var applies = 0
  var failApply: Set<Int> = []
  var failCommit: Set<Int> = []
  var onWrite: (() throws -> Void)?
  var onLock: (() -> Void)?
  init(_ baseline: NetworkProtocolState) { external(baseline) }
  func external(_ value: NetworkProtocolState, service: String? = nil) {
    committed[service ?? primary] = value
    effective[service ?? primary] = value
  }
  func primaryService() throws -> String { primary }
  func read(_ kind: NetworkSettingKind, service: String) throws -> NetworkProtocolState {
    guard kind == .proxy, let value = (locked ? staged : committed)[service] else { throw Failure.injected }
    return value
  }
  func authorize() throws {}
  func lock() throws { onLock?(); locked = true; staged = committed }
  func unlock() { locked = false; staged = committed }
  func synchronize() { staged = committed }
  func set(_ state: NetworkProtocolState, kind: NetworkSettingKind, service: String) throws {
    try expect(locked && kind == .proxy, "proxy-only write requires lock")
    try onWrite?()
    writes += 1
    staged[service] = state
  }
  func commit() throws {
    commits += 1
    if failCommit.contains(commits) { throw Failure.injected }
    committed = staged
  }
  func apply() throws {
    applies += 1
    if failApply.contains(applies) { throw Failure.injected }
    effective = committed
  }
}

private let baseline = NetworkProtocolState(configuration: ["ProxyAutoConfigEnable": 1,
  "ProxyAutoConfigURLString": "https://example.invalid/original.pac", "ExceptionsList": ["original.local"],
  "SupplementalMatchDomains": ["private.example"]], enabled: false)

private func outcome(_ issue: (@escaping (NSDictionary?, String?) -> Void) -> Void) throws -> NSDictionary {
  let semaphore = DispatchSemaphore(value: 0)
  var response: NSDictionary?
  var error: String?
  issue { response = $0; error = $1; semaphore.signal() }
  guard semaphore.wait(timeout: .now() + 5) == .success else { throw Failure.assertion("fixture timeout") }
  if let error = error { throw ProxyHelperFailure(rawValue: error) ?? .unavailable }
  guard let response = response else { throw Failure.assertion("missing reply") }
  return response
}

private func withDirectory(_ action: (URL) throws -> Void) throws {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("entoma-helper-fixture-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
  defer { try? FileManager.default.removeItem(at: url) }
  try action(url)
}

private final class LocalIPCFixture: NSObject, NSXPCListenerDelegate, ProxyHelperProtocol {
  enum Mode { case normal, noReply, recoveryFailure, invalidVersion }
  let mode: Mode
  let listener = NSXPCListener.anonymous()
  private let connectionLock = NSLock()
  private var connections: [NSXPCConnection] = []
  private var closing = false
  private var owned = false
  init(mode: Mode) {
    self.mode = mode
    super.init()
    listener.delegate = self
    listener.resume()
  }
  func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
    connectionLock.lock(); defer { connectionLock.unlock() }
    guard !closing else { return false }
    connection.exportedInterface = NSXPCInterface(with: ProxyHelperProtocol.self)
    connection.exportedObject = self
    connections.append(connection)
    connection.resume()
    return true
  }
  private func respond(_ reply: @escaping (NSDictionary?, String?) -> Void) {
    switch mode {
    case .noReply: return
    case .recoveryFailure: reply(nil, ProxyHelperFailure.recoveryRequired.rawValue)
    case .normal, .invalidVersion:
      reply(["available": true, "matches": owned, "owned": owned, "restorationPending": false,
             "protocolVersion": mode == .invalidVersion ? 999 : ProxyHelperIdentity.protocolVersion], nil)
    }
  }
  func status(port: Int, bypass: [String], reply: @escaping (NSDictionary?, String?) -> Void) { respond(reply) }
  func applyProxy(port: Int, bypass: [String], reply: @escaping (NSDictionary?, String?) -> Void) { owned = true; respond(reply) }
  func restoreProxy(reply: @escaping (NSDictionary?, String?) -> Void) { owned = false; respond(reply) }
  func prepareUnregister(reply: @escaping (NSDictionary?, String?) -> Void) { owned = false; respond(reply) }
  @available(macOS 13.0, *)
  func client(timeout: TimeInterval = 2) -> ProxyHelperClient {
    let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
    connection.remoteObjectInterface = NSXPCInterface(with: ProxyHelperProtocol.self)
    connection.resume()
    return ProxyHelperClient(fixtureConnection: connection, timeout: timeout)
  }
  func close() {
    listener.invalidate()
    connectionLock.lock()
    closing = true
    let pending = connections
    connections = []
    connectionLock.unlock()
    for connection in pending { connection.invalidate() }
  }
}

@main
private enum ProxyHelperTests {
  static func main() throws {
    let tests: [(String, () throws -> Void)] = [
      ("strict bounded input and requirement construction", {
        for port in [-1, 0, 80, 65536] { try fails { try ProxyHelperIdentity.validate(port: port, bypass: []) } }
        try fails { try ProxyHelperIdentity.validate(port: 17890, bypass: ["bad\nentry"]) }
        try fails { try ProxyHelperIdentity.validate(port: 17890, bypass: Array(repeating: "a", count: 257)) }
        try fails { try ProxyHelperIdentity.validate(port: 17890, bypass: [String(repeating: "界", count: 400)]) }
        try fails { _ = try ProxyHelperIdentity.requirement(identifier: "other.app", team: "ABCDEFGHIJ") }
        try fails { _ = try ProxyHelperIdentity.requirement(identifier: ProxyHelperIdentity.appIdentifier, team: "bad\"team") }
        let expression = try ProxyHelperIdentity.requirement(identifier: ProxyHelperIdentity.appIdentifier, team: "ABCDEFGHIJ")
        var requirement: SecRequirement?
        try expect(SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
                   "public Security API parses strict requirement")
      }),
      ("unsigned fixture cannot query or register privileged service", {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var raw: CFDictionary?
        try expect(SecCodeCopySelf([], &code) == errSecSuccess, "fixture code identity available")
        try expect(SecCodeCopyStaticCode(code!, [], &staticCode) == errSecSuccess, "fixture static identity available")
        try expect(SecCodeCopySigningInformation(staticCode!, SecCSFlags(rawValue: kSecCSSigningInformation), &raw) == errSecSuccess,
                   "fixture signature information available")
        let info = raw! as NSDictionary
        try expect(info[kSecCodeInfoIdentifier] as? String == ProxyHelperIdentity.appIdentifier, "real GUI identifier is present")
        let flags = info[kSecCodeInfoFlags] as? NSNumber
        try expect((flags?.uint32Value ?? 0) & UInt32(SecCodeSignatureFlags.adhoc.rawValue) != 0,
                   "negative signing test really uses an ad-hoc signature")
        try fails { _ = try ProxyHelperIdentity.ownTeam(expectedIdentifier: ProxyHelperIdentity.appIdentifier) }
        if #available(macOS 13.0, *) {
          let client = ProxyHelperClient()
          for action in [{ _ = try client.registrationStatus() }, { _ = try client.register() },
                         { _ = try client.status(port: 17890, bypass: []) }, { _ = try client.apply(port: 17890, bypass: []) }] {
            do { try action(); throw Failure.assertion("unsigned operation accepted") }
            catch ProxyHelperFailure.signingRequired {} // no register call is reached
          }
          try expect(!client.needsRestoration, "preflight failure acquired no resources")
        }
      }),
      ("real anonymous XPC status apply restore acknowledgement", {
        if #available(macOS 13.0, *) {
          let fixture = LocalIPCFixture(mode: .normal)
          defer { fixture.close() }
          let client = fixture.client()
          let initial = try client.status(port: 17890, bypass: [])
          try expect(initial["owned"] as? Bool == false && !client.needsRestoration, "read alone owns no resources")
          _ = try client.apply(port: 17890, bypass: [])
          try expect(client.needsRestoration, "successful mutation requires restoration")
          _ = try client.restore()
          try expect(!client.needsRestoration, "actual restore reply clears local pending state")
        }
      }),
      ("real XPC timeout recovery error and invalid version retain unknown ownership", {
        if #available(macOS 13.0, *) {
          for mode in [LocalIPCFixture.Mode.noReply, .recoveryFailure, .invalidVersion] {
            let fixture = LocalIPCFixture(mode: mode)
            defer { fixture.close() }
            let client = fixture.client(timeout: 0.2)
            try fails { _ = try client.status(port: 17890, bypass: []) }
            try expect(client.needsRestoration, "connected status UNKNOWN cannot take unowned stop path")
            try fails { _ = try client.restore() }
            try expect(client.needsRestoration, "failed restoration cannot clear unknown state")
          }
        }
      }),
      ("journal load is mandatory and corrupt read cannot be overwritten", {
        let network = Network(baseline), journal = Journal()
        let owner = OwnedNetworkSettings(backend: network, journal: journal)
        try fails { try owner.startProxy(port: 17890, bypass: []) }
        journal.failRead = true
        try fails { try owner.recoverJournal() }
        try fails { try owner.stop(.proxy) }
        try fails { _ = try owner.proxyStatus(port: 17890, bypass: []) }
        try expect(journal.saves == 0 && network.writes == 0, "unknown journal is never cleared or treated as empty")
      }),
      ("write-ahead phases precede each system write", {
        let network = Network(baseline), journal = Journal()
        let owner = OwnedNetworkSettings(backend: network, journal: journal)
        try owner.recoverJournal()
        network.onWrite = {
          let expected: NetworkSettingsPhase = network.writes == 0 ? .applying : .restoring
          try expect(journal.records[.proxy]?.phase == expected, "durable intent precedes write")
        }
        try owner.startProxy(port: 17890, bypass: ["localhost"])
        try expect(journal.records[.proxy]?.phase == .applied, "applied phase acknowledged")
        try owner.stop(.proxy)
        try expect(journal.records.isEmpty && network.effective[network.primary] == baseline, "durable clear after effective restore")
      }),
      ("journal save failure prevents apply and retains retryable intent", {
        let network = Network(baseline), journal = Journal()
        let owner = OwnedNetworkSettings(backend: network, journal: journal)
        try owner.recoverJournal()
        journal.failWrite = true
        try fails { try owner.startProxy(port: 17890, bypass: []) }
        try expect(network.writes == 0 && owner.restorationPending, "no write after failed journal")
        journal.failWrite = false
        try owner.stop(.proxy)
        try expect(!owner.hasOwnedSettings && journal.records.isEmpty, "safe retry preserves baseline")
      }),
      ("owned A to B save failure restores baseline before publishing B", {
        for afterPublish in [false, true] {
          let network = Network(baseline), journal = Journal()
          let owner = OwnedNetworkSettings(backend: network, journal: journal)
          try owner.recoverJournal(); try owner.startProxy(port: 17890, bypass: [])
          // Reconfigure must first save restoring A, then empty, then prepare B.
          let preparingB = journal.saves + 3
          if afterPublish { journal.failAfterPublish = [preparingB] }
          else { journal.failSaves = [preparingB] }
          try fails { try owner.startProxy(port: 17891, bypass: []) }
          try expect(network.effective[network.primary] == baseline && owner.restorationPending,
                     "failed B publication cannot leave old A applied but unrecorded")
          if afterPublish {
            try expect(journal.records[.proxy]?.applied.configuration?["HTTPPort"] as? Int == 17891,
                       "fault really occurs after next record publication")
            let restarted = OwnedNetworkSettings(backend: network, journal: journal)
            try restarted.recoverJournal()
            try expect(network.effective[network.primary] == baseline && journal.records.isEmpty,
                       "restart after rename-before-fsync failure safely restores baseline")
          }
          journal.failSaves = []; journal.failAfterPublish = []
          try owner.stop(.proxy)
          try expect(network.effective[network.primary] == baseline && journal.records.isEmpty && !owner.restorationPending,
                     "same-process stop cannot clear journal and leave A stranded")
        }
      }),
      ("helper restart restores full PAC bypass enabled and nil baselines", {
        for configuration: [String: Any]? in [nil, [:], baseline.configuration] {
          for enabled in [false, true] {
            let original = NetworkProtocolState(configuration: configuration, enabled: enabled)
            let network = Network(original), journal = Journal()
            let old = OwnedNetworkSettings(backend: network, journal: journal)
            try old.recoverJournal(); try old.startProxy(port: 17890, bypass: ["localhost"])
            let restarted = OwnedNetworkSettings(backend: network, journal: journal)
            try restarted.recoverJournal()
            try expect(network.committed[network.primary] == original && network.effective[network.primary] == original,
                       "exact restart restoration")
            try expect(journal.records.isEmpty, "recovery durably completed")
          }
        }
      }),
      ("crash either side of commit retries pending effective apply", {
        for phase in [NetworkSettingsPhase.applying, .applied, .restoring] {
          for currentIsOriginal in [true, false] {
            let network = Network(baseline), journal = Journal()
            let owner = OwnedNetworkSettings(backend: network, journal: journal)
            try owner.recoverJournal(); try owner.startProxy(port: 17890, bypass: [])
            let applied = network.committed[network.primary]!
            journal.records[.proxy]?.phase = phase
            network.committed[network.primary] = currentIsOriginal ? baseline : applied
            network.effective[network.primary] = applied
            let restarted = OwnedNetworkSettings(backend: network, journal: journal)
            try restarted.recoverJournal()
            try expect(network.effective[network.primary] == baseline && journal.records.isEmpty,
                       "interrupted commit/apply must not clear before effective apply")
          }
        }
      }),
      ("restore failure remains journaled across restart", {
        let network = Network(baseline), journal = Journal()
        let owner = OwnedNetworkSettings(backend: network, journal: journal)
        try owner.recoverJournal(); try owner.startProxy(port: 17890, bypass: [])
        network.failApply = [2]
        try fails { try owner.stop(.proxy) }
        try expect(journal.records[.proxy]?.phase == .restoring && owner.restorationPending, "failed effective restore retained")
        let restarted = OwnedNetworkSettings(backend: network, journal: journal)
        try restarted.recoverJournal()
        try expect(network.effective[network.primary] == baseline && !restarted.hasOwnedSettings, "restart retries actual apply")
      }),
      ("restore commit failure preserves applied operand for restart", {
        let network = Network(baseline), journal = Journal()
        let owner = OwnedNetworkSettings(backend: network, journal: journal)
        try owner.recoverJournal(); try owner.startProxy(port: 17890, bypass: [])
        let applied = network.effective[network.primary]
        network.failCommit = [2]
        try fails { try owner.stop(.proxy) }
        try expect(network.effective[network.primary] == applied && journal.records[.proxy]?.phase == .restoring,
                   "failed commit does not lose restoration operand")
        let restarted = OwnedNetworkSettings(backend: network, journal: journal)
        try restarted.recoverJournal()
        try expect(network.effective[network.primary] == baseline && journal.records.isEmpty, "commit failure safely retried")
      }),
      ("external dictionary enabled and network-service changes preserve third-party settings", {
        for change in ["dictionary", "enabled", "service"] {
          let network = Network(baseline), journal = Journal()
          let owner = OwnedNetworkSettings(backend: network, journal: journal)
          try owner.recoverJournal(); try owner.startProxy(port: 17890, bypass: [])
          let oldService = network.primary
          var dictionary = network.committed[oldService]!.configuration!
          dictionary["ProxyAutoConfigURLString"] = "https://example.invalid/external.pac"
          let external = NetworkProtocolState(configuration: dictionary, enabled: change != "enabled")
          if change == "service" { network.primary = "other-service" }
          network.external(external)
          let restarted = OwnedNetworkSettings(backend: network, journal: journal)
          try restarted.recoverJournal()
          try expect(network.effective[network.primary] == external, "external modification preserved")
          if change == "service" { try expect(network.effective[oldService] == baseline, "old service restored separately") }
        }
      }),
      ("status requires full snapshot match and requested port bypass", {
        let network = Network(baseline), journal = Journal()
        let owner = OwnedNetworkSettings(backend: network, journal: journal)
        try owner.recoverJournal(); try owner.startProxy(port: 17890, bypass: ["localhost"])
        try expect(try owner.proxyStatus(port: 17890, bypass: ["localhost"]).matches, "exact applied readback")
        try expect(try !owner.proxyStatus(port: 17891, bypass: ["localhost"]).matches, "port mismatch")
        try expect(try !owner.proxyStatus(port: 17890, bypass: []).matches, "bypass mismatch")
        var changed = network.committed[network.primary]!.configuration!
        changed["UnrelatedExternalField"] = true
        network.external(NetworkProtocolState(configuration: changed, enabled: true))
        try expect(try !owner.proxyStatus(port: 17890, bypass: ["localhost"]).matches, "full dictionary mismatch")
      }),
      ("external same-port proxy still uses listener after ownership is released", {
        let network = Network(baseline), journal = Journal()
        let owner = OwnedNetworkSettings(backend: network, journal: journal)
        try owner.recoverJournal(); try owner.startProxy(port: 17890, bypass: ["localhost"])
        var external = network.committed[network.primary]!.configuration!
        external["ExceptionsList"] = ["externally.changed"]
        network.external(NetworkProtocolState(configuration: external, enabled: true))
        let before = try owner.proxyStatus(port: 17890, bypass: ["localhost"])
        try expect(!before.matches && before.owned && before.usesListener, "external bypass change does not hide listener use")
        try owner.stop(.proxy)
        let after = try owner.proxyStatus(port: 17890, bypass: ["localhost"])
        try expect(!after.matches && !after.owned && after.usesListener, "retained external settings still need core")
        try expect(network.effective[network.primary]?.configuration?["ExceptionsList"] as? [String] == ["externally.changed"],
                   "stop did not overwrite external settings")
        let coordinator = ProxyHelperCoordinator(owner: owner)
        let session = UUID()
        coordinator.opened(session)
        let readback = try outcome { coordinator.status(session: session, port: 17890, bypass: ["localhost"], reply: $0) }
        try expect(readback["usesListener"] as? Bool == true && readback["owned"] as? Bool == false,
                   "helper status maps the independently observed listener use")
        let restored = try outcome { coordinator.restore(session: session, reply: $0) }
        try expect(restored["usesListener"] == nil, "portless restore does not invent a listener result")
      }),
      ("listener observation checks each protocol host port and enabled state", {
        for prefix in ["HTTP", "HTTPS", "SOCKS"] {
          for host in ["127.0.0.1", "localhost", "LOCALHOST", "::1", "[::1]"] {
            let dictionary: [String: Any] = ["\(prefix)Enable": 1, "\(prefix)Proxy": host,
                                            "\(prefix)Port": 17890, "ExceptionsList": ["different"]]
            let network = Network(NetworkProtocolState(configuration: dictionary, enabled: true))
            let owner = OwnedNetworkSettings(backend: network)
            let status = try owner.proxyStatus(port: 17890, bypass: [])
            try expect(status.usesListener && !status.owned && !status.matches, "partial external proxy conservatively keeps listener")
            try expect(try !owner.proxyStatus(port: 17891, bypass: []).usesListener, "different port does not retain core")
            network.external(NetworkProtocolState(configuration: dictionary, enabled: false))
            try expect(try !owner.proxyStatus(port: 17890, bypass: []).usesListener, "disabled protocol does not use listener")
            var disabled = dictionary; disabled["\(prefix)Enable"] = 0
            network.external(NetworkProtocolState(configuration: disabled, enabled: true))
            try expect(try !owner.proxyStatus(port: 17890, bypass: []).usesListener, "disabled proxy kind does not use listener")
            var remote = dictionary; remote["\(prefix)Proxy"] = "proxy.example.invalid"
            network.external(NetworkProtocolState(configuration: remote, enabled: true))
            try expect(try !owner.proxyStatus(port: 17890, bypass: []).usesListener, "non-loopback proxy is not our listener")
          }
        }
      }),
      ("single lease blocks competing client and disconnect restores before next apply", {
        let network = Network(baseline), journal = Journal()
        let coordinator = ProxyHelperCoordinator(owner: OwnedNetworkSettings(backend: network, journal: journal))
        let first = UUID(), second = UUID()
        coordinator.opened(first); coordinator.opened(second)
        _ = try outcome { coordinator.apply(session: first, port: 17890, bypass: [], reply: $0) }
        try fails { _ = try outcome { coordinator.apply(session: second, port: 17891, bypass: [], reply: $0) } }
        coordinator.closed(first)
        let after = try outcome { coordinator.status(session: second, port: 17890, bypass: [], reply: $0) }
        try expect(after["owned"] as? Bool == false && network.effective[network.primary] == baseline, "disconnect restored before new session")
        _ = try outcome { coordinator.apply(session: second, port: 17891, bypass: [], reply: $0) }
        _ = try outcome { coordinator.restore(session: second, reply: $0) }
      }),
      ("late disconnected session and unregister drain cannot restart proxy", {
        let network = Network(baseline)
        let coordinator = ProxyHelperCoordinator(owner: OwnedNetworkSettings(backend: network))
        let session = UUID()
        coordinator.opened(session)
        _ = try outcome { coordinator.apply(session: session, port: 17890, bypass: [], reply: $0) }
        let prepared = try outcome { coordinator.restore(session: session, unregister: true, reply: $0) }
        try expect(prepared["owned"] as? Bool == false && prepared["draining"] as? Bool == true, "restore acknowledgment precedes unregister")
        let writes = network.writes
        try fails { _ = try outcome { coordinator.apply(session: session, port: 17890, bypass: [], reply: $0) } }
        coordinator.closed(session)
        try fails { _ = try outcome { coordinator.status(session: session, port: 17890, bypass: [], reply: $0) } }
        try expect(network.writes == writes && network.effective[network.primary] == baseline,
                   "rejected late apply cannot modify the restored network")
      }),
      ("failed unregister preparation keeps drain and forbids new apply", {
        let network = Network(baseline), journal = Journal()
        let coordinator = ProxyHelperCoordinator(owner: OwnedNetworkSettings(backend: network, journal: journal))
        let session = UUID()
        coordinator.opened(session)
        _ = try outcome { coordinator.apply(session: session, port: 17890, bypass: [], reply: $0) }
        network.failApply = [2]
        try fails { _ = try outcome { coordinator.restore(session: session, unregister: true, reply: $0) } }
        let failed = try outcome { coordinator.status(session: session, port: 17890, bypass: [], reply: $0) }
        try expect(failed["restorationPending"] as? Bool == true && failed["draining"] as? Bool == true,
                   "no false unregister readiness")
        try fails { _ = try outcome { coordinator.apply(session: session, port: 17890, bypass: [], reply: $0) } }
        let retried = try outcome { coordinator.restore(session: session, unregister: true, reply: $0) }
        try expect(retried["owned"] as? Bool == false && network.effective[network.primary] == baseline, "safe preparation retry")
      }),
      ("disconnect restoration failure prevents another owner until recovery", {
        let network = Network(baseline), journal = Journal()
        let coordinator = ProxyHelperCoordinator(owner: OwnedNetworkSettings(backend: network, journal: journal))
        let first = UUID(), second = UUID()
        coordinator.opened(first); coordinator.opened(second)
        _ = try outcome { coordinator.apply(session: first, port: 17890, bypass: [], reply: $0) }
        network.failApply = [2, 3]
        coordinator.closed(first)
        try fails { _ = try outcome { coordinator.apply(session: second, port: 17891, bypass: [], reply: $0) } }
        try expect(journal.records[.proxy]?.phase == .restoring, "failed restore remains durable")
        network.failApply = []
        _ = try outcome { coordinator.apply(session: second, port: 17891, bypass: [], reply: $0) }
        _ = try outcome { coordinator.restore(session: second, reply: $0) }
      }),
      ("console switch revokes old session apply and status but permits owned restore", {
        let network = Network(baseline), journal = Journal()
        var console: uid_t? = 501
        let coordinator = ProxyHelperCoordinator(owner: OwnedNetworkSettings(backend: network, journal: journal), consoleUser: { console })
        let old = UUID(), current = UUID()
        coordinator.opened(old, user: 501)
        _ = try outcome { coordinator.apply(session: old, port: 17890, bypass: [], reply: $0) }
        let writes = network.writes
        console = 502
        try fails { _ = try outcome { coordinator.status(session: old, port: 17890, bypass: [], reply: $0) } }
        try fails { _ = try outcome { coordinator.apply(session: old, port: 17891, bypass: [], reply: $0) } }
        try fails { _ = try outcome { coordinator.restore(session: old, unregister: true, reply: $0) } }
        try expect(network.writes == writes, "old connection cannot mutate new console settings")
        _ = try outcome { coordinator.restore(session: old, reply: $0) }
        try expect(network.effective[network.primary] == baseline, "old owner can finish CAS cleanup")
        coordinator.opened(current, user: 502)
        _ = try outcome { coordinator.apply(session: current, port: 17891, bypass: [], reply: $0) }
        _ = try outcome { coordinator.restore(session: current, reply: $0) }
      }),
      ("console is rechecked after lock and journal wait before actual apply", {
        for timing in ["lock", "journal"] {
          let network = Network(baseline), journal = Journal()
          var console: uid_t? = 501
          let coordinator = ProxyHelperCoordinator(owner: OwnedNetworkSettings(backend: network, journal: journal), consoleUser: { console })
          let old = UUID()
          coordinator.opened(old, user: 501)
          if timing == "lock" { network.onLock = { console = 502 } }
          else { journal.onSave = { console = 502 } }
          try fails { _ = try outcome { coordinator.apply(session: old, port: 17890, bypass: [], reply: $0) } }
          try expect(network.writes == 0 && network.effective[network.primary] == baseline,
                     "a delayed old-user apply is rejected at write boundary")
          _ = try outcome { coordinator.restore(session: old, reply: $0) }
          try expect(journal.records.isEmpty, "old user may clean a prepared but unapplied transaction")
        }
      }),
      ("real file journal round-trip lock private mode and strict schema", {
        try withDirectory { directory in
          let store = try SecureProxyJournal.fixture(directory: directory)
          try fails { _ = try SecureProxyJournal.fixture(directory: directory) }
          let network = Network(baseline)
          let owner = OwnedNetworkSettings(backend: network, journal: store)
          try owner.recoverJournal(); try owner.startProxy(port: 17890, bypass: ["localhost"])
          let record = try store.load()[.proxy]
          try expect(record?.original == baseline && record?.phase == .applied, "real FD/plist roundtrip")
          let attrs = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("proxy-journal.plist").path)
          try expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600, "private journal mode")
          try owner.stop(.proxy)
          try expect(try store.load().isEmpty, "durable empty tombstone")
          try Data("not a journal".utf8).write(to: directory.appendingPathComponent("proxy-journal.plist"))
          try fails { _ = try store.load() }
          let untouched = try Data(contentsOf: directory.appendingPathComponent("proxy-journal.plist"))
          let restarted = OwnedNetworkSettings(backend: network, journal: store)
          try fails { try restarted.recoverJournal() }
          try fails { try restarted.stop(.proxy) }
          try expect(try Data(contentsOf: directory.appendingPathComponent("proxy-journal.plist")) == untouched, "corrupt record not overwritten")
        }
      }),
      ("symlink hardlink and loose-mode entries rejected without following targets", {
        try withDirectory { directory in
          let target = directory.appendingPathComponent("unrelated.txt")
          try Data("fixture sentinel".utf8).write(to: target)
          let path = directory.appendingPathComponent("proxy-journal.plist")
          let store = try SecureProxyJournal.fixture(directory: directory)
          try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target)
          try fails { _ = try store.load() }
          try fails { try store.save([:]) }
          try expect(try String(contentsOf: target, encoding: .utf8) == "fixture sentinel", "symlink target untouched")
          try FileManager.default.removeItem(at: path)
          try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
          try FileManager.default.linkItem(at: target, to: path)
          try fails { _ = try store.load() }
          try FileManager.default.removeItem(at: path)
          try Data("bad".utf8).write(to: path)
          try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)
          try fails { _ = try store.load() }
        }
        try withDirectory { directory in
          let target = directory.appendingPathComponent("unrelated.txt")
          try Data("lock sentinel".utf8).write(to: target)
          try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("owner.lock"), withDestinationURL: target)
          try fails { _ = try SecureProxyJournal.fixture(directory: directory) }
          try expect(try String(contentsOf: target, encoding: .utf8) == "lock sentinel", "lock symlink target untouched")
        }
      }),
      ("FIFO and directory symlink reject without blocking or following", {
        try withDirectory { directory in
          let store = try SecureProxyJournal.fixture(directory: directory)
          let path = directory.appendingPathComponent("proxy-journal.plist")
          try expect(mkfifo(path.path, 0o600) == 0, "fixture FIFO created")
          try fails { _ = try store.load() }
          try fails { try store.save([:]) }
          let alias = directory.appendingPathComponent("alias")
          try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
          try fails { _ = try SecureProxyJournal.fixture(directory: alias) }
        }
      }),
      ("throwing journal init never double-closes a reused real FD", {
        for fault in ["busy", "unsafe"] {
          try withDirectory { directory in
            let sentinel = directory.appendingPathComponent("descriptor-identity.txt")
            try Data("identity sentinel".utf8).write(to: sentinel)
            let source = open(sentinel.path, O_RDONLY | O_CLOEXEC)
            try expect(source >= 0, "sentinel FD open")
            defer { close(source) }
            var expected = stat()
            try expect(fstat(source, &expected) == 0, "sentinel identity captured")
            var first: SecureProxyJournal?
            if fault == "busy" { first = try SecureProxyJournal.fixture(directory: directory) }
            else { try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("owner.lock"), withDestinationURL: sentinel) }
            var reused: [Int32] = []
            SecureProxyJournal.fixtureAfterFailedInitCleanup = { descriptors in
              for descriptor in descriptors {
                if dup2(source, descriptor) == descriptor { reused.append(descriptor) }
              }
            }
            defer {
              SecureProxyJournal.fixtureAfterFailedInitCleanup = nil
              for descriptor in reused { close(descriptor) }
              first = nil
            }
            try fails { _ = try SecureProxyJournal.fixture(directory: directory) }
            SecureProxyJournal.fixtureAfterFailedInitCleanup = nil
            try expect(reused.count == (fault == "busy" ? 2 : 1), "closed constructor descriptors actually reused before unwind")
            for descriptor in reused {
              var actual = stat()
              try expect(fstat(descriptor, &actual) == 0 && actual.st_dev == expected.st_dev && actual.st_ino == expected.st_ino,
                         "deinit must not close the new identity occupying a former local FD")
            }
            if let first = first {
              for descriptor in first.fixtureDescriptors { try expect(fcntl(descriptor, F_GETFD) != -1, "live owner FDs remain valid") }
            }
          }
        }
      }),
    ]
    for (name, test) in tests {
      do { try test(); print("PASS: \(name)"); fflush(stdout) }
      catch { fputs("FAIL: \(name): \(error)\n", stderr); exit(1) }
    }
    print("macOS proxy helper: \(tests.count) fixture groups passed; no service registration or OS network settings changed.")
  }
}
