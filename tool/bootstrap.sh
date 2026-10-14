#!/usr/bin/env bash
set -euo pipefail
ENTOMA_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ENTOMA_ROOT"
git submodule update --init core/Clash.Meta lib/sdk/flutter_xboard_sdk
for ENTOMA_PATCH in mihomo-listener-errors.patch mihomo-android-tun-name.patch; do
  if git -C core/Clash.Meta apply --check "../../patches/$ENTOMA_PATCH"; then
    git -C core/Clash.Meta apply "../../patches/$ENTOMA_PATCH"
  elif ! git -C core/Clash.Meta apply --reverse --check "../../patches/$ENTOMA_PATCH"; then
    printf '%s\n' "The pinned core does not match the reviewed patch: $ENTOMA_PATCH" >&2
    exit 1
  fi
done
(cd lib/sdk/flutter_xboard_sdk && flutter pub get && dart run build_runner build --delete-conflicting-outputs)
flutter pub get
dart run build_runner build --delete-conflicting-outputs
