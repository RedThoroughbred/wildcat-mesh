#!/bin/zsh
# Pull the RNode Bluetooth diary (Documents/rnode-ble.log) off the phone and show its tail.
#
#   tools/rnode-diag.sh <udid> [lines]      # last 80 lines; the id can also come from WILDCAT_PHONE
#   tools/rnode-diag.sh <udid> 300
#
# The app writes the log by itself in DEBUG builds (tools/run-on-phone.sh), or in a Release
# build launched with -RNodeDiag. The file lands in rnode-ble.log in the build folder on the Code-Docker
# drive (WILDCAT_BUILD overrides it), or in $TMPDIR when that drive isn't plugged in.
# The phone has to be paired with this Mac; it needn't be unlocked.
set -uo pipefail
cd "$(dirname "$0")/.."

DEVICE="${1:-${WILDCAT_PHONE:-}}"
[[ -n "$DEVICE" ]] || { echo "Give the phone's id (xcrun devicectl list devices) as the first argument, or set WILDCAT_PHONE."; exit 1; }
LINES="${2:-80}"
BUNDLE="com.thebench.wildcatgames"
OUT_DIR="${WILDCAT_BUILD:-/Volumes/Code-Docker/dev-cache/wildcat-build}"
[[ -d "${OUT_DIR:h}" ]] || OUT_DIR="${TMPDIR:-/tmp}/wildcat-games-ios"
OUT="$OUT_DIR/rnode-ble.log"
mkdir -p "$OUT_DIR"

echo "▸ Pulling Documents/rnode-ble.log from $DEVICE ($BUNDLE)"
if ! xcrun devicectl device copy from --device "$DEVICE" \
      --domain-type appDataContainer --domain-identifier "$BUNDLE" \
      --source Documents/rnode-ble.log --destination "$OUT" --quiet; then
  echo "Could not pull the log. Is the phone paired and the app installed? Has it opened the RNode"
  echo "console once since this build (the file is created on the first launch of a DEBUG build)?"
  exit 1
fi

echo "▸ $OUT ($(wc -c < "$OUT" | tr -d ' ') bytes, $(grep -c '==== RNode BLE log' "$OUT") sessions); last $LINES lines:"
echo
tail -n "$LINES" "$OUT"
