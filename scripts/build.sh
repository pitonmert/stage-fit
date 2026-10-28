#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL=false
case "${1:-}" in
    '') [ "$#" -eq 0 ] || exit 64 ;;
    --install) [ "$#" -eq 1 ] || exit 64; INSTALL=true ;;
    --help|-h) printf 'Usage: %s [--install]\nBuild StageFit; --install also updates /Applications/StageFit.app. Quit StageFit first.\nThe app is not launched.\n' "$0"; exit 0 ;;
    *) echo 'Usage: build.sh [--install]' >&2; exit 64 ;;
esac
CONFIGURATION="${CONFIGURATION:-release}"
case "$CONFIGURATION" in debug|release) ;; *) echo 'CONFIGURATION must be debug or release.' >&2; exit 64 ;; esac
SIGN_IDENTITY="${STAGEFIT_SIGN_IDENTITY:-}"
IDENTITY_FILE="$HOME/Library/Application Support/StageFit/signing-identity"
if [ -z "$SIGN_IDENTITY" ] && [ -f "$IDENTITY_FILE" ]; then
    SIGN_IDENTITY="$(cat "$IDENTITY_FILE")"
    [ -n "$SIGN_IDENTITY" ] || { echo 'The local signing identity file is empty.' >&2; exit 1; }
fi
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
/usr/bin/xcrun swift build --package-path "$ROOT" -c "$CONFIGURATION"
BIN_DIR="$(/usr/bin/xcrun swift build --package-path "$ROOT" -c "$CONFIGURATION" --show-bin-path)"
STAGING="$(/usr/bin/mktemp -d "$ROOT/.build/package.XXXXXX")"
INSTALL_STAGING=''
cleanup() {
    if [ -n "$INSTALL_STAGING" ]; then
        if [ -d "$INSTALL_STAGING/previous.app" ] && [ ! -e /Applications/StageFit.app ]; then
            if ! /bin/mv "$INSTALL_STAGING/previous.app" /Applications/StageFit.app; then
                printf 'Previous app preserved at: %s/previous.app\n' "$INSTALL_STAGING" >&2
                /bin/rm -rf "$STAGING"
                return 1
            fi
        fi
        /bin/rm -rf "$INSTALL_STAGING"
    fi
    /bin/rm -rf "$STAGING"
}
trap cleanup EXIT
APP="$STAGING/StageFit.app"
/bin/mkdir -p "$APP/Contents/MacOS"
/bin/cp "$BIN_DIR/StageFit" "$APP/Contents/MacOS/StageFit"
/usr/bin/python3 - "$APP/Contents/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as output:
    plistlib.dump({
        'CFBundleIdentifier': 'com.pitonmert.StageFit',
        'CFBundleName': 'StageFit',
        'CFBundleDisplayName': 'StageFit',
        'CFBundleExecutable': 'StageFit',
        'CFBundlePackageType': 'APPL',
        'CFBundleShortVersionString': '1.0.0',
        'CFBundleVersion': '1',
        'LSMinimumSystemVersion': '14.0',
        'LSUIElement': True,
        'NSHighResolutionCapable': True,
    }, output)
PY
/usr/bin/codesign --force --sign "$SIGN_IDENTITY" --identifier com.pitonmert.StageFit "$APP"
/usr/bin/codesign --verify --strict "$APP"
# A plain build replaces only the generated bundle.
/bin/rm -rf "$ROOT/.build/StageFit.app"
/bin/mv "$APP" "$ROOT/.build/StageFit.app"
printf 'Built: %s\n' "$ROOT/.build/StageFit.app"
if "$INSTALL"; then
    RUNNING=0
    /usr/bin/pgrep -x StageFit >/dev/null || RUNNING=$?
    case "$RUNNING" in
        0) echo 'Quit StageFit before installing.' >&2; exit 1 ;;
        1) ;;
        *) echo 'Could not check whether StageFit is running. Installation cancelled.' >&2; exit 1 ;;
    esac
    [ ! -L /Applications/StageFit.app ] || { echo 'Refusing to replace a symbolic link.' >&2; exit 1; }
    INSTALL_STAGING="$(/usr/bin/mktemp -d /Applications/.StageFit.XXXXXX)"
    /usr/bin/ditto "$ROOT/.build/StageFit.app" "$INSTALL_STAGING/StageFit.app"
    /usr/bin/codesign --verify --strict "$INSTALL_STAGING/StageFit.app"
    if [ -e /Applications/StageFit.app ]; then
        /bin/mv /Applications/StageFit.app "$INSTALL_STAGING/previous.app"
    fi
    /bin/mv "$INSTALL_STAGING/StageFit.app" /Applications/StageFit.app
    printf 'Installed: /Applications/StageFit.app\n'
fi
