# Entoma client MVP

This client reuses FlClash's native core, dashboard, node/group selection, delay tests,
profiles, settings, tray/window integration, logs and platform VPN components. It
uses an independent HTTPS Solution adapter for accounts and business features.

## Anchors and authority

- Entoma base: `b8cc86af02c4aff50fde2b3fe54309617b2e86c1`.
- Solution public-contract checkout: `704fc8ebfca88e4ae76e5f7c067acd6170c819d2`.
- Current STG deployment confirmed by read-only Cloudflare deployment metadata:
  version `300b9257-5a5f-4efd-bf81-154ddd4564fc`, 100%, source annotation
  `d5a91bdec12e71b1d76f5b71e069b7809b567a9b` (JSON product features).
  This is distinct from remote Solution main. Extra product presentation fields
  are optional; authentication, price and order DTOs retain the stable contract.
- Core submodule: `413467ae6b3665fa63d072f18dfccd871c9cda6a` plus
  `patches/mihomo-listener-errors.patch`. The patch propagates TCP/UDP/TUN bind errors.
- XBoard SDK submodule: `d595221a2cdd88ae6ad25eb09507b779984100d3`, retained for
  legacy source generation and analysis; not initialized on the live app path.

The default test origin is `https://cc-solution-stg.482658.xyz`. Set the nonsecret
`SOLUTION_ORIGIN` build variable for another approved HTTPS origin. No production
service was changed. V2Board retains all business authority and callback ownership.

## Behavior

- Local interface opens before remote APIs. Session restore and network refresh run
  after the first frame. Local proxy profiles remain usable during API outages.
- Login/register/email code/password reset use Solution's public contract. Passwords
  are never stored; Token/session and unknown-operation journal use native secure
  storage. macOS uses the ordinary Keychain without sharing/provisioning.
  Native reads have a 10-second deadline, so a pending OS authorization cannot
  indefinitely block local core initialization. An unreadable journal fails closed.
- Account, wallet, current plan, traffic and expiry are read separately. Only a
  confirmed authentication failure clears the session. No client JWT interpretation.
- Subscription content uses `Clash.Meta/...` UA (verified against STG); `mihomo/...`
  returned Base64 SS links on this deployment. Downloads carry no account Bearer,
  allow no redirects and must remain on the configured Solution HTTPS origin.
- YAML is bounded, provider/script inputs rejected for this MVP, local control and
  extra listeners stripped, TLS bypass disabled, and automatic/fallback groups added.
  Full core parsing precedes staged replacement. Account-owned profiles have hashed
  IDs; no credential URL is stored in ordinary preferences. Other profiles are preserved.
- Prices are display-only server values. Order creation returns an ID; order detail
  supplies authoritative amount/status. Checkout supports finished, opaque QR data,
  and validated HTTPS redirects. Every action waits for authoritative order status.
- Mutations have durable pending records before transmission. Lost responses are
  UNKNOWN and are not automatically repeated. New-intent recovery requires latest
  records and explicit user confirmation; it never retries the old operation.
- Ordinary notices render as selectable text, without JavaScript execution. Tickets,
  replies, closure, referral codes and commission history use Solution.
- Native desktop TUN uses per-launch system authorization and a core integrity hash;
  the old persistent setuid/Windows helper path is not used. IPC uses random proof,
  private Unix socket permissions, bounded frames and connection deadlines. Random
  proof is not a defense against a fully compromised same-user process that can
  inspect command lines. Windows OS/TUN and macOS elevated operation need device QA.
- System proxy only changes on explicit connection with that mode enabled. Native
  macOS/Windows adapters retain original settings and preserve later external changes.

## Build and checks

Required tools: Flutter 3.44.2/Dart 3.12.2, Go 1.26.4, macOS Xcode/CocoaPods,
Windows Visual Studio including ATL/Inno Setup, or Android JDK17/SDK36/NDK29/CMake3.22.1.

```sh
bash tool/bootstrap.sh
flutter test --no-pub test
(cd core && CGO_ENABLED=0 go test -tags=with_gvisor ./...)
bash tool/build_mvp.sh macos  # Windows/android on their applicable build hosts
```

Flutter 3.44.2's LSP launcher uses character length for Content-Length. A Chinese
checkout path therefore crashes `flutter analyze` before diagnostics. An ASCII
symlink to the same checkout, not another clone, works:

```sh
ln -s /Users/wang/Documents/ChatGPT/客户端/Entoma /tmp/entoma-mvp-source
flutter analyze --no-pub --no-fatal-infos --no-fatal-warnings /tmp/entoma-mvp-source
```

Standalone distributor and SDK subprojects are excluded from app analysis; their
fixed sources are not maintained in this Work Unit. Generated code is excluded.
Existing legacy-code warning/info diagnostics are retained, not counted as errors.

The artifact-only CI uses pinned actions, contents:read and hosted platform runners.
It does not create releases, send notifications, commit changelogs or deploy.
Android without supplied release keys is explicitly a test-signed package.
macOS test PKG and Windows installer are unsigned; distribution signing is separate.

`tool/stg_smoke.dart` reads credentials from stdin and prints only bounded status,
counts and hashes. Passing a core path verifies the actual Entoma IPC core, config
loading, selection, delay, real HTTPS proxy traffic, LKG after malformed input and
listener release. It never changes system proxy or enables TUN. Subscription bytes
stay in process memory; temporary geodata/IPC directories are removed afterward.
The node probe uses a MATCH rule to the selected group and converts YAML `rules`
to the embedded core's singular JSON `rule` field, as the GUI already does. It
requires the HTTPS connection chain to contain the selected node and group and
exclude DIRECT; HTTP 200 alone cannot pass the node-forwarding assertion.
The optional numeric `loopbackProxyPort` stdin field uses an already running local
proxy for the probe's API HTTPS transport only; it changes no system setting and
does not implement client control-channel failover. Evidence records this choice.

## Evidence limits and review

Build, unit/integration, actual API, native forwarding, UI and device evidence are
separate. A successful core return/UI transition is not network forwarding evidence.
The live test account authorizes login, subscription, nodes and read-only business
checks. No real payment, registration, ticket notification, commission transfer or
production operation is inferred from a Mock test.

STG has antiBot disabled. Enabled reCAPTCHA registration still needs an approved
visible challenge acquisition entry point; the client fails closed rather than
turning off server protection. Android/Windows real device and native permission
flows, payment-provider callbacks and release signing require separate conditions.
Formal independent review remains REQUIRED until the Project workflow accepts a
review of the final candidate. Embedded specialist feedback does not replace it.

Ad-hoc macOS test bundles have hash-based signing requirements. A rebuilt binary
may need the user's system authorization to read an older Keychain item. Native
sampling confirmed a synchronous Keychain decrypt wait on this Mac. The read
deadline releases startup but cannot cancel that native operation or approve the
system dialog; continued account operations can still require manual authorization.
No ACL, Keychain contents, TLS policy or OS credential was bypassed or changed.

See `REVIEW.md` for the final review surface, evidence classification and remaining
release gates, and `evidence/stg-core-smoke.json` for sanitized live core evidence.
