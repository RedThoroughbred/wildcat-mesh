#!/usr/bin/env python3
"""Wildcat Mesh firmware manifest: the newest stable Meshtastic and MeshCore releases.

Writes firmware.json, which the app reads only when the user taps "Check for updates"
(Node settings → Firmware, or ≡ Menu → Firmware). It holds version numbers, dates,
the official release page and a short plain-text summary. No download links: the app
sends people to the official release pages and flashers, and we never re-host firmware.

How to run (Python 3 standard library only; needs the network):

    python3 tools/firmware_manifest.py                      # writes tools/firmware.json
    python3 tools/firmware_manifest.py -o tools/firmware.json \
        -o ~/Development/RedThoroughbred.github.io/wildcat/firmware.json

The GitHub API allows 60 unauthenticated requests an hour; set GITHUB_TOKEN to raise that.
The script makes at most a few requests per run.

When to re-run:
  - when Meshtastic or MeshCore publishes a new release (the firmware watcher in
    docs/FIRMWARE_PLAN.md says so), then commit tools/firmware.json and publish the site copy
    at https://redthoroughbred.github.io/wildcat/firmware.json (publishing needs Seth's OK);
  - after a bench test of a new version: raise TESTED below first, then re-run.

Which release counts as "latest stable":
  - Meshtastic (meshtastic/firmware): tags look like v2.7.26.54e0d8d (version + commit).
    Meshtastic names its channels in the release title: "Alpha" builds are marked
    pre-release on GitHub; "Beta" builds are full releases and are what Meshtastic offers
    as its stable firmware. Some titles add "(Revoked)" when a build was pulled.
    Rule: not a draft, not a GitHub pre-release, and the title/tag doesn't say alpha,
    rc or revoked. The newest by version number wins.
  - MeshCore (meshcore-dev/MeshCore): each version is three releases with their own tags,
    companion-vX.Y.Z, repeater-vX.Y.Z and room-server-vX.Y.Z (assets per board inside each).
    A phone connects only to Companion firmware, so "latest" means the newest non-draft,
    non-pre-release release whose tag starts with "companion-v".

Versions are normalised to dotted numbers ("2.7.26", "1.17.1") for comparison; the full
upstream string is kept too. The app compares the node's own version string against these.
"""

import argparse
import datetime as dt
import json
import os
import re
import sys
import urllib.error
import urllib.request

SCHEMA = 1
API = "https://api.github.com/repos/{repo}/releases?per_page=100&page={page}"
MAX_PAGES = 5

# The newest versions Wildcat has been tested against (hand-maintained; raise after a
# bench test). An "x" component matches anything: "2.7.x" covers every 2.7 release.
TESTED = {
    "meshtastic": {"version": "2.7.x", "note": "Wildcat Mesh 1.1 was built and tested against Meshtastic 2.7."},
    "meshcore": {"version": "1.17.1", "note": "Wildcat Mesh 1.1 was built and tested against MeshCore companion 1.17.1."},
}

NETWORKS = {
    "meshtastic": {"repo": "meshtastic/firmware", "role": None},
    "meshcore": {"repo": "meshcore-dev/MeshCore", "role": "companion"},
}

SUMMARY_LIMIT = 280


def fetch(repo):
    """Every release of `repo`, newest first (a few pages at most)."""
    out = []
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "wildcat-firmware-manifest"}
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = "Bearer " + token
    for page in range(1, MAX_PAGES + 1):
        req = urllib.request.Request(API.format(repo=repo, page=page), headers=headers)
        with urllib.request.urlopen(req, timeout=30) as r:
            batch = json.load(r)
        if not isinstance(batch, list):
            raise RuntimeError(f"{repo}: unexpected API answer: {str(batch)[:200]}")
        out.extend(batch)
        if len(batch) < 100:
            break
    return out


def numbers(text):
    """'v2.7.26.54e0d8d' -> (2, 7, 26); 'companion-v1.17.1' -> (1, 17, 1). None if not a version."""
    m = re.search(r"(\d+)\.(\d+)(?:\.(\d+))?", text or "")
    if not m:
        return None
    return tuple(int(g) for g in m.groups() if g is not None)


def is_stable_meshtastic(r):
    if r.get("draft") or r.get("prerelease"):
        return False
    words = ((r.get("name") or "") + " " + (r.get("tag_name") or "")).lower()
    return not any(w in words for w in ("alpha", "revoked", "-rc", " rc"))


def is_stable_meshcore_companion(r):
    if r.get("draft") or r.get("prerelease"):
        return False
    return (r.get("tag_name") or "").startswith("companion-v")


def plain(line):
    """One line of release-notes markdown as plain text (no links, URLs, credits or emoji)."""
    line = re.sub(r"!\[[^\]]*\]\([^)]*\)", "", line)        # images
    line = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", line)   # [text](url) -> text
    line = re.sub(r"\s+by @\S+(\s+in\s+\S+)?", "", line)   # "by @someone in https://…"
    line = re.sub(r"<?https?://\S+>?", "", line)           # bare URLs
    line = re.sub(r"[*_`]", "", line)                      # emphasis, code
    line = re.sub(r"[^\w\s.,:;!?()'\"/&+%=-]", "", line)   # emoji and symbols
    return re.sub(r"\s+", " ", line).strip(" :-")


def summary(body, fallback):
    """The first lines of the release notes as plain text: prose and warnings as sentences,
    then "Heading: item; item; item" for lists."""
    text = ""
    heading, items = None, []

    def flush():
        nonlocal text, heading, items
        # A heading with nothing under it says nothing.
        chunk = ((heading + ": " if heading else "") + "; ".join(items) + ".") if items else ""
        text = (text + " " + chunk).strip()
        heading, items = None, []

    for raw in (body or "").splitlines():
        line = re.sub(r"^>\s*", "", raw.strip())               # quotes
        if not line or re.fullmatch(r"\[![A-Z]+\]", line):      # GitHub alert markers
            continue
        if line.startswith("#"):
            flush()
            heading = plain(line.lstrip("#")) or None
            if heading and heading.lower() in ("release notes", "what's changed", "whats changed"):
                heading = None
            continue
        bullet = re.match(r"^[-*+]\s+", line)
        line = plain(line[bullet.end():] if bullet else line)
        if len(line) < 3 or line.lower().startswith("full changelog") or line.lower() == "release notes":
            continue
        if bullet:
            items.append(line.rstrip("."))
        else:
            flush()
            text = (text + " " + (line if line[-1] in ".!?" else line + ".")).strip()
        if len(text) + sum(len(i) + 2 for i in items) >= SUMMARY_LIMIT:
            break
    flush()
    if len(text) > SUMMARY_LIMIT:
        text = text[:SUMMARY_LIMIT].rsplit(" ", 1)[0].rstrip(",;:.") + "…"
    return text or fallback


def entry(r, network):
    tag = r["tag_name"]
    version = ".".join(str(n) for n in numbers(tag))
    name = r.get("name") or tag
    if network == "meshtastic":
        # The tag is the version string the node reports: v2.7.26.54e0d8d -> 2.7.26.54e0d8d.
        full = tag[1:] if tag[:1] in "vV" else tag
        build = full[len(version):].lstrip(".") or None
    else:
        # Official MeshCore builds report "v1.17.1-d929643": the commit is in the asset names.
        build = None
        for a in r.get("assets") or []:
            m = re.search(r"-v" + re.escape(version) + r"-([0-9a-f]{6,12})\b", a.get("name") or "")
            if m:
                build = m.group(1)
                break
        full = "v" + version + ("-" + build if build else "")
    return {
        "version": version,
        "full": full,
        "build": build,
        "tag": tag,
        "name": name,
        "date": (r.get("published_at") or r.get("created_at") or "")[:10],
        "url": r["html_url"],
        "summary": summary(r.get("body"), f"{name}. See the release page for what changed."),
    }


def latest(releases, network):
    test = is_stable_meshtastic if network == "meshtastic" else is_stable_meshcore_companion
    stable = [r for r in releases if test(r) and numbers(r.get("tag_name")) and r.get("html_url")]
    if not stable:
        raise RuntimeError(f"{network}: no stable release found")
    return max(stable, key=lambda r: (numbers(r["tag_name"]), r.get("published_at") or ""))


def build(now=None):
    now = now or dt.datetime.now(dt.timezone.utc)
    networks = {}
    for network, info in NETWORKS.items():
        releases = fetch(info["repo"])
        n = {"repo": info["repo"], "latest": entry(latest(releases, network), network), "tested": TESTED[network]}
        if info["role"]:
            n["role"] = info["role"]
        networks[network] = n
    return {
        "schema": SCHEMA,
        "generated": now.replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "source": "GitHub releases of meshtastic/firmware and meshcore-dev/MeshCore (tools/firmware_manifest.py)",
        "networks": networks,
    }


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("-o", "--out", action="append",
                   help="where to write firmware.json (repeatable; default: next to this script)")
    a = p.parse_args(argv)
    outs = a.out or [os.path.join(os.path.dirname(os.path.abspath(__file__)), "firmware.json")]
    try:
        manifest = build()
    except (urllib.error.URLError, RuntimeError) as e:
        print(f"firmware_manifest: {e}", file=sys.stderr)
        return 1
    text = json.dumps(manifest, indent=2, ensure_ascii=False) + "\n"
    for path in outs:
        path = os.path.expanduser(path)
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
        print(f"wrote {path}")
    for network, n in manifest["networks"].items():
        l = n["latest"]
        print(f"  {network}: {l['full']} ({l['date']}), tested {n['tested']['version']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
