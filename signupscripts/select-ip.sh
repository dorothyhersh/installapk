#!/usr/bin/env bash
# Choose how the emulator reaches the internet.
#   IP_MODE=telenor : Tailscale exit node on your Telenor phone (fails if it cannot be used)
#   IP_MODE=runner  : the GitHub runner's own IP (no exit node)
#   IP_MODE=auto    : try Telenor first; if the phone is offline/unreachable, fall back to the runner IP
# Writes the mode that is really active to $RUNNER_TEMP/ip_mode_active (telenor|runner).
set -uo pipefail
ts() { date -u '+%H:%M:%S'; }
say() { echo "[$(ts)] [select-ip] $*"; }

IP_MODE="${IP_MODE:-auto}"
ACTIVE_FILE="${RUNNER_TEMP:-/tmp}/ip_mode_active"
HERE="$(cd "$(dirname "$0")" && pwd)"

use_telenor() {
  command -v tailscale >/dev/null 2>&1 || { say "tailscale is not installed/connected"; return 1; }
  [ -n "${PHONE_IP:-}" ] || { say "PHONE_IP not set"; return 1; }
  timeout 300 bash "$HERE/use-phone-exit-node.sh" || return 1
  echo telenor > "$ACTIVE_FILE"
}

use_runner() {
  if command -v tailscale >/dev/null 2>&1; then
    sudo tailscale set --exit-node= >/dev/null 2>&1 || true
    sleep 3
  fi
  echo runner > "$ACTIVE_FILE"
  say "using the GitHub runner IP: $(curl -s --max-time 30 https://ifconfig.me || echo unknown)"
}

say "requested IP_MODE=$IP_MODE"
case "$IP_MODE" in
  telenor) use_telenor || { say "ERROR: Telenor exit node unavailable (IP_MODE=telenor, not falling back)"; exit 1; } ;;
  runner)  use_runner ;;
  auto)
    if use_telenor; then :; else
      say "Telenor exit node unavailable -> falling back to the runner IP"
      use_runner
    fi ;;
  *) say "ERROR: unknown IP_MODE '$IP_MODE' (telenor|runner|auto)"; exit 1 ;;
esac
say "ACTIVE MODE: $(cat "$ACTIVE_FILE")  | public IP: $(curl -s --max-time 30 https://ifconfig.me || echo unknown)"
