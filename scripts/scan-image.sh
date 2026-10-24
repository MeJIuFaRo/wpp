#!/usr/bin/env bash
# Fail if an image contains private keys or identifiers of your servers.
# Images are public on Docker Hub, so this runs before every push.
# Put your own domains/IPs (one extended regex per line) into
# scripts/scan-patterns.local; that file is not committed.
set -Eeuo pipefail
image="$1"
patterns='BEGIN [A-Z ]*PRIVATE KEY'
local_patterns="$(dirname "$0")/scan-patterns.local"
if [[ -s "$local_patterns" ]]; then
    patterns+="|$(grep -v '^[[:space:]]*\(#\|$\)' "$local_patterns" | paste -sd'|')"
fi
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cid="$(docker create "$image")"
docker export "$cid" | tar -C "$tmp" -xf - --exclude='dev/*' 2>/dev/null || true
docker rm -f "$cid" >/dev/null
# System CA bundles legitimately contain certificates, never private keys.
if grep -rIlE "$patterns" "$tmp" --exclude-dir=proc --exclude-dir=sys 2>/dev/null | grep -v '^$'; then
    echo "FAIL: $image contains forbidden data (files listed above)" >&2
    exit 1
fi
if docker history --no-trunc --format '{{.CreatedBy}}' "$image" | grep -iE "$patterns"; then
    echo "FAIL: $image build history contains forbidden data" >&2
    exit 1
fi
echo "OK: $image"
