#!/usr/bin/env bash
# Start wpp-mtproxy in the shared MTProto role with two keys, run a real
# MTProto handshake with Telegram for each key and check the client byte
# counters in /stats. Usage: tests/smoke-mtproxy.sh IMAGE
set -Eeuo pipefail
image="$1"
here="$(cd "$(dirname "$0")" && pwd)"
dir="$(mktemp -d)"; name="wpp-smoke-mtproto-$$"; port=18443
trap 'docker rm -f "$name" >/dev/null 2>&1; rm -rf "$dir"' EXIT
mkdir -p "$dir/control" "$dir/mtproxy" "$dir/units"
head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$dir/control/agent.token"
curl -fsS -o "$dir/mtproxy/proxy-secret" https://core.telegram.org/getProxySecret
curl -fsS -o "$dir/mtproxy/proxy-multi.conf" https://core.telegram.org/getProxyConfig
k1="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
k2="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
cat > "$dir/units/web-panel-proxy-mtproto.service" <<EOF
[Unit]
Description=WEB PANEL PROXY shared MTProto TCP 8443

[Service]
Type=simple
User=root
ExecStart=/opt/web-panel-proxy/mtproto-shared/mtproto-proxy -u nobody -p 8890 --http-stats -H 8443 -S $k1 -S $k2 --aes-pwd /etc/mtproxy/proxy-secret /etc/mtproxy/proxy-multi.conf -M 1
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
echo '{"enabled":["web-panel-proxy-mtproto.service"],"disabled":[]}' > "$dir/control/mtproto.state.json"
chmod 0600 "$dir/control/agent.token" "$dir/units/"*
chown -R 10000:10000 "$dir"
docker run -d --name "$name" --init -p "127.0.0.1:$port:8443" \
    -e WPP_AGENT_NAME=mtproto -e WPP_AGENT_PORT=9103 -e WPP_AGENT_UNITS=web-panel-proxy-mtproto.service \
    -v "$dir/control:/var/lib/wpp-control" -v "$dir/mtproxy:/etc/mtproxy:ro" -v "$dir/units:/etc/systemd/system:ro" \
    "$image" >/dev/null
stats() { docker exec "$name" python3 -c 'import urllib.request;print(urllib.request.urlopen("http://127.0.0.1:8890/stats",timeout=5).read().decode())'; }
for _ in $(seq 1 30); do stats >/dev/null 2>&1 && break; sleep 1; done
before="$(stats | grep '^wpp_client_' | tr '\n' ' ')"
echo "before:  $before"
for key in "$k1" "$k2"; do
    ok=0
    for attempt in 1 2 3 4 5; do
        if python3 -c "import sys; sys.path.insert(0,'$here'); import probe_mt; probe_mt.probe('127.0.0.1',$port,'$key')" 2>/dev/null; then ok=1; break; fi
        sleep 2   # MTProxy connects to Telegram DCs shortly after start
    done
    [[ "$ok" == 1 ]] || { echo "FAIL: no resPQ for a key"; docker logs --tail 30 "$name"; exit 1; }
    echo "resPQ:   ok"
done
after="$(stats | grep '^wpp_client_' | tr '\n' ' ')"
echo "after:   $after"
read_after="$(stats | awk -F'\t' '$1=="wpp_client_read_bytes"{print $2}')"
write_after="$(stats | awk -F'\t' '$1=="wpp_client_write_bytes"{print $2}')"
(( read_after > 0 && write_after > 0 )) || { echo "FAIL: client byte counters did not grow"; exit 1; }

# Per-key counters: two more handshakes with the first key only.
for _ in 1 2; do
    python3 -c "import sys; sys.path.insert(0,'$here'); import probe_mt; probe_mt.probe('127.0.0.1',$port,'$k1')"
done
sleep 1
key_id() { python3 -c "import hashlib,sys;print(hashlib.sha256(bytes.fromhex(sys.argv[1])).hexdigest()[:16])" "$1"; }
value() { stats | awk -F'\t' -v k="$1" '$1==k{print $2}'; }
h1="$(key_id "$k1")"; h2="$(key_id "$k2")"
r1="$(value "wpp_key_${h1}_read_bytes")"; w1="$(value "wpp_key_${h1}_write_bytes")"
r2="$(value "wpp_key_${h2}_read_bytes")"; w2="$(value "wpp_key_${h2}_write_bytes")"
total_r="$(value wpp_client_read_bytes)"; total_w="$(value wpp_client_write_bytes)"
echo "key 1:   read $r1, write $w1 (3 handshakes)"
echo "key 2:   read $r2, write $w2 (1 handshake)"
echo "total:   read $total_r, write $total_w"
[[ -n "$r1" && -n "$r2" ]] || { echo "FAIL: per-key counters missing"; exit 1; }
(( r2 > 0 && w2 > 0 && r1 > r2 && w1 > w2 )) || { echo "FAIL: per-key counters do not match the handshakes"; exit 1; }
(( r1 + r2 <= total_r && w1 + w2 <= total_w )) || { echo "FAIL: per-key sum exceeds the total"; exit 1; }
stats | grep -qiE "$k1|$k2" && { echo "FAIL: /stats exposes a key"; exit 1; }
echo "user:    $(docker exec "$name" id -u)"
