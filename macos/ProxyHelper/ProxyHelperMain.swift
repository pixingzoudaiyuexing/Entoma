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
  let team: String
  let coordinator: ProxyHelperCoordinator
  init(team: String, coordinator: ProxyHelperCoordinator) { self.team = team; self.coordinator = coordinator }

  func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
    // Scope global network writes to the logged-in GUI user. UID/path/PID alone
    // are insufficient: the system additionally authenticates every XPC message
    // against the exact Apple-trusted Developer ID identity below.
    var uid: uid_t = 0
    guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) as String?,
          name != "loginwindow", uid > 0, connection.effectiveUserIdentifier == uid,
          let requirement = try? ProxyHelperIdentity.requirement(identifier: ProxyHelperIdentity.appIdentifier, team: team) else {
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
    guard #available(macOS 13.0, *), geteuid() == 0, CommandLine.arguments.count == 1 else { exit(78) }
    do {
      let team = try ProxyHelperIdentity.ownTeam(expectedIdentifier: ProxyHelperIdentity.helperIdentifier)
      let journal = try SecureProxyJournal.production()
      let owner = OwnedNetworkSettings(backend: RootNetworkSettingsBackend(), journal: journal)
      let coordinator = ProxyHelperCoordinator(owner: owner, consoleUser: {
        var uid: uid_t = 0
        guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) as String?,
              name != "loginwindow", uid > 0 else { return nil }
        return uid
      })
      try coordinator.recoverAtStartup()
      let delegate = ProxyHelperListener(team: team, coordinator: coordinator)
      let listener = NSXPCListener(machServiceName: ProxyHelperIdentity.serviceName)
      // macOS 13's public listener API rejects an invalid signed peer before
      // creating a session or consulting our delegate. The accepted connection
      // additionally checks each incoming message against the same requirement.
      listener.setConnectionCodeSigningRequirement(try ProxyHelperIdentity.requirement(
        identifier: ProxyHelperIdentity.appIdentifier, team: team))
      listener.delegate = delegate
      signal(SIGTERM, SIG_IGN)
      let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
      termination.setEventHandler { coordinator.shutdown { restored in exit(restored ? 0 : 78) } }
      termination.resume()
      listener.resume()
      withExtendedLifetime((delegate, listener, termination)) { dispatchMain() }
    } catch {
      // No filesystem paths, network snapshots or credentials are logged.
      fputs("Entoma proxy helper unavailable; signing or protected recovery preflight failed.\n", stderr)
      exit(78)
    }
  }
}
