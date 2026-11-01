#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ICON_WORK="$(mktemp -d)"
trap 'rm -rf "$ICON_WORK"' EXIT
ICON_DOCUMENT="$ROOT_DIR/Assets/AppIcon.icon"
ICON_COMPOSER="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
[[ -x "$ICON_COMPOSER" ]] || { echo 'Icon Composer from Xcode 26 or later is required.' >&2; exit 1; }
"$ICON_COMPOSER" "$ICON_DOCUMENT" --export-image --output-file "$ROOT_DIR/Assets/AppIcon.png" --platform macOS --rendition Default --width 1024 --height 1024 --scale 1
xcrun actool "$ICON_DOCUMENT" --compile "$ICON_WORK" --platform macosx --minimum-deployment-target 26.0 --app-icon AppIcon --output-partial-info-plist "$ICON_WORK/IconInfo.plist" >/dev/null
cp "$ICON_WORK/AppIcon.icns" "$ROOT_DIR/Assets/AppIcon.icns"
