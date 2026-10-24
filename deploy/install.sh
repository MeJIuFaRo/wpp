#!/usr/bin/env bash
# Prepare ./config and ./data for the containers (UID/GID 10000) and check
# the host. Safe to run again: existing files are kept.
set -Eeuo pipefail
cd "$(dirname "$0")"
die() { echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root (needed to give the directories to UID 10000)"
command -v docker >/dev/null || die "Docker is not installed"
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required"
[[ "$(uname -m)" == x86_64 ]] || die "x86_64 is required"
[[ -f .env ]] || { cp .env.example .env; chmod 0600 .env; die "edit .env (WPP_DOMAIN, WPP_ACME_EMAIL) and run ./install.sh again"; }
set -a; . ./.env; set +a
[[ "${WPP_DOMAIN:-}" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ && "$WPP_DOMAIN" == *.* && "$WPP_DOMAIN" != proxy.example.com ]] ||
    die "set WPP_DOMAIN in .env"
[[ "${WPP_ACME_EMAIL:-}" != admin@example.com ]] || die "set WPP_ACME_EMAIL in .env or leave it empty"
chmod 0600 .env

for port in 80 443 8443; do
    if ss -Hlnt "sport = :$port" | grep -q . && ! docker compose ps -q net 2>/dev/null | grep -q .; then
        die "TCP port $port is already in use on this host"
    fi
done
if ss -Hlnu "sport = :8443" | grep -q . && ! docker compose ps -q net 2>/dev/null | grep -q .; then
    die "UDP port 8443 is already in use on this host"
fi

dirs=(config/control config/panel config/panel/openflux config/units config/relay config/mtproxy
      config/xray config/xray/tls config/caddy config/site
      data/panel data/caddy data/caddy/caddy data/caddy-config data/xray data/openflux)
for d in "${dirs[@]}"; do install -d -m 0750 "$d"; done
chown -R 10000:10000 config data
chmod 0700 config/control config/panel data/panel

ip="$(getent ahostsv4 "$WPP_DOMAIN" | awk 'NR==1{print $1}' || true)"
[[ -n "$ip" ]] && echo "DNS: $WPP_DOMAIN -> $ip" || echo "WARNING: no A record for $WPP_DOMAIN yet; HTTPS will not start until it exists"
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q 'Status: active'; then
    echo "NOTE: Docker publishes ports past UFW; 80/443/8443 will be reachable regardless of UFW rules."
fi
echo "Ready. Start with: docker compose up -d && docker compose logs -f panel"
