#!/usr/bin/env bash
# Build a release .app bundle (with WidgetKit extension) and zip it for distribution.
#
# Usage:
#   ./scripts/package.sh
#   ./scripts/package.sh --out dist
#   ./scripts/package.sh --app-name "AIstat"
#
# Outputs (default under ./dist):
#   dist/AIstat.app
#   dist/AIstat-macos-arm64.zip

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT/dist"
CONFIGURATION=release
PRODUCT_NAME="aistat"
# Avoid hyphens in CFBundleExecutable (some plugin scanners mishandle them).
WIDGET_PRODUCT_NAME="AIstatWidget"
WIDGET_SPM_PRODUCT_NAME="aistat-widget"
BUNDLE_ID="app.aistat"
WIDGET_BUNDLE_ID="app.aistat.widget"
DISPLAY_NAME="AIstat"
WIDGET_DISPLAY_NAME="AIstat 额度"
VERSION="0.1.0"
# Bump every package so WidgetKit/chronod invalidates cached descriptors.
BUILD_NUMBER="$(date +%Y%m%d%H%M%S)"
RESOURCE_BUNDLE_NAME="aistat_AIstat.bundle"
# Prefer a real development identity so WidgetKit will load the appex.
# Fall back to ad-hoc (-) when none is available.
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
ICON_NAMES=(
  "MenuBarIconTemplate.png"
  "MenuBarIconTemplate@2x.png"
  "ProviderIcon-openai.png"
  "ProviderIcon-claude.png"
  "ProviderIcon-grok.png"
)
APP_ICON_ICNS="AppIcon.icns"
APP_ENTITLEMENTS="$ROOT/Resources/Entitlements/AIstat.entitlements"
WIDGET_ENTITLEMENTS="$ROOT/Resources/Entitlements/AIstatWidget.entitlements"

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

find_built_product() {
  local name="$1"
  local triple="${2:-}"
  local candidates=(
    "$ROOT/.build/$CONFIGURATION/$name"
    "$ROOT/.build/${triple}/$CONFIGURATION/$name"
    "$ROOT/.build/arm64-apple-macosx/$CONFIGURATION/$name"
  )
  local cand
  for cand in "${candidates[@]}"; do
    if [[ -n "$cand" && -x "$cand" ]]; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  find "$ROOT/.build" -type f -name "$name" -path "*/$CONFIGURATION/*" 2>/dev/null | head -n 1
}

find_widget_build_dir() {
  local triple="${1:-}"
  local candidates=(
    "$ROOT/.build/$CONFIGURATION/AIstatWidget.build"
    "$ROOT/.build/${triple}/$CONFIGURATION/AIstatWidget.build"
    "$ROOT/.build/arm64-apple-macosx/$CONFIGURATION/AIstatWidget.build"
  )
  local cand
  for cand in "${candidates[@]}"; do
    if [[ -n "$cand" && -d "$cand" ]]; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  find "$ROOT/.build" -type d -name "AIstatWidget.build" -path "*/$CONFIGURATION/*" 2>/dev/null | head -n 1
}

# SwiftPM does not emit App Intents metadata. Without Metadata.appintents inside
# the .appex, macOS never shows "Edit Widget" for AppIntentConfiguration.
# Re-compile widget sources with -emit-const-values-path, then run
# appintentsmetadataprocessor into the appex Resources.
emit_widget_appintents_metadata() {
  local widget_resources="$1"
  local triple="$2"
  local widget_build_dir
  widget_build_dir="$(find_widget_build_dir "$triple" || true)"
  [[ -n "${widget_build_dir:-}" && -d "$widget_build_dir" ]] \
    || die "AIstatWidget.build directory not found (needed for App Intents metadata)"

  local sdk_root
  sdk_root="$(xcrun --sdk macosx --show-sdk-path)"
  [[ -n "$sdk_root" && -d "$sdk_root" ]] || die "macOS SDK not found"

  local xcode_version
  xcode_version="$(xcodebuild -version 2>/dev/null | awk '/Build version/{print $3}')"
  [[ -n "$xcode_version" ]] || die "could not read Xcode build version"

  local const_dir="$ROOT/.build/appintents-metadata"
  rm -rf "$const_dir"
  mkdir -p "$const_dir"

  local protocols_json="$const_dir/protocols.json"
  local ofm_json="$const_dir/output-file-map.json"
  local sources_list="$const_dir/sources.txt"
  local const_list="$const_dir/swiftconstvals.txt"
  local modules_dir
  # Prefer the configuration/triple Modules dir next to the widget build product.
  modules_dir="$(dirname "$widget_build_dir")/Modules"
  [[ -d "$modules_dir" ]] || modules_dir="$ROOT/.build/arm64-apple-macosx/$CONFIGURATION/Modules"
  [[ -d "$modules_dir" ]] || die "Swift modules dir not found for AIstatShared import"

  local target_triple="${triple:-arm64-apple-macosx14.0}"
  # Normalize SPM triple (arm64-apple-macosx) → compiler triple with deployment.
  case "$target_triple" in
    *-apple-macosx) target_triple="${target_triple}14.0" ;;
    *-apple-macosx.*) ;;
    *) target_triple="arm64-apple-macosx14.0" ;;
  esac

  python3 - "$ROOT" "$widget_build_dir" "$const_dir" "$TOOLCHAIN_DIR" <<'PY'
import json, os, sys
root, wbuild, const_dir, toolchain = sys.argv[1:5]
sources = []
for name in (
    "AIstatWidgetBundle.swift",
    "QuotaWidget.swift",
    "QuotaWidgetViews.swift",
    "WidgetConfigurationIntent.swift",
    "WidgetTheme.swift",
):
    path = os.path.join(root, "Sources", "AIstatWidget", name)
    if not os.path.isfile(path):
        raise SystemExit(f"missing widget source: {path}")
    sources.append(path)
accessor = os.path.join(wbuild, "DerivedSources", "resource_bundle_accessor.swift")
if os.path.isfile(accessor):
    sources.append(accessor)

ofm = {"": {"object": os.path.join(const_dir, "AIstatWidget.o")}}
const_paths = []
for src in sources:
    base = os.path.basename(src)
    const_path = os.path.join(const_dir, f"{base}.swiftconstvalues")
    ofm[src] = {
        "object": os.path.join(const_dir, f"{base}.o"),
        "const-values": const_path,
    }
    const_paths.append(const_path)

with open(os.path.join(const_dir, "output-file-map.json"), "w") as f:
    json.dump(ofm, f, indent=2)
with open(os.path.join(const_dir, "sources.txt"), "w") as f:
    f.write("\n".join(sources) + "\n")
with open(os.path.join(const_dir, "swiftconstvals.txt"), "w") as f:
    f.write("\n".join(const_paths) + "\n")

share = os.path.join(toolchain, "usr", "share", "swift", "SwiftConstantValues")
protos = []
for name in ("AppIntents.json", "ExtensionKit.json"):
    path = os.path.join(share, name)
    if os.path.isfile(path):
        with open(path) as f:
            protos.extend(json.load(f).get("constValueProtocols", []))
# WidgetConfigurationIntent is defined by WidgetKit, not AppIntents.json.
if "WidgetConfigurationIntent" not in protos:
    protos.append("WidgetConfigurationIntent")
if not protos:
    raise SystemExit(f"no const-value protocols found under {share}")
with open(os.path.join(const_dir, "protocols.json"), "w") as f:
    json.dump(protos, f)
print(f"sources={len(sources)} protocols={len(protos)}")
PY

  log "Emitting Swift const values for App Intents"
  # shellcheck disable=SC2046
  swiftc \
    -sdk "$sdk_root" \
    -target "$target_triple" \
    -module-name AIstatWidget \
    -I "$modules_dir" \
    -parse-as-library \
    -application-extension \
    -output-file-map "$ofm_json" \
    -Xfrontend -const-gather-protocols-file -Xfrontend "$protocols_json" \
    -emit-const-values-path "$const_dir/fallback.swiftconstvalues" \
    -c \
    $(cat "$sources_list") \
    || die "failed to emit Swift const values for widget App Intents"

  # Ensure the intent file produced real const metadata (not empty "[]").
  local intent_const
  intent_const="$(grep -E 'WidgetConfigurationIntent\.swift\.swiftconstvalues$' "$const_list" | head -n 1 || true)"
  [[ -n "$intent_const" && -s "$intent_const" ]] \
    || die "missing WidgetConfigurationIntent.swiftconstvalues"
  local intent_size
  intent_size="$(wc -c < "$intent_const" | tr -d ' ')"
  [[ "$intent_size" -gt 100 ]] \
    || die "WidgetConfigurationIntent const values too small (${intent_size} bytes) — Edit Widget would not appear"

  log "Generating Metadata.appintents for widget"
  # Processor writes <output>/Metadata.appintents/{extract.actionsdata,version.json}
  "$APPINTENTS_PROCESSOR" \
    --output "$widget_resources" \
    --toolchain-dir "$TOOLCHAIN_DIR" \
    --module-name AIstatWidget \
    --sdk-root "$sdk_root" \
    --xcode-version "$xcode_version" \
    --platform-family macOS \
    --deployment-target 14.0 \
    --target-triple "$target_triple" \
    --source-file-list "$sources_list" \
    --swift-const-vals-list "$const_list" \
    --force \
    --quiet-warnings \
    || die "appintentsmetadataprocessor failed"

  [[ -f "$widget_resources/Metadata.appintents/extract.actionsdata" ]] \
    || die "Metadata.appintents/extract.actionsdata was not produced"
  log "App Intents metadata installed under widget Resources"
}

require_cmd swift
require_cmd codesign
require_cmd nm
require_cmd plutil
require_cmd ditto
require_cmd zip
require_cmd python3
require_cmd xcrun
require_cmd xcodebuild

# Resolve Xcode toolchain + App Intents metadata processor (needed for Edit Widget).
TOOLCHAIN_DIR="$(xcrun --find swift | xargs dirname | xargs dirname)"
if [[ ! -d "$TOOLCHAIN_DIR/usr/share/swift/SwiftConstantValues" ]]; then
  # Fall back to default Xcode toolchain when `xcrun --find swift` points at a thin layout.
  TOOLCHAIN_DIR="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain"
fi
APPINTENTS_PROCESSOR="$(xcrun --find appintentsmetadataprocessor 2>/dev/null || true)"
[[ -n "${APPINTENTS_PROCESSOR:-}" && -x "$APPINTENTS_PROCESSOR" ]] \
  || die "appintentsmetadataprocessor not found (install Xcode + command-line tools)"

cd "$ROOT"

case "$OUT_DIR" in
  /*) ;;
  *) OUT_DIR="$ROOT/$OUT_DIR" ;;
esac

APP_PATH="$OUT_DIR/${DISPLAY_NAME}.app"
ZIP_SLUG="$(printf '%s' "$DISPLAY_NAME" | tr ' ' '-')"
ZIP_PATH="$OUT_DIR/${ZIP_SLUG}-macos-arm64.zip"

log "Building ($CONFIGURATION) main + widget"
swift build -c "$CONFIGURATION" --product "$PRODUCT_NAME"
swift build -c "$CONFIGURATION" --product "$WIDGET_SPM_PRODUCT_NAME"

TRIPLE="$(swift -print-target-info 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin)["target"]["triple"])' 2>/dev/null || true)"

BIN_SRC="$(find_built_product "$PRODUCT_NAME" "$TRIPLE" || true)"
[[ -n "${BIN_SRC:-}" && -x "$BIN_SRC" ]] || die "built binary not found for product=$PRODUCT_NAME configuration=$CONFIGURATION"

WIDGET_BIN_SRC="$(find_built_product "$WIDGET_SPM_PRODUCT_NAME" "$TRIPLE" || true)"
[[ -n "${WIDGET_BIN_SRC:-}" && -x "$WIDGET_BIN_SRC" ]] || die "built widget binary not found for product=$WIDGET_SPM_PRODUCT_NAME configuration=$CONFIGURATION"

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
APP_PLUGINS="$APP_CONTENTS/PlugIns"
WIDGET_APPEX="$APP_PLUGINS/AIstatWidget.appex"
WIDGET_MACOS="$WIDGET_APPEX/Contents/MacOS"
WIDGET_RESOURCES="$WIDGET_APPEX/Contents/Resources"
BIN_DST="$APP_MACOS/$PRODUCT_NAME"
WIDGET_BIN_DST="$WIDGET_MACOS/$WIDGET_PRODUCT_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
WIDGET_INFO_PLIST="$WIDGET_APPEX/Contents/Info.plist"

mkdir -p "$APP_MACOS" "$APP_RESOURCES" "$WIDGET_MACOS" "$WIDGET_RESOURCES"
ditto "$BIN_SRC" "$BIN_DST"
chmod +x "$BIN_DST"
ditto "$WIDGET_BIN_SRC" "$WIDGET_BIN_DST"
chmod +x "$WIDGET_BIN_DST"

# A SwiftPM executable can be packaged as .appex and still register with
# pluginkit, but WidgetKit cannot launch it unless NSExtensionMain is the entry.
nm -m "$WIDGET_BIN_DST" | grep 'external _NSExtensionMain' >/dev/null \
  || die "widget binary is missing the NSExtensionMain app-extension entry point"

# Provider brand marks also ship inside the widget appex (same assets as the menu panel).
WIDGET_ICON_NAMES=(
  "ProviderIcon-openai.png"
  "ProviderIcon-claude.png"
  "ProviderIcon-grok.png"
)
WIDGET_SOURCE_ICON_DIR="$ROOT/Sources/AIstatWidget/Resources"

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

installed_widget_icons=0
for icon in "${WIDGET_ICON_NAMES[@]}"; do
  src=""
  if [[ -f "$WIDGET_SOURCE_ICON_DIR/$icon" ]]; then
    src="$WIDGET_SOURCE_ICON_DIR/$icon"
  elif [[ -f "$SOURCE_ICON_DIR/$icon" ]]; then
    src="$SOURCE_ICON_DIR/$icon"
  fi
  if [[ -n "$src" ]]; then
    ditto "$src" "$WIDGET_RESOURCES/$icon"
    installed_widget_icons=$((installed_widget_icons + 1))
  else
    echo "warning: missing widget icon $icon" >&2
  fi
done
[[ "$installed_widget_icons" -gt 0 ]] || die "no provider icons found for widget appex"

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

cat > "$WIDGET_INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>${WIDGET_DISPLAY_NAME}</string>
	<key>CFBundleExecutable</key>
	<string>${WIDGET_PRODUCT_NAME}</string>
	<key>CFBundleIdentifier</key>
	<string>${WIDGET_BUNDLE_ID}</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>${WIDGET_DISPLAY_NAME}</string>
	<key>CFBundlePackageType</key>
	<string>XPC!</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleSupportedPlatforms</key>
	<array>
		<string>MacOSX</string>
	</array>
	<key>CFBundleVersion</key>
	<string>${BUILD_NUMBER}</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>NSExtension</key>
	<dict>
		<key>NSExtensionPointIdentifier</key>
		<string>com.apple.widgetkit-extension</string>
	</dict>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST
plutil -lint "$WIDGET_INFO_PLIST" >/dev/null

# AppIntentConfiguration widgets need Metadata.appintents or the system
# never shows the desktop right-click "Edit Widget" / configure UI.
emit_widget_appintents_metadata "$WIDGET_RESOURCES" "${TRIPLE:-}"

[[ -f "$APP_ENTITLEMENTS" ]] || die "missing entitlements: $APP_ENTITLEMENTS"
[[ -f "$WIDGET_ENTITLEMENTS" ]] || die "missing entitlements: $WIDGET_ENTITLEMENTS"

if [[ -z "$CODESIGN_IDENTITY" ]]; then
  # Prefer a local Apple Development cert when present.
  CODESIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -n 1 || true)"
fi
if [[ -z "$CODESIGN_IDENTITY" ]]; then
  CODESIGN_IDENTITY="-"
fi

log "Codesign identity: $CODESIGN_IDENTITY (widget then app)"
# Sign embedded extension first, then the host app (no --deep so entitlements stick).
# Hardened runtime only with a real identity — ad-hoc + runtime can confuse pluginkit.
SIGN_OPTS=(--force --sign "$CODESIGN_IDENTITY" --entitlements)
if [[ "$CODESIGN_IDENTITY" != "-" ]]; then
  SIGN_OPTS=(--force --sign "$CODESIGN_IDENTITY" --options runtime --timestamp=none --entitlements)
fi
codesign "${SIGN_OPTS[@]}" "$WIDGET_ENTITLEMENTS" "$WIDGET_APPEX"
codesign "${SIGN_OPTS[@]}" "$APP_ENTITLEMENTS" "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"

log "Creating zip: $ZIP_PATH"
mkdir -p "$OUT_DIR"
rm -f "$ZIP_PATH"
(
  cd "$OUT_DIR"
  zip -qry "$(basename "$ZIP_PATH")" "$(basename "$APP_PATH")"
)

log "Package ready"
printf '  app    : %s\n' "$APP_PATH"
printf '  widget : %s\n' "$WIDGET_APPEX"
printf '  zip    : %s\n' "$ZIP_PATH"
printf '  size   : %s\n' "$(du -h "$ZIP_PATH" | awk '{print $1}')"
