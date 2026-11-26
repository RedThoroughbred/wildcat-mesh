#!/bin/zsh
# Draft the next Kotlin porting brief: what changed in the Swift core since the Kotlin port's
# reference snapshot (wildcat-core-kotlin/reference/swift). Read-only; prints Markdown.
#
#   tools/parity/port-brief.sh                 # print the draft
#   tools/parity/port-brief.sh -o brief.md     # write it to a file
#   tools/parity/port-brief.sh --diff          # also include the full unified diffs
#
# Env: CORE (default ~/Development/wildcat-radio-core), KT (default ~/Development/wildcat-core-kotlin)
set -euo pipefail
CORE=${CORE:-$HOME/Development/wildcat-radio-core}
KT=${KT:-$HOME/Development/wildcat-core-kotlin}
REF=$KT/reference/swift
OUT=""; FULL=0
while (( $# )); do
  case $1 in
    -o) OUT=$2; shift 2 ;;
    --diff) FULL=1; shift ;;
    *) print -u2 "unknown option $1"; exit 2 ;;
  esac
done
[[ -d $REF/Sources && -d $CORE/Sources ]] || { print -u2 "need $REF and $CORE"; exit 1; }

head=$(git -C $CORE rev-parse --short HEAD)
branch=$(git -C $CORE branch --show-current)
fixc=$(grep -ho '"swiftCommit"[^,}]*' $KT/fixtures/*.json 2>/dev/null | sort -u | head -3 | tr '\n' ' ' || true)

changed=(); added=(); removed=()
for area in Sources Tests; do
  while IFS= read -r line; do
    case $line in
      "Files "*" differ") f=${${line#Files $CORE/}%% and *}; changed+=$f ;;
      "Only in $CORE/"*) d=${${line#Only in $CORE/}%%: *}; added+="$d/${line##*: }" ;;
      "Only in $REF/"*) d=${${line#Only in $REF/}%%: *}; removed+="$d/${line##*: }" ;;
    esac
  done < <(diff -rq -x .build -x .swiftpm -x '*.json' -x '*.py' $CORE/$area $REF/$area 2>/dev/null || true)
done

p() { print -r -- "$@"; }

brief() {
  p "# Draft brief: port Swift core changes (core @ $head on $branch)"
  p
  p "Generated $(date '+%Y-%m-%d %H:%M') by \`wildcat-games-ios/tools/parity/port-brief.sh\`. Compare against"
  p "\`reference/swift\` (fixtures say: ${fixc:-unknown}). Edit before handing to a session."
  p
  if (( ${#changed} + ${#added} + ${#removed} == 0 )); then
    p "**Nothing to port:** the Swift core matches the Kotlin reference snapshot."; return
  fi
  p "## Swift files"
  p
  p "| File | Change | Lines +/- |"
  p "|---|---|---|"
  for f in $changed; do
    s=$(diff -u $REF/$f $CORE/$f | grep -E '^[+-][^+-]' | awk '/^\+/{a++} /^-/{d++} END{printf "+%d / -%d", a, d}' || true)
    p "| \`$f\` | changed | $s |"
  done
  for f in $added; do p "| \`$f\` | new | +$(wc -l < $CORE/$f | tr -d ' ') |"; done
  for f in $removed; do p "| \`$f\` | removed | |"; done
  p
  p "## Public API touched"
  p
  for f in $changed $added; do
    [[ $f == Sources/* && -f $CORE/$f ]] || continue
    api=$( { if [[ -f $REF/$f ]]; then diff -u $REF/$f $CORE/$f || true; else sed 's/^/+/' $CORE/$f; fi; } | grep -E '^[+-][[:space:]]*public ' | sed 's/^\([+-]\)[[:space:]]*/\1 /' | head -40 || true)
    [[ -n $api ]] && { p "\`$f\`:"; p '```diff'; p $api; p '```'; }
  done
  p
  p "## Tests to mirror"
  p
  for f in $changed $added; do
    [[ $f == Tests/* && -f $CORE/$f ]] || continue
    new=$( { if [[ -f $REF/$f ]]; then diff -u $REF/$f $CORE/$f || true; else sed 's/^/+/' $CORE/$f; fi; } | grep -oE '^\+[[:space:]]*func (test[A-Za-z0-9_]+)' | sed -E 's/.*func //' || true)
    [[ -n $new ]] && { p "- \`$f\`:"; for t in ${(f)new}; do p "  - \`$t\`"; done; }
  done
  p
  p "## Checklist"
  p
  p "- [ ] On the Mac: \`tools/fixture-generator/regenerate.sh\` (adds fixture cases for the new rules)."
  p "- [ ] Refresh \`reference/swift\` from the core at \`$head\` (Sources, Tests, Package.swift)."
  p "- [ ] Port each changed file in its package; keep Swift names and user-facing strings."
  p "- [ ] Mirror every new test by name; replay every new fixture case."
  p "- [ ] \`./gradlew test\` green; update \`wildcat-games-ios/docs/ANDROID_PARITY.md\` (Kotlin column)."
  if (( FULL )); then
    p; p "## Full diffs"; p
    for f in $changed; do p "### \`$f\`"; p '```diff'; diff -u $REF/$f $CORE/$f | tail -n +3 || true; p '```'; done
  fi
}

if [[ -n $OUT ]]; then brief > $OUT; print -u2 "wrote $OUT"; else brief; fi
