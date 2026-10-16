import Foundation
import Darwin
import CoreFoundation

enum ProxyJournalFailure: Error { case unsafePath, io, corrupt, busy }

/// A single fixed root-owned directory, opened component by component without
/// following symlinks. All subsequent operations are relative to its open FD.
/// No XPC argument can choose this directory or any filename within it.
final class SecureProxyJournal: NetworkSettingsJournal {
  private let directory: Int32
  private let lockFile: Int32
  private let owner: uid_t
  private static let journalName = "proxy-journal.plist"
  private static let maximumBytes = 1_048_576

  #if ENTOMA_HELPER_TESTING
  static var fixtureAfterFailedInitCleanup: (([Int32]) -> Void)?
  var fixtureDescriptors: [Int32] { [directory, lockFile] }
  #endif

  private init(directory: Int32, owner: uid_t) throws {
    // Until validation succeeds, resources belong exclusively to these locals.
    // A throwing fully initialized Swift class also runs deinit: assigning the
    // stored FDs early and manually closing them on error would double-close.
    let localLock = openat(directory, "owner.lock", O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard localLock >= 0 else {
      close(directory)
      #if ENTOMA_HELPER_TESTING
      Self.fixtureAfterFailedInitCleanup?([directory])
      #endif
      throw ProxyJournalFailure.unsafePath
    }
    do {
      try Self.checkFile(localLock, owner: owner)
      guard flock(localLock, LOCK_EX | LOCK_NB) == 0 else { throw ProxyJournalFailure.busy }
    } catch {
      close(localLock); close(directory)
      #if ENTOMA_HELPER_TESTING
      Self.fixtureAfterFailedInitCleanup?([directory, localLock])
      #endif
      throw error
    }
    self.directory = directory
    self.owner = owner
    self.lockFile = localLock
  }

  static func production() throws -> SecureProxyJournal {
    guard geteuid() == 0 else { throw ProxyJournalFailure.unsafePath }
    var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { throw ProxyJournalFailure.io }
    do {
      for component in ["Library", "Application Support", "Entoma", "NetworkProxy"] {
        if component == "Entoma" || component == "NetworkProxy" {
          if mkdirat(fd, component, 0o700) == 0 {
            guard fsync(fd) == 0 else { throw ProxyJournalFailure.io }
          } else if errno != EEXIST { throw ProxyJournalFailure.io }
        }
        let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard next >= 0 else { throw ProxyJournalFailure.unsafePath }
        var state = stat()
        guard fstat(next, &state) == 0, state.st_uid == 0,
              state.st_mode & 0o022 == 0 else { close(next); throw ProxyJournalFailure.unsafePath }
        // Refuse extended ACLs instead of assuming mode bits describe all write
        // authority. The journal directory must be private even for reads.
        guard !hasExtendedACL(next),
              !["Entoma", "NetworkProxy"].contains(component) || state.st_mode & 0o077 == 0 else {
          close(next); throw ProxyJournalFailure.unsafePath
        }
        close(fd); fd = next
      }
      let transferred = fd
      fd = -1
      return try SecureProxyJournal(directory: transferred, owner: 0)
    } catch { if fd >= 0 { close(fd) }; throw error }
  }

  #if ENTOMA_HELPER_TESTING
  // Only compiled into the fixture executable, never the shipped daemon.
  static func fixture(directory url: URL) throws -> SecureProxyJournal {
    let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { throw ProxyJournalFailure.unsafePath }
    return try SecureProxyJournal(directory: fd, owner: geteuid())
  }
  #endif

  private static func hasExtendedACL(_ fd: Int32) -> Bool {
    guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else { return errno != ENOENT }
    defer { acl_free(UnsafeMutableRawPointer(acl)) }
    var entry: acl_entry_t?
    return acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == 0
  }

  private static func checkFile(_ fd: Int32, owner: uid_t) throws {
    var state = stat()
    guard fstat(fd, &state) == 0, state.st_uid == owner,
          state.st_mode & S_IFMT == S_IFREG, state.st_mode & 0o077 == 0,
          state.st_nlink == 1, !hasExtendedACL(fd) else { throw ProxyJournalFailure.unsafePath }
  }

  func load() throws -> [NetworkSettingKind: NetworkSettingsSnapshot] {
    let fd = openat(directory, Self.journalName, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    if fd < 0 {
      guard errno == ENOENT else { throw ProxyJournalFailure.unsafePath }
      return [:]
    }
    defer { close(fd) }
    try Self.checkFile(fd, owner: owner)
    var state = stat()
    guard fstat(fd, &state) == 0, state.st_size > 0, state.st_size <= Self.maximumBytes else {
      throw ProxyJournalFailure.corrupt
    }
    var data = Data(count: Int(state.st_size))
    let expected = data.count
    try data.withUnsafeMutableBytes { bytes in
      var offset = 0
      while offset < expected {
        let count = read(fd, bytes.baseAddress!.advanced(by: offset), expected - offset)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw ProxyJournalFailure.io }
        offset += count
      }
    }
    return try Self.decode(data)
  }

  func save(_ snapshots: [NetworkSettingKind: NetworkSettingsSnapshot]) throws {
    let data = try Self.encode(snapshots)
    let temporary = ".proxy-\(UUID().uuidString).tmp"
    let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw ProxyJournalFailure.io }
    defer { close(fd); unlinkat(directory, temporary, 0) }
    try Self.checkFile(fd, owner: owner)
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < data.count {
        let count = write(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw ProxyJournalFailure.io }
        offset += count
      }
    }
    guard fsync(fd) == 0 else { throw ProxyJournalFailure.io }
    // renameat replaces a directory entry, never a symlink's target. Refuse an
    // unexpected existing entry nevertheless, rather than hide suspicious state.
    let existing = openat(directory, Self.journalName, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    if existing >= 0 { defer { close(existing) }; try Self.checkFile(existing, owner: owner) }
    else if errno != ENOENT { throw ProxyJournalFailure.unsafePath }
    guard renameat(directory, temporary, directory, Self.journalName) == 0,
          fsync(directory) == 0 else { throw ProxyJournalFailure.io }
  }

  private static func state(_ value: NetworkProtocolState) -> [String: Any] {
    var result: [String: Any] = ["enabled": value.enabled]
    if let dictionary = value.configuration { result["configuration"] = dictionary }
    return result
  }

  private static func encode(_ snapshots: [NetworkSettingKind: NetworkSettingsSnapshot]) throws -> Data {
    guard snapshots.keys.allSatisfy({ $0 == .proxy }) else { throw ProxyJournalFailure.corrupt }
    let entries: [[String: Any]] = snapshots.values.map {
      ["kind": "proxy", "service": $0.service, "original": state($0.original),
       "applied": state($0.applied), "phase": $0.phase.rawValue]
    }
    let value: [String: Any] = ["schema": 1, "entries": entries]
    guard PropertyListSerialization.propertyList(value, isValidFor: .binary) else { throw ProxyJournalFailure.corrupt }
    let data = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    guard data.count <= maximumBytes else { throw ProxyJournalFailure.corrupt }
    _ = try decode(data)
    return data
  }

  private static func decodeState(_ value: Any?) throws -> NetworkProtocolState {
    guard let dictionary = value as? [String: Any],
          Set(dictionary.keys).isSubset(of: ["enabled", "configuration"]),
          let enabled = dictionary["enabled"] as? NSNumber,
          CFGetTypeID(enabled) == CFBooleanGetTypeID() else { throw ProxyJournalFailure.corrupt }
    if let raw = dictionary["configuration"], !(raw is [String: Any]) { throw ProxyJournalFailure.corrupt }
    return NetworkProtocolState(configuration: dictionary["configuration"] as? [String: Any], enabled: enabled.boolValue)
  }

  private static func decode(_ data: Data) throws -> [NetworkSettingKind: NetworkSettingsSnapshot] {
    guard let value = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
          Set(value.keys) == ["schema", "entries"], let schema = value["schema"] as? NSNumber,
          CFGetTypeID(schema) != CFBooleanGetTypeID(), schema.intValue == 1,
          let entries = value["entries"] as? [[String: Any]], entries.count <= 1 else { throw ProxyJournalFailure.corrupt }
    guard let entry = entries.first else { return [:] }
    guard Set(entry.keys) == ["kind", "service", "original", "applied", "phase"],
          entry["kind"] as? String == "proxy", let service = entry["service"] as? String,
          !service.isEmpty, service.utf8.count <= 128,
          service.utf8.allSatisfy({ $0 == 45 || (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }),
          let rawPhase = entry["phase"] as? String, let phase = NetworkSettingsPhase(rawValue: rawPhase) else {
      throw ProxyJournalFailure.corrupt
    }
    let applied = try decodeState(entry["applied"])
    guard applied.enabled, let configuration = applied.configuration,
          let port = configuration["HTTPPort"] as? Int,
          let bypass = configuration["ExceptionsList"] as? [String],
          configuration["ProxyAutoConfigEnable"] as? Int == 0,
          configuration["ProxyAutoDiscoveryEnable"] as? Int == 0 else { throw ProxyJournalFailure.corrupt }
    do { try ProxyHelperIdentity.validate(port: port, bypass: bypass) }
    catch { throw ProxyJournalFailure.corrupt }
    for prefix in ["HTTP", "HTTPS", "SOCKS"] {
      guard configuration["\(prefix)Enable"] as? Int == 1,
            configuration["\(prefix)Proxy"] as? String == "127.0.0.1",
            configuration["\(prefix)Port"] as? Int == port else { throw ProxyJournalFailure.corrupt }
    }
    return [.proxy: NetworkSettingsSnapshot(service: service, original: try decodeState(entry["original"]),
                                            applied: applied, phase: phase)]
  }

  deinit { close(lockFile); close(directory) }
}
