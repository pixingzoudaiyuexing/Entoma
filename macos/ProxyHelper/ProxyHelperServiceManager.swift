import Foundation
import Security
import Darwin

/// Installer-only control flow. No management command or path is an XPC input.
protocol ProxyHelperServiceBackend {
  func stage() throws
  func stop() throws
  func recover() throws
  func publish() throws
  func start() throws
  func rollback() throws
  func commit() throws
  func remove() throws
}

struct ProxyHelperServiceManager {
  let backend: ProxyHelperServiceBackend
  func install() throws {
    try backend.stage() // Validate/copy before stopping a working service.
    try backend.stop()
    do {
      try backend.recover() // Acquires the original journal lock, restores CAS.
      try backend.publish()
      try backend.start()
      try backend.commit()
    } catch {
      // Restore the previous executable/identity and restart it. A rollback
      // failure is reported, never represented as a successful installation.
      do { try backend.rollback() } catch { throw ProxyHelperFailure.recoveryRequired }
      throw error
    }
  }
  func uninstall() throws {
    try backend.stop()
    do { try backend.recover() }
    catch {
      do { try backend.rollback() } catch { throw ProxyHelperFailure.recoveryRequired }
      throw error
    }
    try backend.remove() // Never delete the journal or its lock inode.
  }
}

struct ProxyHelperRecoveryPlan {
  let binary: Data?
  let receipt: Data?
  let permitsPartialEmptyState: Bool
  init(currentBinary: Data?, currentReceipt: Data?, previousBinary: Data?, previousReceipt: Data?, transaction: Data?) throws {
    if let transaction = transaction {
      guard let state = try PropertyListSerialization.propertyList(from: transaction, format: nil) as? [String: Any],
            state.count == 2, let hadPrevious = state["hadPrevious"] as? Bool,
            let operation = state["operation"] as? String, ["install", "uninstall"].contains(operation) else {
        throw ProxyHelperFailure.recoveryRequired
      }
      permitsPartialEmptyState = !hadPrevious
      if hadPrevious {
        guard let previousBinary = previousBinary, let previousReceipt = previousReceipt else { throw ProxyHelperFailure.recoveryRequired }
        binary = previousBinary; receipt = previousReceipt
      } else {
        // A root-authorized empty-old-state transaction never adopts inert
        // backups, nor mistakes half-published/half-removed files for an install.
        binary = nil; receipt = nil
      }
    } else {
      guard (currentBinary == nil) == (currentReceipt == nil) else { throw ProxyHelperFailure.recoveryRequired }
      binary = currentBinary; receipt = currentReceipt; permitsPartialEmptyState = false
    }
  }
}

final class LaunchdProxyHelperBackend: ProxyHelperServiceBackend {
  private let files: ProxyHelperFiles
  private let launch: ProxyHelperFiles
  private var replacement: Data?
  private var newReceipt: Data?
  private var oldBinary: Data?
  private var oldReceipt: Data?
  private var oldPlist: Data?
  private var published = false
  private var interruptedEmptyInstall = false
  private let installing: Bool
  private let sourceApp: URL?
  private let approvedHashes: [String]

  init(app: URL?, approvedHashes: [String]) throws {
    guard geteuid() == 0 else { throw ProxyHelperFailure.identityRejected }
    self.installing = app != nil
    self.sourceApp = app?.standardizedFileURL.resolvingSymlinksInPath()
    self.approvedHashes = approvedHashes
    files = try ProxyHelperFiles.production(create: app != nil)
    launch = try ProxyHelperFiles.production(create: app != nil, launchDirectory: true)
  }

  func run() throws {
    try files.locked {
      // An interrupted publish has durable old files. Repair it under the same
      // installer lock before accepting another operation.
      let plan = try ProxyHelperRecoveryPlan(currentBinary: files.read("EntomaProxyHelper"),
        currentReceipt: files.read("receipt.plist", limit: 65536), previousBinary: files.read("previous-helper"),
        previousReceipt: files.read("previous-receipt", limit: 65536), transaction: files.read("transaction.plist", limit: 65536))
      oldBinary = plan.binary; oldReceipt = plan.receipt
      interruptedEmptyInstall = plan.permitsPartialEmptyState
      oldPlist = try launch.read(ProxyHelperIdentity.plistName, limit: 65536)
      guard oldPlist == nil || oldBinary != nil || interruptedEmptyInstall else { throw ProxyHelperFailure.recoveryRequired }
      // Refuse to commandeer a legacy/foreign launchd registration.
      if let oldPlist = oldPlist {
        guard let old = try PropertyListSerialization.propertyList(from: oldPlist, format: nil) as? NSDictionary,
              let expected = try PropertyListSerialization.propertyList(from: plistData(), format: nil) as? NSDictionary,
              old == expected else { throw ProxyHelperFailure.identityRejected }
      }
      let manager = ProxyHelperServiceManager(backend: self)
      if installing { try manager.install() } else { try manager.uninstall() }
    }
  }

  private func launchctl(_ arguments: [String]) throws -> Int32 {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    child.arguments = arguments
    child.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
    child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
    try child.run(); child.waitUntilExit()
    return child.terminationStatus
  }
  private var loaded: Bool { get throws {
    try launchctl(["print", "system/" + ProxyHelperIdentity.serviceName]) == 0
  } }
  private func plistData() throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: [
      "Label": ProxyHelperIdentity.serviceName,
      "ProgramArguments": [ProxyHelperFiles.binaryPath],
      "MachServices": [ProxyHelperIdentity.serviceName: true],
      "RunAtLoad": true, "KeepAlive": true, "ThrottleInterval": 10,
      "ProcessType": "Interactive", "Umask": 63,
    ], format: .xml, options: 0)
  }

  func stage() throws {
    guard let app = sourceApp else { throw ProxyHelperFailure.invalidInput }
    let executable = app.appendingPathComponent("Contents/MacOS/EntomaProxyHelper")
    guard app.pathExtension == "app",
          Bundle(url: app)?.bundleIdentifier == ProxyHelperIdentity.appIdentifier else { throw ProxyHelperFailure.identityRejected }
    let appHashes = try ProxyHelperIdentity.hashes(at: app, identifier: ProxyHelperIdentity.appIdentifier)
    guard approvedHashes.count == 1, appHashes.contains(approvedHashes[0]) else { throw ProxyHelperFailure.identityRejected }
    let helperHashes = try ProxyHelperIdentity.hashes(at: executable, identifier: ProxyHelperIdentity.helperIdentifier)
    // Pin to the running installer too, not just a replaceable source pathname.
    var running: SecCode?; var staticCode: SecStaticCode?; var raw: CFDictionary?
    guard SecCodeCopySelf([], &running) == errSecSuccess, let running = running,
          SecCodeCheckValidity(running, [], nil) == errSecSuccess,
          SecCodeCopyStaticCode(running, [], &staticCode) == errSecSuccess, let staticCode = staticCode,
          SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &raw) == errSecSuccess,
          let hash = (raw as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else { throw ProxyHelperFailure.identityRejected }
    let runningHelperHash = hash.map { String(format: "%02x", $0) }.joined()
    guard helperHashes.contains(runningHelperHash) else { throw ProxyHelperFailure.identityRejected }
    let fd = open(executable.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard fd >= 0 else { throw ProxyHelperFailure.unavailable }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    var state = stat()
    guard fstat(fd, &state) == 0, state.st_mode & S_IFMT == S_IFREG,
          state.st_size > 0, state.st_size <= 67108864 else { throw ProxyHelperFailure.identityRejected }
    let bytes = try handle.read(upToCount: 67108865) ?? Data()
    guard bytes.count == state.st_size else { throw ProxyHelperFailure.identityRejected }
    try files.write("candidate-helper", bytes: bytes, executable: true)
    let candidate = URL(fileURLWithPath: ProxyHelperFiles.directoryPath + "/candidate-helper")
    guard try ProxyHelperIdentity.hashes(at: candidate, identifier: ProxyHelperIdentity.helperIdentifier) == helperHashes,
          try ProxyHelperIdentity.hashes(at: app, identifier: ProxyHelperIdentity.appIdentifier) == appHashes else {
      throw ProxyHelperFailure.identityRejected
    }
    // Publish only the architecture whose execution was authenticated. Another
    // slice of a universal source is neither a new caller nor a root executable
    // approved by the currently running GUI's code identity.
    if helperHashes.count > 1 {
      try files.remove("candidate-thin")
      let thin = Process(); thin.executableURL = URL(fileURLWithPath: "/usr/bin/lipo")
      thin.arguments = [candidate.path, "-thin", ProxyHelperIdentity.architecture, "-output", ProxyHelperFiles.directoryPath + "/candidate-thin"]
      thin.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
      try thin.run(); thin.waitUntilExit()
      guard thin.terminationStatus == 0,
            try ProxyHelperIdentity.hashes(at: URL(fileURLWithPath: ProxyHelperFiles.directoryPath + "/candidate-thin"), identifier: ProxyHelperIdentity.helperIdentifier) == [runningHelperHash] else { throw ProxyHelperFailure.identityRejected }
      replacement = try files.read("candidate-thin")
    } else { replacement = bytes }
    newReceipt = try PropertyListEncoder().encode(ProxyHelperReceipt(
      version: ProxyHelperIdentity.protocolVersion, appHashes: approvedHashes, helperHashes: [runningHelperHash]))
  }

  func stop() throws {
    if try loaded {
      guard (oldBinary != nil && oldReceipt != nil) || interruptedEmptyInstall else { throw ProxyHelperFailure.recoveryRequired }
      guard try launchctl(["bootout", "system/" + ProxyHelperIdentity.serviceName]) == 0 else {
        throw ProxyHelperFailure.unavailable
      }
    }
    guard try !loaded else { throw ProxyHelperFailure.unavailable }
    try files.remove("ready.plist")
  }
  func recover() throws {
    // Keep the original journal/owner.lock. Busy or corrupt recovery fails closed.
    let journal = try SecureProxyJournal.production()
    let owner = OwnedNetworkSettings(backend: RootNetworkSettingsBackend(), journal: journal)
    try owner.recoverJournal()
    try owner.stop(.proxy)
    guard !owner.hasOwnedSettings && !owner.restorationPending else { throw ProxyHelperFailure.restoreFailed }
  }
  func publish() throws {
    guard let bytes = replacement, let receipt = newReceipt else { throw ProxyHelperFailure.unavailable }
    try beginTransaction("install")
    published = true
    try files.write("EntomaProxyHelper", bytes: bytes, executable: true)
    try files.write("receipt.plist", bytes: receipt)
    try launch.write(ProxyHelperIdentity.plistName, bytes: plistData())
  }
  func start() throws {
    guard try launchctl(["enable", "system/" + ProxyHelperIdentity.serviceName]) == 0,
          try launchctl(["bootstrap", "system", ProxyHelperFiles.launchPlist]) == 0 else { throw ProxyHelperFailure.unavailable }
    let deadline = Date().addingTimeInterval(10)
    let expected = try files.read("receipt.plist", limit: 65536)
    while Date() < deadline {
      if let ready = try files.read("ready.plist", limit: 65536),
         let value = try PropertyListSerialization.propertyList(from: ready, format: nil) as? [String: Any],
         value["receipt"] as? Data == expected, let pid = value["pid"] as? Int32,
         pid > 1, kill(pid, 0) == 0 { return }
      Thread.sleep(forTimeInterval: 0.1) // Poll a real startup acknowledgement.
    }
    throw ProxyHelperFailure.unavailable
  }
  func rollback() throws {
    if published, try loaded {
      guard try launchctl(["bootout", "system/" + ProxyHelperIdentity.serviceName]) == 0 else { throw ProxyHelperFailure.recoveryRequired }
    }
    try files.remove("ready.plist")
    if let oldBinary = oldBinary, let oldReceipt = oldReceipt {
      try files.write("EntomaProxyHelper", bytes: oldBinary, executable: true)
      try files.write("receipt.plist", bytes: oldReceipt)
      try launch.write(ProxyHelperIdentity.plistName, bytes: plistData())
      if try !loaded { try start() }
    } else if published {
      try launch.remove(ProxyHelperIdentity.plistName)
      try files.remove("EntomaProxyHelper"); try files.remove("receipt.plist")
    }
  }
  private func beginTransaction(_ operation: String) throws {
    if let oldBinary = oldBinary, let oldReceipt = oldReceipt {
      try files.write("previous-helper", bytes: oldBinary, executable: true)
      try files.write("previous-receipt", bytes: oldReceipt)
    }
    let transaction = try PropertyListSerialization.data(fromPropertyList: ["operation": operation,
      "hadPrevious": oldBinary != nil], format: .binary, options: 0)
    try files.write("transaction.plist", bytes: transaction)
  }
  func commit() throws {
    // Remove the transaction marker first. Leftover backups alone are inert;
    // a crash during cleanup must not roll back a completed healthy upgrade.
    try files.remove("transaction.plist")
    try files.remove("previous-helper"); try files.remove("previous-receipt"); try files.remove("candidate-helper"); try files.remove("candidate-thin")
  }
  func remove() throws {
    guard try !loaded else { throw ProxyHelperFailure.recoveryRequired }
    try beginTransaction("uninstall")
    try launch.remove(ProxyHelperIdentity.plistName)
    try files.remove("EntomaProxyHelper"); try files.remove("receipt.plist")
    try commit()
    try files.remove("ready.plist")
    // The fixed directory and installer lock remain to serialize a later install.
    // NetworkProxy journal/lock remain intact even after successful uninstall.
  }
}
