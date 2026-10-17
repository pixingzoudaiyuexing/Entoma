import Foundation
import Security

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
  private var fixtureManagement: ((String) throws -> Void)?
  // Anonymous, unprivileged local IPC only. Absent from the application build.
  init(fixtureConnection: NSXPCConnection, timeout: TimeInterval, management: ((String) throws -> Void)? = nil) {
    connection = fixtureConnection
    operationTimeout = timeout
    fixtureMode = true
    fixtureManagement = management
  }
  #endif

  private func receipt() throws -> ProxyHelperReceipt {
    let receipt = try ProxyHelperReceipt.installed()
    let own = try ProxyHelperIdentity.hashes(at: Bundle.main.bundleURL, identifier: ProxyHelperIdentity.appIdentifier)
    let running = try ProxyHelperIdentity.runningHash(identifier: ProxyHelperIdentity.appIdentifier)
    guard receipt.appHashes == [running], own.contains(running) else { throw ProxyHelperFailure.identityRejected }
    return receipt
  }

  func registrationStatus() throws -> NSDictionary {
    do { _ = try receipt() }
    catch ProxyHelperFailure.missing {
      return ["available": false, "registration": "notRegistered", "protocolVersion": ProxyHelperIdentity.protocolVersion]
    } catch ProxyHelperFailure.identityRejected {
      return ["available": false, "registration": "updateRequired", "protocolVersion": ProxyHelperIdentity.protocolVersion]
    }
    let observed = try status(port: 17890, bypass: [])
    return ["available": true, "registration": "enabled", "protocolVersion": ProxyHelperIdentity.protocolVersion,
            "restorationPending": observed["restorationPending"] ?? true, "draining": observed["draining"] ?? true]
  }

  func register() throws -> NSDictionary {
    // No installer is invoked by status(), startup or apply(). Only an explicit
    // user installation/update action can request administrator authorization.
    if let current = try? registrationStatus(), current["available"] as? Bool == true,
       current["draining"] as? Bool == false { return current }
    if needsRestoration { _ = try? restore() }
    // A failed/old-identity RPC cannot bypass restoration: the authorized root
    // installer must stop the old job and recover its journal before publishing.
    connection?.invalidate(); connection = nil
    do { try administrator(operation: "--install") }
    catch ProxyHelperFailure.authorizationCancelled { throw ProxyHelperFailure.authorizationCancelled }
    catch { needsRestoration = true; throw ProxyHelperFailure.operationUnknown }
    needsRestoration = true
    let installed = try registrationStatus() // Actual authenticated daemon reply required.
    guard installed["available"] as? Bool == true else { needsRestoration = true; throw ProxyHelperFailure.operationUnknown }
    needsRestoration = installed["restorationPending"] as? Bool != false
    return installed
  }

  func unregister() throws -> NSDictionary {
    // An updated App may no longer satisfy the old daemon's pin. A failed XPC
    // drain does not make privileged uninstall unreachable: the administrator
    // path independently stops the service and proves journal restoration.
    if let prepared = try? request({ $0.prepareUnregister(reply: $1) }),
       prepared["restorationPending"] as? Bool == false,
       prepared["owned"] as? Bool == false { needsRestoration = false }
    do { try administrator(operation: "--uninstall") }
    catch ProxyHelperFailure.authorizationCancelled { throw ProxyHelperFailure.authorizationCancelled }
    catch { needsRestoration = true; throw ProxyHelperFailure.operationUnknown }
    needsRestoration = true
    connection?.invalidate(); connection = nil
    let status = try registrationStatus()
    guard status["registration"] as? String == "notRegistered" else { throw ProxyHelperFailure.unavailable }
    needsRestoration = false
    return status
  }

  private func administrator(operation: String) throws {
    #if ENTOMA_HELPER_TESTING
    if fixtureMode, let management = fixtureManagement { try management(operation); return }
    #endif
    guard ["--install", "--uninstall"].contains(operation) else { throw ProxyHelperFailure.invalidInput }
    let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/EntomaProxyHelper")
    let runningHash = try ProxyHelperIdentity.runningHash(identifier: ProxyHelperIdentity.appIdentifier)
    let appHashes = try ProxyHelperIdentity.hashes(at: Bundle.main.bundleURL, identifier: ProxyHelperIdentity.appIdentifier)
    guard appHashes.contains(runningHash) else { throw ProxyHelperFailure.identityRejected }
    let appRequirement = try ProxyHelperIdentity.requirement(identifier: ProxyHelperIdentity.appIdentifier, hashes: [runningHash])
    _ = try ProxyHelperIdentity.hashes(at: helper, identifier: ProxyHelperIdentity.helperIdentifier)
    // The authorized shell executes only a root-private sealed app snapshot,
    // pinned to this running GUI. Separate mutable-path helper checks are not
    // sufficient: the app's nested-code seal must bind the actual root program.
    let shell = Self.installationCommand(app: Bundle.main.bundleURL.path, requirement: appRequirement,
      operation: operation, hashes: [runningHash])
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    task.arguments = ["-e", "on run argv\ndo shell script (item 1 of argv) with administrator privileges with prompt (item 2 of argv)\nend run", shell, "Entoma 安装、更新或卸载系统代理服务"]
    task.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
    task.standardOutput = FileHandle.nullDevice
    let errors = Pipe(); task.standardError = errors
    try task.run()
    let bytes = errors.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    guard task.terminationStatus == 0 else {
      if String(data: bytes, encoding: .utf8)?.contains("(-128)") == true { throw ProxyHelperFailure.authorizationCancelled }
      throw ProxyHelperFailure.unavailable
    }
  }

  static func installationCommand(app: String, requirement: String, operation: String, hashes: [String]) -> String {
    let arguments = operation == "--install"
      ? [operation, hashes.joined(separator: ",")] : [operation]
    let installArguments = operation == "--install"
      ? Self.shellQuote(arguments[0]) + " \"$stage/Entoma.app\" " + Self.shellQuote(arguments[1])
      : Self.shellQuote(operation)
    let architecture = ProxyHelperIdentity.architecture
    return "umask 077; cd /; set -eu; " +
      "stage=$(/usr/bin/mktemp -d /private/var/tmp/entoma-proxy-install.XXXXXXXX); " +
      "trap '/bin/rm -rf -- \"$stage\"' EXIT; " +
      "/usr/bin/ditto --noqtn " + Self.shellQuote(app) + " \"$stage/Entoma.app\"; " +
      "/usr/bin/codesign --verify --deep --strict --architecture " + architecture + " -R " + Self.shellQuote("=" + requirement) + " \"$stage/Entoma.app\"; " +
      "/usr/bin/arch -" + architecture + " \"$stage/Entoma.app/Contents/MacOS/EntomaProxyHelper\" " + installArguments
  }

  static func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
    let receipt = try self.receipt()
    if let value = connection { return value }
    let value = NSXPCConnection(machServiceName: ProxyHelperIdentity.serviceName, options: .privileged)
    value.remoteObjectInterface = NSXPCInterface(with: ProxyHelperProtocol.self)
    value.setCodeSigningRequirement(try receipt.helperRequirement)
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

  deinit { connection?.invalidate() }
}
