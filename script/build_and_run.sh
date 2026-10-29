#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-run}"
APP_NAME=PurpleMatter
BUNDLE_ID=nl.lucasilverentand.mac-model-api
APP_BUNDLE="$ROOT_DIR/dist/Purple Matter.app"
if [[ -f "$ROOT_DIR/Config/Signing.local" ]]; then source "$ROOT_DIR/Config/Signing.local"; fi
if [[ -z "${MODEL_API_SIGNING_IDENTITY:-}" ]]; then
  MODEL_API_SIGNING_IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: [^"]*\)"/\1/p' | head -1)"
fi
[[ -n "$MODEL_API_SIGNING_IDENTITY" ]] || { echo 'Set MODEL_API_SIGNING_IDENTITY to your Apple Development identity.' >&2; exit 1; }
case "$MODE" in run|build|--debug|--logs|--telemetry|--verify) ;; *) echo 'Usage: script/build_and_run.sh [run|build|--debug|--logs|--telemetry|--verify]' >&2; exit 2 ;; esac
if [[ "$MODE" != build ]]; then
  pkill -TERM -x "$APP_NAME" >/dev/null 2>&1 || true
  # Retire the earlier development process after the product rename.
  pkill -TERM -x MacModelAPI >/dev/null 2>&1 || true
  for ATTEMPT in {1..30}; do
    if ! pgrep -x "$APP_NAME" >/dev/null && ! pgrep -x MacModelAPI >/dev/null; then break; fi
    sleep 0.2
  done
  if pgrep -x "$APP_NAME" >/dev/null || pgrep -x MacModelAPI >/dev/null; then
    echo 'The previous app is still shutting down. No second instance was launched.' >&2
    exit 1
  fi
fi
SWIFT_ARGS=(--package-path "$ROOT_DIR")
if [[ -n "${MODEL_API_SCRATCH_PATH:-}" ]]; then SWIFT_ARGS+=(--scratch-path "$MODEL_API_SCRATCH_PATH"); fi
swift build "${SWIFT_ARGS[@]}" --product "$APP_NAME"
BUILD_DIR="$(swift build "${SWIFT_ARGS[@]}" --show-bin-path)"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/LICENSE" "$ROOT_DIR/NOTICE" "$APP_BUNDLE/Contents/Resources/"
cp "$ROOT_DIR/Assets/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>PurpleMatter</string>
<key>CFBundleIdentifier</key><string>nl.lucasilverentand.mac-model-api</string>
<key>CFBundleName</key><string>Purple Matter</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign "$MODEL_API_SIGNING_IDENTITY" --options runtime "$APP_BUNDLE"
codesign --verify --strict --deep "$APP_BUNDLE"
case "$MODE" in
  build) echo "$APP_BUNDLE" ;;
  run) /usr/bin/open -n "$APP_BUNDLE" ;;
  --debug) lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME" ;;
  --logs) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'process == "PurpleMatter"' ;;
  --telemetry) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'process == "PurpleMatter"' ;;
  --verify) /usr/bin/open -n "$APP_BUNDLE"; sleep 1; pgrep -x "$APP_NAME" >/dev/null ;;
esac
