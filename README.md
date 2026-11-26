# Wildcat Mesh

The source code of **Wildcat Mesh**, an iPhone app for LoRa mesh radios. One app
for Meshtastic® and MeshCore radios, with a Reticulum beta: chat on each network,
bridge a private channel between them through the phone, and play games outside
(Fox Hunt, Geo Gifts).

No account and no servers. The phone talks to your own radios over Bluetooth.

- App Store: **Wildcat Mesh** (free, no ads). iPhone, iOS 17 or later.
- Website, guide and support: https://redthoroughbred.github.io/wildcat/

This repository is a snapshot of the source of each App Store release, one commit
per release. Day-to-day work happens elsewhere, so there is no history here.

## What is in here

```
wildcat-games-ios/     the app (SwiftUI)
  WildcatGames/        screens, models, design
  WildcatWidgets/      Home Screen widget
  Shared/              code both targets use
  WildcatGamesTests/   app tests
  Reticulum/python/    Wildcat's Python glue for the Reticulum stack
  tools/               build, test and radio scripts
wildcat-radio-core/    Swift package: protocols, Bluetooth links, game rules
```

The app finds the core at `../wildcat-radio-core`, so keep the two folders side
by side.

- **Meshtastic:** the app has its own small codec for the phone API, written
  from the wire format. It contains no Meshtastic source code and no `.proto`
  files. Tests compare its bytes against the official Python package.
- **MeshCore:** the companion Bluetooth protocol, written from MeshCore's docs.
- **Reticulum:** the official stack (RNS and LXMF from PyPI, unmodified) runs
  inside the app in an embedded CPython 3.13 (BeeWare's build). The Swift side
  only reads the outer packet header. No RNS or LXMF code is ported or
  re-implemented here, and please don't add any: use the real stack.

## Build

You need a Mac with Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
cd wildcat-games-ios
tools/reticulum/fetch.sh     # once: downloads the pinned Python runtime, RNS and LXMF, checking each hash
xcodegen generate
open WildcatGames.xcodeproj
```

- Set your own team and bundle identifier in `project.yml` before running on a phone.
- The scripts in `tools/` put build output in the folder named by `WILDCAT_BUILD`.
  Set it: the default is a drive on the author's Mac.
- No radio? The app has a Practice mode with pretend radios. Nothing is transmitted.

## Test

```sh
cd wildcat-radio-core && swift test
cd ../wildcat-games-ios && xcodebuild test -project WildcatGames.xcodeproj \
  -scheme WildcatGames -destination 'id=<simulator id>'
```

Radio data comes from strangers over the air, so parsing must never crash.

## License

Copyright (C) 2026 Seth Egger.

Wildcat Mesh and WildcatRadioCore are free software under the GNU General Public
License, version 3 or (at your option) any later version. See [LICENSE](LICENSE).

The app runs the Reticulum Network Stack and LXMF, which have their own licence
(the Reticulum License). [LICENSE-EXCEPTION](LICENSE-EXCEPTION) is a GPLv3
section 7 additional permission that allows that combination. It does not change
the terms of RNS or LXMF. Everything the app bundles is listed, with its licence
text, in [THIRD_PARTY_NOTICES.md](wildcat-games-ios/THIRD_PARTY_NOTICES.md).

## Trademarks and affiliation

Meshtastic® is a registered trademark of Meshtastic LLC. Meshtastic software
components are released under various licenses, see GitHub for details. No
warranty is provided - use at your own risk.

Wildcat Mesh is not affiliated with or endorsed by Meshtastic LLC, the
Meshtastic project or the MeshCore project.

Includes the Reticulum Network Stack and LXMF by Mark Qvist (Reticulum License).
Wildcat Mesh is not affiliated with or endorsed by the Reticulum project.
