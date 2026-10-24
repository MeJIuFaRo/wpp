#!/usr/bin/env bash
# Download pinned upstream sources into upstream/ (not committed, not shipped).
# Used to generate patches and to check that src/ starts from the right base.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../versions.env
. "$ROOT/versions.env"
UP="$ROOT/upstream"
mkdir -p "$UP"

if [[ ! -d "$UP/web-panel-proxy/.git" ]]; then
    git clone --quiet --depth 1 --branch "$WPP_UPSTREAM_TAG" "$WPP_UPSTREAM_REPO" "$UP/web-panel-proxy"
fi
git -C "$UP/web-panel-proxy" describe --tags --exact-match >/dev/null

if [[ ! -d "$UP/tproxy-server/.git" ]]; then
    git init --quiet "$UP/tproxy-server"
    git -C "$UP/tproxy-server" remote add origin "$TPROXY_REPO"
fi
git -C "$UP/tproxy-server" fetch --quiet --depth 1 origin "$TPROXY_REF"
git -C "$UP/tproxy-server" checkout --quiet --detach --force FETCH_HEAD
[[ "$(git -C "$UP/tproxy-server" rev-parse HEAD)" == "$TPROXY_REF" ]]

if [[ ! -f "$UP/MTProxy/.commit" ]] || [[ "$(cat "$UP/MTProxy/.commit")" != "$MTPROXY_COMMIT" ]]; then
    tmp="$(mktemp -d)"
    curl -fsSL --proto '=https' --tlsv1.2 -o "$tmp/mtproxy.tar.gz" \
        "https://github.com/TelegramMessenger/MTProxy/archive/${MTPROXY_COMMIT}.tar.gz"
    echo "${MTPROXY_SHA256}  $tmp/mtproxy.tar.gz" | sha256sum -c - >/dev/null
    rm -rf "$UP/MTProxy"; mkdir -p "$UP/MTProxy"
    tar -C "$UP/MTProxy" --strip-components=1 -xzf "$tmp/mtproxy.tar.gz"
    echo "$MTPROXY_COMMIT" > "$UP/MTProxy/.commit"
    rm -rf "$tmp"
fi
echo "upstream: web-panel-proxy $WPP_UPSTREAM_TAG, tproxy-server ${TPROXY_REF:0:12}, MTProxy ${MTPROXY_COMMIT:0:12}"
