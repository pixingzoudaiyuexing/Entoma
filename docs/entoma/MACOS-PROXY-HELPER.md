# macOS system proxy helper — implementation and review boundary

This change implements the macOS 13+ system-proxy boundary requested by Owner.
It is not permission to merge, install an unsigned daemon, publish a release or
change system security policy. Formal Independent Delta Review remains required.

## Current delivery status

- The standalone helper compiles for arm64 and x86_64 with a macOS 13 deployment
  target. The plugin retains its existing deployment target and guards 13+ APIs.
- Twenty-six fixture groups exercise ownership, durable recovery, input validation,
  unsigned preflight, real anonymous unprivileged XPC replies/timeouts and real
  temporary-file protections. Existing seventeen
  network-ownership fixture groups still cover the in-process DNS path.
- No helper registration, privileged service installation, authorization database
  modification, sudoers change or system network write was performed for these
  tests. Native compiler/fixture success is not signed-XPC or device acceptance.
- This Mac reported `0 valid identities found` from the read-only
  `security find-identity -v -p codesigning` check. Developer ID signing,
  notarization, approval and real helper-driven proxy tests are **BLOCKED**.
- An ad-hoc build fails `StartProxy` / `GetProxyStatus` with
  `HELPER_SIGNING_REQUIRED`. There is no osascript, arbitrary command or legacy
  privileged fallback for system proxy. DNS and TUN keep their separate existing
  authorization boundaries; this helper cannot operate either.

## Compatibility and minimum signing inputs

Owner's2026-10-17 decision makes macOS13.0 the minimum for the first public test
version. The GUI, CocoaPods, owned plugins and Helper now share that supported
minimum; the product installer has an explicit13.0 OS gate. macOS10.15–12 are
unsupported and no fallback is being developed. See [MACOS-13-DELTA.md](MACOS-13-DELTA.md)
for artifact checks and the narrowly scoped review handoff. This product decision
does not waive the new exact-head delta review, signature or device gates.
PR #8 alone also lacks the new native state protocol: combined macOS review must
use PR #9's full tree. Keep the temporary-session branch separate.

The least external inputs for the positive signed-Helper acceptance path are:

1. An effective Developer ID Application signing identity in this Mac's signing
   environment (or a controlled signing executor), with its private key usable by
   codesign. Owner configures it through Apple/Xcode; handoff only the public
   identity name/fingerprint and Team ID, never a private key, P12 password or
   Apple Account password. Recheck validity before building.
2. A macOS13+ controlled test Mac and Owner completion of the first daemon/system
   approval. Existing protected administrator prompts remain Owner operations.
3. For a notarized acceptance artifact, Owner configures a notarytool credential
   profile in that signing environment and supplies only its profile name, or
   returns the signed/notarized artifact with verification evidence. This is not
   needed for code-level review and is not a request for account credentials.
4. If the PKG itself must be signed, Developer ID Installer is additionally
   required; an app ZIP acceptance artifact does not require that second identity.

Apple Development, Apple Distribution, ad-hoc and Developer ID Installer do not
satisfy this implementation's Developer ID Application leaf OID requirement
`1.2.840.113635.100.6.1.13`. A development-signed daemon must not be accepted by
relaxing the production peer requirement to make tests pass. Apple documents the
different code-signing identities in [TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)
and the [certificate overview](https://developer.apple.com/help/account/certificates/certificates-overview/).

After those inputs exist, embed using the existing script, finalize and verify
GUI/helper identities and signature chain, notarize/staple where required, then
test registration, approval, signed XPC, repeated toggles, cold start, denial,
recovery, abnormal exit, safe unregister and selected-node HTTPS chains. Record
the final signed binary hashes, signature requirements, exact source SHA and
before/after network ownership evidence separately. Current unsigned CI PKGs do
not embed the Helper and cannot establish that acceptance.

## Component map

| File | Responsibility |
|---|---|
| `plugins/proxy/macos/Classes/ProxyHelperProtocol.swift` | Fixed ObjC-compatible XPC methods, bounded input, self-signature and peer requirement policy |
| `plugins/proxy/macos/Classes/ProxyHelperClient.swift` | Explicit SMAppService registration/unregistration, authenticated daemon connection and bounded replies |
| `plugins/proxy/macos/Classes/ProxyPlugin.swift` | Flutter channel mapping; retains only DNS on the former Authorization Services backend |
| `plugins/proxy/macos/Classes/OwnedNetworkSettings.swift` | Exact service/dictionary/enabled snapshots, optional durable write-ahead phases and CAS restoration |
| `macos/ProxyHelper/ProxyHelperMain.swift` | Root-only signed daemon entry, console-user check, authenticated listener and termination cleanup |
| `macos/ProxyHelper/ProxyHelperCoordinator.swift` | One serialized owner lease, disconnect recovery, startup recovery and unregister drain |
| `macos/ProxyHelper/RootNetworkSettingsBackend.swift` | Proxy-only SystemConfiguration access without shell or Authorization Services |
| `macos/ProxyHelper/SecureProxyJournal.swift` | Protected fixed directory, FD-relative atomic journal, exclusive lock and strict bounded schema |

The privileged executable exports only `status(port,bypass)`,
`applyProxy(port,bypass)`, `restoreProxy()` and `prepareUnregister()`. The client
cannot pass a service identifier, arbitrary settings dictionary, path, command,
script, executable, DNS record, password, Token or business payload. The host is
always `127.0.0.1`, the port is 1024...65535, and bypass entries are bounded to
256 entries / 1024 UTF-8 bytes each with control characters rejected.

## Identity and privilege boundary

1. GUI and helper inspect their own code signature using public Security APIs.
   The identifier must exactly match `com.entoma.client` or
   `com.entoma.client.proxy-helper`. A valid Developer ID Application trust chain,
   ten-character Team ID, non-ad-hoc signature and hardened runtime are required.
2. Get-task-allow, disabled library validation and DYLD-environment entitlements
   are not permitted by the peer requirement. Release entitlements should omit
   these keys, including keys explicitly set to false.
3. The daemon calls the public macOS 13+
   `NSXPCListener.setConnectionCodeSigningRequirement` before resuming. Invalid
   peers are rejected before the delegate or session creation. Each accepted
   connection also calls `setCodeSigningRequirement` before resuming, checking
   every incoming message. The GUI imposes the same fixed-helper / same-Team
   requirement in the opposite direction.
4. The team comes from the process's validated signature, never from an XPC
   request. Requirement construction validates input and calls
   `SecRequirementCreateWithString` before passing it to Foundation.
5. A daemon connection is additionally limited to the current console user's
   non-root UID. The captured UID is checked again on every apply/status/unregister and
   after lock/journal waits before a new write. Old-owner CAS restoration and
   termination cleanup remain allowed after a user switch. PID/path checks are not used as a substitute for signature
   validation. No private `NSXPCConnection.auditToken` accessor is used.
6. Root is limited to the proxy-only executable. mihomo is not made into a
   persistent privileged helper. This implementation does not change its pin,
   launch process or TUN permissions.

The listener requirement closes identity checks before accepting a connection.
Signed-peer acceptance/rejection still needs a pair of real Developer ID signed
test clients and an approved test daemon; the unsigned fixture does not prove it.

## Ownership and durable recovery

The daemon owns at most one authenticated connection lease. Apply, readback,
restore, disconnect and unregister run on one serial transaction queue. A new
connection cannot apply over another live lease or an unresolved dead lease.
After a disconnected lease, the daemon retries only restoration before allowing
another apply. Normal unregister first drains and restores, checks the result,
then invokes SMAppService; it never kills a daemon as a substitute for restoration.

The journal is fixed to:

`/Library/Application Support/Entoma/NetworkProxy/proxy-journal.plist`

Production opens each directory relative to a verified parent FD with
`O_DIRECTORY | O_NOFOLLOW`. Parents must be root-owned and not group/world
writable; application directories must be private. Extended ACLs are rejected
rather than assuming mode bits capture all write authority. Files must be
regular, private, root-owned, single-link and free of extended ACLs. A separate
exclusive file lock prevents two helper instances from using the same journal.
There is no user-controlled production path. The alternate fixture directory
factory exists only under `ENTOMA_HELPER_TESTING`, absent from the daemon build.
Constructor FDs remain local until all validation and locking succeeds; throwing
initializers do not transfer them into a class that could close them a second
time during deinitialization. A fixture forcibly reuses the exact released FD
numbers for another real inode before error unwind to verify this boundary.

Journal writes use a fresh exclusive temporary file, bounded binary plist,
`fsync(file)`, `renameat` and `fsync(directory)`. Empty state is also written
durably. Full proxy/PAC/bypass dictionaries are sensitive local network metadata;
they remain in this root-private directory and are not logged or returned over
XPC. No account data is placed in this journal.

| Phase | Durable state and recovery rule |
|---|---|
| applying | Save original/applied operands before any system write; a crash may precede or follow commit/apply |
| applied | Save only after commit and apply returned successfully |
| restoring | Save before restoration; crash recovery handles either the exact old-applied or exact original committed state |
| empty | Save only after effective apply succeeded, or after a third-party state was deliberately preserved |

On startup, journal recovery finishes before the listener starts. Recovery never
starts a new proxy. If current settings equal the saved applied state, restore the
exact original service dictionary and enabled flag. If the committed state is
already original but effective apply may have been interrupted, apply again
before clearing the record. A third state is external ownership: preserve it and
clear only Entoma's record. Old-service restoration does not modify a newly
selected primary service.

An existing owned proxy that needs a new port/bypass is restored and durably
cleared before the next apply transaction is prepared. If the next journal rename
lands but its directory fsync fails, the system is already at the baseline; it
cannot remain on old applied A while only new applied B is recorded. An initial
write-ahead failure also rolls the in-memory snapshot back and keeps the failure
gate until safe restoration/persistence succeeds. Fixtures cover errors both
before and after publishing the next record, including process-restart recovery.

Unreadable, corrupt or unsafe journal state is **not empty**. A `journalLoaded`
gate prevents even `stop()` from overwriting unknown data with an empty snapshot.
A write failure prevents the subsequent system mutation. Readback/storage/
restoration errors propagate; no false "restored" reply is generated.

## Flutter channel contract

- `StartProxy`: existing arguments `{port, bypassDomain}`; true only after helper
  success and exact readback for these parameters.
- `StopProxy`: true after acknowledged restore; a plugin instance that has never
  requested a helper mutation has no owned resources to restore. Failed or
  unanswered mutations retain `needsRestoration` and cannot use this no-op path.
- `GetProxyStatus`: same arguments; returns
  `{available, matches, owned, restorationPending, usesListener, protocolVersion, draining}`.
  `matches` uses actual SystemConfiguration readback, exact full applied snapshot
  when owned, port and bypass. A failed read throws, not false success.
  `usesListener` independently observes an enabled HTTP/HTTPS/SOCKS proxy that
  still targets the requested loopback port, even after an external bypass/host
  edit releases ownership. The desktop coordinator must keep an automatically
  started core alive and report this external dependency after restoration;
  successful `StopProxy` alone does not authorize killing a still-used listener.
- `HelperStatus`: registration status only. `enabled` is not a proxy connection
  success claim; the shared desktop coordinator must still read actual status.
- `RegisterHelper`: explicit user action; may return `requiresApproval`. App
  startup and status reads do not register automatically.
- `UnregisterHelper`: prepare/drain/restore acknowledgement before unregister.

Errors include `HELPER_SIGNING_REQUIRED`, `HELPER_REQUIRES_MACOS_13`,
`HELPER_APPROVAL_REQUIRED`, `HELPER_NOT_FOUND`, `HELPER_BUSY`, `HELPER_DRAINING`,
`HELPER_OPERATION_UNKNOWN`, `HELPER_RECOVERY_REQUIRED`, `NETWORK_RESTORE_FAILED`.
Flutter errors include `available:false` and the local potential-restoration flag.
A 10-second RPC deadline is an UNKNOWN result, not operation completion. It
invalidates the XPC connection to trigger helper-side restoration; the core must
remain available while restoration is uncertain. Replies do not expose snapshots.

## Build and signing integration

Pure compile/fixture verification (never runs the daemon):

```bash
bash tool/test_macos_proxy_helper.sh
bash tool/build_macos_proxy_helper.sh --compile-only dist/proxy-helper-compile
```

With the approved signing identity available, stage the helper in an app bundle:

```bash
ENTOMA_HELPER_SIGNING_IDENTITY='Developer ID Application: <approved identity>' \
ENTOMA_HELPER_TEAM_ID='<approved ten-character team>' \
bash tool/build_macos_proxy_helper.sh --embed dist/proxy-helper-signed \
  build/macos/Build/Products/Release/Entoma.app
```

`--embed` refuses missing signing inputs before modifying the app. It compiles a
universal helper, embeds Info.plist in Mach-O, signs with hardened runtime and
validates its Developer ID / identifier / Team requirement, then stages the
binary and launchd plist. It does not register, install or notarize anything. Sign
the enclosing app after staging and notarize it before service registration.
SMAppService APIs do not mean that an ad-hoc build satisfies release conditions.

The current core hash pipeline signs the core ad-hoc before embedding its SHA in
Flutter. For Developer ID builds, sign the core with its **final** identity before
calculating `CORE_SHA256`, then build Flutter, stage/sign helper/frameworks and
sign the enclosing app without rewriting the already-hashed core. A final blanket
`codesign --deep --force` can break core integrity verification and is not a
substitute for the ordered signing pipeline.

Updating the helper/plist requires re-registration. The app must obtain a
successful old-helper drain/restore result before unregistering. The completion
variant of unregister waits for process termination before reporting success or
allowing a user to re-register an updated helper. A completion deadline is an
error, never proof of removal. This patch deliberately provides explicit
registration/unregistration only and does not silently upgrade an active helper.

## Remaining evidence and limits

- BLOCKED: real Developer ID identity, notarization and signed-peer XPC tests;
  first approval, repeated toggles without prompts, app restart, revocation,
  signed upgrade, service removal, target-node HTTPS and real network restoration.
- NOT TESTED: power-loss persistence behavior on supported filesystems. fsync/
  rename fixtures prove the executed API path, not hardware fault resilience.
- UNKNOWN: recovery after root/OS destruction of the entire journal directory,
  root-level rollback/tampering or simultaneous loss of app and helper state.
  A missing record cannot prove Entoma owned pre-existing proxy settings; those
  settings are never guessed from a loopback port.
- The journal is local, not a secret escrow. Helper removal while still owning
  settings or user revocation may prevent restoration until the approved service
  can run again. Surface the failure and retain recovery information.
- A network-service disappearance prevents a trustworthy read/restore; the
  record remains pending. No arbitrary replacement service is written.
- Existing AutoDNS authorization can still request permission independently.
  This patch does not promise to eliminate TUN/DNS permissions or all macOS
  security dialogs.

## Required review and device matrix

Review exact helper/client/plugin/ownership/journal diff, signing requirements,
unregister ordering and GUI state handling before merge. With a signed approved
test bundle: reject wrong Team/identifier/debuggable/unsigned clients; exercise
first approval/denial/revocation; same-port repeated toggles and restart; external
PAC/bypass/enabled changes; service switch; apply/restore callback loss; daemon
kill/restart; journal corruption and denied writes; safe unregister and upgrade.
For every successful connection use a real HTTPS request with selected-node
connection-chain evidence, then verify full proxy snapshot and listener cleanup.

## Primary references (design only; no competitor code copied)

- [Apple SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)
- [Apple daemon registration](https://developer.apple.com/documentation/servicemanagement/smappservice/daemon(plistname:))
- [Apple updating helper executables](https://developer.apple.com/documentation/servicemanagement/updating-helper-executables-from-earlier-versions-of-macos)
- [Apple NSXPCConnection signature requirements](https://developer.apple.com/documentation/foundation/nsxpcconnection/setcodesigningrequirement(_:))
- [Apple NSXPCListener peer requirements](https://developer.apple.com/documentation/foundation/nsxpclistener/setconnectioncodesigningrequirement(_:))

The installed SDK headers were also checked directly. They document the macOS
13 availability, code-signing/notarization and approval requirements. Existing
competitor evidence was reused; historical desktop dynamic behavior remains
NOT AVAILABLE. ClashX.Meta's older SMJobBless implementation and Clash Verge
Rev's state coalescing were consulted as design comparisons only, with their
AGPLv3/GPLv3 licenses checked and no source copied into this implementation.
