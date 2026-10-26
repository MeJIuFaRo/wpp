#!/usr/bin/env bash
# Start wpp-openflux with a unit in the form the panel writes and a dummy
# Yandex document: the core must accept every flag, run unprivileged and keep
# its state in /var/lib/wpp-openflux/<profile>. A real tunnel needs a real
# document and a client, see docs/ARCHITECTURE.md.
#   tests/smoke-openflux.sh IMAGE
set -Eeuo pipefail
image="$1"
dir="$(mktemp -d)"; name="wpp-smoke-openflux-$$"
trap 'docker rm -f "$name" >/dev/null 2>&1; rm -rf "$dir"' EXIT
mkdir -p "$dir/control" "$dir/units" "$dir/openflux" "$dir/state"
head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$dir/control/agent.token"
echo 'https://disk.yandex.ru/i/wpp-smoke-test' > "$dir/openflux/document-url"
head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$dir/openflux/encryption-key"
echo enabled > "$dir/openflux/enabled"
state=/var/lib/wpp-openflux/main
cat > "$dir/units/web-panel-proxy-openflux.service" <<EOF
[Unit]
Description=WEB PANEL PROXY OpenFlux exit node
ConditionPathExists=/etc/web-proxy-panel/openflux/enabled

[Service]
Type=simple
ExecStart=/bin/sh -c 'mkdir -p $state && cd $state && exec /opt/web-panel-proxy/openflux/openflux --role=exit --mode=l4 --codec=batched --transport=yandex --cookie-store=$state/cookies.json --url "\$\$(cat /etc/web-proxy-panel/openflux/document-url)" --encryption-key-file=/etc/web-proxy-panel/openflux/encryption-key'
Restart=on-failure
RestartSec=4

[Install]
WantedBy=multi-user.target
EOF
echo '{"enabled":["web-panel-proxy-openflux.service"],"disabled":[]}' > "$dir/control/openflux.state.json"
chmod 0600 "$dir/control/agent.token"
chown -R 10000:10000 "$dir"
docker run -d --name "$name" --init --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges \
    -v "$dir/control:/var/lib/wpp-control" -v "$dir/units:/etc/systemd/system:ro" \
    -v "$dir/openflux:/etc/web-proxy-panel/openflux:ro" -v "$dir/state:/var/lib/wpp-openflux" \
    "$image" >/dev/null
sleep 12
logs="$(docker logs "$name" 2>&1)"
echo "$logs" | grep 'web-panel-proxy-openflux' | tail -8
if echo "$logs" | grep -qiE 'flag provided but not defined|unknown flag|usage of'; then
    echo "FAIL: the core rejected a flag"; exit 1
fi
version="$(docker exec "$name" /opt/web-panel-proxy/openflux/openflux --version 2>&1 | head -1 || true)"
echo "version: ${version:-?}"
[[ -d "$dir/state/main" ]] || { echo "FAIL: state directory was not created"; exit 1; }
echo "state:   $(ls -A "$dir/state/main" | tr '\n' ' ')(directory exists, owner $(stat -c %u "$dir/state/main"))"
docker exec "$name" sh -c 'ps -o user=,args= 2>/dev/null || true' | grep -m1 openflux || true
echo "user:    $(docker exec "$name" id -u)"
