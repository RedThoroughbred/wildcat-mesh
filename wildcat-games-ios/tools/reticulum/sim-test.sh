#!/bin/zsh
# The Reticulum spike without a radio: Wildcat in the iPhone Simulator runs the real Reticulum stack
# and exchanges LXMF messages with a test peer on this Mac over loopback TCP. Nothing goes over the
# air or onto the LAN: the peer (tools/reticulum/lxmf_peer.py) listens on 127.0.0.1 only and has no
# other interface, and the app's Reticulum config has only that TCP interface.
#
#   tools/reticulum/sim-test.sh [--build] [--no-install] [simulator-udid] [port]
#
# --no-install launches the copy already in the simulator (the one `xcodebuild test` put there),
# for when `simctl install` hangs.
#
# Passes when the app's message to the peer is delivered, the peer's echo comes back, and a second
# message is delivered after Reticulum was stopped and started again in the same run
# (the app's "PASS delivered", "PASS echo" and "PASS restart" lines). Logs: $TMPDIR/wildcat-sim-test/.
set -uo pipefail
cd "${0:A:h}/../.."
BUILD=0
INSTALL=1
[[ ${1:-} == --build ]] && { BUILD=1; shift }
[[ ${1:-} == --no-install ]] && { INSTALL=0; shift }
UDID=${1:-A0DAF082-C613-498D-8D6C-20520453767D}
PORT=${2:-4243}
PY=${PY:-/Volumes/Code-Docker/reticulum/venv/bin/python}
# Build output goes on the Code-Docker drive, not in the repo (the internal disk is small).
# WILDCAT_BUILD points it somewhere else.
BUILD_ROOT=${WILDCAT_BUILD:-/Volumes/Code-Docker/dev-cache/wildcat-build}
[[ -d ${BUILD_ROOT:h} ]] || { print "${BUILD_ROOT:h} is missing: plug in Code-Docker, or set WILDCAT_BUILD."; exit 1 }
APP=$BUILD_ROOT/sim/Build/Products/Debug-iphonesimulator/WildcatGames.app
LOG=${TMPDIR:-/tmp}/wildcat-sim-test
mkdir -p $LOG

if (( BUILD )) || [[ ! -d $APP/app_packages ]]; then
  print "▸ building for the simulator"
  xcodebuild build -project WildcatGames.xcodeproj -scheme WildcatGames -destination "id=$UDID" \
    -derivedDataPath $BUILD_ROOT/sim 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
fi

xcrun simctl boot $UDID 2>/dev/null
xcrun simctl bootstatus $UDID -b >/dev/null
(( INSTALL )) && { xcrun simctl install $UDID $APP || exit 1 }

print "▸ LXMF test peer on 127.0.0.1:$PORT"
$PY tools/reticulum/lxmf_peer.py --port $PORT --echo --announce-every 10 --timeout 190 > $LOG/peer.log 2>&1 &
PEER=$!
sleep 3

print "▸ Wildcat with -ReticulumAutoTest"
xcrun simctl launch --console-pty --terminate-running-process $UDID com.thebench.wildcatgames \
  -ReticulumAutoTest -ReticulumRestart -ReticulumTCP 127.0.0.1:$PORT > $LOG/app.log 2>&1 &
LAUNCH=$!

ok=0
for i in {1..130}; do
  if grep -aq "PASS echo" $LOG/app.log && grep -aq "PASS delivered" $LOG/app.log && grep -aq "PASS restart" $LOG/app.log; then ok=1; break; fi
  sleep 1
done
sleep 1
grep -a "\[ReticulumAutoTest\]" $LOG/app.log | sed 's/.*\[ReticulumAutoTest\] //' | awk '!seen[$0]++' | grep -v "^heartbeat"
print -- "--- peer"
grep -v '"announced"' $LOG/peer.log
kill $PEER $LAUNCH 2>/dev/null
xcrun simctl terminate $UDID com.thebench.wildcatgames 2>/dev/null
if (( ok )); then print "✓ PASS: delivered both ways, and again after a restart"; exit 0; fi
print "✗ FAIL (logs in $LOG)"
exit 1
