import Foundation
import SystemConfiguration
import Darwin

private final class ProxyHelperSession: NSObject, ProxyHelperProtocol {
  let id = UUID()
  let coordinator: ProxyHelperCoordinator
  init(coordinator: ProxyHelperCoordinator, user: uid_t) {
    self.coordinator = coordinator
    super.init()
    coordinator.opened(id, user: user)
  }
  func status(port: Int, bypass: [String], reply: @escaping (NSDictionary?, String?) -> Void) {
    coordinator.status(session: id, port: port, bypass: bypass, reply: reply)
  }
  func applyProxy(port: Int, bypass: [String], reply: @escaping (NSDictionary?, String?) -> Void) {
    coordinator.apply(session: id, port: port, bypass: bypass, reply: reply)
  }
  func restoreProxy(reply: @escaping (NSDictionary?, String?) -> Void) {
    coordinator.restore(session: id, reply: reply)
  }
  func prepareUnregister(reply: @escaping (NSDictionary?, String?) -> Void) {
    coordinator.restore(session: id, unregister: true, reply: reply)
  }
}

@available(macOS 13.0, *)
private final class ProxyHelperListener: NSObject, NSXPCListenerDelegate {
  let requirement: String
  let coordinator: ProxyHelperCoordinator
  init(requirement: String, coordinator: ProxyHelperCoordinator) { self.requirement = requirement; self.coordinator = coordinator }

  func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
    // Scope global network writes to the logged-in GUI user. UID/path/PID alone
    // are insufficient: XPC additionally authenticates every message against
    // the CodeDirectory identity approved during administrator installation.
    var uid: uid_t = 0
    guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) as String?,
          name != "loginwindow", uid > 0, connection.effectiveUserIdentifier == uid else {
      return false
    }
    connection.setCodeSigningRequirement(requirement)
    let session = ProxyHelperSession(coordinator: coordinator, user: uid)
    connection.exportedInterface = NSXPCInterface(with: ProxyHelperProtocol.self)
    connection.exportedObject = session
    connection.invalidationHandler = { [coordinator, id = session.id] in coordinator.closed(id) }
    connection.interruptionHandler = { [weak connection] in connection?.invalidate() }
    connection.resume()
    return true
  }
}

@main
private enum ProxyHelperMain {
  static func main() {
    guard #available(macOS 13.0, *), geteuid() == 0 else { exit(78) }
    do {
      if CommandLine.arguments.count > 1 {
        let args = Array(CommandLine.arguments.dropFirst())
        guard (args.count == 3 && args[0] == "--install") || (args.count == 1 && args[0] == "--uninstall") else { exit(64) }
        try LaunchdProxyHelperBackend(app: args[0] == "--install" ? URL(fileURLWithPath: args[1]) : nil,
                                      approvedHashes: args.count == 3 ? args[2].components(separatedBy: ",") : []).run()
        return
      }
      guard CommandLine.arguments.count == 1 else { exit(64) }
      let receipt = try ProxyHelperReceipt.installed()
      let executable = URL(fileURLWithPath: ProxyHelperFiles.binaryPath)
      guard try ProxyHelperIdentity.hashes(at: executable, identifier: ProxyHelperIdentity.helperIdentifier) == receipt.helperHashes else {
        throw ProxyHelperFailure.identityRejected
      }
      let journal = try SecureProxyJournal.production()
      let owner = OwnedNetworkSettings(backend: RootNetworkSettingsBackend(), journal: journal)
      let coordinator = ProxyHelperCoordinator(owner: owner, consoleUser: {
        var uid: uid_t = 0
        guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) as String?,
              name != "loginwindow", uid > 0 else { return nil }
        return uid
      })
      try coordinator.recoverAtStartup()
      let delegate = ProxyHelperListener(requirement: try receipt.appRequirement, coordinator: coordinator)
      let listener = NSXPCListener(machServiceName: ProxyHelperIdentity.serviceName)
      // macOS 13's public listener API rejects an invalid signed peer before
      // creating a session or consulting our delegate. The accepted connection
      // additionally checks each incoming message against the same requirement.
      listener.setConnectionCodeSigningRequirement(try receipt.appRequirement)
      listener.delegate = delegate
      signal(SIGTERM, SIG_IGN)
      let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
      termination.setEventHandler { coordinator.shutdown { restored in exit(restored ? 0 : 78) } }
      termination.resume()
      listener.resume()
      let files = try ProxyHelperFiles.production(create: false)
      guard let installed = try files.read("receipt.plist", limit: 65536) else { throw ProxyHelperFailure.missing }
      let ready = try PropertyListSerialization.data(fromPropertyList: ["pid": getpid(), "receipt": installed], format: .binary, options: 0)
      try files.write("ready.plist", bytes: ready)
      withExtendedLifetime((delegate, listener, termination)) { dispatchMain() }
    } catch {
      // No filesystem paths, network snapshots or credentials are logged.
      fputs("Entoma proxy helper unavailable; signing or protected recovery preflight failed.\n", stderr)
      exit(78)
    }
  }
}
