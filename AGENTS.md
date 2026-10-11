# Entoma engineering contract

- Formal checkout: `/Users/wang/Documents/ChatGPT/客户端/Entoma`.
- Read `docs/entoma/MVP.md` before changing the Solution integration or native core.
- Preserve FlClash native components and pinned submodules. Apply owned core changes using the reviewed patches in `patches/`; do not silently change submodule commits.
- `lib/solution` is the live account/business adapter. Legacy XBoard initialization, SDK business calls, remote tasks and WebSocket reporting must remain unreachable from the application entry points.
- HTTPS and platform certificate validation are mandatory. Credentials go through native secure storage; never persist passwords or log tokens, credential URLs or raw business payloads.
- V2Board owns prices, entitlement, order and payment state. No automatic mutation retries; preserve durable unknown outcomes across reauthentication and require authoritative readback before a user starts a new intent.
- Subscription updates must validate completely, preserve LKG and unrelated profiles, and restore the active core on failure. Explicit logout removes Entoma-owned account configuration; API failure does not.
- Tests: `flutter test --no-pub test`; core: `cd core && CGO_ENABLED=0 go test -tags=with_gvisor ./...`; build: `tool/bootstrap.sh` then `tool/build_mvp.sh PLATFORM`.
- Formal independent review is REQUIRED for this MVP. Embedded specialist or local test success does not authorize production release, deployment or a final acceptance claim.
