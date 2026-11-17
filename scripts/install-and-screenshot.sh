#!/usr/bin/env bash
# Download APK -> Install -> Launch -> (optional) Sign in -> Screenshots
# Env: APK_URL (required), PACKAGE_NAME (optional), SPOOF_DEVICE (1 = experimental),
#      DO_LOGIN (1 = log in), BSKY_IDENTIFIER, BSKY_PASSWORD (from GitHub secrets)
set -uo pipefail

ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
ARTIFACTS="${ROOT}/artifacts"
mkdir -p "$ARTIFACTS"
exec > >(tee -a "$ARTIFACTS/run.log") 2>&1

APK_URL="${APK_URL:-}"
PACKAGE_NAME="${PACKAGE_NAME:-}"
SPOOF_DEVICE="${SPOOF_DEVICE:-0}"
DO_LOGIN="${DO_LOGIN:-0}"
BSKY_IDENTIFIER="${BSKY_IDENTIFIER:-}"
BSKY_PASSWORD="${BSKY_PASSWORD:-}"

# APK and UI dumps are stored OUTSIDE artifacts/ so they are never uploaded
APK_FILE="${RUNNER_TEMP:-/tmp}/app.apk"
UI_XML="${RUNNER_TEMP:-/tmp}/ui.xml"

log() { printf '[install] %s\n' "$*"; }
adb_sh() { adb shell "$@" | tr -d '\r'; }

# Print a colored ASCII preview of a PNG into the step log
preview() {
  local f="$1"
  if command -v chafa >/dev/null 2>&1; then
    echo "-------- preview: $(basename "$f") --------"
    chafa --format=symbols --colors=256 --size=50x45 "$f" 2>/dev/null || true
    echo "-------------------------------------------"
  fi
}

screenshot() {
  local f="$ARTIFACTS/$1"
  adb exec-out screencap -p > "$f" 2>/dev/null
  if [[ -s "$f" ]]; then
    log "screenshot saved: $1 ($(stat -c%s "$f") bytes)"
    preview "$f"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
      echo "- screenshot \`$1\` ($(stat -c%s "$f") bytes)" >> "$GITHUB_STEP_SUMMARY"
    fi
  else
    log "screenshot FAILED: $1"; rm -f "$f"
  fi
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

# ---------- UI automation helpers (uiautomator) ----------
ui_dump() {
  local i
  for i in 1 2 3; do
    if adb shell uiautomator dump /sdcard/ui.xml 2>&1 | grep -q "dumped to"; then
      adb pull /sdcard/ui.xml "$UI_XML" >/dev/null 2>&1 && return 0
    fi
    sleep 1
  done
  return 1
}

# ui_find <text|class> <regex> <index>  -> prints "x y" of the match, or nothing
ui_find() {
  ui_dump || return 1
  python3 - "$UI_XML" "$1" "$2" "$3" <<'PY'
import re, sys, xml.etree.ElementTree as ET
path, mode, pat, idx = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
rx = re.compile(pat, re.I)
hits = []
for n in ET.parse(path).getroot().iter('node'):
    a = n.attrib
    if mode == 'class':
        ok = rx.search(a.get('class', ''))
    else:
        ok = rx.search(a.get('text', '')) or rx.search(a.get('content-desc', ''))
    if ok:
        m = re.findall(r'\d+', a.get('bounds', ''))
        if len(m) == 4:
            x1, y1, x2, y2 = map(int, m)
            hits.append(((x1 + x2) // 2, (y1 + y2) // 2))
if len(hits) > idx:
    print(hits[idx][0], hits[idx][1])
PY
}

# tap_text <regex> [fallback "x y"] [tries]
tap_text() {
  local pat="$1" fallback="${2:-}" tries="${3:-5}" xy="" i
  for ((i=0; i<tries; i++)); do
    xy="$(ui_find text "$pat" 0 || true)"
    [[ -n "$xy" ]] && break
    sleep 2
  done
  if [[ -z "$xy" && -n "$fallback" ]]; then
    log "'$pat' not found in UI, tapping fallback coordinates $fallback"
    xy="$fallback"
  fi
  if [[ -z "$xy" ]]; then log "'$pat' not found"; return 1; fi
  log "tap '$pat' at $xy"
  adb shell input tap $xy
}

# tap_field <index>  -> taps the Nth text input
tap_field() {
  local xy="" i
  for i in 1 2 3 4; do
    xy="$(ui_find class 'EditText' "$1" || true)"
    [[ -n "$xy" ]] && break
    sleep 2
  done
  if [[ -z "$xy" ]]; then log "text field #$1 not found (typing into focused field)"; return 1; fi
  log "tap text field #$1 at $xy"
  adb shell input tap $xy
}

# type_text <string>  (never logged)
type_text() {
  local s="$1" q="'"
  s="${s//$q/$q\\$q$q}"
  s="${s// /%s}"
  adb shell "input text '$s'" >/dev/null 2>&1
}

login_flow() {
  if [[ -z "$BSKY_IDENTIFIER" || -z "$BSKY_PASSWORD" ]]; then
    log "login skipped: BSKY_IDENTIFIER / BSKY_PASSWORD secrets are empty"
    return 0
  fi

  log "Login: tapping Sign in"
  tap_text '^Sign in$' "540 2258" || true
  sleep 4
  screenshot "04-signin-screen.png"

  log "Login: entering username/email"
  tap_field 0 || true
  sleep 1
  type_text "$BSKY_IDENTIFIER"
  sleep 1
  screenshot "05-username-entered.png"

  log "Login: entering password (hidden in screenshot)"
  tap_field 1 || true
  sleep 1
  type_text "$BSKY_PASSWORD"
  sleep 1
  screenshot "06-password-entered.png"

  log "Login: submitting"
  adb shell input keyevent 66    # ENTER
  sleep 3
  tap_text '^Next$' "" 1 || true
  sleep 12
  screenshot "07-after-login-12s.png"

  # Look for common problems on screen
  if ui_dump; then
    if grep -qiE 'invalid|incorrect|wrong|failed' "$UI_XML"; then
      log "WARNING: an error message appears to be on screen (wrong credentials?)"
    fi
    if grep -qiE 'verification|confirmation code|2fa' "$UI_XML"; then
      log "WARNING: a verification code is requested (email 2FA). Use an App Password to avoid this."
    fi
  fi

  sleep 10
  screenshot "08-after-login-22s.png"
}

# ---------- Experimental device spoof ----------
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

# 7. Sign in
if [[ "$DO_LOGIN" == "1" ]]; then
  login_flow || log "login flow ended with an error"
else
  log "login disabled (DO_LOGIN=$DO_LOGIN)"
fi

log "Done!"
