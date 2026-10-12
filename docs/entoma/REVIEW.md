# Entoma MVP review package

Review the HEAD of `codex/entoma-solution-mvp` against
`b8cc86af02c4aff50fde2b3fe54309617b2e86c1`. Delivery reports and the draft PR supply
the full candidate SHA and its CI run; this document deliberately does not claim
that a future commit or unsigned installer has passed formal release review.

## Result and authority

The existing formal Entoma checkout is reused. FlClash UI/core/platform components
provide profiles, nodes, delay tests, routing, connection, settings and diagnostics.
`lib/solution` owns HTTPS account, subscription and business integration. The live
app no longer initializes XBoard credentials, WebSocket or remote-task services.
The legacy SDK remains pinned for source generation. No Solution/V2Board code or
database, production deployment, business payment or notification was changed.

User passwords are transient form/request values. Tokens and mutation journals use
native secure storage. Subscription configuration contains node credentials because
the core needs them; owned cached files use restrictive permissions and are never
included in evidence, source control or installers. The last valid file/core state
is retained on API or configuration failures.

## Focused review surfaces

| Surface | Files / invariants | Regression evidence |
| --- | --- | --- |
| HTTPS / auth | `lib/solution/api.dart`, `session.dart`; exact HTTPS origin, valid TLS, no redirects or automatic POST retries, bounded responses, opaque Bearer | `solution_test.dart`, `solution_auth_contract_test.dart` |
| Session isolation | serialized vault writes, generation checks after async boundaries, UNKNOWN journal before transmission, storage failure locks mutations | `solution_races_test.dart`; blocked native-read test |
| Subscription | `configuration.dart`, `subscription.dart`; bounded YAML, allowed data plane, local control stripped, TLS bypass rejected, stage/validate/apply rollback, account ownership | subscription safety tests, live core smoke |
| Payments | `shop_page.dart`; no client price calculation/status authority, exact create/checkout DTO, validated HTTPS action, authoritative readback, disposed/stale page cannot launch | `solution_payment_page_test.dart`: QR/redirect/finished, terminal polling, dispose/logout, server amount, coupon rejection, lost response |
| Native startup | `lib/clash`, `core`, listener patch; bind failure propagates, rejected config keeps old core, owned session callbacks, authenticated IPC | `core_wrapper_test.dart`, 9 Go tests, live startup/stop/traffic |
| Desktop permissions | per-launch TUN authorization, stamped core SHA, no live persistent setuid/Windows helper, private macOS socket | source review; elevated device flows NOT VERIFIED |
| System proxy | macOS SystemConfiguration and Windows WinInet adapters snapshot/read back/restore owned settings, preserve later external changes | source review; OS mutation/device QA NOT VERIFIED |
| Android VPN | native start callback carries actual outcome, captured service connection generation, explicit private components, backup/cleartext off | build; device permission/VPN QA NOT VERIFIED |

## Current evidence classes

- Flutter: 73 automated tests passed locally, including account, parser, session
  races, timed-out native read single-flight/recovery, stale storage notice and
  real payment-page widget tests. Static analysis produced zero errors;
  warning/info diagnostics remain in legacy app and new style-only lines. Analysis
  flags tolerate warnings/info and do not silently convert them into clean lint.
- Go: core tests passed with `CGO_ENABLED=0 go test -tags=with_gvisor ./...`.
- Real STG: login, active account, wallet, subscription overview, 6 products,
  7 orders, 2 billing methods, tickets and referrals were read successfully.
  The final replay used an existing loopback proxy for API HTTPS transport after
  direct network timeouts. It did not enable Entoma system proxy or TUN.
- Real core: 4 SS subscription nodes parsed/validated; authenticated Entoma IPC,
  start, node selection, positive delay, TLS HTTPS forwarding and positive traffic;
  the active HTTPS connection chain contains the selected SS node and group and
  excludes DIRECT. The probe forces one MATCH route and uses the existing GUI's
  YAML `rules` to JSON `rule` conversion; this does not change client routing.
  malformed update rejected with forwarding preserved; disconnect released listener.
  Status/count/hash-only evidence is in `evidence/stg-core-smoke.json`.
  Earlier probe records used the YAML field directly on the JSON seam and proved
  DIRECT forwarding only. They do not count as node acceptance; the corrected
  probe and selected-node chain assertion supersede those records.
- macOS GUI: real login, subscription nodes and measured delays, native dashboard,
  connection, HTTP 200/TLS verification through the owned mixed listener, then
  stop and listener release. A later rebuilt ad-hoc bundle's Keychain restore was
  blocked in `SecItemCopyMatching`; deadline regression is tested, but renewed
  system authorization and final GUI session-persistence acceptance remain pending.
- Builds: macOS universal and Android arm64 builds succeeded locally; Windows x64
  installer succeeded on GitHub CI. The final report binds final packages and CI
  to the delivery SHA. Builds do not prove Android/Windows device acceptance.

No live register/reset/email sending, ticket notification, order creation, payment
transaction/provider callback, refund or commission transfer is claimed. Those
normal/error client paths use Mock/widget evidence. STG antiBot is disabled;
enabled reCAPTCHA requires an approved visible challenge entry point and fails
closed today. This is a retained onboarding limitation, not a protection bypass.

## Independent feedback and formal gate

Two frozen-candidate internal reviews identified and led to fixes for session
single-flight/epoch races, mutation completion durability, stale callback ownership,
native listener outcomes, Windows proxy ownership, and packaged core integrity.
Subsequent read-only delta checks confirmed those fixes. The business reviewer also
identified the payment-page delayed-readback race; the final delta adds that fix
and controlled widget regressions. These are internal Engineer quality evidence.

Formal Independent Review: **REQUIRED / PENDING**. The Project + Product Manager
must arrange/accept an independent review of the final candidate before release.
No merge, deployment, signing approval or formal PASS is inferred from this package.

agy Specialist Calls: **5**

- Research Scout: 0
- Root-Cause Challenger: 0
- Design Challenger: 1 (completed)
- Test Designer: 0
- Embedded Reviewer: 4 (0 completed; 1 file-permission failure, 3 timeouts)

Embedded Review Calls: **4 / 0 completed / 4 failed / 0 re-review**.
Two of the failed calls were inline-evidence fallback attempts. agy failure is not
a code finding or a substitute for formal review. No permission bypass was used.

## Release conditions

- Owner macOS Keychain system authorization for the rebuilt test bundle; stable
  distribution signing/notarization and Windows signing, Android release keys.
- Android/Windows devices, plus macOS/Windows TUN and native system proxy QA.
- Approved disposable billing flow and payment-provider callback environment;
  actual email lifecycle/antiBot challenge condition when applicable.
- Final independent safety review accepted through the Project workflow.

Reference installer metadata was inspected read-only. No Moetor package was run,
and proprietary resources were not copied. Visual/behavioral parity beyond the
specified MVP list has not been accepted on those reference applications.
