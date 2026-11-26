#!/bin/bash
# Xcode build phase (WildcatGames target, after resources): puts the Python runtime and the
# Reticulum packages into the app bundle. Needs tools/reticulum/fetch.sh to have run once.
#
#   <app>/python/lib/python3.13   CPython's standard library for this SDK and architecture
#                                 (BeeWare's install_stdlib), less what an embedded app never uses
#   <app>/app                     Wildcat's own Python: the bridge and the RNode interface
#   <app>/app_packages            rns, LXMF, serial; cryptography and cffi built for this SDK
#   <app>/Frameworks/*.framework  every binary module (.so) as a signed framework, as iOS requires
#                                 (BeeWare's process_dylibs leaves a .fwork pointer in its place)
#
# bash, not zsh: BeeWare's Python.xcframework/build/utils.sh is written for it.
set -euo pipefail

XCF=Reticulum/vendor/python-support/Python.xcframework
VENDOR="$PROJECT_DIR/Reticulum/vendor"
if [ ! -d "$PROJECT_DIR/$XCF" ] || [ ! -d "$VENDOR/app_packages" ]; then
    echo "error: Python for the Reticulum spike is missing: run tools/reticulum/fetch.sh"
    exit 1
fi

# BeeWare's install_stdlib copies lib-$ARCHS: one architecture per build. (project.yml excludes
# x86_64 from simulator builds; the iOS wheels for the simulator are arm64 only.)
if [[ "$ARCHS" == *" "* ]]; then
    echo "error: the embedded Python supports one architecture per build, got ARCHS=\"$ARCHS\""
    exit 1
fi

# Unsigned builds (CODE_SIGNING_ALLOWED=NO, e.g. measuring size) still need the frameworks signed
# for the layout to be complete: ad hoc.
export EXPANDED_CODE_SIGN_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
export EXPANDED_CODE_SIGN_IDENTITY_NAME="${EXPANDED_CODE_SIGN_IDENTITY_NAME:-ad hoc}"

# shellcheck source=/dev/null
source "$PROJECT_DIR/$XCF/build/utils.sh"

install_stdlib "$XCF"

# Not needed in an app: CPython's own test suite (35 MB), IDLE, Tk, the REPL, pip's bootstrapper,
# venv, curses, docs, and the test-only extension modules. Nothing in RNS or LXMF imports them.
STD="$CODESIGNING_FOLDER_PATH/python/lib/python3.13"
rm -rf "$STD/test" "$STD/idlelib" "$STD/tkinter" "$STD/turtledemo" "$STD/ensurepip" "$STD/pydoc_data" \
       "$STD/venv" "$STD/_pyrepl" "$STD/curses" "$STD/__phello__" "$STD/turtle.py" "$STD/sqlite3/test"
find "$STD/lib-dynload" \( -name "_test*.so" -o -name "xx*.so" -o -name "_ctypes_test*.so" \) -delete

# Wildcat's own Python.
rsync -a --delete --exclude "__pycache__" "$PROJECT_DIR/Reticulum/python/" "$CODESIGNING_FOLDER_PATH/app/"

# Reticulum and friends: the pure packages, then the binary ones for this SDK.
rsync -a --delete --exclude "__pycache__" "$VENDOR/app_packages/" "$CODESIGNING_FOLDER_PATH/app_packages/"
rsync -a --exclude "__pycache__" "$VENDOR/app_packages.$PLATFORM_NAME/" "$CODESIGNING_FOLDER_PATH/app_packages/"

# Privacy manifests for the modules that carry OpenSSL. Apple lists OpenSSL among the SDKs that must ship one
# (ITMS-91061 refused 2.0 build 1 for _hashlib and _ssl), and the 3.13-b16 support package has none.
# Reticulum/OpenSSL.xcprivacy is BeeWare's own file (Python-Apple-support, patch/Python/OpenSSL.xcprivacy):
# no data collected, no tracking, file timestamps for reason C617.1. BeeWare's install_dylib moves
# <module>.xcprivacy into the module's framework as PrivacyInfo.xcprivacy.
for m in "$STD/lib-dynload/_hashlib" "$STD/lib-dynload/_ssl" \
         "$CODESIGNING_FOLDER_PATH/app_packages/cryptography/hazmat/bindings/_rust"; do
    if ls "$m".*.so >/dev/null 2>&1; then
        cp "$PROJECT_DIR/Reticulum/OpenSSL.xcprivacy" "$m.xcprivacy"
    else
        echo "error: no extension module at $m for the OpenSSL privacy manifest"
        exit 1
    fi
done

echo "Install Python standard library extension modules..."
process_dylibs "$XCF" python/lib/python3.13/lib-dynload
echo "Install app_packages extension modules..."
process_dylibs "$XCF" app_packages
