#!/bin/zsh
# Fetch the pinned pieces of the Reticulum spike into Reticulum/vendor/ (gitignored), checking every
# download against its SHA-256 below, then unpack them where the Xcode build phase
# (tools/reticulum/install-python.sh) picks them up. Run once after cloning, and after changing a pin:
#
#   tools/reticulum/fetch.sh            # everything
#   tools/reticulum/fetch.sh --check    # only verify what is already downloaded
#
# What and from where:
# - CPython 3.13 for iOS: BeeWare Python-Apple-support 3.13-b16 (Python 3.13.16, OpenSSL 3.5.9,
#   libFFI 3.4.7, BZip2 1.0.8, XZ 5.6.4, mpdecimal 4.0.0), the official GitHub release. Its digest
#   is the one GitHub publishes for the asset.
# - Reticulum: rns 1.5.7 and lxmf 1.2.0, the official wheels from PyPI, unmodified. RNS's
#   RNodeInterface imports pyserial (3.5, PyPI) even when it never opens a serial port. Digests are
#   PyPI's.
# - PyCA cryptography 47.0.0 and cffi 2.0.0 built for iOS by BeeWare (pypi.anaconda.org/beeware), so
#   RNS uses OpenSSL rather than its pure-Python fallback. BeeWare's index publishes no digests:
#   these are the SHA-256s of the files as first downloaded on 2026-10-11.
set -euo pipefail
ROOT=${0:A:h:h:h}
VENDOR=$ROOT/Reticulum/vendor
DL=$VENDOR/downloads
CHECK_ONLY=0
[[ ${1:-} == --check ]] && CHECK_ONLY=1

typeset -a PINS=(
  # file | sha256 | url
  "Python-3.13-iOS-support.b16.tar.gz|22b96f3d0c3663225f078556b036d2ee6ce3ff98c885706585240681335c71ea|https://github.com/beeware/Python-Apple-support/releases/download/3.13-b16/Python-3.13-iOS-support.b16.tar.gz"
  "rns-1.5.7-py3-none-any.whl|0e4aaf8cc47f770da34572d2215b45fea900e104b009551600eb9741a41faddf|https://files.pythonhosted.org/packages/6a/5a/ee933b9f465040039286ffa76c5e509f334b61014061cdc1b0e46bcb3753/rns-1.5.7-py3-none-any.whl"
  "lxmf-1.2.0-py3-none-any.whl|805f053e61082f585efc6d09beffd039fd921174c5e1547a2e690bc479d75b85|https://files.pythonhosted.org/packages/b4/39/a15dd88f5bafcee5664dbfee288507e5aa02e2f33f0f3a24aab81c660e97/lxmf-1.2.0-py3-none-any.whl"
  "pyserial-3.5-py2.py3-none-any.whl|c4451db6ba391ca6ca299fb3ec7bae67a5c55dde170964c7a14ceefec02f2cf0|https://files.pythonhosted.org/packages/07/bc/587a445451b253b285629263eb51c2d8e9bcea4fc97826266d186f96f558/pyserial-3.5-py2.py3-none-any.whl"
  "cryptography-47.0.0-cp313-abi3-ios_13_0_arm64_iphoneos.whl|e62eec90567173553046e20e05c8e190dd785e002cca300e01b8202788bee948|https://pypi.anaconda.org/beeware/simple/cryptography/47.0.0/cryptography-47.0.0-cp313-abi3-ios_13_0_arm64_iphoneos.whl"
  "cryptography-47.0.0-cp313-abi3-ios_13_0_arm64_iphonesimulator.whl|3d9650d49dfd995971d79201800e5dc46a1c0bf35391c4e7af8266efb6bf8262|https://pypi.anaconda.org/beeware/simple/cryptography/47.0.0/cryptography-47.0.0-cp313-abi3-ios_13_0_arm64_iphonesimulator.whl"
  "cffi-2.0.0-cp313-cp313-ios_13_0_arm64_iphoneos.whl|cfb6e5c2e578cb334ed163914d88edc42bb43aaef11012dbc805ae5c1f4c4b5e|https://pypi.anaconda.org/beeware/simple/cffi/2.0.0/cffi-2.0.0-cp313-cp313-ios_13_0_arm64_iphoneos.whl"
  "cffi-2.0.0-cp313-cp313-ios_13_0_arm64_iphonesimulator.whl|604b9cbb6173900c5732dde50b165f0e0847df2bcc61199884931be76abef6c1|https://pypi.anaconda.org/beeware/simple/cffi/2.0.0/cffi-2.0.0-cp313-cp313-ios_13_0_arm64_iphonesimulator.whl"
)

mkdir -p $DL
for pin in $PINS; do
  file=${pin%%|*}; rest=${pin#*|}; sha=${rest%%|*}; url=${rest#*|}
  if [[ ! -f $DL/$file ]]; then
    (( CHECK_ONLY )) && { print -u2 "missing $file"; exit 1 }
    print "▸ $file"
    curl -fsSL --retry 3 -m 600 -o $DL/$file.part $url
    mv $DL/$file.part $DL/$file
  fi
  got=$(shasum -a 256 $DL/$file | cut -d' ' -f1)
  if [[ $got != $sha ]]; then
    print -u2 "✗ $file: sha256 $got, pinned $sha"; exit 1
  fi
  print "✓ $file"
done
(( CHECK_ONLY )) && exit 0

# Python.xcframework (+ the support package's build helpers and licence files).
rm -rf $VENDOR/python-support && mkdir -p $VENDOR/python-support
tar -xzf $DL/Python-3.13-iOS-support.b16.tar.gz -C $VENDOR/python-support
print "✓ Python.xcframework"

# Pure-Python packages, the same for device and simulator: a wheel is a zip of its install tree.
rm -rf $VENDOR/app_packages && mkdir -p $VENDOR/app_packages
for w in rns-1.5.7-py3-none-any.whl lxmf-1.2.0-py3-none-any.whl pyserial-3.5-py2.py3-none-any.whl; do
  unzip -q -o $DL/$w -d $VENDOR/app_packages
done
# Console scripts and other non-library files are not needed in the app.
rm -rf $VENDOR/app_packages/*.data(N)
print "✓ app_packages (rns, LXMF, serial)"

# Binary packages, one tree per SDK.
for sdk in iphoneos iphonesimulator; do
  d=$VENDOR/app_packages.$sdk
  rm -rf $d && mkdir -p $d
  unzip -q -o $DL/cryptography-47.0.0-cp313-abi3-ios_13_0_arm64_$sdk.whl -d $d
  unzip -q -o $DL/cffi-2.0.0-cp313-cp313-ios_13_0_arm64_$sdk.whl -d $d
  print "✓ app_packages.$sdk (cryptography, cffi)"
done
