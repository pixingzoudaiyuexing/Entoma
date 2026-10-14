#!/usr/bin/env bash
set -euo pipefail
ENTOMA_TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ENTOMA_SWIFT_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/entoma-network-tests.XXXXXX")"
trap 'rm -rf -- "$ENTOMA_SWIFT_TEST_DIR"' EXIT
swiftc "$ENTOMA_TEST_ROOT/plugins/proxy/macos/Classes/OwnedNetworkSettings.swift" \
  "$ENTOMA_TEST_ROOT/test/native/macos_network_ownership_test.swift" \
  -o "$ENTOMA_SWIFT_TEST_DIR/network-ownership-tests"
"$ENTOMA_SWIFT_TEST_DIR/network-ownership-tests"
