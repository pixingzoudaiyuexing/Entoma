# Desktop one-click system proxy

Base: `138558ab90da556c080ddf64cdab6d79e3a78aa1`. NET-002 remains CLOSED;
this task neither reopens Android exit nor replaces its physical acceptance.
The existing `codex/entoma-macos-temporary-session` branch and its commits are
preserved separately. This branch does not silently include that auth change.

## Behavior

The saved `NetworkProps.systemProxy` boolean is a mode preference, not an
instruction to connect on every mount. The session coordinator's `desired`
value starts false. Controller initialization alone decides whether `autoRun`
starts the core and the preferred mode. `autoRun=false` preserves the saved
preference without starting a listener or writing a new proxy. A user intent
issued while initialization is waiting supersedes the late startup decision.

Manager mount/readiness observes state; it never manufactures a connect intent.
Port/bypass changes can reconfigure an established connection, but cannot retry
a failed or disconnected one. Explicit switches and tray actions are submitted
once by the controller. Tray checks use session intent; Retry repeats that
intent, including off/recovery, rather than the saved mode. Manual core start
uses the preferred mode; stopping the core does not erase that preference.

Dashboard, network settings and tray all submit the same system-proxy intent.
`DesktopProxyCoordinator` serializes native writes and rollback, converging on
the latest intent after rapid clicks. Its observable phases are CONNECTING,
CONNECTED, DISCONNECTING, FAILED, plus the initial DISCONNECTED.

Enabling first checks the native backend, validates/loads the selected existing
profile through the real controller, starts the listener if necessary, verifies
a real loopback SOCKS greeting, applies native settings and reads them back.
Only a matching native result with a running core becomes CONNECTED. A failed
backend never becomes success because a saved configuration boolean changed.
Neither the readiness handshake nor CONNECTED alone proves an Internet request
used a selected node; device acceptance still requires an actual HTTPS chain.

Disabling restores the native owned snapshot before releasing a listener. A
failed or unknown restore keeps FAILED and the core available for explicit
retry. Native readback after restore also identifies external configuration
still using the target loopback listener; the coordinator retains the core in
that case instead of stopping a listener that the OS still references.

Only a listener automatically started by this intent, with no TUN or explicit
manual-core user, is eligible for automatic stop. Existing independently running
cores are preserved. The play button remains manual control, not a second step
required to enable system proxy. A newer connect intent supersedes a manual
stop that was still waiting for restoration.

Core loss or later OS proxy changes revoke CONNECTED. They trigger safe
restoration/readback, not an automatic overwrite loop. A user retry is required.
The native adapters preserve third-party changes through their existing CAS
ownership rules and complete proxy/PAC/bypass snapshots.

## Exit and concurrency boundary

macOS and Windows use awaited desktop exit transactions: seal new starts,
cancel pending core launch, drain admitted configuration/core work and the
proxy flight, restore DNS where applicable and the owned proxy, then shutdown
core, destroy IPC, save and exit. Windows no longer relies on a fixed 300 ms
forced exit. Failure keeps the application recoverable. This is a network
recovery change and requires Formal Independent Delta Review.

Configuration rollback failure signals the latest proxy-off intent and unwinds
its current startup action; it must not await the very same proxy flight that
is waiting for that action. Stop operations participate in exit drain. Sealed
exit retains automatic-core ownership if a later exit step fails and resumes.

## Platform split

- Windows continues current-user WinINet. Native readback checks the full flags,
  server, bypass and PAC snapshot. Strict method arguments, failed writes and
  unconfirmed refreshes retain recovery state; no service, Helper or UAC is added
  for ordinary system proxy. TUN retains its separate permission boundary.
- macOS depends on the independently reviewed restricted signed Helper change
  described in [`MACOS-PROXY-HELPER.md`](MACOS-PROXY-HELPER.md). Until it is present,
  approved and signed, the UI reports an explicit unavailable/failed state. It
  does not fall back to repeated ad-hoc elevation or claim success.
- Linux retains its existing adapter. Android VPN behavior is unchanged.

## Validation and delivery gate

Tests cover real dashboard/settings widget taps, real controller rollback-failed
wiring, latest-intent races, listener handshake, native partial failure,
post-restore readback, external listener use, core ownership and exit failure.
The Windows native policy fixture compiles against the production policy header;
it does not claim an actual WinINet/Windows device test.

The artifact workflow includes the new native policy fixture. macOS Helper
compilation/security fixtures are isolated in the Helper change. Local builds,
unsigned package identity, current CI/PR availability and actual device evidence
are recorded in `dist/desktop-proxy-20261016/`; missing evidence remains
BLOCKED/NOT TESTED. Prior Windows and macOS physical evidence is preserved but
does not establish this new one-click flow has passed on those devices.

Both changes require formal independent review before merge. No release,
production deployment, real financial operation, authdb/sudoers modification or
unsigned privileged service installation is authorized by these test results.

PR #8 alone does not implement the new macOS native status protocol. It is not
a macOS runnable/distributable candidate. Review shared control/Windows against
main and the Helper increment against the exact #8 HEAD; use #9's full tree for
combined macOS review and acceptance. Only after accepted review and product
gates may #8 merge normally and #9's base move to main. Record the resulting
base/head and verify the exact delta and runtime tree without rebase/force push.
Do not silently include the independent temporary-session auth branch.

The app's minimum deployment target remains 10.15. The proposed Helper backend
requires macOS13+ and currently removes the old system-proxy path on10.15–12.
That is an unresolved feature-compatibility gap, not approval to drop supported
systems. The macOS combination remains gated until an approved compatibility
implementation or an explicit Owner decision on minimum support; merely keeping
the app build target at10.15 is insufficient. No target or fallback security
policy is changed by this startup-semantic correction.

## References used only for design comparison

- [Clash Verge Rev proxy control](https://github.com/clash-verge-rev/clash-verge-rev/blob/main/src-tauri/src/core/proxy_control.rs)
  and [UI state](https://github.com/clash-verge-rev/clash-verge-rev/blob/main/src/hooks/use-system-proxy-state.ts):
  actual-state feedback and serialized intent, not code copied into this project.
- [ClashX.Meta managers](https://github.com/MetaCubeX/ClashX.Meta/tree/master/ClashX/General/Managers):
  legacy privileged separation examined; its SMJobBless/authorization policy
  is not adopted as this Helper's trust boundary.
- Apple [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)
  and [XPC signing requirement](https://developer.apple.com/documentation/foundation/nsxpcconnection/setcodesigningrequirement(_:))
  are the authoritative service and message identity interfaces.

The references' GPL/AGPL obligations were considered before comparison. No
proprietary samples, source implementation or resources were copied. Entoma's
own GPLv3 corresponding-source/signing/publication checklist remains required.
