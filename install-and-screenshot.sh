#!/usr/bin/env bash
# Download APK -> Install -> Launch -> Take screenshots
# Inputs come from env vars set by the workflow:
#   APK_URL       (required) direct link to an .apk
#   PACKAGE_NAME  (optional) auto-detected if empty
#   SPOOF_DEVICE  (optional) 1 = try device identity spoof (off by default)
set -euo pipefail

ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
ARTIFACTS="${ROOT}/artifacts"
mkdir -p "$ARTIFACTS"

APK_URL="${APK_URL:-}"
PACKAGE_NAME="${PACKAGE_NAME:-}"
SPOOF_DEVICE="${SPOOF_DEVICE:-0}"
APK_FILE="$ARTIFACTS/app.apk"
HAVE_ROOT=0

log() { printf '[install] %s\n' "$*"; }

# Always save a final screenshot + logcat, even if the script fails
on_exit() {
  local code=$?
  log "exit code: $code, saving debug output"
  adb exec-out screencap -p > "$ARTIFACTS/99-final-state.png" 2>/dev/null || true
  adb logcat -d > "$ARTIFACTS/logcat.txt" 2>/dev/null || true
  exit "$code"
}
trap on_exit EXIT

[[ -n "$APK_URL" ]] || { log "APK_URL not set"; exit 1; }

adb_sh() { adb shell "$@" | tr -d '\r'; }

wait_for_boot() {
  adb wait-for-device
  local i=0
  while (( i < 180 )); do
    if [[ "$(adb_sh getprop sys.boot_completed 2>/dev/null || true)" == "1" ]]; then
      sleep 5
      return 0
    fi
    sleep 2
    i=$((i+1))
  done
  log "timed out waiting for boot"
  return 1
}

uid_is_root() { [[ "$(adb_sh id -u 2>/dev/null || true)" == "0" ]]; }

ensure_root() {
  for _ in 1 2 3 4 5; do
    if uid_is_root; then log "root available"; return 0; fi
    adb root >/dev/null 2>&1 || true
    sleep 3
    adb wait-for-device
  done
  if uid_is_root; then return 0; fi
  log "no root"
  return 1
}

# ---------- Random device profile (optional spoof) ----------
pick_android_device() {
  local devices=(
    "samsung|SM-S928B|e3sxxx|e3s|Galaxy S24 Ultra|samsung/e3sxxx/e3s:14/UP1A.231005.007/S928BXXS3AXKF:user/release-keys|14|420"
    "samsung|SM-S911B|dm1qxxx|dm1q|Galaxy S23|samsung/dm1qxxx/dm1q:14/UP1A.231005.007/S911BXXS3AXK1:user/release-keys|14|420"
    "google|Pixel 8 Pro|husky|husky|Pixel 8 Pro|google/husky/husky:14/AP2A.240905.003/12234114:user/release-keys|14|420"
    "google|Pixel 7|panther|panther|Pixel 7|google/panther/panther:14/AP2A.240905.003/12234114:user/release-keys|14|420"
    "OnePlus|CPH2449|OPD2101|OPD2101|OnePlus 11|OnePlus/CPH2449/OPD2101:14/UKQ1.230924.001/R.19a:user/release-keys|14|480"
  )
  local choice="${devices[RANDOM % ${#devices[@]}]}"
  IFS='|' read -r BRAND MODEL NAME DEVICE MARKETNAME FINGERPRINT SDK DENSITY <<< "$choice"
  log "Selected device: $MARKETNAME ($MODEL)"
}

write_device_identity() {
  local tmp; tmp="$(mktemp)"
  cat > "$tmp" <<PROP
ro.product.brand=${BRAND}
ro.product.manufacturer=${BRAND}
ro.product.model=${MODEL}
ro.product.name=${NAME}
ro.product.device=${DEVICE}
ro.product.marketname=${MARKETNAME}
ro.build.fingerprint=${FINGERPRINT}
ro.build.type=user
ro.build.tags=release-keys
ro.sf.lcd_density=${DENSITY}
PROP
  adb push "$tmp" /data/local.prop >/dev/null
  adb_sh chmod 644 /data/local.prop || true
  rm -f "$tmp"
  log "pushed device identity -> $MARKETNAME (note: ro.* props usually stay unchanged on this image)"
}

settle_device() {
  adb shell svc power stayon true >/dev/null 2>&1 || true
  adb shell settings put global stay_on_while_plugged_in 3 >/dev/null 2>&1 || true
  adb shell settings put secure lockscreen.disabled 1 >/dev/null 2>&1 || true
  adb shell locksettings set-disabled true >/dev/null 2>&1 || true
  adb shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
  adb shell wm dismiss-keyguard >/dev/null 2>&1 || true
}

screenshot() {
  adb exec-out screencap -p > "${ARTIFACTS}/$1"
  log "screenshot -> ${ARTIFACTS}/$1"
}

third_party_packages() {
  adb shell pm list packages -3 | tr -d '\r' | sed 's/^package://' | sort
}

# ===================== MAIN =====================

# ---------- 1. Download APK first (fail fast on a bad URL) ----------
log "Downloading APK from $APK_URL"
curl -L --fail --retry 3 --connect-timeout 20 -o "$APK_FILE" "$APK_URL"
ls -lh "$APK_FILE"

# An APK is a zip file and must start with "PK"
if [[ "$(head -c 2 "$APK_FILE")" != "PK" ]]; then
  log "ERROR: downloaded file is not an APK (probably an HTML page). Use a DIRECT .apk link."
  head -c 300 "$APK_FILE" || true
  echo
  exit 1
fi

# ---------- 2. Boot / root / settle ----------
log "waiting for device..."
wait_for_boot
if ensure_root; then HAVE_ROOT=1; fi
settle_device

# ---------- 3. Optional device spoof ----------
if [[ "$SPOOF_DEVICE" == "1" ]]; then
  pick_android_device
  if [[ "$HAVE_ROOT" == "1" ]]; then
    write_device_identity
    log "rebooting to apply identity..."
    adb reboot
    wait_for_boot
    if ensure_root; then HAVE_ROOT=1; else HAVE_ROOT=0; fi
    settle_device
  else
    log "spoof requested but no root, skipping"
  fi
else
  log "device spoof disabled"
fi

# ---------- 4. Install ----------
BEFORE_PKGS="$(third_party_packages || true)"

log "Installing APK..."
if ! adb install -r -t -g "$APK_FILE"; then
  log "install failed, retrying with -d (allow downgrade)"
  adb install -r -t -g -d "$APK_FILE"
fi
sleep 2
screenshot "01-after-install.png"

# ---------- 5. Detect package ----------
if [[ -z "$PACKAGE_NAME" ]]; then
  log "Auto-detecting package name..."
  AFTER_PKGS="$(third_party_packages || true)"
  PACKAGE_NAME="$(comm -13 <(printf '%s\n' "$BEFORE_PKGS") <(printf '%s\n' "$AFTER_PKGS") | head -1 || true)"

  # Fallback 1: aapt from build-tools
  if [[ -z "$PACKAGE_NAME" ]]; then
    AAPT="$(ls "${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}}"/build-tools/*/aapt 2>/dev/null | sort -V | tail -1 || true)"
    if [[ -n "$AAPT" ]]; then
      PACKAGE_NAME="$("$AAPT" dump badging "$APK_FILE" 2>/dev/null | sed -n "s/^package: name='\([^']*\)'.*/\1/p" | head -1 || true)"
    fi
  fi

  # Fallback 2: last third-party package
  if [[ -z "$PACKAGE_NAME" ]]; then
    PACKAGE_NAME="$(printf '%s\n' "$AFTER_PKGS" | tail -1)"
  fi
fi

[[ -n "$PACKAGE_NAME" ]] || { log "could not determine package name"; exit 1; }
log "Package: $PACKAGE_NAME"

# ---------- 6. Launch ----------
log "Launching $PACKAGE_NAME ..."
if ! adb shell monkey -p "$PACKAGE_NAME" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1; then
  ACTIVITY="$(adb shell cmd package resolve-activity --brief "$PACKAGE_NAME" | tr -d '\r' | tail -1)"
  log "monkey failed, trying am start -n $ACTIVITY"
  adb shell am start -n "$ACTIVITY"
fi

sleep 10   # give the app time to open
screenshot "02-after-launch.png"

sleep 5
screenshot "03-after-launch-15s.png"

log "Done!"
ls -la "$ARTIFACTS"
