#!/bin/zsh
# Build Wildcat Mesh (Debug) and install + launch it on a paired iPhone.
#
#   tools/run-on-phone.sh                   # first paired device
#   tools/run-on-phone.sh <udid> [args…]    # by devicectl identifier, extra launch args passed to the app
#
# Needs the team's Apple ID signed in under Xcode > Settings > Accounts, the phone paired with
# this Mac and Developer Mode on. The phone must be unlocked to launch (install works locked).
set -euo pipefail
cd "$(dirname "$0")/.."

# Build output goes on the Code-Docker drive, not in the repo (the internal disk is small).
# WILDCAT_BUILD points it somewhere else.
BUILD_ROOT="${WILDCAT_BUILD:-/Volumes/Code-Docker/dev-cache/wildcat-build}"
[[ -d "${BUILD_ROOT:h}" ]] || { echo "${BUILD_ROOT:h} is missing: plug in Code-Docker, or set WILDCAT_BUILD."; exit 1; }

DEVICE="${1:-}"
[[ $# -gt 0 ]] && shift
if [[ -z "$DEVICE" ]]; then
  DEVICE=$(xcrun devicectl list devices --json-output /dev/stdout 2>/dev/null \
    | python3 -c "import sys,json; d=[x for x in json.load(sys.stdin)['result']['devices'] if x.get('connectionProperties',{}).get('pairingState')=='paired']; print(d[0]['identifier'] if d else '')")
  [[ -z "$DEVICE" ]] && { echo "No paired device found. Run: xcrun devicectl list devices"; exit 1; }
fi

echo "▸ Generating Xcode project"
xcodegen generate -q

echo "▸ Building for device"
xcodebuild -project WildcatGames.xcodeproj -scheme WildcatGames -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath "$BUILD_ROOT/device" \
  -allowProvisioningUpdates build -quiet

APP="$BUILD_ROOT/device/Build/Products/Debug-iphoneos/WildcatGames.app"
echo "▸ Installing on $DEVICE"
xcrun devicectl device install app --device "$DEVICE" "$APP" | grep -E "installationURL|error" || true

echo "▸ Launching"
xcrun devicectl device process launch --terminate-existing --device "$DEVICE" com.thebench.wildcatgames "$@"
