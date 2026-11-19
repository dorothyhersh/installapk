#!/usr/bin/env bash
# Route this runner's traffic through the phone (Tailscale exit node) and verify it.
# Expects: PHONE_IP, BASELINE_IP in the environment. Tailscale must already be connected.
set -euo pipefail

echo "---- exit nodes ----"
tailscale exit-node list || true

sudo tailscale set --exit-node="$PHONE_IP" --exit-node-allow-lan-access=true
sleep 8
tailscale status
tailscale ping -c 4 "$PHONE_IP" || true

NEW_IP=$(curl -s --max-time 30 https://ifconfig.me || true)
echo "Baseline IP: ${BASELINE_IP:-unknown}"
echo "Phone IP:    ${NEW_IP:-none}"
curl -s --max-time 20 "https://ipinfo.io/${NEW_IP}/org" || true
echo

if [ -z "${NEW_IP}" ] || [ "${NEW_IP}" = "${BASELINE_IP:-}" ]; then
  echo "ERROR: traffic is NOT going through the phone"
  exit 1
fi
echo "OK: traffic is going through the phone"
