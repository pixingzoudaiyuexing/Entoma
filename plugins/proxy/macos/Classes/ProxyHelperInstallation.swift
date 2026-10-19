import Foundation
import Darwin

/// Public identity metadata, not an account credential or bearer token. Only
/// root can publish it; XPC authenticates the running peer against these pins.
struct ProxyHelperReceipt: Codable {
  let version: Int
  let appHashes: [String]
  let helperHashes: [String]
  var appRequirement: String { get throws {
    try ProxyHelperIdentity.requirement(identifier: ProxyHelperIdentity.appIdentifier, hashes: appHashes)
  } }
  var helperRequirement: String { get throws {
    try ProxyHelperIdentity.requirement(identifier: ProxyHelperIdentity.helperIdentifier, hashes: helperHashes)
  } }
  func validate() throws {
    guard version == ProxyHelperIdentity.protocolVersion, appHashes.count == 1, helperHashes.count == 1 else { throw ProxyHelperFailure.unavailable }
    _ = try appRequirement; _ = try helperRequirement
  }
  static func installed() throws -> ProxyHelperReceipt {
    let directory = try ProxyHelperFiles.production(create: false)
    guard let bytes = try directory.read("receipt.plist", limit: 65536) else { throw ProxyHelperFailure.missing }
    let receipt = try PropertyListDecoder().decode(Self.self, from: bytes)
    try receipt.validate()
    return receipt
  }
}

/// Fixed root-owned directory. No client-supplied path reaches this API in a
/// production build. Relative operations prevent symlink/rename races.
final class ProxyHelperFiles {
  static let directoryPath = "/Library/PrivilegedHelperTools/EntomaProxy"
  static let binaryPath = directoryPath + "/EntomaProxyHelper"
  static let launchPlist = "/Library/LaunchDaemons/com.entoma.client.proxy-helper.plist"
  private let fd: Int32
  private let owner: uid_t
  private static let names: Set<String> = ["EntomaProxyHelper", "receipt.plist", "previous-helper", "previous-receipt", "candidate-helper", "candidate-thin", "ready.plist", "transaction.plist", ProxyHelperIdentity.plistName, "install.lock"]

  private init(fd: Int32, owner: uid_t) { self.fd = fd; self.owner = owner }
  private static func safe(_ fd: Int32, owner: uid_t, directory: Bool) throws {
    var state = stat()
    guard fstat(fd, &state) == 0, state.st_uid == owner, state.st_mode & 0o022 == 0,
          state.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
          directory || state.st_nlink == 1 else { throw ProxyHelperFailure.identityRejected }
    // Mode bits do not describe extra ACL write grants.
    if let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) {
      defer { acl_free(UnsafeMutableRawPointer(acl)) }
      var entry: acl_entry_t?
      guard acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) != 0 else { throw ProxyHelperFailure.identityRejected }
    } else if errno != ENOENT { throw ProxyHelperFailure.identityRejected }
  }
  private static func openDirectory(parent: Int32, component: String, owner: uid_t,
                                    create: Bool, publish: Bool) throws -> Int32 {
    var created = false
    if create {
      if mkdirat(parent, component, 0o755) == 0 { created = true }
      else if errno != EEXIST { throw ProxyHelperFailure.unavailable }
    }
    let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard next >= 0 else { throw errno == ENOENT ? ProxyHelperFailure.missing : .identityRejected }
    do {
      try safe(next, owner: owner, directory: true)
      // The administrator launcher deliberately uses umask077. Publish only
      // this root-validated identity directory (or a newly created parent) with
      // traversal/read access for the GUI; group/other write remains forbidden.
      // Repair an earlier0700 leaf in place. Never widen the separate private
      // network journal or alter pre-existing system parent permissions.
      if create && (publish || created) {
        guard fchmod(next, 0o755) == 0, fsync(next) == 0 else { throw ProxyHelperFailure.unavailable }
      }
      return next
    } catch { close(next); throw error }
  }

  static func production(create: Bool, launchDirectory: Bool = false) throws -> ProxyHelperFiles {
    if create && geteuid() != 0 { throw ProxyHelperFailure.identityRejected }
    var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw ProxyHelperFailure.unavailable }
    do {
      for component in (launchDirectory ? ["Library", "LaunchDaemons"] : ["Library", "PrivilegedHelperTools", "EntomaProxy"]) {
        let next = try openDirectory(parent: fd, component: component, owner: 0,
          create: create && component != "Library", publish: create && component == "EntomaProxy")
        close(fd); fd = next
      }
      return ProxyHelperFiles(fd: fd, owner: 0)
    } catch { close(fd); throw error }
  }
  #if ENTOMA_HELPER_TESTING
  static func fixtureSharedDirectory(_ parent: URL, create: Bool) throws -> ProxyHelperFiles {
    let parentFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard parentFD >= 0 else { throw ProxyHelperFailure.unavailable }
    defer { close(parentFD) }
    let fd = try openDirectory(parent: parentFD, component: "EntomaProxy", owner: geteuid(),
                               create: create, publish: create)
    return ProxyHelperFiles(fd: fd, owner: geteuid())
  }
  static func fixture(_ url: URL) throws -> ProxyHelperFiles {
    let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw ProxyHelperFailure.unavailable }
    do { try safe(fd, owner: geteuid(), directory: true) }
    catch { close(fd); throw error }
    return ProxyHelperFiles(fd: fd, owner: geteuid())
  }
  #endif
  func read(_ name: String, limit: Int = 67108864) throws -> Data? {
    guard Self.names.contains(name) else { throw ProxyHelperFailure.invalidInput }
    let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    if file < 0 { if errno == ENOENT { return nil }; throw ProxyHelperFailure.identityRejected }
    defer { close(file) }
    try Self.safe(file, owner: owner, directory: false)
    var state = stat(); guard fstat(file, &state) == 0, state.st_size >= 0, state.st_size <= limit else { throw ProxyHelperFailure.unavailable }
    var result = Data(); var buffer = [UInt8](repeating: 0, count: 16384)
    while true {
      let count = Darwin.read(file, &buffer, buffer.count)
      if count < 0 { if errno == EINTR { continue }; throw ProxyHelperFailure.unavailable }
      if count == 0 { break }
      result.append(contentsOf: buffer.prefix(count))
      guard result.count <= limit else { throw ProxyHelperFailure.unavailable }
    }
    return result
  }
  func write(_ name: String, bytes: Data, executable: Bool = false) throws {
    guard Self.names.contains(name), name != "install.lock", geteuid() == owner else { throw ProxyHelperFailure.invalidInput }
    _ = try read(name) // Reject an unsafe existing destination.
    let temporary = ".stage-" + UUID().uuidString
    let file = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard file >= 0 else { throw ProxyHelperFailure.unavailable }
    defer { close(file); unlinkat(fd, temporary, 0) }
    try bytes.withUnsafeBytes { raw in
      var offset = 0
      while offset < raw.count {
        let count = Darwin.write(file, raw.baseAddress!.advanced(by: offset), raw.count - offset)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw ProxyHelperFailure.unavailable }
        offset += count
      }
    }
    guard fchmod(file, executable ? 0o755 : 0o644) == 0, fsync(file) == 0,
          renameat(fd, temporary, fd, name) == 0, fsync(fd) == 0 else { throw ProxyHelperFailure.unavailable }
  }
  func remove(_ name: String) throws {
    guard name != "install.lock" else { throw ProxyHelperFailure.invalidInput }
    if try read(name) == nil { return }
    guard unlinkat(fd, name, 0) == 0, fsync(fd) == 0 else { throw ProxyHelperFailure.unavailable }
  }
  func locked<T>(_ action: () throws -> T) throws -> T {
    let file = openat(fd, "install.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o644)
    guard file >= 0 else { throw ProxyHelperFailure.unavailable }
    defer { close(file) }
    try Self.safe(file, owner: owner, directory: false)
    guard flock(file, LOCK_EX | LOCK_NB) == 0 else { throw ProxyHelperFailure.busy }
    defer { flock(file, LOCK_UN) }
    return try action()
  }
  deinit { close(fd) }
}
