#!/usr/bin/env bash
set -euo pipefail
ENTOMA_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ENTOMA_ROOT"
git submodule update --init core/Clash.Meta lib/sdk/flutter_xboard_sdk
if git -C core/Clash.Meta apply --check ../../patches/mihomo-listener-errors.patch; then
  git -C core/Clash.Meta apply ../../patches/mihomo-listener-errors.patch
elif ! git -C core/Clash.Meta apply --reverse --check ../../patches/mihomo-listener-errors.patch; then
  printf '%s\n' 'The pinned core does not match the reviewed listener patch.' >&2
  exit 1
fi
(cd lib/sdk/flutter_xboard_sdk && flutter pub get && dart run build_runner build --delete-conflicting-outputs)
flutter pub get
dart run build_runner build --delete-conflicting-outputs
