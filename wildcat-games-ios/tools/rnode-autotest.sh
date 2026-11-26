#!/bin/zsh
# Check a real RNode against the installed Wildcat build, from the Mac.
#
#   tools/rnode-autotest.sh [--listen] [serial-port] [udid]
#
# --listen: after the checks, set the radio to the Macs' test settings (914.875 MHz, 125 kHz, SF8,
# CR 4/5, 7 dBm), turn the receiver on and log every packet heard with its decoded Reticulum
# header (`heard |` lines). Receive only. Something must be announcing on those settings to see
# anything, e.g. `rnode2.sh beacon` with the second RNode (that one does transmit).
#
# 1. Puts the RNode (plugged into this Mac by USB) into Bluetooth pairing mode with rnodeconf -p
#    and shows the 6-digit PIN it prints. The window is 35 seconds.
# 2. Launches Wildcat on the phone with -RNodeAutoTest and streams its console: the app scans,
#    connects to the strongest RNode (or the last one), prints the rnodeconf --info block, reads
#    the radio settings, changes the spreading factor and reads it back, restores it, then logs
#    signal and battery as they arrive. Nothing is transmitted.
# When iOS asks for the PIN on the phone, type the one shown here. Not paired before: the RNode
# drops the link once after pairing and the app reconnects by itself.
#
# Stop rnsd / Sideband first (an RNode talks to one host at a time). The phone must be unlocked.
set -uo pipefail
cd "$(dirname "$0")/.."
LISTEN=()
if [[ "${1:-}" == "--listen" ]]; then LISTEN=(-RNodeAutoTestListen); shift; fi
PORT="${1:-/dev/cu.usbmodem113101}"
DEVICE="${2:-${WILDCAT_PHONE:-}}"
[[ -n "$DEVICE" ]] || { echo "Give the phone's id (xcrun devicectl list devices) as the second argument, or set WILDCAT_PHONE."; exit 1; }
RNODECONF="${RNODECONF:-/Volumes/Code-Docker/reticulum/venv/bin/rnodeconf}"

if pgrep -f rnsd >/dev/null; then echo "rnsd is running; stop it first (rnode.sh down)"; exit 1; fi

echo "▸ Pairing mode on $PORT (35 s window)…"
# rnodeconf -p waits for Enter; give it 40 s then let it send CMD_LEAVE.
( sleep 40; echo ) | "$RNODECONF" -p "$PORT" 2>&1 | grep -E "PIN|pairing|Device connected|Could not|rror" &
PAIR=$!
sleep 4

echo "▸ Launching Wildcat with -RNodeAutoTest (console follows; Ctrl-C to stop)"
xcrun devicectl device process launch --console --terminate-existing --device "$DEVICE" \
  com.thebench.wildcatgames -RNodeAutoTest "${LISTEN[@]}" 2>&1 | grep --line-buffered -E "RNodeAutoTest|Locked|error" &
LAUNCH=$!
wait $PAIR
wait $LAUNCH
