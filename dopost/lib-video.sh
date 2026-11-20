#!/usr/bin/env bash
# lib-video.sh - download a reel from Mega, re-encode it, push it to the emulator gallery (sourced)

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

# H.264 Main / yuv420p / 30 fps / max 720 px wide / AAC: the emulator can always decode this.
reencode_reel() {
  local in="$1" dir base out
  dir="$(dirname "$in")/enc"; base="$(basename "$in")"; base="${base%.*}.mp4"
  mkdir -p "$dir"; out="${dir}/${base}"
  command -v ffmpeg >/dev/null 2>&1 || { log "WARNING: ffmpeg not installed, skipping re-encode"; return 1; }
  ffmpeg -y -loglevel error -i "$in" \
    -vf "scale='min(720,iw)':-2,fps=30,format=yuv420p" \
    -c:v libx264 -profile:v main -level 3.1 -preset veryfast -crf 23 \
    -c:a aac -b:a 128k -ar 44100 -ac 2 \
    -movflags +faststart "$out" </dev/null || return 1
  [[ -s "$out" ]] || return 1
  echo "$out"
}

# On-device name: letters, digits, . _ - only (brackets in names broke the media scan before)
safe_device_name() {
  local n ext stem; n="$(basename "$1")"
  ext="${n##*.}"; stem="${n%.*}"
  [[ "$n" == *.* ]] || { ext="mp4"; stem="$n"; }
  ext="${ext//[^A-Za-z0-9]/}"; [[ -n "$ext" ]] || ext="mp4"
  stem="${stem//[^A-Za-z0-9._-]/_}"
  stem="${stem:0:50}"
  printf 'reel_%s.%s' "$stem" "$ext"
}

media_scan() {
  adb shell "am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d 'file://$1'" >/dev/null 2>&1
}

media_indexed() {
  adb shell "content query --uri content://media/external/video/media --projection _display_name" 2>/dev/null \
    | tr -d '\r' | grep -qF "$1"
}

push_reel_to_device() {
  local local_path="$1" safe remote_path i
  safe="$(safe_device_name "$local_path")"
  remote_path="/sdcard/Movies/${safe}"
  adb shell "mkdir -p /sdcard/Movies" >/dev/null 2>&1
  adb push "$local_path" "$remote_path" >/dev/null 2>&1 || return 1
  for i in 1 2 3 4 5; do
    media_scan "$remote_path"; sleep 3
    if media_indexed "$safe"; then log "video indexed by the gallery: $safe" >&2; echo "$remote_path"; return 0; fi
  done
  log "WARNING: gallery indexing not confirmed for $safe, continuing" >&2
  echo "$remote_path"
}

remove_reel_from_device() {
  [[ -n "${1:-}" ]] || return 0
  adb shell "rm -f '$1'" >/dev/null 2>&1
  media_scan "$1"
}

# Finds the single video thumbnail in the picker (duration badge, else first big clickable cell)
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
    print(hits[0][0], hits[0][1]); sys.exit(0)
best = None
for n in root.iter('node'):
    a = n.attrib
    if a.get('clickable') != 'true':
        continue
    m = re.findall(r'\d+', a.get('bounds', ''))
    if len(m) != 4:
        continue
    x1, y1, x2, y2 = map(int, m)
    if x2 - x1 < 150 or y2 - y1 < 150 or y1 < 350:
        continue
    if best is None or (y1, x1) < (best[0], best[1]):
        best = (y1, x1, (x1 + x2) // 2, (y1 + y2) // 2)
if best:
    print(best[2], best[3])
PY
}
