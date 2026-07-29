#!/usr/bin/env bash
# Build a release .app bundle and zip it for distribution / GitHub Releases.
#
# Usage:
#   ./scripts/package.sh
#   ./scripts/package.sh --out dist
#   ./scripts/package.sh --app-name "AIstat"
#
# Outputs (default under ./dist):
#   dist/AIstat.app
#   dist/Agent-Status-macos-arm64.zip

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT/dist"
CONFIGURATION=release
PRODUCT_NAME="aistat"
BUNDLE_ID="app.aistat"
DISPLAY_NAME="AIstat"
VERSION="0.1.0"
BUILD_NUMBER="1"
RESOURCE_BUNDLE_NAME="aistat_AIstat.bundle"
ICON_NAMES=(
  "MenuBarIconTemplate.png"
  "MenuBarIconTemplate@2x.png"
  "ProviderIcon-openai.png"
  "ProviderIcon-claude.png"
  "ProviderIcon-grok.png"
)
APP_ICON_ICNS="AppIcon.icns"

usage() {
  cat <<'EOF'
Usage: scripts/package.sh [options]

Options:
  --out <dir>         Output directory (default: ./dist)
  --app-name <name>   Display / bundle folder name (default: AIstat)
  --debug             Build the debug binary instead of release
  -h, --help          Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)
      OUT_DIR="${2:?--out requires a value}"
      shift 2
      ;;
    --app-name)
      DISPLAY_NAME="${2:?--app-name requires a value}"
      shift 2
      ;;
    --debug)
      CONFIGURATION=debug
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

require_cmd swift
require_cmd codesign
require_cmd plutil
require_cmd ditto
require_cmd zip

cd "$ROOT"

# Resolve absolute out dir after cd.
case "$OUT_DIR" in
  /*) ;;
  *) OUT_DIR="$ROOT/$OUT_DIR" ;;
esac

APP_PATH="$OUT_DIR/${DISPLAY_NAME}.app"
ZIP_SLUG="$(printf '%s' "$DISPLAY_NAME" | tr ' ' '-')"
ZIP_PATH="$OUT_DIR/${ZIP_SLUG}-macos-arm64.zip"

log "Building ($CONFIGURATION)"
swift build -c "$CONFIGURATION" --product "$PRODUCT_NAME"

TRIPLE="$(swift -print-target-info 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin)["target"]["triple"])' 2>/dev/null || true)"
CANDIDATES=(
  "$ROOT/.build/$CONFIGURATION/$PRODUCT_NAME"
  "$ROOT/.build/${TRIPLE:-}/$CONFIGURATION/$PRODUCT_NAME"
  "$ROOT/.build/arm64-apple-macosx/$CONFIGURATION/$PRODUCT_NAME"
)
BIN_SRC=""
for cand in "${CANDIDATES[@]}"; do
  if [[ -n "$cand" && -x "$cand" ]]; then
    BIN_SRC="$cand"
    break
  fi
done
if [[ -z "$BIN_SRC" ]]; then
  BIN_SRC="$(find "$ROOT/.build" -type f -name "$PRODUCT_NAME" -path "*/$CONFIGURATION/*" | head -n 1 || true)"
fi
[[ -n "$BIN_SRC" && -x "$BIN_SRC" ]] || die "built binary not found for configuration=$CONFIGURATION"

BUNDLE_CANDIDATES=(
  "$ROOT/.build/$CONFIGURATION/$RESOURCE_BUNDLE_NAME"
  "$ROOT/.build/${TRIPLE:-}/$CONFIGURATION/$RESOURCE_BUNDLE_NAME"
  "$ROOT/.build/arm64-apple-macosx/$CONFIGURATION/$RESOURCE_BUNDLE_NAME"
)
BUNDLE_SRC=""
for cand in "${BUNDLE_CANDIDATES[@]}"; do
  if [[ -n "$cand" && -d "$cand" ]]; then
    BUNDLE_SRC="$cand"
    break
  fi
done
if [[ -z "$BUNDLE_SRC" ]]; then
  BUNDLE_SRC="$(find "$ROOT/.build" -type d -name "$RESOURCE_BUNDLE_NAME" -path "*/$CONFIGURATION/*" | head -n 1 || true)"
fi

SOURCE_ICON_DIR="$ROOT/Sources/AIstat/Resources"

log "Assembling app bundle at: $APP_PATH"
rm -rf "$APP_PATH"
APP_CONTENTS="$APP_PATH/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
BIN_DST="$APP_MACOS/$PRODUCT_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"

mkdir -p "$APP_MACOS" "$APP_RESOURCES"
ditto "$BIN_SRC" "$BIN_DST"
chmod +x "$BIN_DST"

installed_icons=0
for icon in "${ICON_NAMES[@]}"; do
  src=""
  if [[ -n "$BUNDLE_SRC" && -f "$BUNDLE_SRC/$icon" ]]; then
    src="$BUNDLE_SRC/$icon"
  elif [[ -f "$SOURCE_ICON_DIR/$icon" ]]; then
    src="$SOURCE_ICON_DIR/$icon"
  fi
  if [[ -n "$src" ]]; then
    ditto "$src" "$APP_RESOURCES/$icon"
    installed_icons=$((installed_icons + 1))
  else
    echo "warning: missing icon $icon" >&2
  fi
done
[[ "$installed_icons" -gt 0 ]] || die "no menu bar icons found to install"

# App icon (.icns) for Finder / About / Force Quit. Optional but recommended.
if [[ -f "$SOURCE_ICON_DIR/$APP_ICON_ICNS" ]]; then
  ditto "$SOURCE_ICON_DIR/$APP_ICON_ICNS" "$APP_RESOURCES/$APP_ICON_ICNS"
  log "Installed app icon: $APP_ICON_ICNS"
else
  echo "warning: missing $APP_ICON_ICNS (app will use default generic icon)" >&2
fi

cat > "$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>${DISPLAY_NAME}</string>
	<key>CFBundleExecutable</key>
	<string>${PRODUCT_NAME}</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>${BUNDLE_ID}</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>${DISPLAY_NAME}</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${BUILD_NUMBER}</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
PLIST
plutil -lint "$INFO_PLIST" >/dev/null

log "Ad-hoc codesign"
codesign --force --deep --sign - "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"

log "Creating zip: $ZIP_PATH"
mkdir -p "$OUT_DIR"
rm -f "$ZIP_PATH"
(
  cd "$OUT_DIR"
  # -y: store symlinks as symlinks; -r: recursive; avoid nested parent path noise
  zip -qry "$(basename "$ZIP_PATH")" "$(basename "$APP_PATH")"
)

log "Package ready"
printf '  app : %s\n' "$APP_PATH"
printf '  zip : %s\n' "$ZIP_PATH"
printf '  size: %s\n' "$(du -h "$ZIP_PATH" | awk '{print $1}')"
