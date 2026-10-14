# macOS network authorization and restoration

This change starts from Entoma main `0c77d0b8f337405fbacea833cb7db5b4dbe8846a`.
It does not install a helper, daemon, rights-database entry, sudoers rule or
background privilege service.

## System proxy and automatic DNS

Both settings now use the proxy plugin's single serial worker queue and cached
`AuthorizationRef` / `SCPreferences` session. Before an actual write, the plugin
checks the existing `system.services.systemconfiguration.network` grant without
interaction, then requests that exact right with interaction only when needed.
An expired/revoked right or macOS policy can still require a system dialog. This
is session reuse, not a promise of permanent authorization.

Authorization takes place before the preferences lock. After authorization and
locking, the plugin rechecks the primary service and the complete current state.
The UI thread remains available while the system authorization waits. Cancel,
denial, external changes and failed restoration have distinct native error codes;
no passwords or authorization payloads are exposed to Dart or logs.

The production `OwnedNetworkSettings` seam retains one snapshot per setting
kind, containing the original service ID, nullable dictionary and protocol
enabled state. Already matching settings are no-ops and do not acquire ownership
or authorization. Restore only overwrites the exact state this process applied;
external dictionary or enabled-only changes are preserved. A network switch
restores the old owned service and leaves the new service untouched. Failed
Apply after successful Commit remains pending and is retried even when the saved
dictionary already equals the original.

Automatic DNS keeps the existing `223.5.5.5` behavior and user DNS entries. It
uses the same native authorization and service ownership, replacing the separate
`networksetup` writer and service-name parsing. Existing resolver entries are
preserved without taking ownership. The provider listener awaits native success
and reports failure rather than silently assuming DNS was changed.

## Normal exit

macOS normal exit no longer races a 300 ms forced-close timer. Its single-flight
coordinator first cancels a pending unauthenticated core launch, waits for current
configuration / connect / restart operations, attempts both owned DNS and proxy
restoration, then shuts down the core, saves preferences and closes the app.
If either restoration fails, it keeps the app open and permits explicit retry.
New macOS start/configuration callbacks check the closing state, including the
continuations after profile validation, configuration application and core restart.
Flutter disposal remains best-effort; it is not the normal-exit completion proof.
Other platform exit behavior is unchanged.

## Validation and acceptance limits

- `bash tool/test_macos_network_ownership.sh` compiles the actual production Swift
  seam with an in-memory backend. It exercises precise ownership, no-op behavior,
  authorization races, external edits, network switch, partial failure and retry.
- `flutter test --no-pub test/macos_exit_test.dart test/macos_dns_channel_test.dart
  test/proxy_ownership_test.dart` checks awaited exit ordering beyond 300 ms,
  concurrent exit, failure/retry, DNS channel routing and existing proxy disposal.
- Swift plugin type-check against the installed FlutterMacOS framework checks
  the native SystemConfiguration / Security integration without changing settings.

These are code-level tests, not proof that a particular macOS version displays a
permission dialog, grants rights, forwards traffic or restores device settings.
Device acceptance must separately record a fresh network baseline, enabled flags,
per-service proxy/DNS equality, active system-proxy quit, permission cancellation,
repeat toggles and TUN lifecycle. Formal independent delta review remains required
for the native permission and exit boundary before a release verdict.

## TUN boundary

The earlier 60-second IPC authentication timer began before `osascript` system
authorization. It therefore included time spent waiting for the OS dialog, and
an absent dialog could not be attributed to Owner delay. The launch boundary is
handled separately by the authorization/launch versus authenticated IPC deadline
split in `lib/clash/service.dart` and `lib/common/core_launch*.dart`.
The proxy/DNS/exit tests do not prove this launch boundary or TUN device acceptance.

## Official references

- Apple's [SCPreferences rights definition](https://github.com/apple-oss-distributions/configd/blob/main/SystemConfiguration.fproj/SCPreferencesPrivate.h)
  and [helper authorization implementation](https://github.com/apple-oss-distributions/configd/blob/main/SystemConfiguration.fproj/helper/SCHelper_server.c)
  establish the exact network right. The plugin uses public Authorization and
  SystemConfiguration APIs, not the private header.
- Apple's [Authorization tasks](https://developer.apple.com/library/archive/documentation/Security/Conceptual/authorization_concepts/03authtasks/authtasks.html)
  describe reusable authorization references and rights acquisition.
- Apple's [Technical Note TN2065](https://developer.apple.com/library/archive/technotes/tn2065/_index.html)
  describes AppleScript administrator authorization behavior; it does not guarantee
  reuse for changing per-launch command strings.

## Launch deadline implementation and local evidence

Elevated macOS launches now have a five-minute authorization/executable-launch
limit. The authorized shell uses noclobber to create a unique non-secret PID marker
in the existing GUI-owned mode-0700 IPC directory immediately before exec. The
marker is mode 0644 so the GUI can read a root-created file; other users cannot
traverse the directory. It contains no token, IPC secret or authorization material.
The original executable SHA-256 verification and random IPC proof remain required.
A marker starts the separate 60-second IPC authentication limit. Successful IPC
authentication cancels both deadlines even when it precedes the marker poll.
Missing authorization/launch and missing authenticated IPC produce distinct errors.

Cancellation retires the launch epoch even before session creation, rechecks it
after server/hash waits, and kills a process handle that arrives after cancellation.
Late cores cannot authenticate to a retired session. Marker polling is stopped
and only that session's marker is removed on authentication, failure or shutdown.
Normal quit cancels a pending unauthenticated launch without killing a running
core before owned network restoration.

Local evidence: 151 Flutter tests passed, including delayed authorization, both
deadline phases, cancellation before hashing/handle completion, quoted readiness
commands, existing-file and symlink refusal. Four actual /bin/sh fixture tests
execute the production shell command with /usr/bin/true, without elevation or
OS network changes. Seventeen production Swift ownership seam tests passed.
The macOS release application built successfully. These results do not replace
root-to-GUI marker verification, native prompt/repeated-toggle tests or active
proxy quit on the actual device; those remain separately recorded acceptance.

## macOS device check on 1f11aa8

Local release build (Entoma executable SHA-256
`cfa986fd431be97b279f0d72434336937f9ae9ba157b9954f28113b9a3c5bceb`)
ran on the current Mac. Cold startup restored the existing session/account.
The system proxy used 17890; explicit-loopback HTTPS returned 200 and the
application's exported target-only evidence confirmed the selected test node,
not DIRECT. After Owner completed one observed network authorization, repeated
off/on operations in that session did not start another SecurityAgent. The
second off restored all seven service proxy/DNS/protocol snapshots exactly.
Normal active-system-proxy quit restored those seven snapshots and left no
Entoma GUI or owned core process. Initial and later snapshots had external
all-service proxy changes during the longer session; do not claim the initial
7890 snapshot was restored by Entoma. The precise repeat-test baseline is
`dist/post-device/0c77d0b8/macos/repeat-baseline.json` in the formal checkout.

Owner then authorized the new TUN launch. A UID-0 core and new utun6 appeared;
default TLS HTTPS with no explicit proxy returned 200, the route selected utun6,
and the target request used the selected test node. Disconnect removed utun6.
The long TUN interval's full network snapshots differ (including all-service
proxy changes outside Entoma's single-service writer), so full DNS/proxy restore
for that interval is NOT CONFIRMED. Preserve the earlier accepted TUN results
without substituting them for this candidate. Root-to-GUI marker timing and
permission cancellation have automated coverage; no forced live permission
cancellation or 5-minute timeout is claimed as a device pass.

Candidate CI `38543405272`: macOS, Windows and Android builds and checks passed.
Formal permission/security Delta Re-review is still pending; PR #4 must not merge
automatically. Windows device acceptance remains blocked by the locked RDP
account and unavailable VNC; no remote login or TUN retry was attempted.
