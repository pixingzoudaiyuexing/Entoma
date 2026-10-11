import Cocoa
import FlutterMacOS
import Security
import SystemConfiguration

public class ProxyPlugin: NSObject, FlutterPlugin {
  private struct Snapshot {
    let service: String
    let original: [String: Any]
    let enabled: Bool
    var applied: [String: Any]
  }
  private var restorationPending = false
  private var snapshot: Snapshot?
  private var preferences: SCPreferences?
  private var authorization: AuthorizationRef?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "proxy", binaryMessenger: registrar.messenger)
    registrar.addMethodCallDelegate(ProxyPlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    do {
      switch call.method {
      case "StartProxy":
        guard let args = call.arguments as? [String: Any], let port = args["port"] as? Int,
              (1024...65535).contains(port), let bypass = args["bypassDomain"] as? [String] else {
          throw ProxyFailure.invalidInput
        }
        try start(port: port, bypass: bypass)
        result(true)
      case "StopProxy":
        try stop()
        result(true)
      default: result(FlutterMethodNotImplemented)
      }
    } catch { result(false) }
  }

  private enum ProxyFailure: Error { case invalidInput, unavailable, changed, writeFailed }

  private func session() throws -> SCPreferences {
    if let value = preferences { SCPreferencesSynchronize(value); return value }
    var auth: AuthorizationRef?
    guard AuthorizationCreate(nil, nil, [.interactionAllowed], &auth) == errAuthorizationSuccess,
          let value = SCPreferencesCreateWithAuthorization(nil, "Entoma" as CFString, nil, auth) else {
      throw ProxyFailure.unavailable
    }
    authorization = auth
    preferences = value
    return value
  }

  private func networkProtocol(_ prefs: SCPreferences, serviceID: String) throws -> SCNetworkProtocol {
    guard let service = SCNetworkServiceCopy(prefs, serviceID as CFString),
          let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else {
      throw ProxyFailure.unavailable
    }
    return proto
  }

  private func primaryService() throws -> String {
    guard let store = SCDynamicStoreCreate(nil, "Entoma" as CFString, nil, nil) else {
      throw ProxyFailure.unavailable
    }
    for family in ["IPv4", "IPv6"] {
      if let state = SCDynamicStoreCopyValue(store, "State:/Network/Global/\(family)" as CFString) as? [String: Any],
         let service = state["PrimaryService"] as? String { return service }
    }
    throw ProxyFailure.unavailable
  }

  private func configuration(_ proto: SCNetworkProtocol) -> [String: Any] {
    return SCNetworkProtocolGetConfiguration(proto) as? [String: Any] ?? [:]
  }

  private func commit(_ prefs: SCPreferences) throws {
    guard SCPreferencesCommitChanges(prefs), SCPreferencesApplyChanges(prefs) else {
      throw ProxyFailure.writeFailed
    }
  }

  private func start(port: Int, bypass: [String]) throws {
    guard !restorationPending else { throw ProxyFailure.writeFailed }
    let prefs = try session()
    guard SCPreferencesLock(prefs, true) else { throw ProxyFailure.unavailable }
    defer { SCPreferencesUnlock(prefs) }
    let id = try primaryService()
    if let previous = snapshot, previous.service != id {
      throw ProxyFailure.changed // Restore the old service before changing networks.
    }
    let proto = try networkProtocol(prefs, serviceID: id)
    let current = configuration(proto)
    if let previous = snapshot,
       !NSDictionary(dictionary: current).isEqual(to: previous.applied) { throw ProxyFailure.changed }
    var owned = snapshot ?? Snapshot(service: id, original: current,
        enabled: SCNetworkProtocolGetEnabled(proto), applied: [:])
    var next = current
    for (enabled, host, number) in [
      (kSCPropNetProxiesHTTPEnable, kSCPropNetProxiesHTTPProxy, kSCPropNetProxiesHTTPPort),
      (kSCPropNetProxiesHTTPSEnable, kSCPropNetProxiesHTTPSProxy, kSCPropNetProxiesHTTPSPort),
      (kSCPropNetProxiesSOCKSEnable, kSCPropNetProxiesSOCKSProxy, kSCPropNetProxiesSOCKSPort)
    ] {
      next[enabled as String] = 1
      next[host as String] = "127.0.0.1"
      next[number as String] = port
    }
    next[kSCPropNetProxiesProxyAutoConfigEnable as String] = 0
    next[kSCPropNetProxiesProxyAutoDiscoveryEnable as String] = 0
    next[kSCPropNetProxiesExceptionsList as String] = bypass
    guard SCNetworkProtocolSetConfiguration(proto, next as CFDictionary),
          SCNetworkProtocolSetEnabled(proto, true) else { throw ProxyFailure.writeFailed }
    do { try commit(prefs) }
    catch {
      owned.applied = configuration(proto)
      snapshot = owned
      if SCNetworkProtocolSetConfiguration(proto, owned.original as CFDictionary),
         SCNetworkProtocolSetEnabled(proto, owned.enabled), SCPreferencesCommitChanges(prefs) {
        restorationPending = true
        if SCPreferencesApplyChanges(prefs) { snapshot = nil; restorationPending = false }
      }
      throw error
    }
    owned.applied = configuration(proto)
    snapshot = owned
  }

  private func stop() throws {
    guard let owned = snapshot else { return } // Opening the app never changes user settings.
    let prefs = try session()
    guard SCPreferencesLock(prefs, true) else { throw ProxyFailure.unavailable }
    defer { SCPreferencesUnlock(prefs) }
    let proto = try networkProtocol(prefs, serviceID: owned.service)
    let expected = restorationPending ? owned.original : owned.applied
    guard NSDictionary(dictionary: configuration(proto)).isEqual(to: expected) else {
      snapshot = nil
      restorationPending = false
      return
    }
    if !restorationPending {
      guard SCNetworkProtocolSetConfiguration(proto, owned.original as CFDictionary),
            SCNetworkProtocolSetEnabled(proto, owned.enabled),
            SCPreferencesCommitChanges(prefs) else { throw ProxyFailure.writeFailed }
      restorationPending = true
    }
    guard SCPreferencesApplyChanges(prefs) else { throw ProxyFailure.writeFailed }
    snapshot = nil
    restorationPending = false
  }

  deinit {
    try? stop()
    if let auth = authorization { AuthorizationFree(auth, []) }
  }
}
