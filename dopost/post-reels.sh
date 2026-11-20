#!/usr/bin/env bash
# post-reels.sh - posts reels to the (already logged-in) Page, one video at a time (sourced)
#
# Per video: download from Mega -> re-encode -> push to emulator -> + -> Reel -> pick -> Next ->
#            caption -> Share now -> move video from MEGA_REELS_SRC to MEGA_REELS_DONE.
# A video is moved ONLY after the share is confirmed, so nothing is ever posted twice or lost.

blind_tap_next() {
  local sz w h x y
  sz="$(adb shell wm size 2>/dev/null | tr -d '\r' | grep -oE '[0-9]+x[0-9]+' | tail -1)"
  w="${sz%x*}"; h="${sz#*x}"
  [[ "$w" =~ ^[0-9]+$ && "$h" =~ ^[0-9]+$ ]] || { w=1080; h=2400; }
  x=$(( w * 922 / 1000 )); y=$(( h * 880 / 1000 ))
  log "blind tap on Next at $x $y (screen ${w}x${h})"
  adb shell input tap $x $y
}

dismiss_play_error() {
  local xy
  grep -qiE "Couldn.t play video" "$UI_XML" || return 1
  xy="$(ui_query text '^OK$' 0 || true)"
  [[ -n "$xy" ]] || xy="883 1255"
  log "dismissing 'Couldn't play video' (OK at $xy)"
  adb shell input tap $xy; sleep 2
  return 0
}

# Edit reel screen: dismiss playback-error dialogs and tap Next (never plays the video).
# 0 = Next tapped | 1 = Next never appeared | 3 = same, and the play error was seen
advance_past_edit_screen() {
  local idx="$1" xy seen_err=0 dump_fails=0 blind=0 logged=0 deadline=$(( SECONDS + 150 ))
  while (( SECONDS < deadline )); do
    if ! ui_dump_fast; then
      dump_fails=$((dump_fails+1))
      if (( dump_fails >= 2 && blind < 3 )); then
        screenshot "r${idx}-02d-before-blind-next-${blind}.png"
        blind_tap_next; blind=$((blind+1)); sleep 4
        screenshot "r${idx}-02e-after-blind-next-${blind}.png"
        log "focus after blind tap: $(focus_line)"
        dump_fails=0
      fi
      sleep 1; continue
    fi
    dump_fails=0
    if (( ! logged )); then log "texts on the edit screen:"; ui_texts | head -15 | sed 's/^/[fb]   /'; logged=1; fi
    if dismiss_play_error; then seen_err=1; continue; fi
    if grep -qi 'Describe your reel' "$UI_XML"; then log "already on Reel Settings"; return 0; fi
    xy="$(ui_query text '^Next$' 0 || true)"
    if [[ -n "$xy" ]]; then
      log "tap Next at $xy"; adb shell input tap $xy; sleep 4
      return 0
    fi
    if (( blind > 0 )); then log "blind tap on Next was accepted"; return 0; fi
    sleep 2
  done
  screenshot "r${idx}-02c-no-next.png"
  log "ERROR: could not tap Next on the Edit reel screen"
  (( seen_err )) && return 3
  return 1
}

# Return codes: 0 shared | 1 this video failed (retry later) | 2 structural failure (stop all)
#               3 playback error (counts toward MAX_PLAYBACK_FAILS)
compose_one_reel() {
  local idx="$1" caption="$2" xy ok=0 i rc st en x y retapped=0

  tap_text '^(Create|Add)$' "780 119" 4 || { log "ERROR: create (+) button not found"; return 2; }
  sleep 4
  screenshot "r${idx}-00-create-menu.png"; save_ui "r${idx}-create-menu"
  log "texts in create menu:"; ui_texts | head -30 | sed 's/^/[fb]   /'

  xy="$(ui_find text '^Reel$' 0 || true)"
  [[ -z "$xy" ]] && xy="$(ui_find text 'Reel' 0 || true)"
  [[ -n "$xy" ]] || { log "ERROR: 'Reel' option not found in the create menu"; return 2; }
  log "tap Reel option at $xy"; adb shell input tap $xy; sleep 6

  screenshot "r${idx}-01-create-reel-gallery.png"; save_ui "r${idx}-create-reel-gallery"
  xy="$(pick_single_video_thumb || true)"
  for i in 1 2 3; do
    [[ -n "$xy" ]] && break
    log "no video in the gallery yet (try $i/3), waiting"
    sleep 6; ui_dump || true
    xy="$(pick_single_video_thumb || true)"
  done
  [[ -n "$xy" ]] || { log "ERROR: video thumbnail not found in the gallery"; return 1; }
  log "tap video thumbnail at $xy"; adb shell input tap $xy; sleep 5

  screenshot "r${idx}-02-edit-reel.png"
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

  enter_caption "$idx" "$caption" || { log "ERROR: could not get the caption into the field"; screenshot "r${idx}-04-caption-failed.png"; return 1; }
  screenshot "r${idx}-04-caption-typed.png"
  hide_keyboard_safely || { screenshot "r${idx}-04b-left-settings.png"; return 1; }

  wait_and_tap_share
  screenshot "r${idx}-05-share-tapped.png"

  # Poll until the composer closes. If still on Reel Settings with an active button after ~20 s, tap again.
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
        if [[ "$en" == "true" ]]; then log "tapping Share now again at $x $y"; adb shell input tap "$x" "$y"; retapped=1; fi
      fi
    fi
  done
  screenshot "r${idx}-05-after-share.png"; save_ui "r${idx}-after-share"
  if [[ "$ok" == "1" ]]; then log "reel #${idx} SHARED"; return 0; fi
  log "ERROR: could not confirm reel #${idx} finished sharing (see r${idx}-05-after-share.png)"
  return 1
}

post_reels_flow() {
  local count="$REEL_COUNT"
  [[ "$count" =~ ^[0-9]+$ ]] || count=0
  (( count > 0 )) || { log "REEL_COUNT is 0, skipping reel posting"; return 0; }

  setup_rclone || { log "ERROR: rclone/Mega not ready, cannot fetch reels"; return 1; }
  local caption; caption="$(read_caption)" || return 1
  log "caption loaded ($(printf '%s' "$caption" | wc -c) bytes)"

  mapfile -t pending < <(list_pending_reels)
  (( ${#pending[@]} > 0 )) || { log "no videos found in ${MEGA_REELS_SRC}"; return 0; }
  log "found ${#pending[@]} video(s) in ${MEGA_REELS_SRC}, will post up to $count"

  local posted=0 idx=0 playback_fails=0 name local_path enc remote_path rc
  for name in "${pending[@]}"; do
    (( posted >= count )) && break
    idx=$((idx+1))
    log "=== reel $((posted+1))/$count (file #$idx): $name ==="

    local_path="$(download_reel "$name" || true)"
    [[ -n "$local_path" ]] || { log "ERROR: could not download $name, skipping"; continue; }

    if [[ "$REENCODE_REELS" == "1" ]]; then
      if enc="$(reencode_reel "$local_path")" && [[ -n "$enc" ]]; then
        rm -f "$local_path"; local_path="$enc"
        log "re-encoded: $(basename "$enc") ($(stat -c%s "$enc") bytes)"
      else
        log "WARNING: re-encode failed, using the original file"
      fi
    fi

    remote_path="$(push_reel_to_device "$local_path" || true)"
    rm -f "$local_path"
    [[ -n "$remote_path" ]] || { log "ERROR: could not push $name to the device, skipping"; continue; }

    compose_one_reel "$idx" "$caption"; rc=$?
    remove_reel_from_device "$remote_path"
    if [[ "$rc" != "0" ]]; then recover_to_feed; else return_to_feed; fi

    case "$rc" in
      0)
        playback_fails=0
        if rclone moveto "${MEGA_REMOTE}:${MEGA_REELS_SRC}/${name}" "${MEGA_REMOTE}:${MEGA_REELS_DONE}/${name}" --retries 5 -q; then
          log "moved $name to ${MEGA_REELS_DONE}"
        else
          log "WARNING: posted but could not move $name in Mega - move it manually or it may be reposted"
        fi
        posted=$((posted+1)) ;;
      2)
        log "structural failure, stopping (see r${idx}-* artifacts)"; break ;;
      3)
        playback_fails=$((playback_fails+1))
        log "playback error ($playback_fails/$MAX_PLAYBACK_FAILS), $name left in ${MEGA_REELS_SRC}"
        if (( playback_fails >= MAX_PLAYBACK_FAILS )); then log "stopping: repeated playback errors (emulator codec/GPU)"; break; fi ;;
      *)
        playback_fails=0
        log "reel $name failed, left in ${MEGA_REELS_SRC} for retry" ;;
    esac
  done
  log "reel posting done: $posted/${count} posted"
  (( posted > 0 ))   # non-zero exit if nothing was posted, so the workflow shows red
}
