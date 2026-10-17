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
  private let acceptedRequirement: String?
  init(mode: Mode, requirement: String? = nil) {
    self.mode = mode
    self.acceptedRequirement = requirement
    super.init()
    if #available(macOS 13.0, *), let requirement = requirement {
      listener.setConnectionCodeSigningRequirement(requirement)
    }
    listener.delegate = self
    listener.resume()
  }
  func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
    connectionLock.lock(); defer { connectionLock.unlock() }
    guard !closing else { return false }
    if #available(macOS 13.0, *), let requirement = acceptedRequirement {
      connection.setCodeSigningRequirement(requirement)
    }
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
  func client(timeout: TimeInterval = 2, management: ((String) throws -> Void)? = nil) -> ProxyHelperClient {
    let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
    connection.remoteObjectInterface = NSXPCInterface(with: ProxyHelperProtocol.self)
    connection.resume()
    return ProxyHelperClient(fixtureConnection: connection, timeout: timeout, management: management)
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

private final class ServiceFixture: ProxyHelperServiceBackend {
  var events: [String] = []
  var fail: Set<String> = []
  func step(_ event: String) throws { events.append(event); if fail.contains(event) { throw Failure.injected } }
  func stage() throws { try step("stage") }
  func stop() throws { try step("stop") }
  func recover() throws { try step("recover") }
  func publish() throws { try step("publish") }
  func start() throws { try step("start") }
  func rollback() throws { try step("rollback") }
  func commit() throws { try step("commit") }
  func remove() throws { try step("remove") }
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
        try fails { _ = try ProxyHelperIdentity.requirement(identifier: "other.app", hashes: [String(repeating: "a", count: 40)]) }
        try fails { _ = try ProxyHelperIdentity.requirement(identifier: ProxyHelperIdentity.appIdentifier, hashes: ["bad\"hash"]) }
        let expression = try ProxyHelperIdentity.requirement(identifier: ProxyHelperIdentity.appIdentifier, hashes: [String(repeating: "a", count: 40)])
        var requirement: SecRequirement?
        try expect(SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
                   "public Security API parses pinned requirement")
      }),
      ("ad-hoc installation identity is accepted but forged identifiers and hashes are rejected", {
        let url = URL(fileURLWithPath: CommandLine.arguments[0])
        let hashes = try ProxyHelperIdentity.hashes(at: url, identifier: ProxyHelperIdentity.appIdentifier)
        try expect(!hashes.isEmpty, "real ad-hoc code must be usable without Developer ID")
        try expect(hashes.contains(ProxyHelperIdentity.runningHash(identifier: ProxyHelperIdentity.appIdentifier)), "pin belongs to running GUI, not only its path")
        try fails { _ = try ProxyHelperIdentity.hashes(at: url, identifier: ProxyHelperIdentity.helperIdentifier) }
        var code: SecStaticCode?
        try expect(SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, "fixture identity available")
        let wrong = try ProxyHelperIdentity.requirement(identifier: ProxyHelperIdentity.appIdentifier, hashes: [String(repeating: "0", count: 40)])
        var requirement: SecRequirement?
        try expect(SecRequirementCreateWithString(wrong as CFString, [], &requirement) == errSecSuccess, "wrong pin parses")
        try expect(SecStaticCodeCheckValidity(code!, [], requirement) != errSecSuccess, "same identifier with wrong approved pin rejected")
        let receipt = ProxyHelperReceipt(version: ProxyHelperIdentity.protocolVersion, appHashes: [hashes[0]], helperHashes: [hashes[0]])
        try receipt.validate()
        try fails { try ProxyHelperReceipt(version: 999, appHashes: hashes, helperHashes: hashes).validate() }
        try fails { try ProxyHelperReceipt(version: ProxyHelperIdentity.protocolVersion, appHashes: [hashes[0], String(repeating: "a", count: 40)], helperHashes: [hashes[0]]).validate() }
      }),
      ("local ad-hoc GUI loads its dylib with explicit entitlement while root helper rejects that entitlement", {
        try withDirectory { directory in
          func run(_ arguments: [String]) throws -> Int32 {
            let task = Process(); task.executableURL = URL(fileURLWithPath: arguments[0]); task.arguments = Array(arguments.dropFirst())
            task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
            try task.run(); task.waitUntilExit(); return task.terminationStatus
          }
          let library = directory.appendingPathComponent("fixture.dylib")
          let loader = directory.appendingPathComponent("loader")
          let librarySource = directory.appendingPathComponent("library.c")
          let loaderSource = directory.appendingPathComponent("loader.c")
          try "int entoma_fixture(void) { return 42; }\n".write(to: librarySource, atomically: true, encoding: .utf8)
          try "#include <dlfcn.h>\nint main(int n,char **v) { void *p=dlopen(v[1],RTLD_NOW); if(!p) return 1; int (*f)(void)=dlsym(p,\"entoma_fixture\"); return !f || f()!=42; }\n".write(to: loaderSource, atomically: true, encoding: .utf8)
          try expect(run(["/usr/bin/xcrun", "clang", "-dynamiclib", librarySource.path, "-o", library.path]) == 0, "owned dylib compile")
          try expect(run(["/usr/bin/xcrun", "clang", loaderSource.path, "-o", loader.path]) == 0, "owned loader compile")
          for target in [library, loader] {
            try expect(run(["/usr/bin/codesign", "--force", "--options", "runtime", "--sign", "-", "--identifier", ProxyHelperIdentity.appIdentifier, target.path]) == 0, "ad-hoc runtime sign")
          }
          let baselineLoad = try run([loader.path, library.path])
          // macOS releases and hosted-runner policy differ. The Owner Mac's
          // rejection is preserved separately; do not invent it on permissive
          // runners. The positive load and privileged-policy rejection below
          // must pass on every host.
          print("INFO: host ad-hoc dylib baseline exit=\(baselineLoad)")
          let entitlements = directory.appendingPathComponent("local.entitlements")
          try PropertyListSerialization.data(fromPropertyList: ["com.apple.security.cs.disable-library-validation": true], format: .xml, options: 0).write(to: entitlements)
          try expect(run(["/usr/bin/codesign", "--force", "--options", "runtime", "--sign", "-", "--entitlements", entitlements.path, "--identifier", ProxyHelperIdentity.appIdentifier, loader.path]) == 0, "sign explicit local GUI permission")
          try expect(run([loader.path, library.path]) == 0, "local GUI actually loads/executes owned dylib")
          _ = try ProxyHelperIdentity.hashes(at: loader, identifier: ProxyHelperIdentity.appIdentifier)
          try expect(run(["/usr/bin/codesign", "--force", "--options", "runtime", "--sign", "-", "--entitlements", entitlements.path, "--identifier", ProxyHelperIdentity.helperIdentifier, loader.path]) == 0, "root rejection fixture sign")
          try fails { _ = try ProxyHelperIdentity.hashes(at: loader, identifier: ProxyHelperIdentity.helperIdentifier) }
        }
      }),
      ("real XPC authenticates approved ad-hoc code and rejects a wrong pin", {
        if #available(macOS 13.0, *) {
          let hashes = try ProxyHelperIdentity.hashes(at: URL(fileURLWithPath: CommandLine.arguments[0]), identifier: ProxyHelperIdentity.appIdentifier)
          let accepted = try ProxyHelperIdentity.requirement(identifier: ProxyHelperIdentity.appIdentifier, hashes: hashes)
          let good = LocalIPCFixture(mode: .normal, requirement: accepted)
          defer { good.close() }
          let goodClient = good.client()
          try expect(goodClient.status(port: 17890, bypass: [])["available"] as? Bool == true, "approved caller gets real reply")
          let rejected = try ProxyHelperIdentity.requirement(identifier: ProxyHelperIdentity.appIdentifier, hashes: [String(repeating: "0", count: 40)])
          let bad = LocalIPCFixture(mode: .normal, requirement: rejected)
          defer { bad.close() }
          let badClient = bad.client(timeout: 0.2)
          try fails { _ = try badClient.apply(port: 17890, bypass: []) }
        }
      }),
      ("interrupted install and uninstall select durable previous state without resurrecting inert backups", {
        let old = Data("old".utf8), new = Data("new".utf8)
        for operation in ["install", "uninstall"] {
          for previous in [true, false] {
            let marker = try PropertyListSerialization.data(fromPropertyList: ["operation": operation, "hadPrevious": previous], format: .binary, options: 0)
            for binary in [nil, new] as [Data?] {
              for receipt in [nil, new] as [Data?] {
                let plan = try ProxyHelperRecoveryPlan(currentBinary: binary, currentReceipt: receipt,
                  previousBinary: old, previousReceipt: old, transaction: marker)
                try expect(plan.binary == (previous ? old : nil) && plan.receipt == (previous ? old : nil), "marker selects intended prior state")
                try expect(plan.permitsPartialEmptyState == !previous, "both operation kinds can recover an empty old state")
              }
            }
          }
        }
        let committed = try ProxyHelperRecoveryPlan(currentBinary: new, currentReceipt: new, previousBinary: old, previousReceipt: old, transaction: nil)
        try expect(committed.binary == new, "completed install ignores inert backup")
        try fails { _ = try ProxyHelperRecoveryPlan(currentBinary: new, currentReceipt: nil, previousBinary: old, previousReceipt: old, transaction: nil) }
        let malformed = try PropertyListSerialization.data(fromPropertyList: ["operation": "exec", "hadPrevious": false], format: .binary, options: 0)
        try fails { _ = try ProxyHelperRecoveryPlan(currentBinary: nil, currentReceipt: nil, previousBinary: nil, previousReceipt: nil, transaction: malformed) }
      }),
      ("installer publishes only after stop and recovery and rolls back failed starts", {
        let backend = ServiceFixture()
        try ProxyHelperServiceManager(backend: backend).install()
        try expect(backend.events == ["stage", "stop", "recover", "publish", "start", "commit"], "safe install transaction")
        for failure in ["stage", "stop", "recover", "publish", "start", "commit"] {
          let backend = ServiceFixture(); backend.fail = [failure]
          try fails { try ProxyHelperServiceManager(backend: backend).install() }
          if ["stage", "stop"].contains(failure) {
            try expect(!backend.events.contains("publish") && !backend.events.contains("rollback"), "preflight/stop never publishes")
          } else { try expect(backend.events.last == "rollback", "failed install preserves previous service") }
        }
        let broken = ServiceFixture(); broken.fail = ["start", "rollback"]
        do { try ProxyHelperServiceManager(backend: broken).install(); throw Failure.assertion("accepted failed rollback") }
        catch ProxyHelperFailure.recoveryRequired {}
      }),
      ("uninstall never removes recovery files on failed stop or restoration", {
        let ok = ServiceFixture()
        try ProxyHelperServiceManager(backend: ok).uninstall()
        try expect(ok.events == ["stop", "recover", "remove"], "cleanup requires actual recovery")
        for failure in ["stop", "recover", "remove"] {
          let backend = ServiceFixture(); backend.fail = [failure]
          try fails { try ProxyHelperServiceManager(backend: backend).uninstall() }
          if failure != "remove" { try expect(!backend.events.contains("remove"), "no destructive cleanup before restore") }
          if failure == "recover" { try expect(backend.events.last == "rollback", "restart previous recovery agent") }
        }
      }),
      ("real installation files reject symlink hardlink FIFO loose mode and overlapping installers", {
        try withDirectory { directory in
          let files = try ProxyHelperFiles.fixture(directory)
          try files.write("receipt.plist", bytes: Data("safe".utf8))
          try expect(files.read("receipt.plist") == Data("safe".utf8), "atomic real-file round trip")
          try files.locked {
            let second = try ProxyHelperFiles.fixture(directory)
            try fails { try second.locked {} }
          }
          try files.locked {} // lock released, not removed/recreated
          try files.remove("receipt.plist")
          let path = directory.appendingPathComponent("receipt.plist").path
          let outside = directory.appendingPathComponent("outside")
          try Data("protected".utf8).write(to: outside)
          try expect(symlink(outside.path, path) == 0, "symlink fixture")
          try fails { _ = try files.read("receipt.plist") }
          try fails { try files.write("receipt.plist", bytes: Data()) }
          unlink(path)
          try expect(link(outside.path, path) == 0, "hardlink fixture")
          try fails { _ = try files.read("receipt.plist") }; unlink(path)
          try expect(mkfifo(path, 0o600) == 0, "FIFO fixture")
          try fails { _ = try files.read("receipt.plist") }; unlink(path)
          try files.write("receipt.plist", bytes: Data("safe".utf8))
          chmod(path, 0o666)
          try fails { _ = try files.read("receipt.plist") }
          chmod(path, 0o644)
          try fails { _ = try files.read("../../outside") }
          try expect(try Data(contentsOf: outside) == Data("protected".utf8), "protected target unchanged")
        }
      }),
      ("administrator snapshot accepts sealed fixture and rejects replaced or resealed helper before execution", {
        try withDirectory { directory in
          let app = directory.appendingPathComponent("Fixture App.app")
          let contents = app.appendingPathComponent("Contents")
          let macos = contents.appendingPathComponent("MacOS")
          try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
          let main = macos.appendingPathComponent("Gui")
          let helper = macos.appendingPathComponent("EntomaProxyHelper")
          func compile(_ output: URL, marker: String) throws {
            let source = directory.appendingPathComponent("fixture.c")
            try "#include <stdio.h>\nint main(void) { puts(\"\(marker)\"); return 0; }\n".write(to: source, atomically: true, encoding: .utf8)
            let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            task.arguments = ["clang", source.path, "-o", output.path]
            try task.run(); task.waitUntilExit(); try expect(task.terminationStatus == 0, "compile owned fixture")
          }
          try compile(main, marker: "GUI")
          try compile(helper, marker: "APPROVED")
          let info: [String: Any] = ["CFBundleIdentifier": ProxyHelperIdentity.appIdentifier,
            "CFBundleExecutable": "Gui", "CFBundlePackageType": "APPL", "CFBundleVersion": "1"]
          try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
          func sign(_ path: URL, identifier: String) throws {
            let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            task.arguments = ["--force", "--options", "runtime", "--sign", "-", "--identifier", identifier, path.path]
            task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
            try task.run(); task.waitUntilExit()
            try expect(task.terminationStatus == 0, "fixture sign")
          }
          try sign(helper, identifier: ProxyHelperIdentity.helperIdentifier)
          try sign(app, identifier: ProxyHelperIdentity.appIdentifier)
          let pins = try ProxyHelperIdentity.hashes(at: app, identifier: ProxyHelperIdentity.appIdentifier)
          let requirement = try ProxyHelperIdentity.requirement(identifier: ProxyHelperIdentity.appIdentifier, hashes: pins)
          let command = ProxyHelperClient.installationCommand(app: app.path, requirement: requirement, operation: "--uninstall", hashes: pins)
          func run() throws -> Int32 {
            let task = Process(); task.executableURL = URL(fileURLWithPath: "/bin/sh"); task.arguments = ["-c", command]
            let output = Pipe(); task.standardOutput = output; task.standardError = output
            try task.run()
            let result = output.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
            if task.terminationStatus != 0 { print("snapshot fixture output: " + (String(data: result, encoding: .utf8) ?? "invalid")) }
            return task.terminationStatus
          }
          // Only the source-built puts/return fixture can run, never Entoma
          // management code, an administrator prompt or an OS network write.
          try expect(run() == 0, "sealed approved fixture can execute")
          try FileManager.default.removeItem(at: helper)
          try compile(helper, marker: "REPLACED")
          try sign(helper, identifier: ProxyHelperIdentity.helperIdentifier)
          try expect(run() != 0, "changed nested code rejected before execution")
          try sign(app, identifier: ProxyHelperIdentity.appIdentifier)
          try expect(run() != 0, "new ad-hoc app with same ID still rejected by captured pin")
        }
      }),
      ("administrator command quoting treats hostile paths as data", {
        for value in ["plain", "a'b", "$(touch /tmp/not-a-command)", "a\nb", "a\"b"] {
          let child = Process(); let output = Pipe()
          child.executableURL = URL(fileURLWithPath: "/bin/sh")
          child.arguments = ["-c", "printf %s " + ProxyHelperClient.shellQuote(value)]
          child.standardOutput = output
          try child.run()
          let data = output.fileHandleForReading.readDataToEndOfFile(); child.waitUntilExit()
          try expect(child.terminationStatus == 0 && String(data: data, encoding: .utf8) == value, "shell quoting round trip")
        }
      }),
      ("unknown administrator uninstall preserves restoration protection and cancellation remains explicit", {
        if #available(macOS 13.0, *) {
          let fixture = LocalIPCFixture(mode: .normal); defer { fixture.close() }
          var calls: [String] = []
          let client = fixture.client(management: { calls.append($0); throw ProxyHelperFailure.unavailable })
          do { _ = try client.unregister(); throw Failure.assertion("unknown uninstall accepted") }
          catch ProxyHelperFailure.operationUnknown {}
          try expect(calls == ["--uninstall"] && client.needsRestoration, "unknown maintenance cannot release core safety")
          let cancelled = fixture.client(management: { _ in throw ProxyHelperFailure.authorizationCancelled })
          do { _ = try cancelled.unregister(); throw Failure.assertion("cancellation accepted") }
          catch ProxyHelperFailure.authorizationCancelled {}
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
