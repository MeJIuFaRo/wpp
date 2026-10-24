#!/usr/bin/env bash
# Start wpp-relay alone with a throwaway config and check the agent API,
# relay health and per-profile metrics. Usage: tests/smoke-relay.sh IMAGE
set -Eeuo pipefail
image="$1"
dir="$(mktemp -d)"; name="wpp-smoke-relay-$$"
trap 'docker rm -f "$name" >/dev/null 2>&1; rm -rf "$dir"' EXIT
mkdir -p "$dir/control" "$dir/relay" "$dir/site"
head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$dir/control/agent.token"
echo '<!doctype html><title>ok</title>' > "$dir/site/index.html"
cat > "$dir/relay/config.json" <<'EOF'
{"public_hostname":"example.test","listen":"127.0.0.1:8080","admin_listen":"127.0.0.1:8081",
 "public_dir":"/srv/tproxy-site","profiles_file":"/etc/tproxy-server/profiles.json","limits":{"max_profiles":128}}
EOF
echo '{"profiles":[{"name":"default","secret":"000102030405060708090a0b0c0d0e0f","backend":"127.0.0.1:2398","carrier_mode":"https"}]}' \
    > "$dir/relay/profiles.json"
chmod 0600 "$dir/control/agent.token" "$dir/relay/profiles.json"
chown -R 10000:10000 "$dir"
docker run -d --name "$name" --init \
    -v "$dir/control:/var/lib/wpp-control" -v "$dir/relay:/etc/tproxy-server:ro" -v "$dir/site:/srv/tproxy-site:ro" \
    "$image" >/dev/null
token="$(cat "$dir/control/agent.token")"
api() { docker exec "$name" python3 -c '
import json,sys,urllib.request
r=urllib.request.Request("http://127.0.0.1:9101/v1/action",data=sys.argv[2].encode(),headers={"X-WPP-Token":sys.argv[1]})
print(urllib.request.urlopen(r,timeout=10).read().decode())' "$token" "$1"; }
fetch() { docker exec "$name" python3 -c 'import sys,urllib.request;print(urllib.request.urlopen(sys.argv[1],timeout=5).read().decode())' "$1"; }
for _ in $(seq 1 20); do fetch http://127.0.0.1:8081/healthz >/dev/null 2>&1 && break; sleep 0.5; done
echo "healthz: $(fetch http://127.0.0.1:8081/healthz)"
echo "show:    $(api '{"verb":"show","unit":"tproxy-server.service"}' | python3 -c 'import json,sys;p=json.load(sys.stdin)["properties"];print(p["ActiveState"],p["SubState"],"pid",p["MainPID"])')"
api '{"verb":"restart","unit":"tproxy-server.service"}' >/dev/null
sleep 1
echo "restart: $(api '{"verb":"show","unit":"tproxy-server.service"}' | python3 -c 'import json,sys;p=json.load(sys.stdin)["properties"];print(p["ActiveState"],"pid",p["MainPID"])')"
echo "metrics: $(fetch http://127.0.0.1:8081/metrics | grep -c '^tproxy_') tproxy_* lines"
echo "logs:"; api '{"verb":"logs","unit":"tproxy-server.service","options":{"n":5}}' | python3 -c 'import json,sys;print("\n".join(json.load(sys.stdin)["lines"]))'
code="$(docker exec "$name" python3 -c '
import urllib.request,urllib.error
try: urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:9101/v1/action",data=b"{}",headers={"X-WPP-Token":"bad"}),timeout=5)
except urllib.error.HTTPError as e: print(e.code)')"
echo "bad token -> HTTP $code"
[[ "$code" == 403 ]]
echo "user: $(docker exec "$name" id -u)"
