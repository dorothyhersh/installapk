#!/usr/bin/env bash
# MODE=login   : install -> launch -> sign in -> dismiss popups -> switch to Page (verified) -> encrypted backup -> upload to Mega
# MODE=restore : download backup from Mega -> install -> restore -> launch -> verify logged in
# Env: APK_URL, PACKAGE_NAME (default com.facebook.katana), FB_IDENTIFIER, FB_PASSWORD,
#      FB_PAGE_NAME (exact Page name, strongly recommended), FB_REQUIRE_PAGE (default 1),
#      BACKUP_PASSPHRASE, RCLONE_CONF_CONTENT, MEGA_FOLDER, MEGA_FILE, MAKE_BACKUP, RESAVE
# Phone exit node: PHONE_IP, BASELINE_IP, EXPECTED_PHONE_IP (optional) are used by the IP guard.
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

setup_rclone() {
  if ! command -v rclone >/dev/null 2>&1 || ! rclone_has_mega; then
    log "installing official rclone"
    local tmp; tmp="$(mktemp -d)"
    curl -fsSL -o "$tmp/rclone.zip" https://downloads.rclone.org/rclone-current-linux-amd64.zip \
      && unzip -q "$tmp/rclone.zip" -d "$tmp" \
      && sudo install -m 0755 "$tmp"/rclone-*-linux-amd64/rclone /usr/local/bin/rclone
    rm -rf "$tmp"; hash -r
  fi
  rclone_has_mega || { log "rclone has no mega backend"; return 1; }
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
  else
    log "WARNING: feed not detected, NOT creating a backup (a good old backup is never replaced by a bad one)"
    return 1
  fi
}

restore_flow() {
  phone_guard || return 1
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
    [[ "$RESAVE" == "1" ]] && { backup_and_upload || log "WARNING: refreshed backup not created"; }
    return 0
  fi
  log "RESTORE FAILED: not logged in (see screenshots 10 and 11)"
  return 1
}

# ===================== MAIN =====================
log "mode: $MODE"

# Refuse to do anything (APK download, Mega, login) unless the phone exit node is active
phone_guard || exit 1

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
