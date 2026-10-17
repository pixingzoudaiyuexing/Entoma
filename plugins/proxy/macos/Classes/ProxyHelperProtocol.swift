import Foundation
import Security

enum ProxyHelperFailure: String, Error {
  case authorizationCancelled = "NETWORK_PERMISSION_CANCELLED"
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
  static let protocolVersion = 2
  #if arch(arm64)
  static let architecture = "arm64"
  #else
  static let architecture = "x86_64"
  #endif

  // Pin the code approved at installation, including local ad-hoc signatures.
  // An identifier or path alone is forgeable. Updates refresh these pins only
  // through the administrator-authorized installer, never through an RPC.
  static func requirement(identifier: String, hashes: [String]) throws -> String {
    guard [appIdentifier, helperIdentifier].contains(identifier), !hashes.isEmpty,
          hashes.count <= 8, hashes.allSatisfy({ $0.count == 40 && $0.utf8.allSatisfy({
            (48...57).contains($0) || (97...102).contains($0)
          }) }) else { throw ProxyHelperFailure.identityRejected }
    let pins = hashes.map { "cdhash H\"\($0)\"" }.joined(separator: " or ")
    let value = "identifier \"\(identifier)\" and (\(pins)) and !entitlement[\"com.apple.security.get-task-allow\"] exists and !entitlement[\"com.apple.security.cs.disable-library-validation\"] exists and !entitlement[\"com.apple.security.cs.allow-dyld-environment-variables\"] exists"
    var parsed: SecRequirement?
    guard SecRequirementCreateWithString(value as CFString, [], &parsed) == errSecSuccess,
          parsed != nil else { throw ProxyHelperFailure.identityRejected }
    return value
  }

  static func hashes(at url: URL, identifier: String) throws -> [String] {
    var full: SecStaticCode?
    guard SecStaticCodeCreateWithPath(url as CFURL, [], &full) == errSecSuccess,
          let full = full,
          SecStaticCodeCheckValidity(full, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate), nil) == errSecSuccess else {
      throw ProxyHelperFailure.identityRejected
    }
    var hashes = Set<String>()
    for architecture in ["arm64", "x86_64"] {
      var code: SecStaticCode?
      let attributes = [kSecCodeAttributeArchitecture as String: architecture] as CFDictionary
      guard SecStaticCodeCreateWithPathAndAttributes(url as CFURL, [], attributes, &code) == errSecSuccess,
            let code = code else { continue }
      var raw: CFDictionary?
      guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &raw) == errSecSuccess,
            let info = raw as? [String: Any], info[kSecCodeInfoIdentifier as String] as? String == identifier,
            let flags = info[kSecCodeInfoFlags as String] as? NSNumber,
            flags.uint32Value & UInt32(SecCodeSignatureFlags.runtime.rawValue) != 0,
            let hash = info[kSecCodeInfoUnique as String] as? Data else { throw ProxyHelperFailure.identityRejected }
      hashes.insert(hash.map { String(format: "%02x", $0) }.joined())
    }
    let values = hashes.sorted()
    let expression = try requirement(identifier: identifier, hashes: values)
    var parsed: SecRequirement?
    guard SecRequirementCreateWithString(expression as CFString, [], &parsed) == errSecSuccess,
          SecStaticCodeCheckValidity(full, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), parsed) == errSecSuccess else {
      throw ProxyHelperFailure.identityRejected
    }
    return values
  }

  static func runningHash(identifier: String) throws -> String {
    var code: SecCode?; var staticCode: SecStaticCode?; var raw: CFDictionary?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code = code,
          SecCodeCheckValidity(code, [], nil) == errSecSuccess,
          SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode = staticCode,
          SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &raw) == errSecSuccess,
          let info = raw as? [String: Any], info[kSecCodeInfoIdentifier as String] as? String == identifier,
          let hash = info[kSecCodeInfoUnique as String] as? Data else { throw ProxyHelperFailure.identityRejected }
    return hash.map { String(format: "%02x", $0) }.joined()
  }

  static func validate(port: Int, bypass: [String]) throws {
    guard (1024...65535).contains(port), bypass.count <= 256,
          bypass.allSatisfy({ $0.utf8.count <= 1024 && !$0.unicodeScalars.contains(where: {
            $0.value < 32 || $0.value == 127
          }) }) else { throw ProxyHelperFailure.invalidInput }
  }
}
