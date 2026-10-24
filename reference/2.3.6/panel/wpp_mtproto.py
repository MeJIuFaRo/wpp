"""One MTProxy listener with independently revocable keys. Caller holds manager.lock."""
import os
import re
import subprocess
import time
from pathlib import Path

SERVICE = 'web-panel-proxy-mtproto.service'
UNIT = Path('/etc/systemd/system') / SERVICE
PORT = 8443
STATS = 8890
LIMIT = 64
LIMIT_MESSAGE = 'WPP_MT_LIMIT: Максимум 64 активных MTProto-ключей на порту 8443. Отключите один из клиентов.'


def profiles(data):
    return [u for u in data.get('users', []) if u.get('protocol') == 'mtproto']


def validate(data):
    active = [u for u in profiles(data) if u.get('enabled', True)]
    if len(active) > LIMIT:
        raise ValueError(LIMIT_MESSAGE)
    if any(not re.fullmatch(r'[0-9a-f]{32}', u.get('secret', '')) for u in active):
        raise ValueError('Invalid MTProto key format')
    if len({u['secret'] for u in active}) != len(active):
        raise ValueError('Duplicate MTProto keys')
    return sorted(active, key=lambda u: u['id'])


def run(*args, check=True):
    p = subprocess.run(args, capture_output=True, text=True, timeout=20)
    if check and p.returncode:
        # Never surface systemctl's ExecStart (contains keys) in panel errors.
        raise RuntimeError('Shared MTProto service operation failed: ' + args[0])
    return p


def unit_text(data):
    active = validate(data)
    keys = ' '.join('-S ' + u['secret'] for u in active)
    return f'''[Unit]
Description=WEB PANEL PROXY shared MTProto TCP 8443
After=network-online.target web-proxy-panel-firewall.service
Wants=network-online.target
Requires=web-proxy-panel-firewall.service

[Service]
Type=simple
User=root
Group=root
ExecStart=/opt/web-panel-proxy/mtproto-shared/mtproto-proxy -u nobody -p {STATS} -H {PORT} {keys} --aes-pwd /etc/mtproxy/proxy-secret /etc/mtproxy/proxy-multi.conf -M 1
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
'''


def ready():
    if run('systemctl', 'is-active', '--quiet', SERVICE, check=False).returncode:
        return False
    pid = run('systemctl', 'show', SERVICE, '-p', 'MainPID', '--value').stdout.strip()
    sockets = run('ss', '-Hlntp', 'sport = :8443').stdout
    return pid != '0' and re.search(r'\bpid=' + re.escape(pid) + r'\b', sockets) is not None


def sync(data):
    active = validate(data)
    if not active:
        if UNIT.exists():
            run('systemctl', 'disable', '--now', SERVICE)
        # No disabled/revoked keys remain in the unit on disk.
        text = unit_text(data)
    else:
        text = unit_text(data)
    changed = not UNIT.exists() or UNIT.read_text() != text
    if changed:
        tmp = UNIT.with_suffix('.service.tmp')
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, 'w') as f:
            f.write(text)
        os.chmod(tmp, 0o600)
        os.replace(tmp, UNIT)
        run('systemctl', 'daemon-reload')
    if active:
        run('systemctl', 'enable', SERVICE)
        if changed or not ready():
            run('systemctl', 'restart', SERVICE)
        for _ in range(30):
            if ready():
                return
            time.sleep(0.1)
        raise RuntimeError('Shared MTProto listener 8443 did not become ready')


def change(before, after, save):
    validate(after)
    try:
        sync(after)
        save(after)
    except Exception:
        sync(before)
        save(before)
        raise


def connection_count():
    p = run('ss', '-Hnt', 'state', 'established', 'sport = :8443', check=False)
    return len(p.stdout.splitlines()) if p.returncode == 0 else None
