#!/usr/bin/env bash
# MODE=login   : install -> launch -> sign in -> dismiss popups -> encrypted backup -> upload to Mega
# MODE=restore : download backup from Mega -> install -> restore -> launch -> dismiss popups -> verify
# Env: APK_URL, PACKAGE_NAME, SPOOF_DEVICE, DO_LOGIN, MAKE_BACKUP, RESAVE,
#      BSKY_IDENTIFIER, BSKY_PASSWORD, BACKUP_PASSPHRASE,
#      RCLONE_CONF_CONTENT (rclone config text, from the RCLONE_CONF secret),
#      MEGA_REMOTE (default mega), MEGA_FOLDER (default bluesky-android-backup),
#      MEGA_FILE (default session.tgz.enc), MEGA_UPLOAD (1), MEGA_DOWNLOAD (1), MEGA_KEEP (10)
set -uo pipefail

ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
ARTIFACTS="${ROOT}/artifacts"
BACKUP_DIR="${ROOT}/backup"
BACKUP_FILE="${BACKUP_DIR}/session.tgz.enc"
mkdir -p "$ARTIFACTS" "$BACKUP_DIR"
exec > >(tee -a "$ARTIFACTS/run.log") 2>&1

MODE="${MODE:-login}"
APK_URL="${APK_URL:-}"
PACKAGE_NAME="${PACKAGE_NAME:-}"
SPOOF_DEVICE="${SPOOF_DEVICE:-0}"
DO_LOGIN="${DO_LOGIN:-0}"
MAKE_BACKUP="${MAKE_BACKUP:-0}"
RESAVE="${RESAVE:-0}"
BSKY_IDENTIFIER="${BSKY_IDENTIFIER:-}"
BSKY_PASSWORD="${BSKY_PASSWORD:-}"
BACKUP_PASSPHRASE="${BACKUP_PASSPHRASE:-}"

# ----- Mega / rclone settings -----
RCLONE_CONF_CONTENT="${RCLONE_CONF_CONTENT:-}"
RCLONE_CFG="${HOME}/.config/rclone/rclone.conf"
MEGA_REMOTE="${MEGA_REMOTE:-mega}"
MEGA_FOLDER="${MEGA_FOLDER:-bluesky-android-backup}"
MEGA_FILE="${MEGA_FILE:-session.tgz.enc}"
MEGA_UPLOAD="${MEGA_UPLOAD:-1}"
MEGA_DOWNLOAD="${MEGA_DOWNLOAD:-1}"
MEGA_KEEP="${MEGA_KEEP:-10}"
MEGA_DIR="${MEGA_REMOTE}:${MEGA_FOLDER}"

# APK, UI dumps and the decrypted archive live OUTSIDE artifacts/ so they are never uploaded
APK_FILE="${RUNNER_TEMP:-/tmp}/app.apk"
UI_XML="${RUNNER_TEMP:-/tmp}/ui.xml"
SESSION_TMP="${RUNNER_TEMP:-/tmp}/session.tgz"

# Buttons that close popups / dialogs
DISMISS_REGEX='^(Cancel|Not now|Maybe later|No thanks|Skip|Later|Dismiss|Got it)\b'

log() { printf '[install] %s\n' "$*"; }
adb_sh() { adb shell "$@" | tr -d '\r'; }

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
  ls -la "$ARTIFACTS" "$BACKUP_DIR"
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

# =====================================================================
#  Mega.nz via rclone
# =====================================================================
setup_rclone() {
  if ! command -v rclone >/dev/null 2>&1; then
    log "installing rclone..."
    sudo apt-get install -y -qq rclone >/dev/null 2>&1 \
      || { curl -fsSL https://rclone.org/install.sh | sudo bash >/dev/null 2>&1; }
  fi
  command -v rclone >/dev/null 2>&1 || { log "rclone is not available"; return 1; }

  if [[ ! -s "$RCLONE_CFG" ]]; then
    if [[ -z "$RCLONE_CONF_CONTENT" ]]; then
      log "no rclone config found (RCLONE_CONF secret is empty)"
      return 1
    fi
    mkdir -p "$(dirname "$RCLONE_CFG")"
    printf '%s\n' "$RCLONE_CONF_CONTENT" > "$RCLONE_CFG"
    chmod 600 "$RCLONE_CFG"
    log "rclone config written"
  fi
  if ! rclone listremotes 2>/dev/null | grep -qx "${MEGA_REMOTE}:"; then
    log "rclone remote '${MEGA_REMOTE}' not found in the config (expected a [${MEGA_REMOTE}] section)"
    return 1
  fi
  return 0
}

mega_upload() {
  setup_rclone || return 1
  [[ -s "$BACKUP_FILE" ]] || { log "mega upload: no local backup file"; return 1; }

  local stamp; stamp="$(date -u +%Y%m%d-%H%M%S)"
  log "uploading backup to ${MEGA_DIR}/"
  rclone mkdir "$MEGA_DIR" --retries 5 || { log "mega upload failed: cannot create/open folder (login problem?)"; return 1; }
  rclone copyto "$BACKUP_FILE" "${MEGA_DIR}/${MEGA_FILE}" --retries 5 -q \
    || { log "mega upload failed: ${MEGA_FILE}"; return 1; }
  rclone copyto "$BACKUP_FILE" "${MEGA_DIR}/session-${stamp}.tgz.enc" --retries 5 -q \
    || log "WARNING: dated copy was not uploaded"

  # verify the upload really exists
  if [[ -z "$(rclone lsf "${MEGA_DIR}/${MEGA_FILE}" 2>/dev/null)" ]]; then
    log "mega upload could not be verified"; return 1
  fi
  log "MEGA UPLOAD OK: ${MEGA_FOLDER}/${MEGA_FILE} and session-${stamp}.tgz.enc"
  rclone lsl "$MEGA_DIR" 2>/dev/null | sed 's/^/[mega] /'

  # keep only the newest N dated copies
  if [[ "$MEGA_KEEP" =~ ^[0-9]+$ ]]; then
    local old f
    old="$(rclone lsf "$MEGA_DIR" --include 'session-*.tgz.enc' 2>/dev/null | sort | head -n -"$MEGA_KEEP")"
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      log "removing old backup ${f}"
      rclone deletefile "${MEGA_DIR}/${f}" --mega-hard-delete 2>/dev/null || true
    done <<< "$old"
  fi
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    echo "- Mega backup uploaded: \`${MEGA_FOLDER}/${MEGA_FILE}\` (+ dated copy \`session-${stamp}.tgz.enc\`)" >> "$GITHUB_STEP_SUMMARY"
  fi
}

mega_download() {
  setup_rclone || return 1
  log "listing ${MEGA_DIR}/"
  rclone lsl "$MEGA_DIR" --retries 5 2>&1 | sed 's/^/[mega] /'
  if [[ -z "$(rclone lsf "${MEGA_DIR}/${MEGA_FILE}" 2>/dev/null)" ]]; then
    log "mega download failed: ${MEGA_FOLDER}/${MEGA_FILE} not found. Run the login/backup workflow first."
    return 1
  fi
  mkdir -p "$BACKUP_DIR"
  rclone copyto "${MEGA_DIR}/${MEGA_FILE}" "$BACKUP_FILE" --retries 5 -q \
    || { log "mega download failed"; return 1; }
  [[ -s "$BACKUP_FILE" ]] || { log "mega download failed: file is empty"; return 1; }
  log "MEGA DOWNLOAD OK: ${MEGA_FILE} ($(stat -c%s "$BACKUP_FILE") bytes)"
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

# ui_query <text|class> <regex> <index>  (uses the last dump) -> prints "x y"
ui_query() {
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

ui_find() { ui_dump || return 1; ui_query "$@"; }

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

# Close any popup / dialog (e.g. "Invite your friends" -> Cancel)
dismiss_popups() {
  local rounds="${1:-5}" i xy hit
  for ((i=0; i<rounds; i++)); do
    hit=0
    if ui_dump; then
      xy="$(ui_query text "$DISMISS_REGEX" 0 || true)"
      if [[ -n "$xy" ]]; then
        log "popup found, tapping dismiss button at $xy"
        adb shell input tap $xy
        hit=1
        sleep 2
      fi
    fi
    if [[ "$hit" == "0" ]]; then
      (( i >= 1 )) && break
      sleep 3
    fi
  done
}

# Feed tabs visible and no welcome-screen buttons = logged in
is_logged_in() {
  ui_dump || return 1
  grep -qiE 'Discover|Following' "$UI_XML" && ! grep -qiE 'Create account' "$UI_XML"
}

launch_app() {
  log "Launching $PACKAGE_NAME ..."
  adb shell input keyevent KEYCODE_WAKEUP
  adb shell wm dismiss-keyguard
  if ! adb shell monkey -p "$PACKAGE_NAME" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1; then
    local act; act="$(adb_sh cmd package resolve-activity --brief "$PACKAGE_NAME" | tail -1)"
    log "monkey failed, am start -n $act"
    adb shell am start -n "$act"
  fi
}

# ---------- Backup / restore of the app's data (needs adb root) ----------
need_root() {
  adb root >/dev/null 2>&1; sleep 3; adb wait-for-device
  [[ "$(adb_sh id -u 2>/dev/null)" == "0" ]]
}

backup_session() {
  if [[ -z "$BACKUP_PASSPHRASE" ]]; then
    log "backup skipped: BACKUP_PASSPHRASE secret is empty"; return 1
  fi
  need_root || { log "backup failed: adb root not available"; return 1; }

  adb shell am force-stop "$PACKAGE_NAME"; sleep 2; adb shell sync
  local remote=/data/local/tmp/session.tgz
  adb shell "rm -f $remote; tar -czf $remote --exclude='*/cache/*' --exclude='*/code_cache/*' -C /data/data $PACKAGE_NAME" \
    || adb shell "rm -f $remote; tar -czf $remote -C /data/data $PACKAGE_NAME" \
    || { log "backup failed: tar error"; return 1; }
  adb pull "$remote" "$SESSION_TMP" >/dev/null 2>&1 || { log "backup failed: pull error"; return 1; }
  adb shell "rm -f $remote"

  local size; size="$(stat -c%s "$SESSION_TMP" 2>/dev/null || echo 0)"
  if (( size < 10000 )); then log "backup failed: archive too small ($size bytes)"; rm -f "$SESSION_TMP"; return 1; fi

  mkdir -p "$BACKUP_DIR"
  openssl enc -aes-256-cbc -pbkdf2 -salt -in "$SESSION_TMP" -out "$BACKUP_FILE" -pass env:BACKUP_PASSPHRASE \
    || { log "backup failed: encryption error"; rm -f "$SESSION_TMP"; return 1; }
  rm -f "$SESSION_TMP"
  log "encrypted backup created: backup/session.tgz.enc ($(stat -c%s "$BACKUP_FILE") bytes)"
}

# create the backup, then upload it to Mega
backup_and_upload() {
  backup_session || return 1
  if [[ "$MEGA_UPLOAD" == "1" ]]; then
    mega_upload || log "WARNING: backup was created but NOT uploaded to Mega"
  else
    log "Mega upload disabled (MEGA_UPLOAD=$MEGA_UPLOAD)"
  fi
}

restore_session() {
  [[ -s "$BACKUP_FILE" ]] || { log "restore failed: $BACKUP_FILE not found"; return 1; }
  [[ -n "$BACKUP_PASSPHRASE" ]] || { log "restore failed: BACKUP_PASSPHRASE secret is empty"; return 1; }
  need_root || { log "restore failed: adb root not available"; return 1; }

  openssl enc -d -aes-256-cbc -pbkdf2 -in "$BACKUP_FILE" -out "$SESSION_TMP" -pass env:BACKUP_PASSPHRASE \
    || { log "restore failed: decryption error (wrong BACKUP_PASSPHRASE?)"; return 1; }
  tar -tzf "$SESSION_TMP" >/dev/null 2>&1 || { log "restore failed: archive is corrupt"; return 1; }

  local uid; uid="$(adb_sh stat -c %u "/data/data/$PACKAGE_NAME")"
  [[ -n "$uid" ]] || { log "restore failed: app data dir not found (was the app installed and launched once?)"; return 1; }
  log "app uid: $uid"

  local remote=/data/local/tmp/session.tgz
  adb shell am force-stop "$PACKAGE_NAME"
  adb push "$SESSION_TMP" "$remote" >/dev/null 2>&1 || { log "restore failed: push error"; return 1; }
  adb shell "find /data/data/$PACKAGE_NAME -mindepth 1 -maxdepth 1 ! -name cache ! -name code_cache -exec rm -rf {} +"
  adb shell "tar -xzf $remote -C /data/data" || { log "restore failed: extract error"; return 1; }
  adb shell "chown -R $uid:$uid /data/data/$PACKAGE_NAME"
  adb shell "restorecon -R /data/data/$PACKAGE_NAME" 2>/dev/null || true
  adb shell setenforce 0 2>/dev/null || true     # disposable emulator: avoid SELinux label issues
  adb shell "rm -f $remote"
  rm -f "$SESSION_TMP"
  log "session data restored"
}

# ---------- Login ----------
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

  if ui_dump; then
    grep -qiE 'invalid|incorrect|wrong|failed' "$UI_XML" && log "WARNING: an error message appears to be on screen (wrong credentials?)"
    grep -qiE 'verification|confirmation code|2fa' "$UI_XML" && log "WARNING: a verification code is requested (email 2FA). Use an App Password to avoid this."
  fi

  sleep 8
  screenshot "08-after-login-20s.png"

  log "Dismissing popups"
  dismiss_popups 5
  sleep 2
  screenshot "09-after-dismiss.png"

  if is_logged_in; then
    log "LOGIN OK (feed is visible)"
    if [[ "$MAKE_BACKUP" == "1" ]]; then
      backup_and_upload || log "WARNING: backup was not created"
      launch_app; sleep 6      # bring the app back so the final screenshot shows it
    fi
  else
    log "WARNING: feed not detected, not creating a backup (so a good old backup is never replaced by a bad one)"
  fi
}

restore_flow() {
  log "Restore: starting the app once so its data folder exists"
  launch_app
  sleep 8
  adb shell am force-stop "$PACKAGE_NAME"
  sleep 1

  restore_session || return 1

  launch_app
  sleep 15
  screenshot "10-restored-launch.png"

  log "Dismissing popups"
  dismiss_popups 5
  sleep 2
  screenshot "11-restored-after-dismiss.png"

  if is_logged_in; then
    log "RESTORE OK: the app opened already logged in"
    if [[ "$RESAVE" == "1" ]]; then
      backup_and_upload || log "WARNING: refreshed backup was not created"
      launch_app; sleep 6
    fi
    return 0
  fi
  log "RESTORE FAILED: the app is not logged in (see screenshots 10 and 11)"
  return 1
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
log "mode: $MODE"
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

# 1b. Restore mode: fetch the encrypted backup from Mega now (fail fast)
if [[ "$MODE" == "restore" ]]; then
  if [[ "$MEGA_DOWNLOAD" == "1" ]]; then
    mega_download || { log "ERROR: could not download the backup from Mega"; exit 1; }
  else
    [[ -s "$BACKUP_FILE" ]] || { log "ERROR: MEGA_DOWNLOAD=0 and no local backup file"; exit 1; }
  fi
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

# 6. Mode-specific work
if [[ "$MODE" == "restore" ]]; then
  restore_flow || exit 1
else
  launch_app
  sleep 10
  screenshot "02-after-launch.png"
  sleep 8
  screenshot "03-after-launch-18s.png"
  adb shell dumpsys window | grep -E "mCurrentFocus|mFocusedApp" | head -3

  if [[ "$DO_LOGIN" == "1" ]]; then
    login_flow || log "login flow ended with an error"
  else
    log "login disabled (DO_LOGIN=$DO_LOGIN)"
  fi
fi

log "Done!"
