#!/usr/bin/env bash
# Runs INSIDE the emulator-runner step after the snapshot was restored:
# launch Facebook, then poll screenshots until the screen has real content (not a blank white frame).
set -uo pipefail
PKG="${PACKAGE_NAME:-com.facebook.katana}"
OUT="${GITHUB_WORKSPACE:-$(pwd)}/artifacts"
MAX_WAIT="${MAX_WAIT:-90}"          # seconds to wait for the UI to draw
MIN_BYTES="${MIN_BYTES:-40000}"     # a blank white PNG is far smaller than a drawn login screen
mkdir -p "$OUT"

adb wait-for-device
until [ "$(adb shell getprop sys.boot_completed | tr -d '\r')" = "1" ]; do sleep 1; done
echo "[launch] emulator ready"

adb shell pm list packages | grep -q "package:$PKG" || { echo "[launch] ERROR: $PKG missing in restored emulator"; exit 1; }

# network sanity check (a restored snapshot can take a few seconds to get connectivity back)
for i in 1 2 3 4 5 6; do
  adb shell ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1 && { echo "[launch] network OK"; break; }
  echo "[launch] waiting for network ($i)"; sleep 3
done

adb shell am force-stop "$PKG"
adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1

start=$(date +%s); n=0
while :; do
  sleep 5; n=$((n+1))
  adb exec-out screencap -p > "$OUT/facebook_$n.png"
  size=$(stat -c%s "$OUT/facebook_$n.png")
  adb shell dumpsys window | grep -E 'mCurrentFocus' > "$OUT/focus.txt"
  echo "[launch] shot $n: ${size} bytes | $(cat "$OUT/focus.txt")"
  if grep -qi "isn't responding\|Application Error" "$OUT/focus.txt"; then
    echo "[launch] app not responding dialog -> waiting"
    adb shell input keyevent KEYCODE_ENTER   # choose "Wait"
  fi
  [ "$size" -ge "$MIN_BYTES" ] && { echo "[launch] UI drawn"; break; }
  [ $(( $(date +%s) - start )) -ge "$MAX_WAIT" ] && { echo "[launch] WARNING: still blank after ${MAX_WAIT}s"; break; }
done
cp "$OUT/facebook_$n.png" "$OUT/facebook.png"

# ---- put any further steps that use the running emulator below this line ----
