#!/usr/bin/env bash
# caption-helpers.sh
# Sourced by scripts/facebook-install-and-login.sh right BEFORE the "MAIN" section.
# Bash lets a later definition replace an earlier one, so this file overrides:
#   setup_adb_keyboard, adb_type_unicode, compose_one_reel
# and adds: enter_caption, wait_and_tap_share, and small helpers.
#
# What it fixes (from run.log):
#   1. "ADBKeyboard could not be set as the default IME" aborted the whole reel.
#      Now: retries ime enable/set, discovers the real IME id, falls back to writing the secure
#      settings directly (adb is root), and if the IME still fails it types with plain
#      `input text` (emoji stripped) instead of giving up.
#   2. The caption field is tapped in several different ways and the text is VERIFIED in the
#      field (EditText text != placeholder) before moving on.
#   3. "Share now" is greyed out until the screen is ready. We now poll its enabled flag,
#      nudge the screen (scroll up/down), wait random seconds, then tap it. The old
#      blind `Back` press (which could leave the Reel Settings screen) only happens if the
#      keyboard is really showing.

ime_input_shown() { adb shell dumpsys input_method 2>/dev/null | grep -q 'mInputShown=true'; }

rand_sleep() { sleep $(( $1 + RANDOM % ($2 - $1 + 1) )); }

setup_adb_keyboard() {
  local ime="${ADBKEYBOARD_PKG}/.AdbIME" found i cur enabled
  if ! adb shell pm list packages 2>/dev/null | grep -q "$ADBKEYBOARD_PKG"; then
    log "installing ADBKeyboard (for typing unicode/emoji captions)"
    curl -fsSL --retry 3 -o "$ADBKEYBOARD_APK" "$ADBKEYBOARD_APK_URL" || { log "ERROR: could not download ADBKeyboard"; return 1; }
    adb install -r -g "$ADBKEYBOARD_APK" || { log "ERROR: could not install ADBKeyboard"; return 1; }
    sleep 4   # let the package manager register the IME service
  fi
  # use the real IME id if the system lists one
  found="$(adb shell ime list -a -s 2>/dev/null | tr -d '\r' | grep -i "$ADBKEYBOARD_PKG" | head -1)"
  [[ -n "$found" ]] && ime="$found"
  adb shell settings put secure show_ime_with_hard_keyboard 1 >/dev/null 2>&1

  for i in 1 2 3 4 5; do
    adb shell ime enable "$ime" >/dev/null 2>&1
    adb shell ime set "$ime" >/dev/null 2>&1
    sleep 2
    cur="$(adb shell settings get secure default_input_method 2>/dev/null | tr -d '\r')"
    [[ "$cur" == *"$ADBKEYBOARD_PKG"* ]] && { log "ADBKeyboard is the default IME (try $i)"; return 0; }
  done

  log "ime set failed 5x, writing the secure settings directly"
  enabled="$(adb shell settings get secure enabled_input_methods 2>/dev/null | tr -d '\r')"
  [[ "$enabled" == "null" ]] && enabled=""
  [[ "$enabled" == *"$ime"* ]] || adb shell settings put secure enabled_input_methods "${enabled:+$enabled:}$ime" >/dev/null 2>&1
  adb shell settings put secure default_input_method "$ime" >/dev/null 2>&1
  sleep 3
  cur="$(adb shell settings get secure default_input_method 2>/dev/null | tr -d '\r')"
  [[ "$cur" == *"$ADBKEYBOARD_PKG"* ]] && { log "ADBKeyboard set via secure settings"; return 0; }

  log "WARNING: ADBKeyboard not usable (current IME: '$cur'; IMEs: $(adb shell ime list -a -s 2>/dev/null | tr -d '\r' | tr '\n' ' '))"
  return 1
}

# Clears the focused field, then types $1 (any UTF-8) via ADBKeyboard broadcasts.
adb_type_unicode() {
  local text="$1" b64
  adb shell am broadcast -a ADB_CLEAR_TEXT >/dev/null 2>&1
  sleep 1
  b64="$(printf '%s' "$text" | base64 -w0)"
  adb shell am broadcast -a ADB_INPUT_B64 --es msg "$b64" >/dev/null 2>&1
  sleep 2
}

# Fallback typing with the stock `input text`: ASCII only (emoji/unicode dropped), small chunks,
# newlines sent as ENTER.
type_ascii_fallback() {
  python3 - "$1" <<'PY'
import subprocess, sys, shlex, time
text = sys.argv[1].replace('\r', '')
lines = text.split('\n')
dev = dict(stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
for li, line in enumerate(lines):
    line = ''.join(c for c in line if 32 <= ord(c) < 127).replace('%', '')
    for i in range(0, len(line), 12):
        chunk = line[i:i + 12].replace(' ', '%s')
        subprocess.run(['adb', 'shell', 'input text ' + shlex.quote(chunk)], **dev)
        time.sleep(0.4)
    if li < len(lines) - 1:
        subprocess.run(['adb', 'shell', 'input keyevent 66'], **dev)
        time.sleep(0.4)
PY
}

# 0 when the caption EditText holds real text (not the "Describe your reel" placeholder)
caption_present() {
  ui_dump_fast || return 1
  python3 - "$UI_XML" <<'PY'
import sys, xml.etree.ElementTree as ET
for n in ET.parse(sys.argv[1]).getroot().iter('node'):
    if n.attrib.get('class', '').endswith('EditText'):
        t = n.attrib.get('text', '').strip()
        if t and not t.startswith('Describe your reel'):
            print(t[:60])
            sys.exit(0)
sys.exit(1)
PY
}

# prints "x y enabled" for the Share now button ("true"/"false"), nothing if it is not on screen
share_state() {
  python3 - "$UI_XML" <<'PY'
import re, sys, xml.etree.ElementTree as ET
best = None
for n in ET.parse(sys.argv[1]).getroot().iter('node'):
    a = n.attrib
    if (a.get('text', '').strip().lower() == 'share now') or (a.get('content-desc', '').strip().lower() == 'share now'):
        m = re.findall(r'\d+', a.get('bounds', ''))
        if len(m) != 4:
            continue
        x1, y1, x2, y2 = map(int, m)
        is_btn = a.get('class', '').endswith('Button')
        if best is None or is_btn:
            best = ((x1 + x2) // 2, (y1 + y2) // 2, a.get('enabled', 'false'), is_btn)
if best:
    print(best[0], best[1], best[2])
PY
}

# Taps the caption box in several different ways, types the caption, and verifies it.
# Returns 0 when the caption is really in the field.
enter_caption() {
  local idx="$1" caption="$2" attempt xy x y ime_ok=0 seen
  if setup_adb_keyboard; then ime_ok=1; else log "WARNING: using plain 'input text' (emoji will be dropped)"; fi

  for attempt in 1 2 3 4 5 6; do
    ui_dump_fast || true
    xy=""
    case "$attempt" in
      1|4) xy="$(ui_query class 'EditText' 0 || true)" ;;
      2|6) xy="684 405" ;;
      3)   xy="684 300" ;;
      5)   xy="500 450" ;;
    esac
    [[ -n "$xy" ]] || xy="684 405"
    x="${xy% *}"; y="${xy#* }"
    log "caption attempt $attempt/6: $( (( attempt == 4 || attempt == 6 )) && echo 'long-press' || echo 'tap' ) caption box at $x $y"
    if (( attempt == 4 || attempt == 6 )); then
      adb shell input swipe "$x" "$y" "$x" "$y" 700      # long press
      sleep 1; adb shell input tap "$x" "$y"
    else
      adb shell input tap "$x" "$y"
    fi
    rand_sleep 2 4
    log "keyboard shown: $(ime_input_shown && echo yes || echo no)"

    if (( ime_ok && attempt <= 3 )); then
      adb_type_unicode "$caption"
    else
      type_ascii_fallback "$caption"
    fi
    sleep 2
    screenshot "r${idx}-04-caption-attempt-${attempt}.png"

    if seen="$(caption_present)"; then
      log "caption is in the field (attempt $attempt): '$seen...'"
      return 0
    fi
    log "caption NOT detected after attempt $attempt"
  done
  return 1
}

# Leaves the keyboard without ever navigating away from Reel Settings.
hide_keyboard_safely() {
  if ime_input_shown; then
    adb shell input keyevent 4 >/dev/null 2>&1; sleep 2
  fi
  ui_dump_fast || return 0
  if ! grep -qiE 'Reel Settings|Describe your reel|Share now' "$UI_XML"; then
    log "WARNING: left Reel Settings while hiding the keyboard"
    return 1
  fi
  return 0
}

# Waits until "Share now" is ENABLED (greyed out until the reel is ready), nudging the screen
# with scrolls and random waits, then taps it. Returns 0 once tapped.
wait_and_tap_share() {
  local deadline=$(( SECONDS + 150 )) polls=0 st x=624 y=2184 en
  while (( SECONDS < deadline )); do
    polls=$((polls+1))
    st=""
    if ui_dump_fast; then st="$(share_state)"; fi
    if [[ -z "$st" ]]; then
      log "Share now not visible, scrolling to reveal it (poll $polls)"
      adb shell input swipe 540 1500 540 800 400; sleep 2
      ui_dump_fast && st="$(share_state)"
    fi
    if [[ -n "$st" ]]; then
      read -r x y en <<<"$st"
      if [[ "$en" == "true" ]]; then
        rand_sleep 2 5
        # re-check right before tapping
        if ui_dump_fast; then st="$(share_state)"; [[ -n "$st" ]] && read -r x y en <<<"$st"; fi
        if [[ "$en" == "true" ]]; then
          x=$(( x + RANDOM % 41 - 20 )); y=$(( y + RANDOM % 21 - 10 ))
          log "Share now is ACTIVE, tapping at $x $y"
          adb shell input tap "$x" "$y"
          return 0
        fi
      fi
      log "Share now still greyed out (poll $polls), nudging screen and waiting"
    fi
    # nudge: scroll down, then up, so the screen re-evaluates the button
    adb shell input swipe 540 1500 540 800 350; sleep 1
    adb shell input swipe 540 800 540 1500 350
    rand_sleep 3 7
  done
  log "WARNING: Share now never became active in 150 s, tapping it anyway at $x $y"
  adb shell input tap "$x" "$y"
  return 0
}

# Full composer flow for one reel: + -> Reel -> pick video -> Next* -> caption -> Share.
# Return codes: 0 shared OK | 1 this video failed (retry later) | 2 structural failure | 3 playback error
compose_one_reel() {
  local idx="$1" caption="$2" xy ok=0 i rc st en x y

  tap_text '^(Create|Add)$' "780 119" 4 || { log "ERROR: create (+) button not found"; return 2; }
  sleep 4
  screenshot "r${idx}-00-create-menu.png"; save_ui "r${idx}-create-menu"
  log "texts in create menu:"; ui_texts | head -30 | sed 's/^/[fb]   /'

  xy="$(ui_find text '^Reel$' 0 || true)"
  [[ -z "$xy" ]] && xy="$(ui_find text 'Reel' 0 || true)"
  [[ -n "$xy" ]] || { log "ERROR: 'Reel' option not found in the create menu"; return 2; }
  log "tap Reel option at $xy"; adb shell input tap $xy; sleep 6

  screenshot "r${idx}-01-create-reel-gallery.png"; save_ui "r${idx}-create-reel-gallery"
  log "texts in Create reel / gallery:"; ui_texts | head -30 | sed 's/^/[fb]   /'

  xy="$(pick_single_video_thumb || true)"
  for i in 1 2 3; do
    [[ -n "$xy" ]] && break
    log "no video in the gallery yet (try $i/3), waiting"
    sleep 6; ui_dump || true
    xy="$(pick_single_video_thumb || true)"
  done
  [[ -n "$xy" ]] || { log "ERROR: video thumbnail not found in the gallery grid"; return 1; }
  log "tap video thumbnail at $xy"; adb shell input tap $xy; sleep 2

  sleep 3
  screenshot "r${idx}-02-edit-reel.png"
  if ui_dump_fast; then cp "$UI_XML" "$ARTIFACTS/ui-r${idx}-edit-reel.xml" 2>/dev/null || true; fi
  advance_past_edit_screen "$idx"; rc=$?
  (( rc == 0 )) || return "$rc"

  for i in $(seq 1 15); do
    ui_dump_fast || { sleep 2; continue; }
    grep -qi 'Describe your reel' "$UI_XML" && break
    if dismiss_play_error; then continue; fi
    xy="$(ui_query text '^Next$' 0 || true)"
    if [[ -n "$xy" ]]; then log "tap Next (extra screen $i) at $xy"; adb shell input tap $xy; sleep 4; continue; fi
    sleep 3
  done

  screenshot "r${idx}-03-reel-settings.png"; save_ui "r${idx}-reel-settings"
  grep -qi 'Describe your reel' "$UI_XML" || { log "ERROR: Reel Settings screen not reached"; return 1; }

  # ---- caption: several tap/type strategies, verified ----
  enter_caption "$idx" "$caption" || { log "ERROR: could not get the caption into the field"; screenshot "r${idx}-04-caption-failed.png"; return 1; }
  screenshot "r${idx}-04-caption-typed.png"
  hide_keyboard_safely || { screenshot "r${idx}-04b-left-settings.png"; return 1; }
  screenshot "r${idx}-04c-after-hide-keyboard.png"

  # ---- Share now: wait until active, then tap ----
  wait_and_tap_share
  screenshot "r${idx}-05-share-tapped.png"

  # Upload+share can take a while; poll until the composer closes. If the screen is still on
  # Reel Settings with an ACTIVE Share now after ~20 s, the first tap did not register: tap once more.
  local retapped=0
  for i in $(seq 1 24); do
    sleep 5
    ui_dump_fast || continue
    if ! grep -qiE 'describe your reel|share now' "$UI_XML" && grep -qiE 'Home|Menu|Notifications' "$UI_XML"; then
      ok=1; break
    fi
    if (( i == 4 && ! retapped )) && grep -qi 'Describe your reel' "$UI_XML"; then
      st="$(share_state)"
      if [[ -n "$st" ]]; then
        read -r x y en <<<"$st"
        if [[ "$en" == "true" ]]; then log "still on Reel Settings, tapping Share now again at $x $y"; adb shell input tap "$x" "$y"; retapped=1; fi
      fi
    fi
  done
  screenshot "r${idx}-05-after-share.png"; save_ui "r${idx}-after-share"
  if [[ "$ok" == "1" ]]; then log "reel #${idx} SHARED"; return 0; fi
  log "ERROR: could not confirm reel #${idx} finished sharing (see r${idx}-05-after-share.png)"
  return 1
}
