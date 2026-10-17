#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
case "$CONFIGURATION" in debug|release) ;; *) echo 'CONFIGURATION must be debug or release.' >&2; exit 64 ;; esac
/usr/bin/xcrun swift build --package-path "$ROOT" -c "$CONFIGURATION"
BIN_DIR="$(/usr/bin/xcrun swift build --package-path "$ROOT" -c "$CONFIGURATION" --show-bin-path)"
STAGING="$(/usr/bin/mktemp -d "$ROOT/.build/package.XXXXXX")"
trap '/bin/rm -rf "$STAGING"' EXIT
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
/usr/bin/codesign --force --sign "${STAGEFIT_SIGN_IDENTITY:--}" --identifier com.pitonmert.StageFit "$APP"
/usr/bin/codesign --verify --strict "$APP"
# Replace only this project's generated bundle. Never touch an installed/running application here.
/bin/rm -rf "$ROOT/.build/StageFit.app"
/bin/mv "$APP" "$ROOT/.build/StageFit.app"
printf 'Built: %s\n' "$ROOT/.build/StageFit.app"
