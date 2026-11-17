#!/usr/bin/env bash
# Download APK -> (optional spoof) -> Install -> Launch -> Screenshots
# Env: APK_URL (required), PACKAGE_NAME (optional), SPOOF_DEVICE (1 = experimental spoof)
set -uo pipefail

ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
ARTIFACTS="${ROOT}/artifacts"
mkdir -p "$ARTIFACTS"
exec > >(tee -a "$ARTIFACTS/run.log") 2>&1

APK_URL="${APK_URL:-}"
PACKAGE_NAME="${PACKAGE_NAME:-}"
SPOOF_DEVICE="${SPOOF_DEVICE:-0}"
APK_FILE="$ARTIFACTS/app.apk"

log() { printf '[install] %s\n' "$*"; }
adb_sh() { adb shell "$@" | tr -d '\r'; }

screenshot() {
  local f="$ARTIFACTS/$1"
  adb exec-out screencap -p > "$f" 2>/dev/null
  if [[ -s "$f" ]]; then log "screenshot saved: $1 ($(stat -c%s "$f") bytes)"
  else log "screenshot FAILED: $1"; rm -f "$f"; fi
}

finish() {
  local code=$?
  log "script exiting with code $code"
  screenshot "99-final-state.png"
  adb logcat -d > "$ARTIFACTS/logcat.txt" 2>/dev/null
  ls -la "$ARTIFACTS"
  exit "$code"
}
trap finish EXIT

wait_for_boot() {
  adb wait-for-device
  local i=0
  while (( i < 180 )); do
    if [[ "$(adb_sh getprop sys.boot_completed 2>/dev/null || true)" == "1" ]]; then
      sleep 5; return 0
    fi
    sleep 2; i=$((i+1))
  done
  log "timed out waiting for boot"; return 1
}

settle_device() {
  adb shell svc power stayon true >/dev/null 2>&1 || true
  adb shell settings put global stay_on_while_plugged_in 3 >/dev/null 2>&1 || true
  adb shell settings put secure lockscreen.disabled 1 >/dev/null 2>&1 || true
  adb shell locksettings set-disabled true >/dev/null 2>&1 || true
  adb shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
  adb shell wm dismiss-keyguard >/dev/null 2>&1 || true
}

# ---------- Experimental device spoof ----------
# Edits build.prop files on the (userdebug) emulator image, then reboots.
spoof_device_identity() {
  local devices=(
    "samsung|SM-S928B|e3sxxx|e3s|Galaxy S24 Ultra|samsung/e3sxxx/e3s:14/UP1A.231005.007/S928BXXS3AXKF:user/release-keys"
    "samsung|SM-S911B|dm1qxxx|dm1q|Galaxy S23|samsung/dm1qxxx/dm1q:14/UP1A.231005.007/S911BXXS3AXK1:user/release-keys"
    "google|Pixel 8 Pro|husky|husky|Pixel 8 Pro|google/husky/husky:14/AP2A.240905.003/12234114:user/release-keys"
    "google|Pixel 7|panther|panther|Pixel 7|google/panther/panther:14/AP2A.240905.003/12234114:user/release-keys"
    "OnePlus|CPH2449|OPD2101|OPD2101|OnePlus 11|OnePlus/CPH2449/OPD2101:14/UKQ1.230924.001/R.19a:user/release-keys"
  )
  local choice="${devices[RANDOM % ${#devices[@]}]}"
  local BRAND MODEL NAME DEVICE MARKETNAME FINGERPRINT
  IFS='|' read -r BRAND MODEL NAME DEVICE MARKETNAME FINGERPRINT <<< "$choice"
  log "Spoofing as: $MARKETNAME ($MODEL)"

  adb root >/dev/null 2>&1; sleep 2; adb wait-for-device
  log "disable-verity: $(adb disable-verity 2>&1 | tr '\n' ' ')"
  adb reboot; wait_for_boot
  adb root >/dev/null 2>&1; sleep 2; adb wait-for-device
  log "remount: $(adb remount 2>&1 | tr '\n' ' ')"

  local tmp; tmp="$(mktemp -d)"
  local part f
  for part in system vendor product system_ext; do
    f="/$part/build.prop"
    adb shell "[ -f $f ]" 2>/dev/null || continue
    adb pull "$f" "$tmp/$part.prop" >/dev/null 2>&1 || { log "cannot pull $f"; continue; }
    sed -i -E \
      -e "s|^(ro\.product\.([a-z_]+\.)?brand)=.*|\1=${BRAND}|" \
      -e "s|^(ro\.product\.([a-z_]+\.)?manufacturer)=.*|\1=${BRAND}|" \
      -e "s|^(ro\.product\.([a-z_]+\.)?model)=.*|\1=${MODEL}|" \
      -e "s|^(ro\.product\.([a-z_]+\.)?name)=.*|\1=${NAME}|" \
      -e "s|^(ro\.product\.([a-z_]+\.)?device)=.*|\1=${DEVICE}|" \
      -e "s|^(ro\.product\.([a-z_]+\.)?marketname)=.*|\1=${MARKETNAME}|" \
      -e "s|^(ro\.([a-z_]+\.)?build\.fingerprint)=.*|\1=${FINGERPRINT}|" \
      "$tmp/$part.prop"
    if adb push "$tmp/$part.prop" "$f" >/dev/null 2>&1; then log "patched $f"
    else log "could not write $f (read-only?)"; fi
  done
  rm -rf "$tmp"

  adb reboot; wait_for_boot
  log "spoof result -> model: $(adb_sh getprop ro.product.model) | brand: $(adb_sh getprop ro.product.brand) | fingerprint: $(adb_sh getprop ro.build.fingerprint)"
}

# ===================== MAIN =====================
log "device:"; adb devices -l

# 1. Download first (fail fast on a bad URL)
[[ -n "$APK_URL" ]] || { log "APK_URL is empty"; exit 1; }
log "Downloading $APK_URL"
curl -L --fail --retry 3 --connect-timeout 20 -o "$APK_FILE" "$APK_URL" \
  || { log "ERROR: download failed"; exit 1; }
ls -lh "$APK_FILE"
if [[ "$(head -c 2 "$APK_FILE")" != "PK" ]]; then
  log "ERROR: not an APK (HTML page?):"; head -c 300 "$APK_FILE"; echo; exit 1
fi

# 2. Boot + settle
wait_for_boot
settle_device
screenshot "00-home-screen.png"

# 3. Optional spoof
if [[ "$SPOOF_DEVICE" == "1" ]]; then
  spoof_device_identity || log "spoof step failed, continuing without it"
  settle_device
  screenshot "00b-after-spoof.png"
else
  log "device spoof disabled (SPOOF_DEVICE=$SPOOF_DEVICE)"
fi

# 4. Package name
if [[ -z "$PACKAGE_NAME" ]]; then
  AAPT="$(ls "${ANDROID_HOME:-/usr/local/lib/android/sdk}"/build-tools/*/aapt 2>/dev/null | sort -V | tail -1)"
  if [[ -n "$AAPT" ]]; then
    PACKAGE_NAME="$("$AAPT" dump badging "$APK_FILE" 2>/dev/null | sed -n "s/^package: name='\([^']*\)'.*/\1/p" | head -1)"
  fi
fi
[[ -z "$PACKAGE_NAME" ]] && PACKAGE_NAME="xyz.blueskyweb.app"
log "Package: $PACKAGE_NAME"

# 5. Install
log "Installing APK..."
if ! adb install -r -t -g "$APK_FILE"; then
  log "retrying with -d"
  adb install -r -t -g -d "$APK_FILE" || { log "ERROR: install failed"; exit 1; }
fi
adb shell pm list packages | grep -F "$PACKAGE_NAME" || { log "ERROR: package not installed"; exit 1; }
sleep 2
screenshot "01-after-install.png"

# 6. Launch
log "Launching $PACKAGE_NAME ..."
adb shell input keyevent KEYCODE_WAKEUP
adb shell wm dismiss-keyguard
if ! adb shell monkey -p "$PACKAGE_NAME" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1; then
  ACT="$(adb_sh cmd package resolve-activity --brief "$PACKAGE_NAME" | tail -1)"
  log "monkey failed, am start -n $ACT"
  adb shell am start -n "$ACT"
fi

sleep 10
screenshot "02-after-launch.png"
sleep 8
screenshot "03-after-launch-18s.png"
adb shell dumpsys window | grep -E "mCurrentFocus|mFocusedApp" | head -3

log "Done!"
