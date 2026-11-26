#!/bin/zsh
# Launch-time comparison: install an app build in the simulator, launch it N times from cold
# (terminated first) with -LaunchTiming, and print the median time from process start to the app's
# init and to its first screen. Run it on two builds (with and without the embedded Python) to
# see what linking Python.framework costs at launch.
#
#   tools/reticulum/launch-timing.sh <path/to/WildcatGames.app> [runs=8] [simulator-udid]
set -uo pipefail
APP=$1
RUNS=${2:-8}
UDID=${3:-A0DAF082-C613-498D-8D6C-20520453767D}
BUNDLE=com.thebench.wildcatgames
OUT=${TMPDIR:-/tmp}/wildcat-launch-timing
mkdir -p $OUT
xcrun simctl boot $UDID 2>/dev/null
xcrun simctl bootstatus $UDID -b >/dev/null
xcrun simctl install $UDID $APP || exit 1

typeset -a inits screens
for i in $(seq 0 $RUNS); do
  xcrun simctl terminate $UDID $BUNDLE 2>/dev/null
  sleep 1
  xcrun simctl launch --console-pty $UDID $BUNDLE -LaunchTiming > $OUT/run.log 2>&1 &
  pid=$!
  for _ in {1..40}; do grep -aq "first screen" $OUT/run.log && break; sleep 0.25; done
  kill $pid 2>/dev/null
  init=$(grep -a "\[LaunchTiming\] app init" $OUT/run.log | head -1 | sed -E 's/.*\+([0-9]+) ms.*/\1/')
  screen=$(grep -a "\[LaunchTiming\] first screen" $OUT/run.log | head -1 | sed -E 's/.*\+([0-9]+) ms.*/\1/')
  if (( i == 0 )); then print "warm-up: init ${init:-?} ms, first screen ${screen:-?} ms"; continue; fi
  print "run $i: init ${init:-?} ms, first screen ${screen:-?} ms"
  [[ -n $init ]] && inits+=$init
  [[ -n $screen ]] && screens+=$screen
done
xcrun simctl terminate $UDID $BUNDLE 2>/dev/null
median() { print -l -- "$@" | sort -n | awk '{a[NR]=$1} END {if (NR%2) print a[(NR+1)/2]; else print (a[NR/2]+a[NR/2+1])/2}' }
print "median: init $(median $inits) ms, first screen $(median $screens) ms ($#screens runs)"
