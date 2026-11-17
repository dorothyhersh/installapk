#!/usr/bin/env bash
# Install APK → Launch → Take 2 screenshots (spoofed device)
set -euo pipefail

ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
ARTIFACTS="${ROOT}/artifacts"
mkdir -p "$ARTIFACTS"

# ========== CONFIG – change these ==========
APK_URL="https://github.com/bluesky-social/social-app/releases/download/1.136.0/Bluesky-1.136.0.apk"          # ← put your APK URL here
PACKAGE_NAME=""                                   # leave empty to auto-detect, or put e.g. com.myapp
# ===========================================

APK_FILE="$ARTIFACTS/app.apk"
CHROME_PKG="com.android.chrome"   # not used, kept for compatibility
HAVE_ROOT=0

log() { printf '[install] %s\n' "$*"; }
adb_sh() { adb shell "$@" | tr -d '\r'; }

wait_for_boot() {
  adb wait-for-device
  local i=0
  while (( i < 180 )); do
    [[ "$(adb_sh getprop sys.boot_completed 2>/dev/null || true)" == "1" ]] && { sleep 5; return 0; }
    sleep 2; i=$((i+1))
  done
  log "timed out waiting for boot"; return 1
}

uid_is_root() { [[ "$(adb_sh id -u 2>/dev/null || true)" == "0" ]]; }

ensure_root() {
  for i in 1 2 3 4 5; do
    uid_is_root && { log "root available"; return 0; }
    adb root >/dev/null 2>&1 || true
    sleep 3
    adb wait-for-device
  done
  uid_is_root && return 0
  log "no root"; return 1
}

# ---------- Random device profile (same style as your demo) ----------
pick_android_device() {
  local devices=(
    "samsung|SM-S928B|e3sxxx|e3s|Galaxy S24 Ultra|samsung/e3sxxx/e3s:14/UP1A.231005.007/S928BXXS3AXKF:user/release-keys|14|420"
    "samsung|SM-S911B|dm1q|dm1q|Galaxy S23|samsung/dm1qxxx/dm1q:14/UP1A.231005.007/S911BXXS3AXK1:user/release-keys|14|420"
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
ro.build.version.release=${SDK}
ro.build.version.sdk=${SDK}
ro.sf.lcd_density=${DENSITY}
PROP
  adb push "$tmp" /data/local.prop
  adb_sh chmod 644 /data/local.prop
  rm -f "$tmp"
  log "pushed device identity → $MARKETNAME"
}

settle_device() {
  adb shell svc power stayon true >/dev/null || true
  adb shell settings put global stay_on_while_plugged_in 3 >/dev/null || true
  adb shell settings put secure lockscreen.disabled 1 >/dev/null || true
  adb shell locksettings set-disabled true >/dev/null 2>&1 || true
  adb shell wm dismiss-keyguard >/dev/null 2>&1 || true
  adb_sh wm size 1080x2340 || true
  adb_sh wm density "${DENSITY:-420}" || true
}

screenshot() {
  adb exec-out screencap -p > "${ARTIFACTS}/$1"
  log "screenshot → ${ARTIFACTS}/$1"
}

# ===================== MAIN =====================
log "waiting for device..."
wait_for_boot
if ensure_root; then HAVE_ROOT=1; fi
settle_device

pick_android_device
if [[ "$HAVE_ROOT" == "1" ]]; then
  write_device_identity
  log "rebooting to apply identity..."
  adb reboot
  wait_for_boot
  ensure_root && HAVE_ROOT=1 || HAVE_ROOT=0
  settle_device
fi

# ---------- Download APK ----------
log "Downloading APK from $APK_URL"
curl -L --fail --retry 3 -o "$APK_FILE" "$APK_URL"
ls -lh "$APK_FILE"

# ---------- Install ----------
log "Installing APK..."
adb install -r -t "$APK_FILE" || {
  log "install failed, trying with -g (grant permissions)"
  adb install -r -t -g "$APK_FILE"
}
screenshot "01-after-install.png"

# ---------- Detect package if not given ----------
if [[ -z "$PACKAGE_NAME" ]]; then
  log "Auto-detecting package name..."
  PACKAGE_NAME=$(adb shell pm list packages -3 | tail -1 | cut -d: -f2 | tr -d '\r')
  log "Detected package: $PACKAGE_NAME"
fi

# ---------- Launch ----------
log "Launching $PACKAGE_NAME ..."
adb shell monkey -p "$PACKAGE_NAME" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || \
adb shell am start -n "$(adb shell cmd package resolve-activity --brief "$PACKAGE_NAME" | tail -1 | tr -d '\r')"

sleep 6   # give the app time to open
screenshot "02-after-launch.png"

log "Done!"
ls -la "$ARTIFACTS"
echo
echo "Screenshots:"
echo "  1. After install → artifacts/01-after-install.png"
echo "  2. After launch  → artifacts/02-after-launch.png"