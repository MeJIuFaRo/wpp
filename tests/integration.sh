#!/usr/bin/env bash
# Full stack on the build host from local images, without a public domain:
# first start, agents, WEB/MTProto clients through the panel manager, hot add
# without relay restart, traffic collection, restart of the whole stack.
#   tests/integration.sh [TAG]
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="${1:-$(sed -n 's/^WPP_VERSION=//p' "$ROOT/versions.env")}"
work="$(mktemp -d /tmp/wpp-it.XXXXXX)"
cp -a "$ROOT/deploy/." "$work/"
cd "$work"
cat > .env <<EOF
WPP_DOMAIN=wpp-it.example.net
WPP_ACME_EMAIL=wpp-it@example.net
WPP_PUBLIC_HOST=192.0.2.10
WPP_ADMIN_USER=admin
WPP_ADMIN_PASSWORD=
WPP_TAG=$TAG
EOF
dc() { docker compose -p wpp-it "$@"; }
cleanup() { dc down -t 5 >/dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; dc ps -a >&2; dc logs --tail 40 >&2; exit 1; }
step() { echo "--- $*"; }
ctl() { dc exec -T panel web-proxy-panelctl "$@"; }
sysd() { dc exec -T panel systemctl "$@"; }

step "install.sh"
./install.sh
step "compose up"
dc up -d --pull missing --wait --wait-timeout 180 panel relay backends mtproto xray openflux || fail "stack did not start"
dc up -d --pull missing caddy
for unit in tproxy-panel tproxy-server mtproxy; do
    sysd is-active --quiet "$unit" || fail "$unit is not active"
done
echo "units active: tproxy-panel tproxy-server mtproxy"
grep -q 'Password:' <<<"$(dc logs panel 2>&1)" || fail "no first-start banner"
[[ -s data/panel/initial-admin-password ]] || fail "generated password was not saved"
grep -q 'max_profiles": 128' config/relay/config.json || fail "relay limit"
dc exec -T panel caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 \
    || echo "note: caddy validate in the panel needs XDG dirs; checked at first start"

step "panel answers"
code="$(dc exec -T panel curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:8090$(sed -n 's/^WEBPROXY_PANEL_PATH=//p' config/panel/panel.env)/login")"
[[ "$code" == 200 ]] || fail "panel login page HTTP $code"
echo "login page: HTTP 200"

step "WEB client: hot add without restarting the relay"
relay_pid="$(sysd show -p MainPID --value tproxy-server.service)"
web="$(ctl add web it-web)" || fail "add web"
uid="$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["id"])' "$web")"
port="$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["backend_port"])' "$web")"
sysd is-active --quiet "web-proxy-user-$uid.service" || fail "user backend not active"
dc exec -T panel ss -Hlnt "sport = :$port" | grep -q . || fail "backend port $port not listening"
[[ "$(sysd show -p MainPID --value tproxy-server.service)" == "$relay_pid" ]] || fail "relay restarted on hot add"
echo "backend :$port active, relay PID unchanged ($relay_pid)"

step "MTProto client on shared 8443"
mt="$(ctl add mtproto it-mt)" || fail "add mtproto"
mt_id="$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["id"])' "$mt")"
mt_secret="$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["secret"])' "$mt")"
sysd is-active --quiet web-panel-proxy-mtproto.service || fail "shared MTProto not active"
dc exec -T panel ss -Hlnt "sport = :8443" | grep -q . || fail "8443 not listening"
dc exec -T panel curl -fsS http://127.0.0.1:8890/stats | grep -q '^wpp_client_read_bytes' || fail "no client byte counters"
echo "web-panel-proxy-mtproto active, 8443 listening, client counters present"

step "MTProto handshake counted for its own client"
ok=0
for _ in 1 2 3 4 5 6 7 8; do
    python3 -c "import sys; sys.path.insert(0,'$ROOT/tests'); import probe_mt; probe_mt.probe('127.0.0.1',8443,'$mt_secret')" 2>/dev/null && { ok=1; break; }
    sleep 3
done
[[ "$ok" == 1 ]] || fail "no resPQ on 8443"
ctl traffic | python3 -c 'import json,sys;d=json.load(sys.stdin);k=d.get(sys.argv[1],{});m=d["mtproto_shared"];assert k.get("up",0)>0 and k.get("down",0)>0,k;print("client:",k["up"],"/",k["down"],"bytes; port total:",m["up"],"/",m["down"])' "$mt_id" \
    || fail "per-client MTProto traffic"

step "traffic collection"
ctl traffic | python3 -c 'import json,sys;d=json.load(sys.stdin);assert "mtproto_shared" in d and "primary" in d,d.keys();print("traffic keys:",", ".join(sorted(d)))' \
    || fail "traffic"

step "service status through the systemctl shim"
for unit in caddy tproxy-server mtproxy web-panel-proxy-mtproto web-panel-proxy-xray web-panel-proxy-openflux; do
    printf '%-28s %s\n' "$unit" "$(sysd is-active "$unit" || true)"
done

step "restart of the whole stack keeps clients"
dc down -t 10 >/dev/null
dc up -d --pull missing --wait --wait-timeout 180 panel relay backends mtproto xray openflux || fail "stack did not restart"
sleep 3
sysd is-active --quiet "web-proxy-user-$uid.service" || fail "WEB client backend lost after restart"
sysd is-active --quiet web-panel-proxy-mtproto.service || fail "shared MTProto lost after restart"
ctl users | python3 -c 'import json,sys;names=sorted(u["name"] for u in json.load(sys.stdin)["users"]);assert names==["it-mt","it-web"],names;print("users:",names)'

step "delete WEB client"
ctl delete "$uid" >/dev/null || fail "delete"
sysd is-active --quiet "web-proxy-user-$uid.service" && fail "backend still active after delete"
[[ ! -e "config/units/web-proxy-user-$uid.service" ]] || fail "unit file left behind"
echo "deleted"
echo "ALL OK"
