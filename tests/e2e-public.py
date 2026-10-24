#!/usr/bin/env python3
"""End-to-end test of a deployed stack through its public address.

Run on the server next to docker-compose.yaml:
  python3 tests/e2e-public.py DOMAIN PUBLIC_IP
Needs python3-cryptography. Creates clients named e2e-* and deletes them.
Never prints keys or links.
"""
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_mt
import probe_web

DOMAIN, PUBLIC_IP = sys.argv[1], sys.argv[2]
created = []


def ctl(*args):
    out = subprocess.run(['docker', 'compose', 'exec', '-T', 'panel', 'web-proxy-panelctl', *args],
                         capture_output=True, text=True, timeout=240)
    if out.returncode:
        raise RuntimeError(f'panelctl {args[0]} failed: {out.stderr.strip()[-400:]}')
    return out.stdout


def add(protocol, name):
    user = json.loads(ctl('add', protocol, name).strip().splitlines()[-1])
    created.append(user['id'])
    return user


def panel(*args):
    return subprocess.run(['docker', 'compose', 'exec', '-T', 'panel', *args],
                          capture_output=True, text=True, timeout=60)


def active(unit):
    return panel('systemctl', 'is-active', '--quiet', unit).returncode == 0


def check(label, condition):
    print(f'{"OK  " if condition else "FAIL"} {label}', flush=True)
    if not condition:
        raise SystemExit(1)


try:
    relay_pid = panel('systemctl', 'show', '-p', 'MainPID', '--value', 'tproxy-server.service').stdout.strip()
    web1 = add('web', 'e2e-web1')
    session = probe_web.WebProbe(web1['secret'], DOMAIN)
    check('WEB Proxy: MTProto resPQ through https://' + DOMAIN, session.exchange())

    web2 = add('web', 'e2e-web2')
    check('open WEB session keeps working after adding another client', session.exchange())
    now_pid = panel('systemctl', 'show', '-p', 'MainPID', '--value', 'tproxy-server.service').stdout.strip()
    check('relay was not restarted by the hot add', now_pid == relay_pid)
    second = probe_web.WebProbe(web2['secret'], DOMAIN)
    check('new WEB client works', second.exchange())
    second.close()
    session.close()

    mt = add('mtproto', 'e2e-mt')
    ok = False
    for _ in range(10):
        try:
            ok = probe_mt.probe(PUBLIC_IP, 8443, mt['secret'])
            break
        except Exception:
            time.sleep(2)
    check(f'MTProto: resPQ through {PUBLIC_IP}:8443', ok)

    time.sleep(12)  # the traffic collector runs every 10 seconds
    traffic = json.loads(ctl('traffic'))
    w = traffic.get(web1['id'], {})
    m = traffic.get('mtproto_shared', {})
    check(f'traffic counted for the WEB client (up {w.get("up", 0)} B, down {w.get("down", 0)} B)',
          w.get('up', 0) > 0 and w.get('down', 0) > 0)
    check(f'traffic counted for shared MTProto (up {m.get("up", 0)} B, down {m.get("down", 0)} B)',
          m.get('up', 0) > 0 and m.get('down', 0) > 0)
    k = traffic.get(mt['id'], {})
    check(f'traffic counted for the MTProto client itself (up {k.get("up", 0)} B, down {k.get("down", 0)} B)',
          k.get('up', 0) > 0 and k.get('down', 0) > 0 and k.get('up', 0) <= m.get('up', 0))

    add('vless', 'e2e-vless')
    check('VLESS: Xray active', active('web-panel-proxy-xray.service'))
    check('VLESS: Xray listens on 127.0.0.1:10000',
          bool(panel('ss', '-Hlnt', 'sport = :10000').stdout.strip()))

    add('hysteria', 'e2e-hy2')
    check('Hysteria2: certificate copied to Xray',
          panel('test', '-s', '/etc/web-panel-proxy-xray/tls/domain.crt').returncode == 0)
    check('Hysteria2: UDP 8443 listening', bool(panel('ss', '-Hlnu', 'sport = :8443').stdout.strip()))
    print('ALL OK')
finally:
    for uid in reversed(created):
        try:
            ctl('delete', uid)
        except Exception as exc:
            print(f'cleanup: {exc}', file=sys.stderr)
    if created:
        print(f'cleanup: {len(created)} test clients deleted')
