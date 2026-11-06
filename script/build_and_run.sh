#!/usr/bin/env bash
# Copyright 2026 Google LLC
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

MODE="${1:-run}"
case "$MODE" in
  run|--build-only|--self-check|--verify|--logs|--telemetry|--debug) ;;
  *)
    echo "usage: $0 [--build-only|--self-check|--verify|--logs|--telemetry|--debug]" >&2
    exit 2
    ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
EXAMPLE_DIR="$ROOT_DIR/mobile/examples/macos_remote_immersive"
APP_NAME=ThreeLiveRemoteImmersive
DERIVED_DATA="$ROOT_DIR/.build/remote-immersive"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
XCODEGEN_BIN="$(command -v xcodegen || true)"

if [[ -z "$XCODEGEN_BIN" ]]; then
  XCODEGEN_BIN="$ROOT_DIR/.build/xcodegen/xcodegen/bin/xcodegen"
  if [[ ! -x "$XCODEGEN_BIN" ]]; then
    mkdir -p "$ROOT_DIR/.build/xcodegen"
    curl -fsSL https://github.com/yonaskolb/XcodeGen/releases/latest/download/xcodegen.zip \
      -o "$ROOT_DIR/.build/xcodegen/xcodegen.zip"
    unzip -qo "$ROOT_DIR/.build/xcodegen/xcodegen.zip" -d "$ROOT_DIR/.build/xcodegen"
  fi
fi

if [[ "$MODE" != --build-only && "$MODE" != --self-check ]]; then
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
fi

USER="${USER:-$(id -un)}" "$XCODEGEN_BIN" generate --spec "$EXAMPLE_DIR/project.yml"
xcodebuild -project "$EXAMPLE_DIR/$APP_NAME.xcodeproj" -scheme "$APP_NAME" \
  -configuration Debug -destination 'platform=macOS' -derivedDataPath "$DERIVED_DATA" build

case "$MODE" in
  --self-check)
    "$APP_BUNDLE/Contents/MacOS/$APP_NAME" --self-check
    ;;
  --build-only)
    echo "$APP_BUNDLE"
    ;;
  --debug)
    /usr/bin/open -n "$APP_BUNDLE"
    lldb -n "$APP_NAME" -w
    ;;
  --logs|--telemetry)
    /usr/bin/open -n "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --verify)
    /usr/bin/open -n "$APP_BUNDLE"
    for attempt in {1..10}; do
      if pgrep -x "$APP_NAME" >/dev/null; then
        echo "$APP_NAME launched"
        exit 0
      fi
      sleep 0.5
    done
    echo "$APP_NAME did not start" >&2
    exit 1
    ;;
  run)
    /usr/bin/open -n "$APP_BUNDLE"
    ;;
esac
