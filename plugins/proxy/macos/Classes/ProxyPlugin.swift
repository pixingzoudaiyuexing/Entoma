import Cocoa
import FlutterMacOS
import Security
import SystemConfiguration

private final class MacNetworkSettingsBackend: NetworkSettingsBackend {
  private var preferences: SCPreferences?
  private var authorization: AuthorizationRef?
  private var locked = false

  private func authorizationReference() throws -> AuthorizationRef {
    if let value = authorization { return value }
    var value: AuthorizationRef?
    guard AuthorizationCreate(nil, nil, [], &value) == errAuthorizationSuccess,
          let value = value else { throw NetworkSettingsFailure.unavailable }
    authorization = value
    return value
  }

  func authorize() throws {
    let auth = try authorizationReference()
    // The SCPreferences helper requests this exact right for network settings.
    // First reuse an existing grant; allow interaction only for an actual write.
    let status: OSStatus = "system.services.systemconfiguration.network".withCString { name in
      var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
      return withUnsafeMutablePointer(to: &item) { pointer in
        var rights = AuthorizationRights(count: 1, items: pointer)
        let cached = AuthorizationCopyRights(auth, &rights, nil, [], nil)
        if cached == errAuthorizationSuccess { return cached }
        DispatchQueue.main.sync { NSApp.activate(ignoringOtherApps: true) }
        return AuthorizationCopyRights(auth, &rights, nil, [.extendRights, .interactionAllowed], nil)
      }
    }
    if status == errAuthorizationCanceled { throw NetworkSettingsFailure.authorizationCancelled }
    guard status == errAuthorizationSuccess else { throw NetworkSettingsFailure.authorizationDenied }
  }

  private func session() throws -> SCPreferences {
    if let value = preferences { return value }
    let auth = try authorizationReference()
    guard let value = SCPreferencesCreateWithAuthorization(nil, "Entoma" as CFString, nil, auth) else {
      throw NetworkSettingsFailure.unavailable
    }
    preferences = value
    return value
  }

  func primaryService() throws -> String {
    guard let store = SCDynamicStoreCreate(nil, "Entoma" as CFString, nil, nil) else {
      throw NetworkSettingsFailure.unavailable
    }
    for family in ["IPv4", "IPv6"] {
      if let state = SCDynamicStoreCopyValue(store, "State:/Network/Global/\(family)" as CFString) as? [String: Any],
         let service = state["PrimaryService"] as? String { return service }
    }
    throw NetworkSettingsFailure.unavailable
  }

  private func networkProtocol(_ prefs: SCPreferences, kind: NetworkSettingKind,
                               service: String) throws -> SCNetworkProtocol {
    let type = kind == .proxy ? kSCNetworkProtocolTypeProxies : kSCNetworkProtocolTypeDNS
    guard let network = SCNetworkServiceCopy(prefs, service as CFString),
          let proto = SCNetworkServiceCopyProtocol(network, type) else {
      throw NetworkSettingsFailure.unavailable
    }
    return proto
  }

  func read(_ kind: NetworkSettingKind, service: String) throws -> NetworkProtocolState {
    let prefs: SCPreferences
    if locked { prefs = try session() }
    else {
      // A fresh, unauthenticated reader makes no-op checks independent of the
      // privileged helper. It also observes external changes before restoring.
      guard let value = SCPreferencesCreate(nil, "Entoma read" as CFString, nil) else {
        throw NetworkSettingsFailure.unavailable
      }
      prefs = value
    }
    let proto = try networkProtocol(prefs, kind: kind, service: service)
    return NetworkProtocolState(configuration: SCNetworkProtocolGetConfiguration(proto) as? [String: Any],
                                enabled: SCNetworkProtocolGetEnabled(proto))
  }

  func lock() throws {
    let prefs = try session()
    SCPreferencesSynchronize(prefs)
    guard SCPreferencesLock(prefs, true) else { throw NetworkSettingsFailure.unavailable }
    locked = true
  }

  func unlock() {
    if locked, let prefs = preferences { SCPreferencesUnlock(prefs) }
    locked = false
  }

  func synchronize() { if let prefs = preferences { SCPreferencesSynchronize(prefs) } }

  func set(_ state: NetworkProtocolState, kind: NetworkSettingKind, service: String) throws {
    guard locked else { throw NetworkSettingsFailure.unavailable }
    let proto = try networkProtocol(session(), kind: kind, service: service)
    let configuration = state.configuration.map { $0 as CFDictionary }
    guard SCNetworkProtocolSetConfiguration(proto, configuration),
          SCNetworkProtocolSetEnabled(proto, state.enabled) else { throw NetworkSettingsFailure.writeFailed }
  }

  func commit() throws {
    let prefs = try session()
    guard SCPreferencesCommitChanges(prefs) else { throw NetworkSettingsFailure.writeFailed }
  }

  func apply() throws {
    let prefs = try session()
    guard SCPreferencesApplyChanges(prefs) else { throw NetworkSettingsFailure.writeFailed }
  }

  deinit { if let auth = authorization { AuthorizationFree(auth, []) } }
}

public class ProxyPlugin: NSObject, FlutterPlugin {
  private let queue = DispatchQueue(label: "com.entoma.network-settings")
  // DNS remains on its existing independently authorized path. The helper is
  // deliberately incapable of DNS or TUN operations.
  private let owner = OwnedNetworkSettings(backend: MacNetworkSettingsBackend())
  private var helperClient: Any?

  @available(macOS 13.0, *)
  private func helper() -> ProxyHelperClient {
    if let value = helperClient as? ProxyHelperClient { return value }
    let value = ProxyHelperClient()
    helperClient = value
    return value
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "proxy", binaryMessenger: registrar.messenger)
    registrar.addMethodCallDelegate(ProxyPlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard ["StartProxy", "StopProxy", "GetProxyStatus", "HelperStatus", "RegisterHelper", "UnregisterHelper",
           "StartAutoDns", "StopAutoDns"].contains(call.method) else {
      result(FlutterMethodNotImplemented)
      return
    }
    let args = call.arguments as? [String: Any]
    queue.async {
      do {
        var value: Any = true
        switch call.method {
        case "StartProxy", "GetProxyStatus":
          guard let port = args?["port"] as? Int, let bypass = args?["bypassDomain"] as? [String] else {
            throw NetworkSettingsFailure.invalidInput
          }
          guard #available(macOS 13.0, *) else { throw ProxyHelperFailure.unsupported }
          if call.method == "GetProxyStatus" {
            value = try self.helper().status(port: port, bypass: bypass)
          } else { _ = try self.helper().apply(port: port, bypass: bypass) }
        case "StopProxy":
          // No connection has ever existed in this plugin instance, so this
          // instance cannot own a helper transaction. The daemon restores an
          // old connection on invalidation and recovers its journal at startup.
          if #available(macOS 13.0, *), let helper = self.helperClient as? ProxyHelperClient,
             helper.needsRestoration {
            _ = try helper.restore()
          }
        case "HelperStatus", "RegisterHelper", "UnregisterHelper":
          guard #available(macOS 13.0, *) else { throw ProxyHelperFailure.unsupported }
          switch call.method {
          case "RegisterHelper": value = try self.helper().register()
          case "UnregisterHelper": value = try self.helper().unregister()
          default: value = try self.helper().registrationStatus()
          }
        case "StartAutoDns": try self.owner.startAutoDns()
        default: try self.owner.stop(.dns)
        }
        DispatchQueue.main.async { result(value) }
      } catch {
        let code: String
        switch error {
        case let helper as ProxyHelperFailure: code = helper.rawValue
        case NetworkSettingsFailure.authorizationCancelled: code = "NETWORK_PERMISSION_CANCELLED"
        case NetworkSettingsFailure.authorizationDenied: code = "NETWORK_PERMISSION_DENIED"
        case NetworkSettingsFailure.changed: code = "NETWORK_SETTINGS_CHANGED"
        case NetworkSettingsFailure.restoreFailed: code = "NETWORK_RESTORE_FAILED"
        case NetworkSettingsFailure.journalFailed: code = "HELPER_RECOVERY_REQUIRED"
        default: code = "NETWORK_SETTINGS_FAILED"
        }
        var details: [String: Any] = ["available": false]
        let unknown = [ProxyHelperFailure.operationUnknown.rawValue,
                       ProxyHelperFailure.recoveryRequired.rawValue,
                       ProxyHelperFailure.restoreFailed.rawValue].contains(code)
        details["restorationPending"] = unknown
        if #available(macOS 13.0, *), let helper = self.helperClient as? ProxyHelperClient {
          details["restorationPending"] = unknown || helper.needsRestoration
        }
        DispatchQueue.main.async { result(FlutterError(code: code, message: code, details: details)) }
      }
    }
  }
}
