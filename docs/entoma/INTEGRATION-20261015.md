# Reviewed integration preflight — 2026-10-15

## Scope and immutable anchors

This is a preflight candidate, not final main or release acceptance.
Main at investigation: `0c77d0b8f337405fbacea833cb7db5b4dbe8846a`.
Reviewed PRs, integrated in this order without textual conflicts:

| PR | Accepted head | Accepted CI |
| --- | --- | --- |
| #3 | `f49b44576b17f72c43920f79e80bb44f7811f660` | 38536044433 |
| #5 | `53f661e470d9774df788ddb470d27fb53f3f7c03` | 38594076691 |
| #4 | `2bbd1eb207c9cb44e47622f25423f1352bf1314c` | 38543405272 |

The frozen combined reviewed tree is commit
`a01eb29cbaf9f937cb15b2612242f76f1468e7ad`.
PR #5 remains stacked on the security branch; do not retarget or merge it until
preflight and the additional review gate below pass.
Core remains pinned to `413467ae6b3665fa63d072f18dfccd871c9cda6a`, with both
owned listener-errors and Android TUN-failed-stack patches applied. No submodule
checkout was reset or cleaned. Journal implementation, native reconnect patch,
OS permissions and core pin are unchanged by the new integration correction.
Ordinary Android/Dart acceptance diagnostics remain opt-in and disabled by the
normal build scripts; no acceptance flag is passed by artifact CI.

## UX-001

Separate commit `9def902281c48ab9c8b022093db7fdbe616d1299` changes only
`lib/widgets/scaffold.dart` and `test/search_close_regression_test.dart`.
Pure search no longer installs a desktop window-close blocker. Page Back still
ends search. Editing and independent hard blockers retain their protection.
The existing controller exit/network cleanup entry point is unchanged.
Six widget regressions pass (Windows/macOS/Linux, Android Back, editing, modal).
The historical Windows X/Alt+F4 reproduction remains the device baseline;
this candidate has not yet been substituted for that runtime evidence.

## ENTOMA-INT-001 — additional formal Delta review REQUIRED

The accepted changes have a semantic interaction: a subscription refresh can
finish validation while macOS exit is waiting for configuration/network restore.
The previous `applyProfile` silently returned when closing, so refresh treated a
skipped core load as success, saved candidate metadata and deleted its LKG backup.
If OS restore was cancelled and the app remained open, disk/UI could describe a
new configuration while the running core retained the old one.

The runnable regression on the frozen combined tree failed because refresh
succeeded instead of rejecting before replacement. This is a new integration
finding, not permission refusal attributed to Owner or a test-only assertion.

Correction:

- Admit the file/core/persistence transaction before replacing a profile; reject
  new admissions during exit without changing LKG.
- Include each admitted transaction in the existing core-operation drain, through
  persistence and rollback, before native DNS/proxy restore or shutdown.
- Use a private controller-local zone lease, expired in the transaction finally.
  An admitted transaction may finish only on the existing core with the current
  TUN privilege. It cannot authorize/restart a different core while closing.
- Explicitly fail skipped configuration application; cancel late UI callbacks
  only for the typed exit-cancellation error. Other failures keep existing paths.
- Non-macOS transaction behavior remains `Future.sync`; no native permission,
  Journal recovery, payment behavior or default network stack is changed.

Review the correction against `9def902` separately from the already accepted PRs.
Do not merge the three PRs while this additional gate remains pending. The task
requires new risk/conflicts to be corrected and reviewed before formal merges.
Embedded review and passing tests cannot replace that decision.

## Executed local evidence

| Check | Result | Boundary |
| --- | --- | --- |
| Frozen combined Flutter suite | 174 PASS | Before UX and integration correction |
| Final candidate Flutter suite | 184 PASS | 6 UX + 4 subscription/exit cases added |
| Go `CGO_ENABLED=0 go test -tags=with_gvisor ./...` | PASS | Core, bridge and state packages |
| Swift native ownership seam | 17 PASS | In-memory backend; no OS configuration changed |
| Focused Dart analysis | 0 errors / 0 warnings | 7 retained style infos |
| Subscription/exit baseline | FAIL as expected | Refresh silently succeeded while closing |
| Drain mutation | FAIL as expected | Removing tracked registration restores premature cleanup |

Four real-controller/real-temporary-file integration cases cover pre-admission
exit, admitted commit, admitted rollback and exit waiting through durable save.
The native restore channels/core/API are fixtures; these are not live TUN or
production acceptance claims. Late callback protection is also exercised by the
existing macOS proxy ownership test.

Private logs, including failed fixture iterations and the genuine red/mutation
proof, are retained under the formal checkout's ignored
`dist/integration-20261015/`. No credentials or raw subscription content are
included in this report. Three-platform candidate artifact CI must be recorded
against its exact committed SHA before review handoff; the old per-PR CI is not
combination evidence.

## Next gate and preserved limits

After new Delta review acceptance: perform #3 → #5 → #4 normal merges, integrate
this correction/UX commit without history rewrite, compare final main runtime
sources to the tested candidate and run exact final-main CI. Device regression
must then use those final-main packages; candidate CI alone does not satisfy it.

Historical Huawei/macOS/Windows evidence remains available in their existing
device reports. This document makes no final combined-device PASS claim. The
new final-main checks, upgrade/Keystore/mixed reconnect and Journal fault tests,
Windows VNC system proxy/TUN/cleanup and macOS permission/cleanup are pending.

Release gates stay open: stable Android distribution signing and repeatable
upgrade, genuinely clean Windows runtime installation, macOS long-term repeated
authorization UX, server-side payment idempotency/reconciliation, broad ROM/
IPv6/power compatibility, signing/notarization and GPLv3 matching source delivery.
No real payment, Release, public distribution, production change, sudoers change
or privileged persistent helper is authorized or performed.
