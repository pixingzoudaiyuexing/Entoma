import Foundation
import SystemConfiguration
import Darwin

/// No Authorization Services, shell, path execution or user-supplied dictionaries.
/// This backend is linked only into the constrained privileged executable.
final class RootNetworkSettingsBackend: NetworkSettingsBackend {
  private var preferences: SCPreferences?
  private var locked = false

  private func session() throws -> SCPreferences {
    guard geteuid() == 0 else { throw NetworkSettingsFailure.unavailable }
    if let value = preferences { return value }
    guard let value = SCPreferencesCreate(nil, "Entoma proxy helper" as CFString, nil) else {
      throw NetworkSettingsFailure.unavailable
    }
    preferences = value
    return value
  }

  func authorize() throws { guard geteuid() == 0 else { throw NetworkSettingsFailure.authorizationDenied } }

  func primaryService() throws -> String {
    guard let store = SCDynamicStoreCreate(nil, "Entoma proxy helper" as CFString, nil, nil) else {
      throw NetworkSettingsFailure.unavailable
    }
    for family in ["IPv4", "IPv6"] {
      if let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/\(family)" as CFString) as? [String: Any],
         let service = value["PrimaryService"] as? String { return service }
    }
    throw NetworkSettingsFailure.unavailable
  }

  private func networkProtocol(_ prefs: SCPreferences, kind: NetworkSettingKind,
                               service: String) throws -> SCNetworkProtocol {
    guard kind == .proxy,
          let network = SCNetworkServiceCopy(prefs, service as CFString),
          let value = SCNetworkServiceCopyProtocol(network, kSCNetworkProtocolTypeProxies) else {
      throw NetworkSettingsFailure.unavailable
    }
    return value
  }

  func read(_ kind: NetworkSettingKind, service: String) throws -> NetworkProtocolState {
    let prefs: SCPreferences
    if locked { prefs = try session() }
    else {
      guard let value = SCPreferencesCreate(nil, "Entoma proxy helper read" as CFString, nil) else {
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
    guard SCNetworkProtocolSetConfiguration(proto, state.configuration.map { $0 as CFDictionary }),
          SCNetworkProtocolSetEnabled(proto, state.enabled) else { throw NetworkSettingsFailure.writeFailed }
  }

  func commit() throws {
    guard SCPreferencesCommitChanges(try session()) else { throw NetworkSettingsFailure.writeFailed }
  }

  func apply() throws {
    guard SCPreferencesApplyChanges(try session()) else { throw NetworkSettingsFailure.writeFailed }
  }
}
