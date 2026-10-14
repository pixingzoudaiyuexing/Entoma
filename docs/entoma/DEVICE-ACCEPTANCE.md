# Device acceptance — 2026-10-13 / 2026-10-14

Update October 14: Owner manually initiated macOS TUN; real selected-node forwarding,
disconnect, reconnect and normal exit while TUN was active passed. Earlier timeout
attempts remain preserved. This update changes evidence only, not application code.

Result: **PARTIAL; RELEASE PENDING**. This report supersedes the earlier device
status snapshots, not the historical evidence. No payment, production deployment,
release, database change, or merge was performed in this round.

## Source and artifact identity

- Merged baseline: `66f24d28546a5304012a46dd1d24a9d85acd8b2c` (PR #1).
- Accepted test artifacts: CI `38208379068`, source
  `1b764e93d260a2e740949dc99d3908a6208fe652`; runtime equivalent to merged baseline.
- New startup/packaging fix: `55dc0587a582d6d06ecd75202a1d9e28fe98e737`,
  [Draft PR #2](https://github.com/pixingzoudaiyuexing/Entoma/pull/2).
- [CI 38385207448](https://github.com/pixingzoudaiyuexing/Entoma/actions/runs/38385207448)
  built and analyzed that exact fix on Android, Windows and macOS: all successful.
- Android QA is a separate package, `com.entoma.client.acceptance`, preserving
  the installed original app and its data. It uses the startup runtime delta and
  the accepted CI native core, not the newly rebuilt CI native core. Its temporary
  package ID/display label are not product source changes. A later braces-only
  formatting edit and Windows-only CMake edit have no Android runtime effect.

| Package | SHA-256 |
| --- | --- |
| Accepted Android APK | `be359fd225c7a73d37a1335b4be8cd4cb566e0679da2b81d9ba9ad0d38b530f7` |
| Accepted Windows installer | `eb945a186ce347e10530162370a5dd23e55380c5a29364bb06481d21216240a8` |
| Accepted macOS PKG | `737b262f9e978daac852b781ce5af2a61c17232bfebef5ab51aeb4b0e32c1b5f` |
| Android QA final APK | `5af556427be6549ab19ce7f8b5fcbf93849566ca0bf99f0927b2eebcf2c857e0` |
| Fix CI Android APK | `2269447b9f740c4374c8ac35693eb77eab9783764d8e98a454c39dd6b76fa2cd` |
| Fix CI Windows installer | `f7b1d695037fb2af21cd41cbd46beecd91711fb8a1ac642b2432bb2591d21a85` |
| Fix CI macOS PKG | `4d78fd25c21a0d320af7356941c02e7538ae8838a85b7c4b94300022184cb06b` |

Packages remain unsigned/test-signed. Fix CI build success is not device acceptance
of those packages. The final Android QA core SHA is
`90816f174e03416f668f83ce5f82648a0fe9d3718cd0ddce98f301ccfba7bc16`.

## Device results

Test sequence followed Owner steering: Android, then remaining Windows work, then
macOS. Tests use Solution STG and its authorized ordinary account. Real device
results, Mock tests and build results remain separate.

| Area | Android | Windows | macOS |
| --- | --- | --- | --- |
| Device | Huawei CDY-AN90, Android 10/API 29, arm64 | Windows 11 Pro 10.0.26300/build 26300, x64, authorized RDP | macOS 15.7.4/24G517, arm64 |
| Install/start | PASS original and QA | PASS after Owner installed VC++ Runtime; original package has clean-install dependency gap | PASS accepted package/portable binary provenance; release signing not tested |
| STG login/account/subscription | PASS original and QA | PASS original | PASS accepted original |
| Login after cold restart | PASS session; original core FAIL | PASS session and fresh account read | PASS session and fresh account information |
| Cold core/config restore | FAIL original; PASS twice in final QA | PASS original | Ordinary startup PASS; timeout recovery requires explicit reconnect |
| Selected-node real HTTPS | PASS original and QA; default TLS, no explicit HTTP proxy, core chain excludes DIRECT | PASS system proxy, default HTTPS and selected-node core chain | PASS earlier controlled system proxy and Owner-initiated TUN, selected-node core chains |
| Repeated TUN connection | FAIL mixed in original and QA; gVisor comparison passes two connections | BLOCKED | PASS Owner-initiated start and reconnect; earlier deadline failures retained |
| Background/node switch | PASS original; QA background NOT VERIFIED | NOT TESTED background/sleep | NOT TESTED sleep/wake |
| Disconnect | PASS VPN agent/FGS/notice cleanup; no FD claim | PASS WinINet exact snapshot and port release | PASS Owner TUN cycle: seven-service network snapshot restored, owned interface/routes and port cleaned; earlier ambiguous proxy cycle retained |
| Normal exit | Process cold-stop tested; independent normal-exit-under-active-VPN NOT TESTED | PASS GUI/core/port gone and native snapshot restored | PASS while TUN active; active-system-proxy exit remains NOT TESTED conclusively |
| Logout then cold start | PASS final QA; profiles page empty | PASS original; profiles page empty | PASS original; profiles page empty |
| Offline startup/LKG | PASS final QA, no active network, nodes retained after failed refresh | NOT TESTED | Earlier timeout LKG hash retained; complete API-outage test NOT TESTED |
| Overall | **FAIL** default mixed reconnect; QA startup improvement verified | **BLOCKED** remaining environment-dependent tests | **FAIL** repeat network-permission UX remains unresolved; tested TUN flow PASS |

### Actual forwarding evidence

Android original: VPN network ownership/UID coverage, Java HTTPS with
`Proxy.NO_PROXY`, HTTP 200 and a TUN-origin `test` node chain; also background and
second-node traffic. Final QA: owner-approved VPN, active owner UID 10198 including
shell UID, foreground service, HTTP 200 and core log `萌兔云[test]` at
19:13:45/19:16:10 on October 13. The QA launcher screenshot was obtained after the
first request, so it does not independently prove QA background forwarding.
A cold-start HTTPS probe with no VPN is retained as
a **DIRECT control**, never counted as client forwarding.

Windows original: WinINet flags changed from 9 to 3, loopback proxy 7890, listener
present, system-selected-proxy HTTPS 200 and the GUI core `test` chain. Disconnect
restored all five queried WinINet options, flags 9 and listener count 0. Normal quit
left GUI/core/port counts 0 and restored the snapshot. Cold restart fetched current
account information; logout and another cold start showed empty login and profiles.

macOS original: earlier controlled test changed only the primary service to
17890, default URLSession HTTPS 200 plus selected-node chain, then exact seven-service
snapshot restoration and listener release. In the final phase, native readback again
confirmed primary-only 17890 and default HTTPS 200; the fresh filtered chain was
not obtained, so that later HTTP 200 is not an additional selected-node proof.
Final proxy flags were off before shutdown. A later raw proxy dictionary retained
disabled port/bypass fields and did not equal that cycle's baseline; no silent
"exact restoration" claim is made for that cycle. Seven-service changes observed
outside the earlier controlled window remain unattributed. Another proxy core was
running; its presence does not establish responsibility.

Owner-initiated macOS TUN on October 14: native root core PID 70099 appeared at
12:08:39, then a new `utun6` at 12:08:42; the other six interfaces were pre-existing.
System proxy remained OFF. Default URLSession HTTPS returned 200, with normal TLS
validation and no explicit proxy; target route was `utun6`. The core log at
12:56:22 showed `www.cloudflare.com:443` through `萌兔云[test]`, excluding DIRECT.
The TUN interface counters increased; that interval also includes background traffic.
Disconnect removed utun6 and its route entries, released port 17890, restored all
seven service proxy/DNS settings and returned the target route to en0. Reconnect
reused the same root core, returned HTTPS 200 and a fresh `test` chain at 13:07:36.
Normal menu quit while TUN remained active left GUI/core counts 0, no owned interface,
route or listener, and exact service/effective-proxy snapshot restoration. No UI read
was made after quit before process/network verification. Full dynamic route-table
equality is not claimed; its changing counters make a raw hash unsuitable.

## Confirmed defects and limitations

1. **Android cold core startup — fixed in PR #2, delta review pending.** Original
   cold restart retained session and cached profile metadata but had empty nodes
   and no connection button. Account ownership restoration could load the cached
   profile before native HomeDir/geodata/CoreState preparation. Prepare the core
   first; storage/preparation failure keeps local account UI but blocks auto-start.
   Two final-QA cold starts restored nodes/button. Five regressions include success,
   preparation failure, ownership failure and storage failure. Exact initial native
   error was not captured on device; do not invent a device GeoIP stack trace.
2. **Windows clean-install runtime — packaging fixed in PR #2, device retest pending.**
   Owner installed VC++ Runtime before successful original startup; the original DLL
   error itself was not captured. New CI ZIP and installer contain eight x64 MSVC
   runtime DLLs beside Entoma.exe, confirmed from files and installer logs. Do not
   uninstall Owner runtime to manufacture a pristine test. New package installation
   is blocked by remote access; pristine-system launch remains NOT TESTED.
3. **Android mixed TUN reconnect — unresolved FAIL.** First QA connection forwards;
   after normal stop/cleanup and reconnect, default and IPv4 HTTPS fail immediately
   (`ConnectException`; IPv4 `ECONNREFUSED`) despite active VPN/FGS. The same-state
   localhost mixed-port request succeeds (HTTP 200/TLS verification 0), selected
   node `test`; node tests remain healthy. This isolates a TUN TCP path, not an app
   crash or proven node failure. gVisor plus VPN HTTP-proxy-off passed two connections
   with selected-node chains; two settings changed, so exact causation is unproven.
   It is a tested workaround, not a fixed default or release acceptance.
   Pinned upstream has a [getTunnelName fix](https://github.com/MetaCubeX/mihomo/commit/f82a36535bec5781a310c3cd14d0359dfc074a55)
   and a subsequent [interface-binding change](https://github.com/MetaCubeX/mihomo/commit/e38aa82a23c1c7b2a7d7ee4ebde50a19ffd72bcc).
   These references do not prove this device's root cause. Native changes require
   a separately reviewed delta; no pinned-core change was made here.
4. **Android UNKNOWN journal recovery — security review required.** NativeSessionVault
   inherits flutter_secure_storage 10 Android `resetOnError:true`. Source and four
   isolated fixture/MethodChannel characterization cases show a possible journal
   loss after storage error, especially a logged-out journal without an active-session
   backup. No real Keystore corruption or duplicate payment was induced. This is
   unresolved in PR #2 and must receive a separate security fix/review or explicit
   risk acceptance; no business write was executed.
5. **macOS repeat network authorization — unresolved UX/permission finding.** Owner
   reports repeated prompts; a closing operation was observed to invoke SecurityAgent
   in this round. Authorization completion did not immediately establish restoration;
   subsequent explicit operation and readback confirmed flags off. Exact prompt
   frequency within a short session is not proven. Current plugin caches an in-process
   AuthorizationRef but has no persistent helper. Do not bypass OS authorization or
   silently add a privileged service. Scope any helper/rights change for formal review.
6. **macOS TUN — PASS for the subsequent Owner-initiated cycle.** The earlier retry reported `Core authentication timed out`;
   no live core and no new utun interface (same six pre-existing interfaces).
   Owner subsequently reported that no administrator dialog was visible for this
   attempt. SecurityAgent was observed initially, but that does not prove a visible
   TUN prompt. The authorization/launch path remains unresolved; the timeout is not
   attributed to Owner declining or delaying authorization.
   TUN off plus explicit ordinary reconnect restored the core; then disconnected.
   Owner subsequently clicked Connect with TUN selected and system proxy off;
   an actual root core and new utun6 appeared. Real selected-node HTTPS, disconnect,
   reconnect and normal exit while TUN active passed as described above. The earlier
   timeout remains an unresolved failure path; this success does not prove reliable
   unattended authorization or resolve the separate repeated network-setting prompt.
7. **Windows remaining tests — BLOCKED.** Service-provider VNC reports connection
   failure; Owner confirms maintenance. RDP reconnect reports account locked,
   `0xd07`; no repeated credential attempts or bypass. TUN was never started and
   routes were not changed. Restore provider VNC and account access before TUN,
   new-installer, background and failure-recovery checks. Already passed cases need
   not be repeated unless the tested package changes.

Core crash/reconnect injection, sleep/wake, complete per-platform API timeout
coverage, Android FD/GlobalRef measurement and real business writes remain NOT TESTED.

## Validation and exact review surface

- Local Flutter tests: **125 passed**, including five startup regressions. Removing
  core preparation makes the relevant regressions fail; restoring it makes all five pass.
- Go core tests: `CGO_ENABLED=0 go test -tags=with_gvisor ./...` passed.
- Local Dart analysis: 0 errors, 22 retained warnings and 94 infos. Local
  `flutter analyze` failed in the Flutter tool's Unicode LSP framing; exact fix CI
  analyzed and tested all three platforms successfully. Do not report local Flutter
  analysis as passed or reuse the old symlink workaround as a newly verified result.
- Android QA/local build passed; exact fix CI builds APK, Windows installer and macOS PKG.
- Runtime diff: `git diff 66f24d2..55dc058 -- lib/application.dart lib/controller.dart
  lib/solution/session.dart test/cold_start_regression_test.dart windows/CMakeLists.txt`.
  Five files, 221 additions/10 deletions; no V2Board/Solution/runtime-permission changes.
- The pre-existing modified `core/Clash.Meta` checkout is preserved and not included
  as a new submodule change. Embedded checks are not Formal Delta Re-review.
- **Formal Delta Re-review: PENDING. PR #2 remains Draft; no merge recommended until
  accepted. Broad user beta and formal release are not ready.** Engineer/device-only
  controlled testing may continue with these known boundaries and no financial writes.

## Evidence and cleanup

Machine-readable safe summary: `evidence/device-acceptance.json`. Detailed retained
local evidence is under `dist/device-acceptance/66f24d2`; snapshots include hashes,
status, process counts and deliberately selected core chains. Older false-positive
regex/quit observations are preserved as historical, not acceptance conclusions.
Private baseline, raw subscription bytes, credentials, VNC session URLs and installers
are not committed. The Android task probe/ADB forward were removed; Wi-Fi restored
and validated, QA process stopped, no active QA VPN/foreground service. Original app
data was preserved. QA gVisor setting is a documented comparison setting, not a new
default. Temporary diagnostic logging/settings were used; these are not release defaults.
macOS ended disconnected with TUN/system proxy off and the account logged out.
In the subsequent Owner-initiated TUN cycle, an account-owned subscription profile
was available before testing. The app ended fully exited with no active owned
TUN/port/system proxy; this test did not log out or clear account/profile data.
The saved TUN mode may remain selected,
which does not itself mean a running connection.

agy Specialist Calls: 3 — Research Scout 0; Root-Cause Challenger 2; Design Challenger 0;
Test Designer 0; Embedded Reviewer 1. One challenge completed, one was denied read
access; embedded review timed out. Two launcher/argument rejections occurred before
agent start and are not counted. Embedded Review Calls: 1 / 0 completed / 1 failed /
0 re-review. Additional read-only Codex embedded checks completed; no formal verdict
is inferred from them.
