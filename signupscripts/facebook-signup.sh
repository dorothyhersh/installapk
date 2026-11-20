#!/usr/bin/env bash
# Create a NEW Facebook account in the Android emulator (Facebook app), step by step like the
# screenshots: Create new account > name > birthday > gender > "Sign up with email" > email >
# password > I agree > 5-digit confirmation code > skip onboarding prompts > encrypted backup to Mega.
#
# Env (required): FB_FIRST_NAME FB_LAST_NAME FB_BIRTHDAY(YYYY-MM-DD) FB_GENDER(male|female) FB_EMAIL FB_PASSWORD
# Env (code):     GMAIL_APP_PASSWORD (auto-read code from your Gmail)  OR  put the code in Mega at
#                 ${MEGA_REMOTE}:${CODE_MEGA_PATH} (a text file containing only the 5 digits)
# Env (optional): IP_MODE_ACTIVE_FILE, MAKE_BACKUP, BACKUP_PASSPHRASE, RCLONE_CONF_CONTENT, PACKAGE_NAME
# It does NOT solve captchas / checkpoints. If Facebook asks for one, it stops and saves screenshots.
set -uo pipefail

ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
ARTIFACTS="${ROOT}/artifacts"
BACKUP_DIR="${ROOT}/backup"
mkdir -p "$ARTIFACTS" "$BACKUP_DIR"
exec > >(tee -a "$ARTIFACTS/run.log") 2>&1

PACKAGE_NAME="${PACKAGE_NAME:-com.facebook.katana}"
FB_FIRST_NAME="${FB_FIRST_NAME:-}"; FB_LAST_NAME="${FB_LAST_NAME:-}"
FB_BIRTHDAY="${FB_BIRTHDAY:-2002-05-17}"; FB_GENDER="${FB_GENDER:-male}"
FB_EMAIL="${FB_EMAIL:-}"; FB_PASSWORD="${FB_PASSWORD:-}"
MAKE_BACKUP="${MAKE_BACKUP:-1}"
BACKUP_PASSPHRASE="${BACKUP_PASSPHRASE:-}"
CODE_WAIT="${CODE_WAIT:-120}"
CODE_ATTEMPTS="${CODE_ATTEMPTS:-4}"

RCLONE_CONF_CONTENT="${RCLONE_CONF_CONTENT:-}"
RCLONE_CFG="${HOME}/.config/rclone/rclone.conf"
MEGA_REMOTE="${MEGA_REMOTE:-mega}"
# separate folder/file so an existing login backup is never overwritten
MEGA_FOLDER="${MEGA_FOLDER:-facebook-signup-backup}"
MEGA_FILE="${MEGA_FILE:-fb-new-session.tgz.enc}"
MEGA_KEEP="${MEGA_KEEP:-10}"
MEGA_DIR="${MEGA_REMOTE}:${MEGA_FOLDER}"
CODE_MEGA_PATH="${CODE_MEGA_PATH:-facebook-signup/code.txt}"

BACKUP_FILE="${BACKUP_DIR}/fb-new-session.tgz.enc"
APK_FILE="${RUNNER_TEMP:-/tmp}/fb.apk"
UI_XML="${RUNNER_TEMP:-/tmp}/ui.xml"
SESSION_TMP="${RUNNER_TEMP:-/tmp}/fb-session.tgz"
ACTIVE_FILE="${RUNNER_TEMP:-/tmp}/ip_mode_active"
ACTIVE_MODE="$(cat "$ACTIVE_FILE" 2>/dev/null || echo runner)"

DISMISS_REGEX='^(Not now|Not Now|Maybe later|No thanks|Skip|Later|Dismiss|Got it|Cancel|Don.t allow|DENY)\b'
BLOCK_REGEX="couldn.t create|can.t create your account|unable to create|try again later|temporarily blocked|we suspended|captcha|security check|confirm it.s you|checkpoint|not a robot|verify you.re human|something went wrong"

log() { printf '[fb] %s\n' "$*"; }

finish() {
  local code=$?
  log "exiting with code $code"
  screenshot "99-final-state.png"
  adb logcat -d > "$ARTIFACTS/logcat.txt" 2>/dev/null
  exit "$code"
}
trap finish EXIT

# The log() above is also defined again in the helpers; that is harmless.
log() { printf '[fb] %s\n' "$*"; }

adb_sh() { adb shell "$@" | tr -d '\r'; }

screenshot() {
  local f="$ARTIFACTS/$1"
  adb exec-out screencap -p > "$f" 2>/dev/null
  if [[ -s "$f" ]]; then log "screenshot: $1"; else log "screenshot FAILED: $1"; rm -f "$f"; fi
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

is_logged_in() {
  ui_dump || return 1
  ! grep -qiE 'Create new account|Forgot password|Log in to Facebook' "$UI_XML" \
    && grep -qiE 'Home|What.s on your mind|Notifications|Menu' "$UI_XML"
}

save_ui() { ui_dump && cp "$UI_XML" "$ARTIFACTS/ui-$1.xml" 2>/dev/null || true; }

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

# ---------------- IP guard (depends on the mode chosen by select-ip.sh) ----------------
ip_guard() {
  if [[ "$ACTIVE_MODE" == "telenor" ]]; then
    bash "${ROOT}/signupscripts/assert-phone-ip.sh" || { log "ABORT: Telenor mode but traffic is not leaving through the phone"; return 1; }
  else
    log "runner IP mode, public IP: $(curl -s --max-time 30 https://ifconfig.me || echo unknown)"
  fi
}

switch_to_runner_ip() {
  [[ "$ACTIVE_MODE" == "telenor" ]] || return 0
  command -v tailscale >/dev/null 2>&1 || return 0
  log "switching OFF the phone exit node: the Mega upload will use the fast runner internet"
  sudo tailscale set --exit-node= || log "WARNING: could not clear the exit node"
  sleep 5
}

backup_and_upload() {
  backup_session || return 1
  switch_to_runner_ip
  mega_upload || log "WARNING: backup created but NOT uploaded to Mega"
}

# ---------------- small UI helpers for the signup flow ----------------
wait_text() {  # wait_text <regex> [tries]  -> 0 if the text shows up on screen
  local pat="$1" tries="${2:-10}" i
  for ((i=0; i<tries; i++)); do
    dismiss_perm
    if ui_dump && grep -qiE "$pat" "$UI_XML"; then return 0; fi
    sleep 2
  done
  return 1
}

dismiss_perm() {  # contacts / notification permission dialogs -> "Don't allow"
  ui_dump || return 0
  local xy; xy="$(ui_query text '^(Don.t allow|Deny)$' 0 || true)"
  [[ -n "$xy" ]] && { log "permission dialog: Don't allow at $xy"; adb shell input tap $xy; sleep 2; }
  return 0
}

is_blocked() { ui_dump && grep -qiE "$BLOCK_REGEX" "$UI_XML"; }

die_if_blocked() {
  if is_blocked; then
    screenshot "blocked-$1.png"; save_ui "blocked-$1"
    log "ERROR: Facebook refused or wants a captcha/security check at step '$1' (IP mode: $ACTIVE_MODE)."
    log "       Nothing is bypassed here. Re-run with the other IP mode (telenor <-> runner) or finish it manually."
    exit 2
  fi
}

next_btn() { tap_text '^Next$' "" 6 || { log "ERROR: Next button not found"; return 1; }; sleep 3; }

# prints: month day year xMonth xDay xYear yCenter rowHeight   (from the 3 spinner EditTexts)
picker_values() {
  python3 - "$UI_XML" <<'PY'
import re,sys,xml.etree.ElementTree as ET
M={m:i+1 for i,m in enumerate("jan feb mar apr may jun jul aug sep oct nov dec".split())}
rows=[]
for n in ET.parse(sys.argv[1]).getroot().iter('node'):
    a=n.attrib
    if 'EditText' not in a.get('class',''): continue
    b=re.findall(r'\d+',a.get('bounds',''))
    if len(b)!=4: continue
    x1,y1,x2,y2=map(int,b)
    rows.append(((x1+x2)//2,(y1+y2)//2,y2-y1,a.get('text','').strip()))
rows.sort()
if len(rows)<3: sys.exit(1)
vals=[];xs=[]
for x,y,h,t in rows[:3]:
    v=int(t) if t.isdigit() else M.get(t[:3].lower())
    if v is None: sys.exit(1)
    vals.append(v);xs.append(x)
print(*vals,*xs,rows[0][1],rows[0][2])
PY
}

# adjust spinner <0=month|1=day|2=year> to <target> by slow single-row swipes (no fling)
adjust_picker() {
  local idx="$1" target="$2" it v diff prev=999 dir=1 steps k cmd
  for ((it=0; it<40; it++)); do
    ui_dump || return 1
    local pv; pv="$(picker_values)" || { log "date picker spinners not found"; return 1; }
    v=($pv)
    local cur="${v[$idx]}" x="${v[$((3+idx))]}" y="${v[6]}" h="${v[7]}"
    diff=$((target-cur))
    if (( idx == 0 )); then (( diff > 6 )) && diff=$((diff-12)); (( diff < -6 )) && diff=$((diff+12)); fi
    (( diff == 0 )) && return 0
    local ad=${diff#-}
    # if the last swipe made it worse, the direction is the other way round
    (( it > 0 && ad >= prev )) && dir=$((-dir))
    prev=$ad
    steps=$(( ad > 6 ? 6 : ad )); cmd=""
    for ((k=0; k<steps; k++)); do
      # swipe DOWN lowers the value, swipe UP raises it (dir flips automatically if wrong)
      if (( (diff < 0 ? 1 : -1) * dir > 0 )); then cmd+="input swipe $x $y $x $((y+h)) 450; "
      else cmd+="input swipe $x $y $x $((y-h)) 450; "; fi
    done
    adb shell "$cmd" >/dev/null 2>&1; sleep 1
  done
  return 1
}

set_birthday() {
  local y="${FB_BIRTHDAY%%-*}" rest="${FB_BIRTHDAY#*-}" m d
  m="${rest%%-*}"; d="${rest#*-}"; m=$((10#$m)); d=$((10#$d)); y=$((10#$y))
  tap_text '^Birthday' "" 6 || { log "ERROR: birthday field not found"; return 1; }
  sleep 2; screenshot "04b-date-dialog.png"; save_ui "date-dialog"
  adjust_picker 2 "$y" || log "WARNING: could not set year"
  adjust_picker 0 "$m" || log "WARNING: could not set month"
  adjust_picker 1 "$d" || log "WARNING: could not set day"
  screenshot "04c-date-set.png"
  tap_text '^SET$' "" 3 || { log "ERROR: SET button not found"; return 1; }
  sleep 2
}

fetch_code() {
  local code="" since="$1"
  if [[ -n "${GMAIL_APP_PASSWORD:-}" ]]; then
    log "reading the confirmation code from Gmail (IMAP) for up to ${CODE_WAIT}s" >&2
    code="$(GMAIL_ADDRESS="$FB_EMAIL" SINCE_EPOCH="$since" CODE_WAIT="$CODE_WAIT" \
            python3 "${ROOT}/signupscripts/fetch-code.py" 2>>"$ARTIFACTS/imap.err")" || code=""
  else
    log "no GMAIL_APP_PASSWORD: waiting for a code file in Mega at ${MEGA_REMOTE}:${CODE_MEGA_PATH} (up to ${CODE_WAIT}s)" >&2
    setup_rclone >&2 || return 1
    rclone deletefile "${MEGA_REMOTE}:${CODE_MEGA_PATH}" 2>/dev/null || true
    local end=$((SECONDS+CODE_WAIT))
    while (( SECONDS < end )); do
      code="$(rclone cat "${MEGA_REMOTE}:${CODE_MEGA_PATH}" 2>/dev/null | tr -dc '0-9' | head -c 5)"
      [[ ${#code} -eq 5 ]] && break
      code=""; sleep 8
    done
    rclone deletefile "${MEGA_REMOTE}:${CODE_MEGA_PATH}" 2>/dev/null || true
  fi
  [[ "$code" =~ ^[0-9]{5}$ ]] || return 1
  printf '%s' "$code"
}


# Keeps looking at the current UI and taps the right entry button until "What's your name" shows.
reach_name_screen() {
  local end=$((SECONDS+${ENTRY_TIMEOUT:-300})) xy last=""
  while (( SECONDS < end )); do
    dismiss_perm
    if ! ui_dump; then sleep 3; continue; fi
    if grep -qiE "What.s your name|First name" "$UI_XML"; then log "name screen reached"; return 0; fi
    die_if_blocked "entry"
    xy="$(ui_query text '^Get started$' 0 || true)"
    if [[ -n "$xy" ]]; then log "entry: 'Get started' -> tap $xy"; adb shell input tap $xy; sleep 5; continue; fi
    xy="$(ui_query text '^(Create new (Facebook )?account|Join Facebook|Sign up)$' 0 || true)"
    if [[ -n "$xy" ]]; then log "entry: 'Create new account' -> tap $xy"; adb shell input tap $xy; sleep 6; continue; fi
    xy="$(ui_query text '^(Continue|Next)$' 0 || true)"
    if [[ -n "$xy" && "$last" != "cont" ]]; then log "entry: '$(echo continue)' -> tap $xy"; adb shell input tap $xy; last=cont; sleep 5; continue; fi
    log "entry: nothing to tap yet (loading?), waiting"; sleep 3
  done
  return 1
}


rand_wait() {  # rand_wait <min> <max> <why>
  local t=$(( $1 + RANDOM % ($2 - $1 + 1) ))
  log "waiting ${t}s ($3)"; sleep "$t"
}

# digits currently inside the first text field on screen
field_digits() {
  python3 - "$UI_XML" <<'PY'
import re,sys,xml.etree.ElementTree as ET
for n in ET.parse(sys.argv[1]).getroot().iter('node'):
    if 'EditText' in n.attrib.get('class',''):
        print(re.sub(r'\D','',n.attrib.get('text',''))); break
PY
}

# the "Do you need help?" bottom sheet can pop up over the code screen: close it
close_help_sheet() {
  ui_dump || return 0
  grep -qi "Do you need help" "$UI_XML" || return 0
  local xy; xy="$(ui_query text '^(Dismiss|Close)$' 0 || true)"
  [[ -n "$xy" ]] && { log "closing the help sheet at $xy"; adb shell input tap $xy; sleep 2; }
  return 0
}

# Type the code one key at a time with key events (adb "input text" duplicated a digit once: 903004),
# then READ the field back and retry until it holds exactly the code.
enter_code() {
  local code="$1" t d got
  for t in 1 2 3; do
    close_help_sheet
    tap_field 0 || return 1; sleep 1
    adb shell "input keyevent 123; for i in 1 2 3 4 5 6 7 8 9 10 11 12; do input keyevent 67; done" >/dev/null 2>&1
    sleep 1
    for ((d=0; d<${#code}; d++)); do adb shell input keyevent $((7 + ${code:d:1})) >/dev/null 2>&1; sleep 0.5; done
    sleep 1
    ui_dump && got="$(field_digits)" || got=""
    if [[ "$got" == "$code" ]]; then log "code typed and verified in the field"; screenshot "10-code-entered-$t.png"; return 0; fi
    log "typed code mismatch (field has ${#got} digits, expected ${#code}), clearing and retrying ($t/3)"
    screenshot "10-code-mismatch-$t.png"
  done
  return 1
}

# tap Next / OK / Continue, whichever is on screen; otherwise press Enter on the keyboard
submit_code() {
  local xy
  ui_dump || true
  xy="$(ui_query text '^(Next|OK|Continue|Confirm|Done)$' 0 || true)"
  if [[ -n "$xy" ]]; then log "submit: tapping button at $xy"; adb shell input tap $xy
  else log "submit: no button found, pressing Enter"; adb shell input keyevent 66; fi
}

# sets CODE_RESULT = ok | bad | timeout
wait_code_result() {
  local i; CODE_RESULT=timeout
  for ((i=0; i<15; i++)); do
    sleep 3
    ui_dump || continue
    if grep -qiE "Do you need help|incorrect|invalid|doesn.t match|isn.t right|wrong code" "$UI_XML"; then CODE_RESULT=bad; return; fi
    if ! grep -qiE "confirmation code|Resend" "$UI_XML"; then CODE_RESULT=ok; return; fi
  done
}

# "I didn't get the code" -> "Resend confirmation code"
resend_code() {
  ui_dump || true
  if ! grep -qi "Resend confirmation code" "$UI_XML"; then
    tap_text "^I didn.t get the code" "" 4 || log "WARNING: 'I didn't get the code' not found"
    sleep 3
  fi
  tap_text '^Resend confirmation code$' "" 5 || { log "WARNING: resend button not found"; return 1; }
  sleep 4; screenshot "10-resend-tapped.png"
  close_help_sheet
}

confirm_with_code() {
  local since="$1" attempt code
  for ((attempt=1; attempt<=CODE_ATTEMPTS; attempt++)); do
    if (( attempt > 1 )); then
      log "attempt $attempt/$CODE_ATTEMPTS: asking Facebook to resend the code"
      resend_code || true
      since="$(date +%s)"
      rand_wait 6 12 "after resend"
    fi
    code="$(fetch_code "$since" | grep -oE '[0-9]{5}' | tail -n 1)"
    [[ "$code" =~ ^[0-9]{5}$ ]] || { log "attempt $attempt: no code arrived within ${CODE_WAIT}s"; continue; }
    log "attempt $attempt: got a ${#code}-digit code"
    enter_code "$code" || { log "attempt $attempt: could not get the code into the field"; continue; }
    submit_code
    wait_code_result
    case "$CODE_RESULT" in
      ok)  log "confirmation code accepted"; screenshot "10b-code-accepted.png"; return 0 ;;
      bad) log "attempt $attempt: Facebook did not accept the code" ;;
      *)   log "attempt $attempt: timed out waiting for the result" ;;
    esac
    screenshot "10c-attempt-$attempt-failed.png"
  done
  return 1
}

# ---------------- The signup ----------------
signup_flow() {
  local missing=""
  for v in FB_FIRST_NAME FB_LAST_NAME FB_EMAIL FB_PASSWORD; do [[ -n "${!v}" ]] || missing+=" $v"; done
  [[ -z "$missing" ]] || { log "ERROR: missing:$missing"; return 1; }
  [[ "$FB_GENDER" =~ ^(male|female)$ ]] || { log "ERROR: FB_GENDER must be male or female"; return 1; }

  ip_guard || return 1
  dismiss_system_dialogs; sleep 5

  # 1) entry screens vary (login page / account switcher / "Get started" / Meta Account page that
  #    again shows "Create new account"). Look at the CURRENT screen each time and tap what is there
  #    until the name screen appears.
  screenshot "03-start.png"
  reach_name_screen || { screenshot "err-name.png"; save_ui "err-name"; log "ERROR: name screen not reached"; return 1; }
  screenshot "03b-name-screen.png"

  # 2) name
  tap_field 0 || return 1; sleep 1; type_text "$FB_FIRST_NAME"
  tap_field 1 || return 1; sleep 1; type_text "$FB_LAST_NAME"
  screenshot "04-name.png"; next_btn || return 1

  # 3) birthday
  wait_text "What.s your birthday" 10 || { screenshot "err-bday.png"; return 1; }
  set_birthday || return 1
  screenshot "04d-birthday.png"; next_btn || return 1

  # 4) gender
  wait_text "What.s your gender" 10 || { screenshot "err-gender.png"; return 1; }
  if [[ "$FB_GENDER" == "male" ]]; then tap_text '^Male$' "" 5; else tap_text '^Female$' "" 5; fi
  sleep 1; screenshot "05-gender.png"; next_btn || return 1

  # 5) mobile number screen -> "Sign up with email"
  wait_text "mobile number" 10 || { screenshot "err-mobile.png"; return 1; }
  tap_text '^Sign up with email$' "" 6 || { log "ERROR: 'Sign up with email' not found"; return 1; }
  sleep 3

  # 6) email
  wait_text "email" 10 || { screenshot "err-email.png"; return 1; }
  tap_field 0 || return 1; sleep 1; type_text "$FB_EMAIL"
  screenshot "06-email.png"; next_btn || return 1

  # 7) password (masked on screen; never printed in the log)
  wait_text "Create a password" 10 || { screenshot "err-pass.png"; return 1; }
  tap_field 0 || return 1; sleep 1; type_text "$FB_PASSWORD"
  screenshot "07-password.png"; next_btn || return 1

  # 8) terms -> I agree
  wait_text "terms and policies|I agree" 10 || { screenshot "err-terms.png"; return 1; }
  local since; since="$(date +%s)"
  ip_guard || return 1          # re-check the IP right before the account is actually created
  tap_text '^I agree$' "" 6 || return 1
  rand_wait 6 12 "after tapping I agree"
  screenshot "08-after-agree.png"

  # 9) wait until the confirmation-code screen is really on screen (or a block shows up)
  local i got=0
  for ((i=0; i<45; i++)); do
    dismiss_perm
    ui_dump && grep -qiE "confirmation code" "$UI_XML" && { got=1; break; }
    die_if_blocked "after-agree"
    sleep 4
  done
  [[ "$got" == "1" ]] || { screenshot "err-no-code-screen.png"; save_ui "no-code-screen"; log "ERROR: confirmation-code screen not reached"; return 1; }
  screenshot "09-code-screen.png"
  rand_wait 6 12 "on the confirmation-code screen"

  # 10) get the code, type it, verify the field, submit; resend + retry if it is not accepted
  confirm_with_code "$since" || { screenshot "err-code-failed.png"; save_ui "code-failed"; log "ERROR: confirmation code was not accepted after $CODE_ATTEMPTS attempts"; return 1; }
  die_if_blocked "after-code"

  tap_text '^(Save|OK)$' "" 1 || true
  post_login_prompts 12 || true
  screenshot "11-after-onboarding.png"; save_ui "final"

  if is_logged_in; then
    log "SIGNUP OK: account created and the feed is visible (IP mode: $ACTIVE_MODE)"
  else
    log "WARNING: code was accepted but the feed was not detected (onboarding/checkpoint?). See 11-after-onboarding.png"
  fi
  [[ "$MAKE_BACKUP" == "1" ]] && { backup_and_upload || log "WARNING: backup not created"; }
  return 0
}

# ===================== MAIN =====================
log "ip mode active: $ACTIVE_MODE"
adb devices -l

[[ -s "$APK_FILE" ]] || { log "ERROR: $APK_FILE missing (download-apk.sh step)"; exit 1; }
[[ "$(head -c 2 "$APK_FILE")" == "PK" ]] || { log "ERROR: not an APK or zip"; exit 1; }
APK_LIST=("$APK_FILE")
if ! unzip -l "$APK_FILE" 2>/dev/null | grep -q 'AndroidManifest.xml'; then
  SPLIT_DIR="${RUNNER_TEMP:-/tmp}/fb-splits"; rm -rf "$SPLIT_DIR"; mkdir -p "$SPLIT_DIR"
  unzip -q -o "$APK_FILE" -d "$SPLIT_DIR" || { log "ERROR: cannot unzip"; exit 1; }
  mapfile -t APK_LIST < <(find "$SPLIT_DIR" -name '*.apk' | sort)
  (( ${#APK_LIST[@]} > 0 )) || { log "ERROR: no .apk inside the zip"; exit 1; }
fi

wait_for_boot; settle_device; sleep 20
dismiss_system_dialogs; screenshot "00-home-screen.png"

# no -g: runtime permissions (contacts etc.) are NOT pre-granted, the app asks and we answer "Don't allow"
log "installing APK"
if (( ${#APK_LIST[@]} > 1 )); then
  adb install-multiple -r -t "${APK_LIST[@]}" || adb install-multiple -r -t -d "${APK_LIST[@]}" || { log "ERROR: install failed"; exit 1; }
else
  adb install -r -t "${APK_LIST[0]}" || adb install -r -t -d "${APK_LIST[0]}" || { log "ERROR: install failed"; exit 1; }
fi
adb shell pm list packages | grep -F "$PACKAGE_NAME" || { log "ERROR: package not installed"; exit 1; }
screenshot "01-after-install.png"

launch_app; sleep 12
dismiss_system_dialogs; screenshot "02-after-launch.png"
signup_flow || { log "signup flow ended with an error"; exit 1; }
log "Done!"
