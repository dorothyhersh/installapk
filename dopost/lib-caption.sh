#!/usr/bin/env bash
# lib-caption.sh - typing the caption and tapping "Share now" (sourced)

ime_input_shown() { adb shell dumpsys input_method 2>/dev/null | grep -q 'mInputShown=true'; }
rand_sleep() { sleep $(( $1 + RANDOM % ($2 - $1 + 1) )); }

read_caption() {
  [[ -s "$CAPTION_FILE" ]] || { log "ERROR: caption file missing or empty: $CAPTION_FILE"; return 1; }
  cat "$CAPTION_FILE"
}

# ADBKeyboard types unicode (emoji, hashtags). Falls back to writing secure settings directly.
setup_adb_keyboard() {
  local ime="${ADBKEYBOARD_PKG}/.AdbIME" found i cur enabled
  if ! adb shell pm list packages 2>/dev/null | grep -q "$ADBKEYBOARD_PKG"; then
    log "installing ADBKeyboard"
    curl -fsSL --retry 3 -o "$ADBKEYBOARD_APK" "$ADBKEYBOARD_APK_URL" || { log "ERROR: could not download ADBKeyboard"; return 1; }
    adb install -r -g "$ADBKEYBOARD_APK" || { log "ERROR: could not install ADBKeyboard"; return 1; }
    sleep 4
  fi
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
  log "ime set failed 5x, writing secure settings directly"
  enabled="$(adb shell settings get secure enabled_input_methods 2>/dev/null | tr -d '\r')"
  [[ "$enabled" == "null" ]] && enabled=""
  [[ "$enabled" == *"$ime"* ]] || adb shell settings put secure enabled_input_methods "${enabled:+$enabled:}$ime" >/dev/null 2>&1
  adb shell settings put secure default_input_method "$ime" >/dev/null 2>&1
  sleep 3
  cur="$(adb shell settings get secure default_input_method 2>/dev/null | tr -d '\r')"
  [[ "$cur" == *"$ADBKEYBOARD_PKG"* ]] && { log "ADBKeyboard set via secure settings"; return 0; }
  log "WARNING: ADBKeyboard not usable (current IME: '$cur')"
  return 1
}

adb_type_unicode() {
  local b64
  adb shell am broadcast -a ADB_CLEAR_TEXT >/dev/null 2>&1; sleep 1
  b64="$(printf '%s' "$1" | base64 -w0)"
  adb shell am broadcast -a ADB_INPUT_B64 --es msg "$b64" >/dev/null 2>&1; sleep 2
}

# ASCII-only fallback with the stock `input text` (emoji dropped)
type_ascii_fallback() {
  python3 - "$1" <<'PY'
import subprocess, sys, shlex, time
lines = sys.argv[1].replace('\r', '').split('\n')
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

# 0 when the caption box holds real text (not the placeholder)
caption_present() {
  ui_dump_fast || return 1
  python3 - "$UI_XML" <<'PY'
import sys, xml.etree.ElementTree as ET
for n in ET.parse(sys.argv[1]).getroot().iter('node'):
    if n.attrib.get('class', '').endswith('EditText'):
        t = n.attrib.get('text', '').strip()
        if t and not t.startswith('Describe your reel'):
            print(t[:60]); sys.exit(0)
sys.exit(1)
PY
}

# prints "x y enabled" for the Share now button
share_state() {
  python3 - "$UI_XML" <<'PY'
import re, sys, xml.etree.ElementTree as ET
best = None
for n in ET.parse(sys.argv[1]).getroot().iter('node'):
    a = n.attrib
    if a.get('text', '').strip().lower() == 'share now' or a.get('content-desc', '').strip().lower() == 'share now':
        m = re.findall(r'\d+', a.get('bounds', ''))
        if len(m) != 4:
            continue
        x1, y1, x2, y2 = map(int, m)
        is_btn = a.get('class', '').endswith('Button')
        if best is None or is_btn:
            best = ((x1 + x2) // 2, (y1 + y2) // 2, a.get('enabled', 'false'))
if best:
    print(*best)
PY
}

# Taps the caption box in different ways, types the caption, verifies it is in the field.
enter_caption() {
  local idx="$1" caption="$2" attempt xy x y ime_ok=0 seen
  if setup_adb_keyboard; then ime_ok=1; else log "WARNING: using plain 'input text' (emoji dropped)"; fi
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
    log "caption attempt $attempt/6 at $x $y"
    if (( attempt == 4 || attempt == 6 )); then
      adb shell input swipe "$x" "$y" "$x" "$y" 700; sleep 1; adb shell input tap "$x" "$y"
    else
      adb shell input tap "$x" "$y"
    fi
    rand_sleep 2 4
    log "keyboard shown: $(ime_input_shown && echo yes || echo no)"
    if (( ime_ok && attempt <= 3 )); then adb_type_unicode "$caption"; else type_ascii_fallback "$caption"; fi
    sleep 2
    screenshot "r${idx}-04-caption-attempt-${attempt}.png"
    if seen="$(caption_present)"; then log "caption is in the field: '$seen...'"; return 0; fi
    log "caption NOT detected after attempt $attempt"
  done
  return 1
}

# Hides the keyboard without leaving Reel Settings
hide_keyboard_safely() {
  if ime_input_shown; then adb shell input keyevent 4 >/dev/null 2>&1; sleep 2; fi
  ui_dump_fast || return 0
  if ! grep -qiE 'Reel Settings|Describe your reel|Share now' "$UI_XML"; then
    log "WARNING: left Reel Settings while hiding the keyboard"; return 1
  fi
  return 0
}

# Waits until "Share now" is enabled (nudging the screen), then taps it.
wait_and_tap_share() {
  local deadline=$(( SECONDS + 150 )) polls=0 st x=624 y=2184 en
  while (( SECONDS < deadline )); do
    polls=$((polls+1)); st=""
    if ui_dump_fast; then st="$(share_state)"; fi
    if [[ -z "$st" ]]; then
      log "Share now not visible, scrolling (poll $polls)"
      adb shell input swipe 540 1500 540 800 400; sleep 2
      ui_dump_fast && st="$(share_state)"
    fi
    if [[ -n "$st" ]]; then
      read -r x y en <<<"$st"
      if [[ "$en" == "true" ]]; then
        rand_sleep 2 5
        if ui_dump_fast; then st="$(share_state)"; [[ -n "$st" ]] && read -r x y en <<<"$st"; fi
        if [[ "$en" == "true" ]]; then
          x=$(( x + RANDOM % 41 - 20 )); y=$(( y + RANDOM % 21 - 10 ))
          log "Share now ACTIVE, tapping at $x $y"
          adb shell input tap "$x" "$y"
          return 0
        fi
      fi
      log "Share now still greyed out (poll $polls), nudging"
    fi
    adb shell input swipe 540 1500 540 800 350; sleep 1
    adb shell input swipe 540 800 540 1500 350
    rand_sleep 3 7
  done
  log "WARNING: Share now never became active in 150 s, tapping anyway at $x $y"
  adb shell input tap "$x" "$y"
  return 0
}
