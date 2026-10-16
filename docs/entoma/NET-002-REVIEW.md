# NET-002 Delta Review request

Status: **REQUIRED / PENDING. Do not merge Draft PR #7 without formal approval.**

- PR: https://github.com/pixingzoudaiyuexing/Entoma/pull/7
- Base: `83214dd041f5f377d6577319cd290b9bc3a2c67c`
- Runtime candidate: `5dbd1b774ed8f4c11e622ef3e394294ca25d5d1b`
- CI: https://github.com/pixingzoudaiyuexing/Entoma/actions/runs/38859938898
- Device APK SHA-256: `3de5792cf318d9f7d9654497671ecd008fd44b078228ab1088512fe5b347cba9`
- Later evidence-only commits must be compared separately; they do not replace
  the runtime candidate or inherit approval for a changed runtime tree.

## Problem and changed boundaries

The Huawei Android 10 baseline was reproduced in this task: Back with
`minimizeOnExit=false` closed both measured ports but left the VPN foreground
service and `tun0` active. The old Android path did not call `stopVpn` and used a
300 ms forced Activity close. The service wrapper also returned stop success
before cleanup and destroyed the reply engine without awaiting it.

The new Android-only exit transaction seals startup, drains admitted profile work
and retained quick startup, preserves preferences, then awaits native VPN stop,
core shutdown, engine destruction and Activity finishing. A failure does not
authorize an early exit. Unknown core teardown retains the admission gate.

Native scope includes permission/Binder generations, stop single-flight and its
caller deadline, observed service identities/onDestroy acknowledgements, owned
FD readback, foreground notification completion, and engine-destruction guards.
No JNI/Go FD-release policy, mihomo pin, default mixed stack, credentials, payment
Journal or subscription rules were changed.

Preserving the background engine required a private Dart port reattach protocol.
Review quick-start readiness and old/new UI reply ownership together with exit;
ordinary delay/status requests remain concurrent. No public network control API
or acceptance entry point was added. New lifecycle logs contain no credentials,
business payloads or endpoint addresses.

## Validation supplied

- Flutter: 219 tests passed; analyzer completed with no errors and retained
  existing warning/info diagnostics. Go core tests passed.
- Android: 8 JVM tests passed against the production guard/transaction/registry;
  release compilation and the ordinary arm64 APK build passed.
- Mutation evidence covers lost shutdown results, rejected stop acknowledgement,
  reopening admission during unknown teardown, wrong UI reply ownership,
  readiness bypass and unwanted serialization of delay requests.
- Huawei CDY-AN90 / Android 10 / arm64, wireless ADB: same-signature data-preserving
  upgrade from vCode16 to17, retained login/cache, selected-node HTTPS with normal
  TLS, two true exits, independent-process cold start/reconnect, minimize/back with
  background HTTPS, explicit disconnect, reopen/reconnect, node switch and switch
  back. No account/Journal reset or real financial mutation.
- Sanitized device summary and ordered lifecycle log excerpts:
  [`evidence/net002-device.json`](evidence/net002-device.json).
- Full local raw commands, stdout/stderr/exit status, snapshots, APK/source binding,
  mutation logs and Base/Head diff: `dist/net002-20261016/` in the formal checkout.

## Remaining review and evidence limits

1. Huawei denies external access to the app's `/proc/<pid>/fd`. This was not
   bypassed. The ordinary native owned-FD readback is combined with independent
   Service/FGS/TUN/port snapshots. It is conservative and non-atomic; an ambiguous
   reused TUN identity fails closed and is never blindly closed by number.
2. Pending bind before any service onCreate is observed remains a platform
   scheduling boundary. The registry covers late observed instances and the
   exit gate stops late creation; a coroutine yield alone is not proof of every
   AMS/ApplicationThread ordering. Controlled helper tests do not replace a full
   delayed-framework delivery experiment on each Android version.
3. Late permission, Binder, stop failure/timeout and delayed notification cases
   have automated coverage/source guards; not all were fault-injected physically
   on Huawei. Retained quick-engine IPC is tested with real Dart ReceivePorts,
   not claimed as exhaustive quick-settings/ROM acceptance.
4. Android may keep its process cached after Activity/engine destruction. Passing
   exit means no active VPN/FGS/TUN/listener and completed cleanup acknowledgements,
   not that Android must kill the entire cached process.
5. Windows/macOS CI builds are regression evidence, not new physical acceptance.
   H02 remains SYNTHETIC ONLY. Real payment, production deployment, public release,
   distribution signing and broader ROM/IPv6/energy testing remain out of scope.

Internal static review was completed after correcting reattach/readiness and
concurrency issues. One agy Design Challenger call completed; one Embedded
Reviewer call failed due its proxy infrastructure and produced no verdict.
Neither internal support nor CI/device evidence replaces this Formal Independent
Delta Review gate.
