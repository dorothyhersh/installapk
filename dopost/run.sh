#!/usr/bin/env bash
# run.sh - ENTRY POINT. Runs inside the emulator step of the workflow.
#   1. wait for the snapshot-booted emulator (Facebook is already installed in it)
#   2. restore the logged-in Facebook session from Mega
#   3. post REEL_COUNT reels with "Share now"
#
# Folder layout (dopost/):
#   config.sh        all settings / env defaults
#   lib-ui.sh        adb + UI helpers
#   lib-mega.sh      rclone + Mega backup download
#   restore.sh       restore the login backup
#   lib-video.sh     reel download / re-encode / push to emulator
#   lib-caption.sh   caption typing + Share now
#   post-reels.sh    the reel posting loop
#   caption.txt      the caption used for every reel
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/config.sh"
exec > >(tee -a "$ARTIFACTS/run.log") 2>&1
for f in lib-ui lib-mega restore lib-video lib-caption post-reels; do source "$DIR/$f.sh"; done

finish() {
  local code=$?
  log "exiting with code $code"
  screenshot "99-final-state.png"
  adb logcat -d > "$ARTIFACTS/logcat.txt" 2>/dev/null
  exit "$code"
}
trap finish EXIT

adb devices -l
wait_for_boot || exit 1
settle_device
sleep 10
dismiss_system_dialogs
screenshot "00-home-screen.png"

adb shell pm list packages | grep -F "$PACKAGE_NAME" || { log "ERROR: $PACKAGE_NAME is not installed in this emulator snapshot"; exit 1; }

restore_flow || { log "ERROR: restore failed, not posting"; exit 1; }
post_reels_flow || { log "ERROR: no reel was posted"; exit 1; }
log "Done!"
