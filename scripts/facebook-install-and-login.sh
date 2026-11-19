#!/usr/bin/env bash
# MODE=login   : install -> launch -> sign in -> dismiss popups -> switch to Page (verified) -> encrypted backup -> upload to Mega
# MODE=restore : download backup from Mega -> install -> restore -> launch -> verify logged in
#                (restore runs on the plain GitHub runner IP: no Tailscale, no phone exit node, no IP guard)
# Env: APK_URL, PACKAGE_NAME (default com.facebook.katana), FB_IDENTIFIER, FB_PASSWORD,
#      FB_PAGE_NAME (exact Page name, strongly recommended), FB_REQUIRE_PAGE (default 1),
#      BACKUP_PASSPHRASE, RCLONE_CONF_CONTENT, MEGA_FOLDER, MEGA_FILE, MAKE_BACKUP, RESAVE
# Phone exit node (LOGIN mode only): PHONE_IP, BASELINE_IP, EXPECTED_PHONE_IP (optional) are used
# by the IP guard. RESTORE mode ignores all of these and just uses whatever IP the runner has.
#
# Reel posting (runs after a successful login or restore, on the Page): set REEL_COUNT to the
# number of reels to post (default 0 = skip). Downloads that many videos from
# mega:<MEGA_REELS_SRC> (default FB_Reels), posts each one with the caption in CAPTION_FILE
# (default scripts/caption.txt), then moves the posted video to mega:<MEGA_REELS_DONE> (default
# FB_Reels2) so it is never posted twice. Uses the ADBKeyboard IME (installed automatically) so
# the caption's emoji/hashtags/unicode type correctly.
#
# REENCODE_REELS=1 (default): each video is re-encoded on the runner to plain Main-profile
# H.264 / AAC, 30 fps, yuv420p, max 720 px wide BEFORE it is pushed to the emulator. The
# emulator's software decoder cannot play many phone clips as-is (HEVC, variable frame rate,
# high profiles) and Facebook then shows "Couldn't play video". Set REENCODE_REELS=0 to skip.
#
# MAX_PLAYBACK_FAILS (default 2): stop the reel loop after this many consecutive
# "Couldn't play video" errors (that is an emulator problem, not a one-off bad file).
set -uo pipefail

ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
ARTIFACTS="${ROOT}/artifacts"
BACKUP_DIR="${ROOT}/backup"
BACKUP_FILE="${BACKUP_DIR}/fb-session.tgz.enc"
mkdir -p "$ARTIFACTS" "$BACKUP_DIR"
exec > >(tee -a "$ARTIFACTS/run.log") 2>&1

MODE="${MODE:-login}"
APK_URL="${APK_URL:-}"
PACKAGE_NAME="${PACKAGE_NAME:-com.facebook.katana}"
FB_IDENTIFIER="${FB_IDENTIFIER:-}"
FB_PASSWORD="${FB_PASSWORD:-}"
BACKUP_PASSPHRASE="${BACKUP_PASSPHRASE:-}"
MAKE_BACKUP="${MAKE_BACKUP:-1}"
RESAVE="${RESAVE:-0}"

RCLONE_CONF_CONTENT="${RCLONE_CONF_CONTENT:-}"
RCLONE_CFG="${HOME}/.config/rclone/rclone.conf"
MEGA_REMOTE="${MEGA_REMOTE:-mega}"
MEGA_FOLDER="${MEGA_FOLDER:-facebook-android-backup}"
MEGA_FILE="${MEGA_FILE:-fb-session.tgz.enc}"
MEGA_KEEP="${MEGA_KEEP:-10}"
MEGA_DIR="${MEGA_REMOTE}:${MEGA_FOLDER}"

# Reel posting
REEL_COUNT="${REEL_COUNT:-0}"
MEGA_REELS_SRC="${MEGA_REELS_SRC:-FB_Reels}"
MEGA_REELS_DONE="${MEGA_REELS_DONE:-FB_Reels2}"
CAPTION_FILE="${CAPTION_FILE:-${ROOT}/scripts/caption.txt}"
REELS_LOCAL_DIR="${RUNNER_TEMP:-/tmp}/reels"
REENCODE_REELS="${REENCODE_REELS:-1}"
MAX_PLAYBACK_FAILS="${MAX_PLAYBACK_FAILS:-2}"
ADBKEYBOARD_APK_URL="${ADBKEYBOARD_APK_URL:-https://github.com/senzhk/ADBKeyBoard/raw/master/ADBKeyboard.apk}"
ADBKEYBOARD_PKG="com.android.adbkeyboard"
ADBKEYBOARD_APK="${RUNNER_TEMP:-/tmp}/ADBKeyboard.apk"

APK_FILE="${RUNNER_TEMP:-/tmp}/fb.apk"
UI_XML="${RUNNER_TEMP:-/tmp}/ui.xml"
SESSION_TMP="${RUNNER_TEMP:-/tmp}/fb-session.tgz"

DISMISS_REGEX='^(Not now|Not Now|Maybe later|No thanks|Skip|Later|Dismiss|Got it|Cancel|Don.t allow|DENY)\b'

log() { printf '[fb] %s\n' "$*"; }
adb_sh() { adb shell "$@" | tr -d '\r'; }

screenshot() {
  local f="$ARTIFACTS/$1"
  adb exec-out screencap -p > "$f" 2>/dev/null
  if [[ -s "$f" ]]; then log "screenshot: $1"; else log "screenshot FAILED: $1"; rm -f "$f"; fi
}

finish() {
  local code=$?
  log "exiting with code $code"
  screenshot "99-final-state.png"
  adb logcat -d > "$ARTIFACTS/logcat.txt" 2>/dev/null
  exit "$code"
}
trap finish EXIT

# ---------------- Phone exit-node guard ----------------
# Fail-closed: if traffic is not leaving through the phone, refuse to continue.
phone_guard() {
  if [[ -z "${PHONE_IP:-}" ]]; then
    log "ABORT: PHONE_IP is not set; refusing to run without the phone exit node"
    return 1
  fi
  bash "${ROOT}/scripts/assert-phone-ip.sh" || { log "ABORT: not on the phone IP, refusing to continue"; return 1; }
}

wait_for_boot() {
  adb wait-for-device
  local i=0
  while (( i < 180 )); do
    [[ "$(adb_sh getprop sys.boot_completed 2>/dev/null || true)" == "1" ]] && { sleep 5; return 0; }
    sleep 2; i=$((i+1))
  done
  log "timed out waiting for boot"; return 1
}

settle_device() {
  adb shell svc power stayon true >/dev/null 2>&1 || true
  adb shell settings put global hide_error_dialogs 1 >/dev/null 2>&1 || true
  adb shell settings put secure lockscreen.disabled 1 >/dev/null 2>&1 || true
  adb shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
  adb shell wm dismiss-keyguard >/dev/null 2>&1 || true
}

# ---------------- Mega via rclone ----------------
rclone_has_mega() { rclone help backends 2>/dev/null | grep -qiE '(^|[[:space:]])mega([[:space:]]|$)'; }

# Downloads the official rclone build (the distro/apt one has no mega backend) with retries and a
# pinned-version fallback, and logs WHY if it fails instead of failing silently.
install_official_rclone() {
  local tmp url attempt bin ok=1
  local pinned="v1.68.2"
  tmp="$(mktemp -d)"
  for url in \
    "https://downloads.rclone.org/rclone-current-linux-amd64.zip" \
    "https://downloads.rclone.org/${pinned}/rclone-${pinned}-linux-amd64.zip" \
    "https://github.com/rclone/rclone/releases/download/${pinned}/rclone-${pinned}-linux-amd64.zip"; do
    for attempt in 1 2 3; do
      rm -rf "$tmp"/*
      if curl -fSL --retry 3 --connect-timeout 20 --max-time 180 -o "$tmp/rclone.zip" "$url" 2>"$tmp/curl.err" \
         && unzip -q -o "$tmp/rclone.zip" -d "$tmp" 2>"$tmp/unzip.err"; then
        bin="$(find "$tmp" -type f -name rclone | head -1)"
        if [[ -n "$bin" ]] && sudo install -m 0755 "$bin" /usr/local/bin/rclone; then ok=0; break 2; fi
      fi
      log "rclone download/install failed ($url, attempt $attempt): $(cat "$tmp/curl.err" "$tmp/unzip.err" 2>/dev/null | tr '\n' ' ' | head -c 300)"
      sleep 4
    done
  done
  rm -rf "$tmp"
  export PATH="/usr/local/bin:$PATH"; hash -r
  return $ok
}

setup_rclone() {
  export PATH="/usr/local/bin:$PATH"
  if ! command -v rclone >/dev/null 2>&1 || ! rclone_has_mega; then
    log "installing official rclone"
    install_official_rclone || log "WARNING: could not download official rclone"
  fi
  if ! rclone_has_mega; then
    log "rclone has no mega backend (rclone path: $(command -v rclone || echo none); $(rclone version 2>&1 | head -1))"
    return 1
  fi
  if [[ ! -s "$RCLONE_CFG" ]]; then
    [[ -n "$RCLONE_CONF_CONTENT" ]] || { log "RCLONE_CONF secret is empty"; return 1; }
    mkdir -p "$(dirname "$RCLONE_CFG")"
    printf '%s\n' "$RCLONE_CONF_CONTENT" > "$RCLONE_CFG"; chmod 600 "$RCLONE_CFG"
  fi
  rclone listremotes 2>/dev/null | grep -qx "${MEGA_REMOTE}:" || { log "remote '${MEGA_REMOTE}' not in config"; return 1; }
}

mega_upload() {
  setup_rclone || return 1
  [[ -s "$BACKUP_FILE" ]] || { log "no local backup file"; return 1; }
  local stamp; stamp="$(date -u +%Y%m%d-%H%M%S)"
  rclone mkdir "$MEGA_DIR" --retries 5 || return 1
  rclone copyto "$BACKUP_FILE" "${MEGA_DIR}/${MEGA_FILE}" --retries 5 -q || return 1
  rclone copyto "$BACKUP_FILE" "${MEGA_DIR}/fb-session-${stamp}.tgz.enc" --retries 5 -q || log "WARNING: dated copy not uploaded"
  [[ -n "$(rclone lsf "${MEGA_DIR}/${MEGA_FILE}" 2>/dev/null)" ]] || { log "upload not verified"; return 1; }
  log "MEGA UPLOAD OK: ${MEGA_FOLDER}/${MEGA_FILE}"
  if [[ "$MEGA_KEEP" =~ ^[0-9]+$ ]]; then
    local f
    while IFS= read -r f; do
      [[ -n "$f" ]] && rclone deletefile "${MEGA_DIR}/${f}" --mega-hard-delete 2>/dev/null || true
    done < <(rclone lsf "$MEGA_DIR" --include 'fb-session-*.tgz.enc' 2>/dev/null | sort | head -n -"$MEGA_KEEP")
  fi
}

mega_download() {
  setup_rclone || return 1
  [[ -n "$(rclone lsf "${MEGA_DIR}/${MEGA_FILE}" 2>/dev/null)" ]] \
    || { log "${MEGA_FOLDER}/${MEGA_FILE} not found. Run the login workflow first."; return 1; }
  rclone copyto "${MEGA_DIR}/${MEGA_FILE}" "$BACKUP_FILE" --retries 5 -q || return 1
  [[ -s "$BACKUP_FILE" ]] || { log "downloaded file is empty"; return 1; }
  log "MEGA DOWNLOAD OK ($(stat -c%s "$BACKUP_FILE") bytes)"
}

# ---------------- UI helpers ----------------
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

# ui_query <class|text|textlow> <regex> <index> -> "x y"
ui_query() {
  python3 - "$UI_XML" "$1" "$2" "$3" <<'PY'
import re, sys, xml.etree.ElementTree as ET
path, mode, pat, idx = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
rx = re.compile(pat, re.I)
hits = []
for n in ET.parse(path).getroot().iter('node'):
    a = n.attrib
    t, d = a.get('text', ''), a.get('content-desc', '')
    ok = rx.search(a.get('class', '')) if mode == 'class' else (rx.search(t) or rx.search(d))
    if ok:
        m = re.findall(r'\d+', a.get('bounds', ''))
        if len(m) == 4:
            x1, y1, x2, y2 = map(int, m)
            hits.append(((x1 + x2) // 2, (y1 + y2) // 2))
if mode == 'textlow':
    if hits:
        h = max(hits, key=lambda p: p[1]); print(h[0], h[1])
elif len(hits) > idx:
    print(hits[idx][0], hits[idx][1])
PY
}
ui_find() { ui_dump || return 1; ui_query "$@"; }

tap_text() {
  local pat="$1" fallback="${2:-}" tries="${3:-5}" mode="${4:-text}" xy="" i
  for ((i=0; i<tries; i++)); do
    xy="$(ui_find "$mode" "$pat" 0 || true)"; [[ -n "$xy" ]] && break; sleep 2
  done
  [[ -z "$xy" && -n "$fallback" ]] && { log "'$pat' not found, fallback tap $fallback"; xy="$fallback"; }
  [[ -z "$xy" ]] && { log "'$pat' not found"; return 1; }
  log "tap '$pat' at $xy"; adb shell input tap $xy
}

tap_field() {
  local xy="" i
  for i in 1 2 3 4; do
    xy="$(ui_find class 'EditText' "$1" || true)"; [[ -n "$xy" ]] && break; sleep 2
  done
  [[ -z "$xy" ]] && { log "text field #$1 not found"; return 1; }
  log "tap text field #$1 at $xy"; adb shell input tap $xy
}

type_text() {
  local s="$1" q="'"
  s="${s//$q/$q\\$q$q}"; s="${s// /%s}"
  adb shell "input text '$s'" >/dev/null 2>&1
}

focus_line() { adb shell dumpsys window 2>/dev/null | grep -E 'mCurrentFocus' | head -1 | tr -d '\r'; }

dismiss_system_dialogs() {
  local i xy
  for ((i=0; i<4; i++)); do
    xy=""
    if ui_dump; then
      if grep -qiE 'responding' "$UI_XML"; then xy="$(ui_query text '^Wait$' 0 || true)"
      elif grep -qiE 'keeps stopping|has stopped' "$UI_XML"; then xy="$(ui_query text '^(Close app|OK)$' 0 || true)"
      fi
    fi
    [[ -z "$xy" ]] && break
    log "system dialog, tapping $xy"; adb shell input tap $xy; sleep 3
  done
  return 0
}

launch_app() {
  log "launching $PACKAGE_NAME"
  adb shell input keyevent KEYCODE_WAKEUP
  adb shell wm dismiss-keyguard
  adb shell monkey -p "$PACKAGE_NAME" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || {
    local act; act="$(adb_sh cmd package resolve-activity --brief "$PACKAGE_NAME" | tail -1)"
    adb shell am start -n "$act"
  }
}

dismiss_popups() {
  local rounds="${1:-5}" i xy hit
  for ((i=0; i<rounds; i++)); do
    dismiss_system_dialogs
    hit=0
    if ui_dump; then
      xy="$(ui_query text "$DISMISS_REGEX" 0 || true)"
      if [[ -n "$xy" ]]; then log "popup, tapping dismiss at $xy"; adb shell input tap $xy; hit=1; sleep 3; fi
    fi
    if [[ "$hit" == "0" ]]; then (( i >= 1 )) && break; sleep 3; fi
  done
}

# True when the profile switcher bottom sheet is on screen (uses the latest ui dump)
switcher_open() { grep -qiE 'Create Facebook Page|Open Accounts Center' "$UI_XML"; }

# Logged in = no login form / no "Create new account" button, the main feed UI is present,
# and the profile switcher sheet is NOT covering it (the feed is visible behind the dimmed sheet)
is_logged_in() {
  ui_dump || return 1
  ! grep -qiE 'Create new account|Forgot password|Log in to Facebook' "$UI_XML" \
    && ! switcher_open \
    && grep -qiE 'Home|What.s on your mind|Notifications|Menu' "$UI_XML"
}

# ---------------- Post-login prompts, Menu and Page switch ----------------
save_ui() { ui_dump && cp "$UI_XML" "$ARTIFACTS/ui-$1.xml" 2>/dev/null || true; }

# prints "x y text" for every visible node that has text, so the log shows what is on screen
ui_texts() {
  python3 - "$UI_XML" <<'PY'
import re, sys, xml.etree.ElementTree as ET
for n in ET.parse(sys.argv[1]).getroot().iter('node'):
    a = n.attrib
    t = (a.get('text') or a.get('content-desc') or '').strip()
    m = re.findall(r'\d+', a.get('bounds', ''))
    if t and len(m) == 4:
        x1, y1, x2, y2 = map(int, m)
        print(f"{(x1 + x2) // 2} {(y1 + y2) // 2} {t}")
PY
}

# Name shown in the Menu header, e.g. "Hollie Wells, see your profile" -> "Hollie Wells"
menu_profile_name() {
  ui_texts | sed -n 's/^[0-9]* [0-9]* \(.*\), see your profile$/\1/p' | head -1
}

# Finds the Page row inside the profile switcher bottom sheet (y >= 1300 only, so Menu items
# behind the sheet and the top header never match).
#  - with a name: exact (case-insensitive) text match
#  - without a name: the row sitting just above a "Page" badge
# Never uses position in the list, so "Dismiss" / the checked main profile cannot be picked.
pick_page_row() {
  python3 - "$UI_XML" "${1:-}" <<'PY'
import re, sys, xml.etree.ElementTree as ET
path, name = sys.argv[1], sys.argv[2]
rows = []
for n in ET.parse(path).getroot().iter('node'):
    a = n.attrib
    t = (a.get('text') or a.get('content-desc') or '').strip()
    m = re.findall(r'\d+', a.get('bounds', ''))
    if not t or len(m) != 4:
        continue
    x1, y1, x2, y2 = map(int, m)
    if y1 < 1300:
        continue
    rows.append(((x1 + x2) // 2, (y1 + y2) // 2, t))
if name:
    for x, y, t in rows:
        if t.lower() == name.lower():
            print(x, y)
            break
    sys.exit(0)
for bx, by, bt in rows:
    if bt.lower() != 'page':
        continue
    c = [r for r in rows if r[1] < by and by - r[1] <= 120 and r[2].lower() != 'page']
    if c:
        r = max(c, key=lambda r: r[1])
        print(r[0], r[1])
        break
PY
}

# After login: "Continue in English (US)" -> "Skip" / "Not now" ... until the feed shows
post_login_prompts() {
  local rounds="${1:-12}" i xy handled
  for ((i=0; i<rounds; i++)); do
    dismiss_system_dialogs
    if is_logged_in; then log "feed detected"; return 0; fi
    handled=0
    xy="$(ui_query text '^Continue in English' 0 || true)"
    if [[ -n "$xy" ]]; then
      log "language prompt: tapping 'Continue in English (US)' at $xy"
      adb shell input tap $xy; handled=1; sleep 5
    else
      xy="$(ui_query text '^Skip$' 0 || true)"
      if [[ -n "$xy" ]]; then
        log "tapping 'Skip' at $xy"; adb shell input tap $xy; handled=1; sleep 5
      else
        xy="$(ui_query text "$DISMISS_REGEX" 0 || true)"
        if [[ -n "$xy" ]]; then log "popup, tapping dismiss at $xy"; adb shell input tap $xy; handled=1; sleep 4; fi
      fi
    fi
    if [[ "$handled" == "0" ]]; then log "no prompt to tap (round $((i+1))/$rounds), waiting"; sleep 4; fi
  done
  return 1
}

# Feed -> Menu -> profile switcher -> Page, then VERIFY the Menu header shows the Page.
# Returns 0 only when the switch is confirmed. Retries once.
switch_to_page() {
  local page="${FB_PAGE_NAME:-}" xy main_name now_name attempt
  log "opening Menu to switch from the main profile to the Page ${page:+($page)}"
  dismiss_popups 2
  tap_text '^Menu' "" 4 || { screenshot "09b-no-menu.png"; save_ui "no-menu"; log "ERROR: Menu tab not found"; return 1; }
  sleep 6
  screenshot "10-menu.png"; save_ui "menu"
  log "texts visible in Menu:"; ui_texts | head -40 | sed 's/^/[fb]   /'
  main_name="$(menu_profile_name)"
  log "profile before switch: '${main_name:-unknown}'"

  for attempt in 1 2; do
    # If a previous attempt left the sheet open, close it first
    ui_dump || true
    if switcher_open; then log "closing leftover switcher sheet"; adb shell input keyevent 4; sleep 3; ui_dump || true; fi
    # Make sure the Menu is open
    if ! grep -qiE 'see your profile|Settings and privacy' "$UI_XML"; then
      tap_text '^Menu' "" 3 || true
      sleep 6
    fi

    xy="$(ui_find text '(Profile switcher|Switch profile|Switch account)' 0 || true)"
    if [[ -z "$xy" ]]; then
      log "ERROR: profile switcher button not found in Menu (see 10-menu.png and ui-menu.xml)"
      return 1
    fi
    log "attempt $attempt: tap profile switcher at $xy"; adb shell input tap $xy; sleep 5
    screenshot "11-switcher-$attempt.png"; save_ui "switcher-$attempt"
    log "texts visible in the switcher:"; ui_texts | head -40 | sed 's/^/[fb]   /'

    xy="$(pick_page_row "$page" || true)"
    if [[ -z "$xy" ]]; then
      log "ERROR: Page row not found in the switcher (set the FB_PAGE_NAME secret to the exact Page name)"
      return 1
    fi
    log "tap Page row at $xy"; adb shell input tap $xy; sleep 15
    dismiss_system_dialogs
    post_login_prompts 4 || true
    screenshot "12-after-page-switch-$attempt.png"; save_ui "after-switch-$attempt"

    # VERIFY 1: the switcher sheet must be gone
    ui_dump || true
    if switcher_open; then log "switch check failed: switcher still open"; continue; fi

    # VERIFY 2: the Menu header must show the Page, not the main profile
    if ! tap_text '^Menu' "" 4; then log "switch check failed: could not open Menu to verify"; continue; fi
    sleep 6
    save_ui "verify-menu-$attempt"
    screenshot "13-verify-menu-$attempt.png"
    now_name="$(menu_profile_name)"
    log "profile after switch: '${now_name:-unknown}'"
    if [[ -n "$page" ]]; then
      if [[ "${now_name,,}" == "${page,,}" ]]; then log "PAGE SWITCH VERIFIED ($now_name)"; return 0; fi
    else
      if [[ -n "$now_name" && "$now_name" != "$main_name" ]]; then log "PAGE SWITCH VERIFIED ($now_name)"; return 0; fi
    fi
    log "switch check failed: still on '${now_name:-unknown}'"
  done
  log "ERROR: could not verify the switch to the Page"
  return 1
}

# ---------------- Backup / restore (needs adb root) ----------------
need_root() {
  adb root >/dev/null 2>&1; sleep 3; adb wait-for-device
  [[ "$(adb_sh id -u 2>/dev/null)" == "0" ]]
}

backup_session() {
  [[ -n "$BACKUP_PASSPHRASE" ]] || { log "backup skipped: BACKUP_PASSPHRASE empty"; return 1; }
  need_root || { log "backup failed: adb root not available"; return 1; }
  adb shell am force-stop "$PACKAGE_NAME"; sleep 2; adb shell sync
  local remote=/data/local/tmp/fb-session.tgz
  adb shell "rm -f $remote; tar -czf $remote --exclude='*/cache/*' --exclude='*/code_cache/*' -C /data/data $PACKAGE_NAME" \
    || { log "backup failed: tar error"; return 1; }
  adb pull "$remote" "$SESSION_TMP" >/dev/null 2>&1 || { log "backup failed: pull error"; return 1; }
  adb shell "rm -f $remote"
  local size; size="$(stat -c%s "$SESSION_TMP" 2>/dev/null || echo 0)"
  (( size < 10000 )) && { log "backup failed: archive too small ($size)"; rm -f "$SESSION_TMP"; return 1; }
  openssl enc -aes-256-cbc -pbkdf2 -salt -in "$SESSION_TMP" -out "$BACKUP_FILE" -pass env:BACKUP_PASSPHRASE \
    || { log "backup failed: encryption error"; rm -f "$SESSION_TMP"; return 1; }
  rm -f "$SESSION_TMP"
  log "encrypted backup created ($(stat -c%s "$BACKUP_FILE") bytes)"
}

# The slow phone link is only needed for the login. Once the backup is made locally, switch the
# exit node OFF so the Mega upload runs on the fast GitHub runner internet.
switch_to_runner_ip() {
  if [[ "$MODE" == "restore" ]]; then
    log "restore mode: already on the runner IP, nothing to switch"
    return 0
  fi
  log "switching OFF the phone exit node: the Mega upload will use the fast runner internet"
  sudo tailscale set --exit-node= || { log "WARNING: could not clear the exit node"; return 1; }
  sleep 5
  log "public IP now: $(curl -s --max-time 30 https://ifconfig.me || echo unknown)  (runner baseline: ${BASELINE_IP:-unknown})"
}

backup_and_upload() {
  backup_session || return 1
  switch_to_runner_ip || log "WARNING: still on the phone link, the upload may be slow"
  mega_upload || log "WARNING: backup created but NOT uploaded to Mega"
}

restore_session() {
  [[ -s "$BACKUP_FILE" ]] || { log "restore failed: no backup file"; return 1; }
  [[ -n "$BACKUP_PASSPHRASE" ]] || { log "restore failed: BACKUP_PASSPHRASE empty"; return 1; }
  need_root || { log "restore failed: adb root not available"; return 1; }
  openssl enc -d -aes-256-cbc -pbkdf2 -in "$BACKUP_FILE" -out "$SESSION_TMP" -pass env:BACKUP_PASSPHRASE \
    || { log "restore failed: decryption error"; return 1; }
  tar -tzf "$SESSION_TMP" >/dev/null 2>&1 || { log "restore failed: corrupt archive"; return 1; }
  local uid; uid="$(adb_sh stat -c %u "/data/data/$PACKAGE_NAME")"
  [[ -n "$uid" ]] || { log "restore failed: app data dir missing"; return 1; }
  local remote=/data/local/tmp/fb-session.tgz
  adb shell am force-stop "$PACKAGE_NAME"
  adb push "$SESSION_TMP" "$remote" >/dev/null 2>&1 || { log "restore failed: push error"; return 1; }
  adb shell "find /data/data/$PACKAGE_NAME -mindepth 1 -maxdepth 1 ! -name cache ! -name code_cache -exec rm -rf {} +"
  adb shell "tar -xzf $remote -C /data/data" || { log "restore failed: extract error"; return 1; }
  adb shell "chown -R $uid:$uid /data/data/$PACKAGE_NAME"
  adb shell "restorecon -R /data/data/$PACKAGE_NAME" 2>/dev/null || true
  adb shell setenforce 0 2>/dev/null || true
  adb shell "rm -f $remote"; rm -f "$SESSION_TMP"
  log "session data restored"
}

# ---------------- Reel posting ----------------

# log_restored_profile() and switch_to_page() both leave the app sitting on the Menu screen
# (they open it to read the profile name). The reel composer is opened from the feed, so make
# sure Menu is closed and the feed is back on screen before touching the + icon.
return_to_feed() {
  local i
  for i in 1 2 3; do
    ui_dump || true
    if grep -qiE 'Your shortcuts|Settings and privacy' "$UI_XML" 2>/dev/null; then
      log "closing Menu to get back to the feed (attempt $i)"
      adb shell input keyevent 4 >/dev/null 2>&1
      sleep 3
    else
      break
    fi
  done
  dismiss_system_dialogs
}

# After a failed (or finished) reel attempt the app can be stuck on the "Couldn't play video"
# dialog, the Edit reel screen, the gallery, or a "Discard?" prompt. Get back to the plain feed
# so the next reel starts from a known state. Last resort: force-stop and relaunch (the logged-in
# session is on disk, so no new login is needed).
# Feed check: the feed has "What's on your mind?"; composer screens have "Add audio",
# "Select multiple", "Camera roll settings" or "Describe your reel". (Do NOT test for
# "Create reel": the feed's own story strip has a "Create reel" tile.)
recover_to_feed() {
  local i xy
  for i in 1 2 3 4 5; do
    ui_dump || true
    # playback error dialog -> OK
    if grep -qiE "Couldn.t play video" "$UI_XML"; then
      xy="$(ui_query text '^OK$' 0 || true)"
      [[ -n "$xy" ]] && { log "recover: dismissing 'Couldn't play video' dialog"; adb shell input tap $xy; sleep 2; }
      ui_dump || true
    fi
    # already on the feed?
    if grep -qiE "What.s on your mind" "$UI_XML" \
       && ! grep -qiE 'Add audio|Select multiple|Camera roll settings|Describe your reel|Share now' "$UI_XML"; then
      return 0
    fi
    # "Discard / Leave" style confirmation -> confirm, otherwise press Back
    xy="$(ui_query text '^(Discard|Discard reel|Discard edits|Delete|Leave|Exit|Leave and discard)$' 0 || true)"
    if [[ -n "$xy" ]]; then
      log "recover: confirming discard at $xy"; adb shell input tap $xy
    else
      adb shell input keyevent 4 >/dev/null 2>&1
    fi
    sleep 3
  done
  log "recover_to_feed: still not on the feed, force-stop + relaunch (session is on disk)"
  adb shell am force-stop "$PACKAGE_NAME"; sleep 2
  launch_app; sleep 20
  dismiss_system_dialogs
  dismiss_popups 3
  return 0
}

# ADBKeyboard types unicode (emoji, hashtags, accents) reliably; the stock `input text` cannot.
setup_adb_keyboard() {
  if adb shell pm list packages 2>/dev/null | grep -q "$ADBKEYBOARD_PKG"; then
    log "ADBKeyboard already installed"
  else
    log "installing ADBKeyboard (for typing unicode/emoji captions)"
    curl -fsSL --retry 3 -o "$ADBKEYBOARD_APK" "$ADBKEYBOARD_APK_URL" || { log "ERROR: could not download ADBKeyboard"; return 1; }
    adb install -r -g "$ADBKEYBOARD_APK" || { log "ERROR: could not install ADBKeyboard"; return 1; }
  fi
  adb shell ime enable ${ADBKEYBOARD_PKG}/.AdbIME >/dev/null 2>&1
  adb shell ime set ${ADBKEYBOARD_PKG}/.AdbIME >/dev/null 2>&1
  sleep 1
  local cur; cur="$(adb shell settings get secure default_input_method 2>/dev/null | tr -d '\r')"
  if [[ "$cur" != *"$ADBKEYBOARD_PKG"* ]]; then
    log "ERROR: ADBKeyboard could not be set as the default IME (current: '$cur')"
    return 1
  fi
}

# Clears the focused field, then types $1 (any UTF-8: emoji, hashtags, accents) via ADBKeyboard
adb_type_unicode() {
  local text="$1" b64
  adb shell am broadcast -a ADB_CLEAR_TEXT >/dev/null 2>&1
  sleep 1
  b64="$(printf '%s' "$text" | base64 -w0)"
  adb shell am broadcast -a ADB_INPUT_B64 --es msg "$b64" >/dev/null 2>&1
  sleep 2
}

read_caption() {
  [[ -s "$CAPTION_FILE" ]] || { log "ERROR: caption file not found or empty: $CAPTION_FILE"; return 1; }
  cat "$CAPTION_FILE"
}

# Video files in mega:<MEGA_REELS_SRC> not yet moved to mega:<MEGA_REELS_DONE>, oldest name first
list_pending_reels() {
  rclone lsf "${MEGA_REMOTE}:${MEGA_REELS_SRC}" \
    --include '*.mp4' --include '*.MP4' --include '*.mov' --include '*.MOV' --include '*.m4v' --include '*.M4V' \
    2>/dev/null | sort
}

download_reel() {
  local name="$1" dest="${REELS_LOCAL_DIR}/${name}"
  mkdir -p "$REELS_LOCAL_DIR"
  rclone copyto "${MEGA_REMOTE}:${MEGA_REELS_SRC}/${name}" "$dest" --retries 5 -q || return 1
  [[ -s "$dest" ]] || return 1
  echo "$dest"
}

# Re-encodes a clip to something the emulator's software decoder can always play:
# H.264 Main profile, yuv420p, 30 fps constant, max 720 px wide (even dimensions), AAC stereo.
# Prints the path of the new file. The output is named <original-name>.mp4 inside a sub-folder so
# the file name on the device stays identical to the one in Mega.
reencode_reel() {
  local in="$1" dir base out
  dir="$(dirname "$in")/enc"; base="$(basename "$in")"; base="${base%.*}.mp4"
  mkdir -p "$dir"; out="${dir}/${base}"
  if ! command -v ffmpeg >/dev/null 2>&1; then
    log "installing ffmpeg"
    sudo apt-get update -qq >/dev/null 2>&1
    sudo apt-get install -y -qq ffmpeg >/dev/null 2>&1 || { log "WARNING: could not install ffmpeg"; return 1; }
  fi
  ffmpeg -y -loglevel error -i "$in" \
    -vf "scale='min(720,iw)':-2,fps=30,format=yuv420p" \
    -c:v libx264 -profile:v main -level 3.1 -preset veryfast -crf 23 \
    -c:a aac -b:a 128k -ar 44100 -ac 2 \
    -movflags +faststart "$out" </dev/null || return 1
  [[ -s "$out" ]] || return 1
  echo "$out"
}

# Pushes the video to the device and triggers a media scan so the gallery picker can see it.
# Each reel is pushed, posted and deleted before the next one, so at most one video ever sits
# on the device at a time - the picker never has to tell two videos apart.
push_reel_to_device() {
  local local_path="$1" name remote_path
  name="$(basename "$local_path")"
  remote_path="/sdcard/Movies/${name}"
  adb push "$local_path" "$remote_path" >/dev/null 2>&1 || return 1
  adb shell am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d "file://${remote_path}" >/dev/null 2>&1
  sleep 3
  echo "$remote_path"
}

remove_reel_from_device() {
  local remote_path="$1"
  [[ -n "$remote_path" ]] || return 0
  adb shell rm -f "$remote_path" >/dev/null 2>&1
  adb shell am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d "file://${remote_path}" >/dev/null 2>&1
}

# In the media picker, finds the one video thumbnail: first by its duration badge (e.g. "0:12"),
# falling back to the first sizeable clickable grid cell below the header.
pick_single_video_thumb() {
  python3 - "$UI_XML" <<'PY'
import re, sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
dur = re.compile(r'^\d{1,2}:\d{2}$')
hits = []
for n in root.iter('node'):
    a = n.attrib
    t = (a.get('text') or '').strip()
    m = re.findall(r'\d+', a.get('bounds', ''))
    if dur.match(t) and len(m) == 4:
        x1, y1, x2, y2 = map(int, m)
        hits.append(((x1 + x2) // 2, (y1 + y2) // 2))
if hits:
    print(hits[0][0], hits[0][1])
    sys.exit(0)
best = None
for n in root.iter('node'):
    a = n.attrib
    if a.get('clickable') != 'true':
        continue
    m = re.findall(r'\d+', a.get('bounds', ''))
    if len(m) != 4:
        continue
    x1, y1, x2, y2 = map(int, m)
    w, h = x2 - x1, y2 - y1
    if w < 150 or h < 150 or y1 < 350:
        continue
    if best is None or (y1, x1) < (best[0], best[1]):
        best = (y1, x1, (x1 + x2) // 2, (y1 + y2) // 2)
if best:
    print(best[2], best[3])
PY
}

# Full composer flow for one reel: + -> Reel -> pick video -> Next* -> caption -> Share.
# Return codes:
#   0 = shared OK
#   1 = this video failed (retryable, left in MEGA_REELS_SRC)
#   2 = a structural step failed (same for every video, so the caller stops the whole loop)
#   3 = Facebook could not play the video in the emulator (counts toward MAX_PLAYBACK_FAILS)
compose_one_reel() {
  local idx="$1" caption="$2" xy ok=0 i

  # feed -> tap + -> "Post / Story / Reel / Live" menu
  tap_text '^(Create|Add)$' "780 119" 4 || { log "ERROR: create (+) button not found"; return 2; }
  sleep 4
  screenshot "r${idx}-00-create-menu.png"; save_ui "r${idx}-create-menu"
  log "texts in create menu:"; ui_texts | head -30 | sed 's/^/[fb]   /'

  xy="$(ui_find text '^Reel$' 0 || true)"
  [[ -z "$xy" ]] && xy="$(ui_find text 'Reel' 0 || true)"
  [[ -n "$xy" ]] || { log "ERROR: 'Reel' option not found in the create menu"; return 2; }
  log "tap Reel option at $xy"; adb shell input tap $xy; sleep 6

  # "Create reel" screen: a Gallery grid is shown directly, no extra button to open it
  screenshot "r${idx}-01-create-reel-gallery.png"; save_ui "r${idx}-create-reel-gallery"
  log "texts in Create reel / gallery:"; ui_texts | head -30 | sed 's/^/[fb]   /'

  xy="$(pick_single_video_thumb || true)"
  [[ -n "$xy" ]] || { log "ERROR: video thumbnail not found in the gallery grid (see r${idx}-01-create-reel-gallery.png)"; return 1; }
  log "tap video thumbnail at $xy"; adb shell input tap $xy; sleep 8

  # Picking the video opens the "Edit reel" screen (Audio/Text/Effects/Stickers/Save, -> Next)
  screenshot "r${idx}-02-edit-reel.png"; save_ui "r${idx}-edit-reel"
  log "texts in Edit reel:"; ui_texts | head -30 | sed 's/^/[fb]   /'

  # Fail fast if the emulator could not decode the video
  if grep -qiE "Couldn.t play video" "$UI_XML"; then
    log "ERROR: Facebook could not play this video in the emulator (codec / GPU issue)"
    return 3
  fi

  xy="$(ui_find text '^Next$' 0 || true)"
  [[ -n "$xy" ]] || { log "ERROR: Next button not found on the Edit reel screen"; return 1; }
  log "tap Next at $xy"; adb shell input tap $xy; sleep 5

  # If there's a second "Next" screen before Reel Settings, step through it too (usually none)
  for i in 1 2; do
    ui_dump || true
    grep -qi 'Describe your reel' "$UI_XML" && break
    xy="$(ui_query text '^Next$' 0 || true)"
    [[ -z "$xy" ]] && break
    log "tap Next ($((i+1))) at $xy"; adb shell input tap $xy; sleep 4
  done

  # "Reel Settings" screen: caption placeholder "Describe your reel. You can also add
  # hashtags here." and the "Share now" button
  screenshot "r${idx}-03-reel-settings.png"; save_ui "r${idx}-reel-settings"
  log "texts in Reel Settings:"; ui_texts | head -30 | sed 's/^/[fb]   /'

  xy="$(ui_find text 'Describe your reel' 0 || true)"
  [[ -n "$xy" ]] || { log "ERROR: caption field not found on Reel Settings"; return 1; }
  log "tap caption field at $xy"; adb shell input tap $xy; sleep 2

  setup_adb_keyboard || { log "ERROR: ADBKeyboard not ready, cannot type caption"; return 1; }
  adb_type_unicode "$caption"
  screenshot "r${idx}-04-caption-typed.png"; save_ui "r${idx}-caption-typed"

  adb shell input keyevent 4 >/dev/null 2>&1; sleep 1   # hide keyboard so Share now is visible

  xy="$(ui_find text '^Share now$' 0 || true)"
  [[ -n "$xy" ]] || { log "ERROR: Share now button not found"; return 1; }
  log "tap Share now at $xy"; adb shell input tap $xy

  # Upload+share can take a while; poll until the composer closes
  for i in $(seq 1 24); do
    sleep 5
    ui_dump || continue
    if ! grep -qiE 'describe your reel|share now' "$UI_XML" && grep -qiE 'Home|Menu|Notifications' "$UI_XML"; then
      ok=1; break
    fi
  done
  screenshot "r${idx}-05-after-share.png"; save_ui "r${idx}-after-share"
  if [[ "$ok" == "1" ]]; then log "reel #${idx} SHARED"; return 0; fi
  log "ERROR: could not confirm reel #${idx} finished sharing (see r${idx}-05-after-share.png)"
  return 1
}

# Downloads up to REEL_COUNT pending videos from Mega and posts each one in turn. A video is
# moved to MEGA_REELS_DONE only after its share is confirmed, so a run that fails partway never
# reposts anything that already went out, and never loses a video that failed to post.
post_reels_flow() {
  local count="$REEL_COUNT"
  [[ "$count" =~ ^[0-9]+$ ]] || count=0
  (( count > 0 )) || { log "REEL_COUNT is 0, skipping reel posting"; return 0; }

  setup_rclone || { log "ERROR: rclone/Mega not ready, cannot fetch reels"; return 1; }
  local caption; caption="$(read_caption)" || return 1
  log "caption loaded from $CAPTION_FILE ($(printf '%s' "$caption" | wc -c) bytes)"

  mapfile -t pending < <(list_pending_reels)
  if (( ${#pending[@]} == 0 )); then
    log "no videos found in ${MEGA_REELS_SRC}"; return 0
  fi
  log "found ${#pending[@]} video(s) in ${MEGA_REELS_SRC}, will post up to $count"

  local posted=0 idx=0 playback_fails=0 name local_path enc remote_path rc
  for name in "${pending[@]}"; do
    (( posted >= count )) && break
    idx=$((idx+1))
    log "=== reel $((posted+1))/$count (file #$idx): $name ==="

    local_path="$(download_reel "$name" || true)"
    [[ -n "$local_path" ]] || { log "ERROR: could not download $name from Mega, skipping"; continue; }

    if [[ "$REENCODE_REELS" == "1" ]]; then
      if enc="$(reencode_reel "$local_path")" && [[ -n "$enc" ]]; then
        rm -f "$local_path"; local_path="$enc"
        log "re-encoded for the emulator: $(basename "$enc") ($(stat -c%s "$enc") bytes)"
      else
        log "WARNING: re-encode failed, using the original file (it may not play in the emulator)"
      fi
    fi

    remote_path="$(push_reel_to_device "$local_path" || true)"
    rm -f "$local_path"
    [[ -n "$remote_path" ]] || { log "ERROR: could not push $name to the device, skipping"; continue; }

    compose_one_reel "$idx" "$caption"; rc=$?
    remove_reel_from_device "$remote_path"

    # Whatever happened, make sure the app is back on the plain feed before anything else, so a
    # stale screen can never be mistaken for a structural failure or break the next video.
    if [[ "$rc" != "0" ]]; then recover_to_feed; else return_to_feed; fi

    if [[ "$rc" == "0" ]]; then
      playback_fails=0
      if rclone moveto "${MEGA_REMOTE}:${MEGA_REELS_SRC}/${name}" "${MEGA_REMOTE}:${MEGA_REELS_DONE}/${name}" --retries 5 -q; then
        log "moved $name to ${MEGA_REELS_DONE} (will not be reposted)"
      else
        log "WARNING: reel posted but could not move $name in Mega - move it manually or it may be reposted"
      fi
      posted=$((posted+1))
    elif [[ "$rc" == "2" ]]; then
      log "structural failure, stopping reel posting (see r${idx}-* artifacts)"
      break
    elif [[ "$rc" == "3" ]]; then
      playback_fails=$((playback_fails+1))
      log "reel $name: playback error ($playback_fails/$MAX_PLAYBACK_FAILS), left in ${MEGA_REELS_SRC} for retry"
      if (( playback_fails >= MAX_PLAYBACK_FAILS )); then
        log "stopping: repeated playback errors point at the emulator (GPU/codec), not at one bad file"
        break
      fi
    else
      playback_fails=0
      log "reel $name failed, left in ${MEGA_REELS_SRC} for retry"
    fi
  done
  log "reel posting done: $posted/${count} posted"
}

# ---------------- Facebook login ----------------
login_flow() {
  if [[ -z "$FB_IDENTIFIER" || -z "$FB_PASSWORD" ]]; then
    log "login skipped: FB_IDENTIFIER / FB_PASSWORD secrets are empty"; return 1
  fi

  # Never type credentials unless traffic is leaving through the phone exit node
  phone_guard || return 1

  dismiss_system_dialogs
  sleep 5
  dismiss_popups 2   # language / permission prompts
  screenshot "03-before-login.png"

  # Some versions show a welcome screen with a "Log in" button before the form
  if ! ui_find class 'EditText' 0 >/dev/null 2>&1 || [[ -z "$(ui_query class 'EditText' 0 || true)" ]]; then
    tap_text '^Log ?in$' "" 3 || true
    sleep 4
  fi

  tap_field 0 || { screenshot "04-no-form.png"; log "ERROR: login form not found"; return 1; }
  sleep 1; type_text "$FB_IDENTIFIER"; sleep 1
  screenshot "05-username-entered.png"

  tap_field 1 || { log "ERROR: password field not found"; return 1; }
  sleep 1; type_text "$FB_PASSWORD"; sleep 1
  screenshot "06-password-entered.png"   # password is masked

  adb shell input keyevent 4 >/dev/null 2>&1; sleep 1   # hide keyboard so the button is visible

  # Re-check right before submitting, in case the exit node dropped while typing
  phone_guard || return 1

  tap_text '^Log ?in$' "" 3 || adb shell input keyevent 66
  sleep 15
  dismiss_system_dialogs
  screenshot "07-after-login-15s.png"

  if ui_dump; then
    grep -qiE 'incorrect|wrong|invalid|doesn.t match' "$UI_XML" && log "WARNING: credentials look wrong"
    grep -qiE 'code|two-factor|authentication app|confirm it.s you|checkpoint|suspicious|secure your account' "$UI_XML" \
      && log "WARNING: Facebook is asking for a security check / 2FA code. Complete it manually; automation stops here."
  fi

  sleep 10
  # "Save your login info?" -> Save keeps the session
  tap_text '^(Save|OK)$' "" 1 || true
  sleep 3
  # Then: "Continue in English (US)" -> "Skip" / "Not now" ... until the feed appears
  post_login_prompts 12 || true
  screenshot "08-after-popups.png"

  if is_logged_in; then
    log "LOGIN OK (feed is visible)"
    screenshot "09-feed.png"
    local page_ok=0
    switch_to_page && page_ok=1
    if [[ "$page_ok" == "0" && "${FB_REQUIRE_PAGE:-1}" == "1" ]]; then
      log "ERROR: could not switch to the Page, NOT creating a backup (set FB_REQUIRE_PAGE=0 to back up the main profile anyway)"
      return 1
    fi
    # backup (local) -> switch to runner IP -> fast Mega upload. The app is NOT relaunched afterwards,
    # so Facebook never sees the runner IP right after the phone IP login.
    [[ "$MAKE_BACKUP" == "1" ]] && { backup_and_upload || log "WARNING: backup not created"; }
    return_to_feed
    post_reels_flow
  else
    log "WARNING: feed not detected, NOT creating a backup (a good old backup is never replaced by a bad one)"
    return 1
  fi
}

# Log which profile the restored session opened as (Page name expected if the backup was made on the Page)
log_restored_profile() {
  local name
  if tap_text '^Menu' "" 3; then
    sleep 6; save_ui "restored-menu"; screenshot "12-restored-menu.png"
    name="$(menu_profile_name)"
    log "restored session profile: '${name:-unknown}'"
    if [[ -n "${FB_PAGE_NAME:-}" ]]; then
      if [[ "${name,,}" == "${FB_PAGE_NAME,,}" ]]; then log "RESTORED AS PAGE OK ($name)"
      else log "WARNING: restored profile is '${name:-unknown}', expected Page '${FB_PAGE_NAME}'"; fi
    fi
  else
    log "could not open Menu to check the restored profile"
  fi
}

restore_flow() {
  # No phone guard here: restore runs on the GitHub runner IP by design
  log "starting the app once so its data folder exists"
  launch_app; sleep 10; dismiss_system_dialogs
  adb shell am force-stop "$PACKAGE_NAME"; sleep 1
  restore_session || return 1
  launch_app; sleep 20; dismiss_system_dialogs
  screenshot "10-restored-launch.png"
  dismiss_popups 5; sleep 2
  screenshot "11-restored-after-dismiss.png"
  if is_logged_in; then
    log "RESTORE OK: Facebook opened already logged in"
    log_restored_profile
    [[ "$RESAVE" == "1" ]] && { backup_and_upload || log "WARNING: refreshed backup not created"; }
    return_to_feed
    post_reels_flow
    return 0
  fi
  log "RESTORE FAILED: not logged in (see screenshots 10 and 11)"
  return 1
}

# ===================== MAIN =====================
log "mode: $MODE"

# LOGIN mode: refuse to do anything unless the phone exit node is active.
# RESTORE mode: runs on the plain GitHub runner IP, no exit node, no guard.
if [[ "$MODE" == "restore" ]]; then
  log "restore mode: using the GitHub runner IP (no phone exit node, no IP guard)"
else
  phone_guard || exit 1
fi

adb devices -l
APK_MEGA_FILE="${APK_MEGA_FILE:-}"
if [[ -s "$APK_FILE" ]]; then
  log "using APK already downloaded by the workflow: $APK_FILE ($(stat -c%s "$APK_FILE") bytes)"
elif [[ -n "$APK_URL" ]]; then
  log "downloading APK from URL"
  curl -L --fail --retry 3 --connect-timeout 20 -o "$APK_FILE" "$APK_URL" || { log "ERROR: download failed"; exit 1; }
elif [[ -n "$APK_MEGA_FILE" ]]; then
  log "downloading APK set from Mega: $APK_MEGA_FILE"
  setup_rclone || { log "ERROR: rclone/Mega not ready"; exit 1; }
  rclone copyto "${MEGA_REMOTE}:${APK_MEGA_FILE}" "$APK_FILE" --retries 5 -q \
    || { log "ERROR: APK not found in Mega at ${APK_MEGA_FILE}"; exit 1; }
else
  log "ERROR: set APK_URL or APK_MEGA_FILE"; exit 1
fi
[[ "$(head -c 2 "$APK_FILE")" == "PK" ]] || { log "ERROR: not an APK or zip (HTML page? use a direct link)"; exit 1; }

# A single APK contains AndroidManifest.xml. Otherwise treat the file as a zip of split APKs
# (base.apk + split_config.*.apk pulled from a phone).
APK_LIST=("$APK_FILE")
if ! unzip -l "$APK_FILE" 2>/dev/null | grep -q 'AndroidManifest.xml'; then
  SPLIT_DIR="${RUNNER_TEMP:-/tmp}/fb-splits"
  rm -rf "$SPLIT_DIR"; mkdir -p "$SPLIT_DIR"
  unzip -q -o "$APK_FILE" -d "$SPLIT_DIR" || { log "ERROR: cannot unzip the download"; exit 1; }
  mapfile -t APK_LIST < <(find "$SPLIT_DIR" -name '*.apk' | sort)
  (( ${#APK_LIST[@]} > 0 )) || { log "ERROR: no .apk files inside the zip"; exit 1; }
  log "split APK set: ${#APK_LIST[@]} file(s)"
fi

if [[ "$MODE" == "restore" ]]; then
  mega_download || { log "ERROR: could not download backup"; exit 1; }
fi

wait_for_boot
settle_device
sleep 20
dismiss_system_dialogs
screenshot "00-home-screen.png"

log "emulator CPU ABIs: $(adb_sh getprop ro.product.cpu.abilist)"
log "installing APK"
if (( ${#APK_LIST[@]} > 1 )); then
  adb install-multiple -r -t -g "${APK_LIST[@]}" \
    || adb install-multiple -r -t -g -d "${APK_LIST[@]}" \
    || { log "ERROR: install-multiple failed (arm64-only build on an x86_64 emulator?)"; exit 1; }
else
  adb install -r -t -g "${APK_LIST[0]}" \
    || adb install -r -t -g -d "${APK_LIST[0]}" \
    || { log "ERROR: install failed (ABI mismatch?)"; exit 1; }
fi
adb shell pm list packages | grep -F "$PACKAGE_NAME" || { log "ERROR: package not installed"; exit 1; }
sleep 2
screenshot "01-after-install.png"

if [[ "$MODE" == "restore" ]]; then
  restore_flow || exit 1
else
  launch_app; sleep 12
  dismiss_system_dialogs
  screenshot "02-after-launch.png"
  login_flow || { log "login flow ended with an error"; exit 1; }
fi
log "Done!"
