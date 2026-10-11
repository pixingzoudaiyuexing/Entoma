#!/usr/bin/env bash
set -euo pipefail
ENTOMA_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ENTOMA_ROOT"
ENTOMA_PLATFORM="${1:?Usage: build_mvp.sh macos|windows|android}"
ENTOMA_API_ORIGIN="${SOLUTION_ORIGIN:-https://cc-solution-stg.482658.xyz}"
case "$ENTOMA_PLATFORM" in
  macos)
    (cd core && GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 go build -ldflags='-w -s' -tags=with_gvisor -o ../libclash/macos/FlClashCore-arm64 .)
    (cd core && GOOS=darwin GOARCH=amd64 CGO_ENABLED=0 go build -ldflags='-w -s' -tags=with_gvisor -o ../libclash/macos/FlClashCore-amd64 .)
    lipo -create libclash/macos/FlClashCore-arm64 libclash/macos/FlClashCore-amd64 -output libclash/macos/FlClashCore
    ENTOMA_CORE=libclash/macos/FlClashCore
    ;;
  windows)
    (cd core && GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build -ldflags='-w -s' -tags=with_gvisor -o ../libclash/windows/FlClashCore.exe .)
    ENTOMA_CORE=libclash/windows/FlClashCore.exe
    ;;
  android)
    : "${ANDROID_SDK_ROOT:?Set ANDROID_SDK_ROOT}"
    ENTOMA_NDK="$ANDROID_SDK_ROOT/ndk/29.0.14206865"
    if [[ "$(uname -s)" == Darwin ]]; then ENTOMA_NDK_HOST=darwin-x86_64; else ENTOMA_NDK_HOST=linux-x86_64; fi
    (cd core && GOOS=android GOARCH=arm64 CGO_ENABLED=1 CC="$ENTOMA_NDK/toolchains/llvm/prebuilt/$ENTOMA_NDK_HOST/bin/aarch64-linux-android23-clang" CFLAGS='-O3 -Werror' go build -ldflags='-w -s' -tags=with_gvisor -buildmode=c-shared -o ../libclash/android/arm64-v8a/libclash.so .)
    ENTOMA_CORE=libclash/android/arm64-v8a/libclash.so
    ;;
  *) exit 2 ;;
esac
ENTOMA_CORE_HASH="$(dart run tool/hash.dart "$ENTOMA_CORE")"
case "$ENTOMA_PLATFORM" in
  macos) flutter build macos --release --no-pub --dart-define="APP_ENV=stable" --dart-define="CORE_SHA256=$ENTOMA_CORE_HASH" --dart-define="SOLUTION_ORIGIN=$ENTOMA_API_ORIGIN" ;;
  windows) flutter build windows --release --no-pub --dart-define="APP_ENV=stable" --dart-define="CORE_SHA256=$ENTOMA_CORE_HASH" --dart-define="SOLUTION_ORIGIN=$ENTOMA_API_ORIGIN" ;;
  android) flutter build apk --release --target-platform android-arm64 --no-pub --dart-define="SOLUTION_ORIGIN=$ENTOMA_API_ORIGIN" ;;
esac
