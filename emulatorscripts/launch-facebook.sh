#!/usr/bin/env bash
# Runs INSIDE the emulator-runner step after the snapshot was restored.
# Launches Facebook and waits until the real welcome / login screen is visible
# (detected from on-screen text via uiautomator, NOT from the splash logo), then screenshots it.
set -uo pipefail
PKG="${PACKAGE_NAME:-com.facebook.katana}"
OUT="${GITHUB_WORKSPACE:-$(pwd)}/artifacts"
MAX_WAIT="${MAX_WAIT:-240}"            # seconds to wait for the welcome screen
NO_DUMP_FALLBACK="${NO_DUMP_FALLBACK:-75}"   # if uiautomator never works, just wait this long
# words that only exist on the real welcome/login screen (not on the splash)
READY_RE='Log in|Log into|Create new account|Create new Facebook account|Mobile number or email|Email or phone|Join Facebook|Get started|Sign up'
mkdir -p "$OUT"

adb wait-for-device
until [ "$(adb shell getprop sys.boot_completed | tr -d '\r')" = "1" ]; do sleep 1; done
echo "[launch] emulator ready"

adb shell pm list packages | grep -q "package:$PKG" || { echo "[launch] ERROR: $PKG missing in restored emulator"; exit 1; }

# no animations = faster UI and reliable uiautomator
adb shell settings put global window_animation_scale 0
adb shell settings put global transition_animation_scale 0
adb shell settings put global animator_duration_scale 0

for i in 1 2 3 4 5 6; do
  adb shell ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1 && { echo "[launch] network OK"; break; }
  echo "[launch] waiting for network ($i)"; sleep 3
done

adb shell am force-stop "$PKG"
adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1

start=$(date +%s); n=0; dump_ok=0; ready=0
while :; do
  sleep 5; n=$((n+1)); elapsed=$(( $(date +%s) - start ))

  adb shell rm -f /sdcard/ui.xml >/dev/null 2>&1
  if adb shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1 && adb shell cat /sdcard/ui.xml > "$OUT/ui.xml" 2>/dev/null && [ -s "$OUT/ui.xml" ]; then
    dump_ok=1
    if grep -Eiq "(text|content-desc)=\"[^\"]*(${READY_RE})" "$OUT/ui.xml"; then
      ready=1
    fi
  fi

  adb exec-out screencap -p > "$OUT/progress.png"
  adb shell dumpsys window | grep -E 'mCurrentFocus' > "$OUT/focus.txt"
  echo "[launch] t=${elapsed}s dump_ok=$dump_ok ready=$ready | $(cat "$OUT/focus.txt")"

  if grep -qi "isn't responding\|Application Error" "$OUT/focus.txt"; then
    echo "[launch] 'not responding' dialog -> choosing Wait"
    adb shell input keyevent KEYCODE_ENTER
  fi

  if [ "$ready" -eq 1 ]; then
    echo "[launch] welcome/login screen detected"
    sleep 3                               # let it finish drawing
    break
  fi
  if [ "$dump_ok" -eq 0 ] && [ "$elapsed" -ge "$NO_DUMP_FALLBACK" ]; then
    echo "[launch] WARNING: uiautomator unavailable, using time-based wait ($elapsed s)"
    break
  fi
  if [ "$elapsed" -ge "$MAX_WAIT" ]; then
    echo "[launch] WARNING: welcome screen not detected after ${MAX_WAIT}s - saving current screen"
    break
  fi
done

adb exec-out screencap -p > "$OUT/facebook.png"
adb shell dumpsys window | grep -E 'mCurrentFocus' > "$OUT/focus.txt"
adb shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1 && adb shell cat /sdcard/ui.xml > "$OUT/ui.xml" 2>/dev/null
echo "[launch] final screenshot saved: facebook.png"

# ---- put any further steps that use the running emulator below this line ----
