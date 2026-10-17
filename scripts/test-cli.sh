#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$ROOT/.build/StageFit.app}"
# Only --help/--version/invalid-argument branches run. None initialize NSApplication or Accessibility.
/usr/bin/python3 - "$APP" <<'PY'
import pathlib, plistlib, subprocess, sys
app = pathlib.Path(sys.argv[1]).resolve()
with (app / 'Contents/Info.plist').open('rb') as stream:
    info = plistlib.load(stream)
assert info['CFBundleIdentifier'] == 'com.pitonmert.StageFit'
assert info['CFBundlePackageType'] == 'APPL'
assert info['LSUIElement'] is True
executable = app / 'Contents/MacOS' / info['CFBundleExecutable']
for args, expected_code, expected_text in [
    (['--version'], 0, f"StageFit {info['CFBundleShortVersionString']}"),
    (['--help'], 0, 'Left-click'),
    (['-h'], 0, 'StageFit'),
    (['--invalid'], 64, 'Unknown arguments'),
]:
    result = subprocess.run([str(executable), *args], capture_output=True, text=True, timeout=10)
    assert result.returncode == expected_code, result
    assert expected_text in result.stdout + result.stderr, result
subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(app)], check=True)
print('CLI checks passed: arguments, bundle metadata, version and signature.')
PY
