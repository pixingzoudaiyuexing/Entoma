import Foundation
import Security

enum ProxyHelperFailure: String, Error {
  case signingRequired = "HELPER_SIGNING_REQUIRED"
  case unsupported = "HELPER_REQUIRES_MACOS_13"
  case missing = "HELPER_NOT_FOUND"
  case approvalRequired = "HELPER_APPROVAL_REQUIRED"
  case unavailable = "HELPER_UNAVAILABLE"
  case operationUnknown = "HELPER_OPERATION_UNKNOWN"
  case identityRejected = "HELPER_IDENTITY_REJECTED"
  case invalidInput = "HELPER_INVALID_INPUT"
  case busy = "HELPER_BUSY"
  case draining = "HELPER_DRAINING"
  case recoveryRequired = "HELPER_RECOVERY_REQUIRED"
  case restoreFailed = "NETWORK_RESTORE_FAILED"
}

/// The privileged boundary intentionally accepts no command, executable, file
/// path, network-service identifier, raw settings dictionary or account data.
@objc(EntomaProxyHelperProtocol)
protocol ProxyHelperProtocol {
  func status(port: Int, bypass: [String], reply: @escaping (NSDictionary?, String?) -> Void)
  func applyProxy(port: Int, bypass: [String], reply: @escaping (NSDictionary?, String?) -> Void)
  func restoreProxy(reply: @escaping (NSDictionary?, String?) -> Void)
  func prepareUnregister(reply: @escaping (NSDictionary?, String?) -> Void)
}

enum ProxyHelperIdentity {
  static let appIdentifier = "com.entoma.client"
  static let helperIdentifier = "com.entoma.client.proxy-helper"
  static let serviceName = "com.entoma.client.proxy-helper"
  static let plistName = "com.entoma.client.proxy-helper.plist"
  static let protocolVersion = 1

  static func requirement(identifier: String, team: String) throws -> String {
    guard [appIdentifier, helperIdentifier].contains(identifier),
          team.count == 10, team.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }) else {
      throw ProxyHelperFailure.signingRequired
    }
    // The team is derived from our own valid signature, not a peer-supplied
    // string. Apple generic anchor + Team ID + exact ID rejects ad-hoc clients.
    let value = "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and !entitlement[\"com.apple.security.get-task-allow\"] exists and !entitlement[\"com.apple.security.cs.disable-library-validation\"] exists and !entitlement[\"com.apple.security.cs.allow-dyld-environment-variables\"] exists"
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(value as CFString, [], &requirement) == errSecSuccess,
          requirement != nil else { throw ProxyHelperFailure.signingRequired }
    return value
  }

  /// No Keychain query: inspect the running process's public code signature.
  static func ownTeam(expectedIdentifier: String) throws -> String {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code = code,
          SecCodeCheckValidity(code, [], nil) == errSecSuccess else {
      throw ProxyHelperFailure.signingRequired
    }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode = staticCode else {
      throw ProxyHelperFailure.signingRequired
    }
    var raw: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &raw) == errSecSuccess,
          let info = raw as? [String: Any],
          let identifier = info[kSecCodeInfoIdentifier as String] as? String,
          identifier == expectedIdentifier,
          let team = info[kSecCodeInfoTeamIdentifier as String] as? String,
          let flags = info[kSecCodeInfoFlags as String] as? NSNumber,
          flags.uint32Value & UInt32(SecCodeSignatureFlags.adhoc.rawValue) == 0,
          flags.uint32Value & UInt32(SecCodeSignatureFlags.runtime.rawValue) != 0 else {
      throw ProxyHelperFailure.signingRequired
    }
    let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
    guard entitlements?["com.apple.security.get-task-allow"] as? Bool != true,
          entitlements?["com.apple.security.cs.disable-library-validation"] as? Bool != true,
          entitlements?["com.apple.security.cs.allow-dyld-environment-variables"] as? Bool != true else {
      throw ProxyHelperFailure.signingRequired
    }
    let expression = try requirement(identifier: expectedIdentifier, team: team)
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
          SecCodeCheckValidity(code, [], requirement) == errSecSuccess else {
      throw ProxyHelperFailure.signingRequired
    }
    return team
  }

  static func validate(port: Int, bypass: [String]) throws {
    guard (1024...65535).contains(port), bypass.count <= 256,
          bypass.allSatisfy({ $0.utf8.count <= 1024 && !$0.unicodeScalars.contains(where: {
            $0.value < 32 || $0.value == 127
          }) }) else { throw ProxyHelperFailure.invalidInput }
  }
}
