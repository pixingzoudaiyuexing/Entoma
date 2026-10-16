#!/usr/bin/env bash
set -euo pipefail
ENTOMA_HELPER_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ENTOMA_HELPER_MODE="${1:-}"
ENTOMA_HELPER_OUTPUT="${2:-}"
ENTOMA_HELPER_APP="${3:-}"
if [[ "$ENTOMA_HELPER_MODE" != --compile-only && "$ENTOMA_HELPER_MODE" != --embed ]] || [[ -z "$ENTOMA_HELPER_OUTPUT" ]]; then
  printf '%s\n' 'Usage: build_macos_proxy_helper.sh --compile-only OUTPUT_DIR' \
    '   or: build_macos_proxy_helper.sh --embed OUTPUT_DIR APP_BUNDLE' >&2
  exit 2
fi
if [[ "$ENTOMA_HELPER_MODE" == --embed ]]; then
  : "${ENTOMA_HELPER_SIGNING_IDENTITY:?Developer ID Application identity required; no ad-hoc helper installation}"
  : "${ENTOMA_HELPER_TEAM_ID:?Apple Team ID required}"
  [[ "$ENTOMA_HELPER_SIGNING_IDENTITY" == 'Developer ID Application: '* && "$ENTOMA_HELPER_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || exit 2
  [[ -d "$ENTOMA_HELPER_APP/Contents/MacOS" ]] || exit 2
fi
mkdir -p "$ENTOMA_HELPER_OUTPUT"
ENTOMA_HELPER_OUTPUT="$(cd -- "$ENTOMA_HELPER_OUTPUT" && pwd)"
ENTOMA_HELPER_CACHE="${CLANG_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/entoma-helper-module-cache}"
mkdir -p "$ENTOMA_HELPER_CACHE"
ENTOMA_HELPER_SOURCES=(
  "$ENTOMA_HELPER_ROOT/plugins/proxy/macos/Classes/OwnedNetworkSettings.swift"
  "$ENTOMA_HELPER_ROOT/plugins/proxy/macos/Classes/ProxyHelperProtocol.swift"
  "$ENTOMA_HELPER_ROOT/macos/ProxyHelper/SecureProxyJournal.swift"
  "$ENTOMA_HELPER_ROOT/macos/ProxyHelper/RootNetworkSettingsBackend.swift"
  "$ENTOMA_HELPER_ROOT/macos/ProxyHelper/ProxyHelperCoordinator.swift"
  "$ENTOMA_HELPER_ROOT/macos/ProxyHelper/ProxyHelperMain.swift"
)
for ENTOMA_HELPER_ARCH in arm64 x86_64; do
  xcrun swiftc -swift-version 5 -O -module-cache-path "$ENTOMA_HELPER_CACHE" \
    -target "$ENTOMA_HELPER_ARCH-apple-macos13.0" \
    -framework Foundation -framework Security -framework SystemConfiguration \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$ENTOMA_HELPER_ROOT/macos/ProxyHelper/Info.plist" \
    "${ENTOMA_HELPER_SOURCES[@]}" -o "$ENTOMA_HELPER_OUTPUT/EntomaProxyHelper-$ENTOMA_HELPER_ARCH"
done
xcrun lipo -create "$ENTOMA_HELPER_OUTPUT/EntomaProxyHelper-arm64" \
  "$ENTOMA_HELPER_OUTPUT/EntomaProxyHelper-x86_64" -output "$ENTOMA_HELPER_OUTPUT/EntomaProxyHelper"
if [[ "$ENTOMA_HELPER_MODE" == --compile-only ]]; then
  printf '%s\n' 'Helper compiled only; no Developer ID signing, registration, installation or OS network writes.'
  exit 0
fi
codesign --force --options runtime --timestamp --sign "$ENTOMA_HELPER_SIGNING_IDENTITY" \
  --identifier com.entoma.client.proxy-helper "$ENTOMA_HELPER_OUTPUT/EntomaProxyHelper"
ENTOMA_HELPER_REQUIREMENT="anchor apple generic and identifier \"com.entoma.client.proxy-helper\" and certificate leaf[subject.OU] = \"$ENTOMA_HELPER_TEAM_ID\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
codesign --verify --strict -R "$ENTOMA_HELPER_REQUIREMENT" "$ENTOMA_HELPER_OUTPUT/EntomaProxyHelper"
mkdir -p "$ENTOMA_HELPER_APP/Contents/Library/LaunchDaemons"
install -m 755 "$ENTOMA_HELPER_OUTPUT/EntomaProxyHelper" "$ENTOMA_HELPER_APP/Contents/MacOS/EntomaProxyHelper"
install -m 644 "$ENTOMA_HELPER_ROOT/macos/ProxyHelper/com.entoma.client.proxy-helper.plist" \
  "$ENTOMA_HELPER_APP/Contents/Library/LaunchDaemons/com.entoma.client.proxy-helper.plist"
printf '%s\n' 'Signed helper embedded only; sign the enclosing app and notarize before registration. No service installed.'
