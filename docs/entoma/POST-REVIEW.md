# Entoma MVP post-review delta

Original review baseline: `09fe23ec5e7a183fe2376f3e4150f1965fdcaac1`.
Branch: `codex/entoma-solution-mvp`; existing Draft PR #1 only.

The Project + Product Manager's authorized handoff records the original formal
verdict **PASS WITH CONDITIONS** and five non-blocking findings. No separate
reviewer artifact was present in the checkout or PR review API. This document
preserves that attribution; internal checks below do not constitute the required
**Formal Independent Delta Re-review**, which remains **PENDING**.

## Finding results

| Finding | Result | Implementation and residual boundary |
| --- | --- | --- |
| NB-01 | PARTIAL; safe fallback implemented | Same-order checkout and cancel share a durable lock, including pending/processing. Exact-ID authenticated order GET releases it only on terminal states after secure-store completion. UI offers status refresh, transaction-record verification and the existing support page. No financial POST retry or user acknowledgement can remove this lock. Safe reopening of an unknown payment session remains unsupported by the current API. |
| NB-02 | COMPLETE | Closed, same-ID authoritative ticket GET clears `ticket:close:<id>` after durable writes. Open tickets offer a separate user confirmation and fresh read before one explicit close; no automatic POST. The old journal stays armed until success, and failed recovery stays locked. Concurrent recovery, account generation, storage failure and page lifetime are guarded. The parent refreshes even when reconciliation removes the recovery button. |
| NB-03 | COMPLETE in source/build; Android device verification pending | One Go lifecycle owns each successfully created JNI GlobalRef: nil config, fd0, failed/partial start release it; successful start retains it until synchronous Stop or replacement. Starts/stops serialize; handler close drains callbacks before releasing the reference, and old hook closures capture the old handler. C++ rejects a failed NewGlobalRef and does not double-release Go-owned references. |
| NB-04 | COMPLETE | About calls Entoma's existing GitHub release loader, not uninitialized XBoard services; manual checks report failures and guard disposed pages, including old retry callbacks. deleteProfile awaits final-profile stop and file/provider-directory cleanup before state removal; stop failure retains the profile. Cleanup rechecks current selection. Existing Profiles/Tools entries remain. Switching to a remaining profile still uses the existing profile listener; deletion completion does not itself prove fallback core reload. |
| NB-05 | COMPLETE for the reported Dart ownership defect | Mac/Windows restoration always delegates to native snapshot ownership, including false/null/exceptional partial starts and failed stop retries. Dart maintains a success flag only for Linux. Manager reports failed restoration accurately and queues owned cleanup after an in-flight start on disposal. Native snapshot implementation is unchanged. |

## Contract evidence and scope

Solution's public order detail DTO exposes status, amount and timestamps, not
payment-session identifiers or an authoritative proof that no payment session
exists. V2Board's pinned `99f8526` checkout implementation saves payment_id and
calls the payment provider while the order can remain status=0/pending. Therefore
pending cannot safely unlock another checkout or cancel. The client does not
pretend that opening support resolves an unknown financial outcome. Only a
terminal readback currently unlocks the order; safely continuing a non-terminal
unknown requires a future server-authoritative payment-session/reconciliation
contract, or support resolving the order server-side.

V2Board's ticket close implementation checks owner/id and writes the target
closed status. Repeating this target-state close does not create payment sessions
or send a reply. This limited semantic property justifies the explicit manual
close recovery; it is not generalized to other mutations.

No Solution contract, V2Board rule/database, deployment, production operation,
real payment, real ticket close/reply or other live business mutation was changed.
All new recovery tests use local HTTP fixtures and fake secure/native adapters.
The existing mihomo listener patch and pinned submodule commits are preserved.
Build-generated Android JNI library changes are not source changes and are not
committed. Existing runtime evidence and prior installers are retained.

## Validation at the source candidate

- Flutter: `flutter test --no-pub test`, **120 passed** (73 prior + 47 added).
  Added: 25 recovery service, 7 recovery widget, 6 update/profile and 9 proxy tests.
- Analysis: `flutter analyze --no-pub --no-fatal-infos --no-fatal-warnings`.
  Result: **0 errors, 22 retained warnings, 95 info**.
  Local analysis uses the existing ASCII symlink `/tmp/entoma-mvp-source` to the
  same formal checkout because of the local analyzer's Unicode path issue.
- Go: `CGO_ENABLED=0 go test -tags=with_gvisor ./...`, **12 top-level tests passed**,
  18 pass events including six lifecycle branch subtests.
- Resource concurrency: `go test -race tun_lifecycle.go tun_lifecycle_test.go`
  passed against the production lifecycle helper. Whole-core host CGO/race is
  unavailable because the existing host CGO build lacks `nextHandle`; this is
  not evidence of full Android runtime race freedom.
- Android: local `tool/build_mvp.sh android` passed, including arm64 Go c-shared,
  NDK/JNI C++ and Flutter Release APK. Existing KGP migration warnings remain.
- macOS: local `tool/build_mvp.sh macos` passed (universal core + Flutter Release).
  Existing Swift Package Manager adoption warnings remain.
- Windows and final exact-commit platform build results are recorded in the
  accompanying sanitized post-review evidence after existing CI completes.
- `git diff --check` passed. Initial tests reproduced cross-operation financial
  unlocking and skipped native restoration before the fixes.

Evidence limits: no new production/API-payment, device VPN/TUN or system proxy
mutation acceptance is claimed. Mac/Windows proxy tests use fakes; Android
lifecycle tests prove the shared production owner on the host, not actual device
JNI reference counts or the Android handler's native callback execution. Test
reauthentication covers generation replacement with one fixture account, not
business acceptance across two real accounts.

Unchanged adjacent risks noted by internal source inspection: upstream global
DefaultSocketHook reads/writes have an existing concurrent replacement boundary;
macOS snapshot comparison does not detect an external enabled-only protocol
change when its dictionary stays identical. The local helper race test and this
Dart-only ownership fix do not resolve or accept those native runtime boundaries.
Delta Reviewer should assess these retained risks under the original controlled
testing/release conditions; no unrequested native architecture expansion was made.

## Internal review and formal gate

Read-only Codex specialists inspected the stable business and native/proxy delta
and reported no newly introduced blocking defect. This is embedded engineering
support, not Formal Independent Delta Re-review.

agy Specialist Calls: **1**
- Research Scout: 0
- Root-Cause Challenger: 0
- Design Challenger: 0
- Test Designer: 0
- Embedded Reviewer: 1 (timed out after 120 seconds; no review result)

Embedded Review Calls: **1 / 0 completed / 1 failed / 0 re-review**.
A preceding CLI invocation rejected an invalid timeout argument before starting a
specialist turn; it is recorded as an invocation error, not a completed review.
No permission bypass or separate proxy configuration was used.

The formal delta must compare the original baseline above to the final source
commit recorded in evidence, inspect all five findings and the retained payment
API limitation, then read the documentation-only evidence follow-up. Use:

```sh
git diff 09fe23ec5e7a183fe2376f3e4150f1965fdcaac1 <source-commit>
git diff --check 09fe23ec5e7a183fe2376f3e4150f1965fdcaac1 <source-commit>
```

No merge has been performed. Recommend merging only after the required formal
delta verdict accepts this source candidate and its documented remaining limits.

## Formal distribution checklist

GPLv3 compliance is a release condition, not a license redesign in this delta:

- [ ] Provide the exact corresponding source for distributed binaries, including
  pinned submodule revisions, Entoma/mihomo patches, build scripts and required
  installation/build information; link it from the release.
- [ ] Include GPLv3 license text, preserve required copyright/attribution and
  third-party notices, and mark relevant changes.
- [ ] Choose and verify a GPLv3-compliant source distribution/offer method for each
  distributed installer; do not impose additional restrictions on covered code.
- [ ] Verify release signing/notarization, release keys and controlled native
  device acceptance separately from these unsigned/test installer builds.
