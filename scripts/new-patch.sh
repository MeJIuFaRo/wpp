#!/usr/bin/env bash
# Write the next hand-made patch: diff between upstream + existing patches and
# the working copy in work/<component>.
#   scripts/new-patch.sh relay 0002-wpp-profile-byte-counters
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
component="$1"; name="$2"
case "$component" in
    relay)   base="$ROOT/upstream/tproxy-server"; patches="$ROOT/src/relay-patches" ;;
    mtproxy) base="$ROOT/upstream/MTProxy";       patches="$ROOT/src/mtproxy-patches" ;;
    *) echo "unknown component: $component" >&2; exit 2 ;;
esac
work="$ROOT/work/$component"
[[ -d "$work" ]] || { echo "missing $work" >&2; exit 1; }
out="$patches/$name.patch"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cp -a "$base" "$tmp/a"; rm -rf "$tmp/a/.git" "$tmp/a/.commit" "$tmp/a/deploy"
for p in "$patches"/*.patch; do
    [[ "$p" == "$out" ]] && continue
    (cd "$tmp/a" && patch -s -p1 < "$p")
done
find "$tmp/a" -name '*.orig' -delete
# work/<component> may hold only the changed files: overlay it on the base.
cp -a "$tmp/a" "$tmp/b"
cp -a "$work/." "$tmp/b/"; rm -rf "$tmp/b/.git" "$tmp/b/.commit" "$tmp/b/deploy"
(cd "$tmp" && diff -ruN a b) > "$out" || [[ $? -eq 1 ]]
[[ -s "$out" ]] || { rm -f "$out"; echo "no changes in $work" >&2; exit 1; }
grep '^+++ ' "$out"
