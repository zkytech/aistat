#!/usr/bin/env bash
# Build a release binary and install it as a local macOS menu bar app (with widgets).
#
# Usage:
#   ./scripts/install.sh              # build, install, launch
#   ./scripts/install.sh --no-launch  # build + install only
#   ./scripts/install.sh --app-path "$HOME/Applications/AIstat.app"
#   ./scripts/install.sh --debug
#
# Layout (codesign-compatible):
#   AIstat.app/
#     Contents/
#       Info.plist
#       MacOS/aistat
#       PlugIns/AIstatWidget.appex/
#       Resources/...

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${HOME}/Applications/AIstat.app"
DO_LAUNCH=1
CONFIGURATION=release
PRODUCT_NAME="aistat"
DISPLAY_NAME="AIstat"
BUNDLE_ID="app.aistat"
WIDGET_BUNDLE_ID="app.aistat.widget"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

usage() {
  cat <<'EOF'
Usage: scripts/install.sh [options]

Options:
  --app-path <path>   Install destination (default: ~/Applications/AIstat.app)
  --no-launch         Install without launching
  --debug             Build/install the debug binary instead of release
  -h, --help          Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-path)
      APP_PATH="${2:?--app-path requires a value}"
      shift 2
      ;;
    --no-launch)
      DO_LAUNCH=0
      shift
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

require_cmd open
require_cmd pkill
require_cmd ditto
require_cmd mktemp
require_cmd plutil
require_cmd pluginkit
[[ -x "$LSREGISTER" ]] || die "missing LaunchServices registration tool: $LSREGISTER"

bundle_identifier() {
  plutil -extract CFBundleIdentifier raw "$1/Contents/Info.plist" 2>/dev/null || true
}

unregister_app() {
  local app="$1"
  local appex="$app/Contents/PlugIns/AIstatWidget.appex"

  if [[ -d "$appex" ]]; then
    pluginkit -r "$appex" >/dev/null 2>&1 || true
  fi
  "$LSREGISTER" -u "$app" >/dev/null 2>&1 || true
}

trash_duplicate_install() {
  local app="$1"
  local trash_path

  [[ -d "$app" ]] || return 0
  [[ "$(bundle_identifier "$app")" == "$BUNDLE_ID" ]] || return 0

  unregister_app "$app"
  mkdir -p "$HOME/.Trash"
  trash_path="$HOME/.Trash/${DISPLAY_NAME}-duplicate-$(date +%Y%m%d%H%M%S).app"
  log "Moving duplicate install to Trash: $app"
  mv "$app" "$trash_path"
}

cd "$ROOT"

PACKAGE_ARGS=(--app-name "$DISPLAY_NAME")
if [[ "$CONFIGURATION" == "debug" ]]; then
  PACKAGE_ARGS+=(--debug)
fi

TMP_OUT="$(mktemp -d "${TMPDIR:-/tmp}/aistat-install.XXXXXX")"
cleanup() { rm -rf "$TMP_OUT"; }
trap cleanup EXIT

log "Packaging via scripts/package.sh → $TMP_OUT"
"$ROOT/scripts/package.sh" --out "$TMP_OUT" "${PACKAGE_ARGS[@]}"

BUILT_APP="$TMP_OUT/${DISPLAY_NAME}.app"
[[ -d "$BUILT_APP" ]] || die "package.sh did not produce $BUILT_APP"

log "Stopping existing instances"
pkill -f "$APP_PATH/Contents/MacOS/$PRODUCT_NAME" 2>/dev/null || true
pkill -f "$ROOT/.build/.*/$PRODUCT_NAME" 2>/dev/null || true
sleep 0.3

# WidgetKit may ignore an extension when multiple app copies with the same
# bundle identifiers are registered. Keep exactly one standard installation.
if [[ "$APP_PATH" != "/Applications/${DISPLAY_NAME}.app" ]]; then
  trash_duplicate_install "/Applications/${DISPLAY_NAME}.app"
fi
if [[ "$APP_PATH" != "${HOME}/Applications/${DISPLAY_NAME}.app" ]]; then
  trash_duplicate_install "${HOME}/Applications/${DISPLAY_NAME}.app"
fi

if [[ -d "$APP_PATH" ]]; then
  unregister_app "$APP_PATH"
fi

log "Installing to $APP_PATH"
mkdir -p "$(dirname "$APP_PATH")"
rm -rf "$APP_PATH"
ditto "$BUILT_APP" "$APP_PATH"

INSTALLED_APPEX="$APP_PATH/Contents/PlugIns/AIstatWidget.appex"
[[ "$(bundle_identifier "$APP_PATH")" == "$BUNDLE_ID" ]] || die "installed app has an unexpected bundle identifier"
[[ "$(bundle_identifier "$INSTALLED_APPEX")" == "$WIDGET_BUNDLE_ID" ]] || die "installed widget has an unexpected bundle identifier"

log "Registering final app and widget extension"
"$LSREGISTER" -f "$APP_PATH"
pluginkit -a "$INSTALLED_APPEX"
"$LSREGISTER" -gc >/dev/null 2>&1 || true

# Force WidgetKit's descriptor cache and desktop gallery to re-read the final
# extension path after replacing or de-duplicating an installation.
killall chronod 2>/dev/null || true
killall Dock 2>/dev/null || true
sleep 2

REGISTERED_WIDGET="$(pluginkit -mAvvv -i "$WIDGET_BUNDLE_ID" 2>/dev/null || true)"
if [[ "$REGISTERED_WIDGET" != *"Path = $INSTALLED_APPEX"* ]]; then
  printf '%s\n' "$REGISTERED_WIDGET" >&2
  die "WidgetKit extension did not register from the final install path"
fi

log "Installed layout"
find "$APP_PATH" -maxdepth 5 \( -type f -o -type d \) | sort | sed 's/^/  /'

if [[ "$DO_LAUNCH" -eq 1 ]]; then
  log "Launching"
  open "$APP_PATH"
  sleep 1
  if pgrep -f "$APP_PATH/Contents/MacOS/$PRODUCT_NAME" >/dev/null; then
    log "Running: $(pgrep -fl "$APP_PATH/Contents/MacOS/$PRODUCT_NAME")"
  else
    die "app did not stay running after open"
  fi
else
  log "Install complete (--no-launch)"
fi
