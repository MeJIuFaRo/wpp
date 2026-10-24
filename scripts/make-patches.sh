#!/usr/bin/env bash
# Rebuild the base patches (changes made on the original server) from reference/
# against pinned upstream. Patches 0001 are that state; 0002+ are written by hand.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UP="$ROOT/upstream"
REF="$ROOT/reference/2.3.6"
"$ROOT/scripts/fetch-upstream.sh"

# The relay copy taken from the server before the hot-reload change must be pristine
# upstream. deploy/ is excluded: the 2.3.6 installer edits install-mtproxy.sh in
# place (apt lock timeout), and the images do not use deploy/ at all.
if ! diff -r -q -x .git -x deploy "$UP/tproxy-server" "$REF/relay-orig" >/dev/null; then
    echo "reference/2.3.6/relay-orig differs from upstream tproxy-server:" >&2
    diff -r -q -x .git -x deploy "$UP/tproxy-server" "$REF/relay-orig" >&2 || true
    exit 1
fi

make_patch() { # <old dir> <new dir> <output>; writes a -p1 unified diff
    local tmp; tmp="$(mktemp -d)"
    cp -a "$1" "$tmp/a"; cp -a "$2" "$tmp/b"
    rm -rf "$tmp/a/.git" "$tmp/b/.git" "$tmp/a/deploy" "$tmp/b/deploy"
    (cd "$tmp" && diff -ruN a b) > "$3" || [[ $? -eq 1 ]]
    rm -rf "$tmp"
    [[ -s "$3" ]] || { echo "empty patch: $3" >&2; exit 1; }
}

make_patch "$REF/relay-orig" "$REF/relay-patched" "$ROOT/src/relay-patches/0001-wpp-profiles-hot-reload.patch"

mt_tmp="$(mktemp -d)"
cp -a "$UP/MTProxy" "$mt_tmp/orig"; rm -f "$mt_tmp/orig/.commit"
cp -a "$mt_tmp/orig" "$mt_tmp/new"
cp "$REF/mtproxy/net-tcp-rpc-ext-server.c" "$mt_tmp/new/net/net-tcp-rpc-ext-server.c"
make_patch "$mt_tmp/orig" "$mt_tmp/new" "$ROOT/src/mtproxy-patches/0001-wpp-64-secrets.patch"
rm -rf "$mt_tmp"

for p in "$ROOT"/src/relay-patches/*.patch; do git -C "$UP/tproxy-server" apply --check "$p"; done
for p in "$ROOT"/src/mtproxy-patches/*.patch; do (cd "$UP/MTProxy" && git apply --check "$p"); done
wc -l "$ROOT"/src/relay-patches/*.patch "$ROOT"/src/mtproxy-patches/*.patch
