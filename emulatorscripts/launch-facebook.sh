#!/usr/bin/env bash
# Runs INSIDE the emulator-runner step after the snapshot was restored: launch Facebook + screenshot.
set -uo pipefail
PKG="${PACKAGE_NAME:-com.facebook.katana}"
OUT="${GITHUB_WORKSPACE:-$(pwd)}/artifacts"
mkdir -p "$OUT"

adb wait-for-device
until [ "$(adb shell getprop sys.boot_completed | tr -d '\r')" = "1" ]; do sleep 1; done
echo "[launch] emulator ready"

adb shell pm list packages | grep -q "package:$PKG" || { echo "[launch] ERROR: $PKG missing in restored emulator"; exit 1; }

adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1
sleep 12
adb shell dumpsys window | grep -E 'mCurrentFocus' | tee "$OUT/focus.txt"
adb exec-out screencap -p > "$OUT/facebook.png"
echo "[launch] screenshot saved"

# ---- put any further steps that use the running emulator below this line ----
