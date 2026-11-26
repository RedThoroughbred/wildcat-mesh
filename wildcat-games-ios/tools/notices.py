#!/usr/bin/env python3
"""Writes THIRD_PARTY_NOTICES.md from the licence files the app ships (WildcatGames/Licenses).

    python3 tools/notices.py

The in-app screen (About -> Open source licences) reads the same files, so the two can't drift.
When a bundled version changes (tools/reticulum/fetch.sh), update licenses.json and the
license-<id>.txt it names, then run this again.
"""
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "WildcatGames", "Licenses")


def main():
    with open(os.path.join(SRC, "licenses.json"), encoding="utf-8") as f:
        components = json.load(f)
    out = ["# Third-party notices", "",
           "Wildcat Mesh includes the software below. Made by `tools/notices.py` from `WildcatGames/Licenses/`;",
           "the app shows the same texts under About → Open source licences.", "",
           "RNS and LXMF are included unmodified from PyPI (versions and SHA-256 pinned in `tools/reticulum/fetch.sh`).",
           "Wildcat Mesh is not affiliated with or endorsed by the Reticulum project.", "",
           "| Component | Version | Licence | By |", "|---|---|---|---|"]
    for c in components:
        out.append("| %s | %s | %s | %s |" % (c["name"], c["version"], c["license"], c["by"]))
    for c in components:
        with open(os.path.join(SRC, "license-%s.txt" % c["id"]), encoding="utf-8") as f:
            text = f.read().rstrip("\n")
        out += ["", "## %s %s" % (c["name"], c["version"]), "", "%s · %s · %s" % (c["license"], c["by"], c["source"]), ""]
        if c["note"]:
            out += [c["note"], ""]
        fence = "````"
        out += [fence + "text", text, fence]
    with open(os.path.join(ROOT, "THIRD_PARTY_NOTICES.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(out) + "\n")
    print("THIRD_PARTY_NOTICES.md: %d components" % len(components))


if __name__ == "__main__":
    main()
