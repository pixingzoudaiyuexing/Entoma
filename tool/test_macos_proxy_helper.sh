#!/usr/bin/env bash
set -euo pipefail
ENTOMA_HELPER_TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ENTOMA_HELPER_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/entoma-helper-tests.XXXXXX")"
trap 'rm -rf -- "$ENTOMA_HELPER_TEST_DIR"' EXIT
ENTOMA_HELPER_TEST_CACHE="${CLANG_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/entoma-helper-module-cache}"
mkdir -p "$ENTOMA_HELPER_TEST_CACHE"
xcrun swiftc -swift-version 5 -D ENTOMA_HELPER_TESTING -module-cache-path "$ENTOMA_HELPER_TEST_CACHE" \
  "$ENTOMA_HELPER_TEST_ROOT/plugins/proxy/macos/Classes/OwnedNetworkSettings.swift" \
  "$ENTOMA_HELPER_TEST_ROOT/plugins/proxy/macos/Classes/ProxyHelperProtocol.swift" \
  "$ENTOMA_HELPER_TEST_ROOT/plugins/proxy/macos/Classes/ProxyHelperInstallation.swift" \
  "$ENTOMA_HELPER_TEST_ROOT/macos/ProxyHelper/ProxyHelperServiceManager.swift" \
  "$ENTOMA_HELPER_TEST_ROOT/macos/ProxyHelper/RootNetworkSettingsBackend.swift" \
  "$ENTOMA_HELPER_TEST_ROOT/plugins/proxy/macos/Classes/ProxyHelperClient.swift" \
  "$ENTOMA_HELPER_TEST_ROOT/macos/ProxyHelper/SecureProxyJournal.swift" \
  "$ENTOMA_HELPER_TEST_ROOT/macos/ProxyHelper/ProxyHelperCoordinator.swift" \
  "$ENTOMA_HELPER_TEST_ROOT/test/native/macos_proxy_helper_test.swift" \
  -framework Foundation -framework Security -framework ServiceManagement \
  -o "$ENTOMA_HELPER_TEST_DIR/proxy-helper-tests"
# This is our source-built, uninstalled fixture, not the daemon. Give it the real
# GUI identifier so pinned ad-hoc acceptance exercises the real identity.
codesign --force --options runtime --sign - --identifier com.entoma.client \
  "$ENTOMA_HELPER_TEST_DIR/proxy-helper-tests"
"$ENTOMA_HELPER_TEST_DIR/proxy-helper-tests"
plutil -lint "$ENTOMA_HELPER_TEST_ROOT/macos/ProxyHelper/com.entoma.client.proxy-helper.plist" \
  "$ENTOMA_HELPER_TEST_ROOT/macos/ProxyHelper/Info.plist"
bash "$ENTOMA_HELPER_TEST_ROOT/tool/build_macos_proxy_helper.sh" --compile-only "$ENTOMA_HELPER_TEST_DIR/build"
