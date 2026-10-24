#!/usr/bin/env python3
"""WEB PANEL PROXY service agent: a small systemd stand-in for one container.

The panel keeps writing systemd unit files as it did on a VPS. Each container
runs this agent, which supervises the units it owns and answers the panel's
systemctl/journalctl shim over loopback (all containers share one network
namespace). Only a subset of systemd is implemented: what the panel uses.

Environment:
  WPP_AGENT_NAME     container role, used for the state file and log prefix
  WPP_AGENT_PORT     loopback API port
  WPP_AGENT_UNITS    space-separated globs of unit names owned by this agent;
                     static units live in /etc/wpp-agent/units, dynamic ones are
                     read from /etc/systemd/system (written by the panel)
  WPP_CONTROL_DIR    shared control directory with agent.token and state files
"""
import collections
import configparser
import fnmatch
import hmac
import json
import os
import re
import shlex
import signal
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

NAME = os.environ.get('WPP_AGENT_NAME', 'agent')
PORT = int(os.environ.get('WPP_AGENT_PORT', '9100'))
PATTERNS = os.environ.get('WPP_AGENT_UNITS', '').split()
STATIC_DIR = Path(os.environ.get('WPP_AGENT_STATIC_DIR', '/etc/wpp-agent/units'))
DYNAMIC_DIR = Path(os.environ.get('WPP_AGENT_DYNAMIC_DIR', '/etc/systemd/system'))
CONTROL = Path(os.environ.get('WPP_CONTROL_DIR', '/var/lib/wpp-control'))
TOKEN_FILE = CONTROL / 'agent.token'
STATE_FILE = CONTROL / f'{NAME}.state.json'
LOG_LINES = 400
MONO_US = lambda: int(time.monotonic() * 1_000_000)


def log(message):
    print(f'[{NAME}] {message}', flush=True)


def owned(unit):
    return any(fnmatch.fnmatchcase(unit, p) for p in PATTERNS)


def parse_unit(path):
    parser = configparser.RawConfigParser(strict=False, interpolation=None, empty_lines_in_values=False)
    parser.optionxform = str
    # systemd allows repeated keys; configparser keeps the last, which matches
    # how the panel's units use them (single ExecStart, single User).
    text = path.read_text(encoding='utf-8')
    parser.read_string(text, source=str(path))
    get = lambda s, k, d='': parser.get(s, k, fallback=d).strip()
    env = {}
    for line in text.splitlines():
        line = line.strip()
        if line.startswith('Environment='):
            for item in shlex.split(line[len('Environment='):]):
                if '=' in item:
                    k, v = item.split('=', 1)
                    env[k] = v
    return {
        'path': str(path),
        'mtime': path.stat().st_mtime_ns,
        'description': get('Unit', 'Description'),
        'condition_path': get('Unit', 'ConditionPathExists'),
        'type': get('Service', 'Type', 'simple'),
        'exec': get('Service', 'ExecStart'),
        'env': env,
        'env_file': get('Service', 'EnvironmentFile'),
        'workdir': get('Service', 'WorkingDirectory'),
        'restart': get('Service', 'Restart', 'no'),
        'restart_sec': float(re.sub(r'[^0-9.]', '', get('Service', 'RestartSec', '2')) or 2),
        'stop_sec': float(re.sub(r'[^0-9.]', '', get('Service', 'TimeoutStopSec', '10')) or 10),
        'user': get('Service', 'User', 'root'),
        'quiet': get('Service', 'StandardOutput') == 'null',
        'default_enabled': bool(get('Install', 'WantedBy')),
        'timer': None,
    }


def parse_timer(path):
    parser = configparser.RawConfigParser(strict=False, interpolation=None)
    parser.optionxform = str
    parser.read(path, encoding='utf-8')
    seconds = lambda v: sum(float(n) * {'s': 1, 'min': 60, 'm': 60, 'h': 3600, 'd': 86400}.get(u or 's', 1)
                            for n, u in re.findall(r'(\d+(?:\.\d+)?)\s*(min|s|m|h|d)?', v or ''))
    get = lambda k: parser.get('Timer', k, fallback='')
    return {
        'unit': get('Unit') or path.stem + '.service',
        'first': seconds(get('OnBootSec') or get('OnActiveSec')),
        'every': seconds(get('OnUnitActiveSec') or get('OnUnitInactiveSec')),
        'after_finish': bool(get('OnUnitInactiveSec')),
    }


def expand(command, env):
    """systemd command line: `$$` is a literal `$`, ${VAR} and $VAR come from the unit."""
    marker = '\0'
    command = command.replace('$$', marker)
    command = re.sub(r'\$\{([A-Za-z_][A-Za-z0-9_]*)\}', lambda m: env.get(m.group(1), ''), command)
    command = re.sub(r'\$([A-Za-z_][A-Za-z0-9_]*)', lambda m: env.get(m.group(1), ''), command)
    argv = shlex.split(command)
    return [a.replace(marker, '$') for a in argv]


class Unit:
    def __init__(self, name, spec):
        self.name, self.spec = name, spec
        self.proc = None
        self.state = 'inactive'      # inactive | activating | active | deactivating | failed
        self.result = 'success'
        self.exit_status = 0
        self.restarts = 0
        self.start_us = 0
        self.wanted = False          # supervisor should keep it running
        self.lines = collections.deque(maxlen=LOG_LINES)
        self.lock = threading.RLock()
        self.cond = threading.Condition(self.lock)
        self.generation = 0

    def note(self, line):
        stamp = time.strftime('%b %d %H:%M:%S')
        self.lines.append(f'{stamp} {NAME} {self.name}: {line}')
        print(f'[{NAME}:{self.name}] {line}', flush=True)

    def environment(self):
        env = {k: v for k, v in os.environ.items() if not k.startswith('WPP_AGENT_')}
        # As in systemd, EnvironmentFile= overrides Environment=.
        env.update(self.spec['env'])
        if self.spec['env_file']:
            optional = self.spec['env_file'].startswith('-')
            path = Path(self.spec['env_file'].lstrip('-'))
            try:
                for line in path.read_text(encoding='utf-8').splitlines():
                    line = line.strip()
                    if line and not line.startswith('#') and '=' in line:
                        k, v = line.split('=', 1)
                        env[k.strip()] = v.strip().strip('"')
            except OSError:
                if not optional:
                    raise
        return env

    def start(self):
        with self.lock:
            self.wanted = True
            if self.proc and self.proc.poll() is None:
                return True
            return self._spawn()

    def _spawn(self):
        cond = self.spec['condition_path']
        if cond:
            negate = cond.startswith('!')
            exists = Path(cond.lstrip('!')).exists()
            if exists == negate:
                self.state, self.result = 'inactive', 'success'
                self.note(f'condition {cond} not met, not starting')
                return True
        try:
            env = self.environment()
            argv = expand(self.spec['exec'], env)
            if not argv:
                raise ValueError('empty ExecStart')
            # StandardOutput=null drops stdout (periodic collectors); errors are kept.
            quiet = self.spec['quiet']
            self.proc = subprocess.Popen(
                argv, env=env, cwd=self.spec['workdir'] or None, stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL if quiet else subprocess.PIPE,
                stderr=subprocess.PIPE if quiet else subprocess.STDOUT, start_new_session=True)
        except Exception as exc:  # spawn failure behaves like an immediate exit
            self.state, self.result, self.exit_status = 'failed', 'exit-code', 203
            self.note(f'failed to start: {type(exc).__name__}: {exc}')
            self._schedule_restart()
            return False
        self.generation += 1
        self.state = 'active'
        self.result = 'success'
        self.start_us = MONO_US()
        threading.Thread(target=self._pump, args=(self.proc, self.generation), daemon=True).start()
        threading.Thread(target=self._wait, args=(self.proc, self.generation), daemon=True).start()
        return True

    def _pump(self, proc, generation):
        for raw in proc.stderr if proc.stdout is None else proc.stdout:
            self.note(raw.decode('utf-8', 'replace').rstrip())

    def _wait(self, proc, generation):
        code = proc.wait()
        with self.lock:
            if generation != self.generation:
                return
            self.exit_status = code
            self.proc = None
            stopping = not self.wanted
            if stopping or (code == 0 and self.spec['type'] == 'oneshot'):
                self.state, self.result = 'inactive', 'success'
            else:
                self.state = 'failed'
                self.result = 'exit-code' if code > 0 else 'signal'
                self.note(f'exited with status {code}')
            self.cond.notify_all()
            if not stopping:
                self._schedule_restart(code)

    def _schedule_restart(self, code=1):
        policy = self.spec['restart']
        if not self.wanted or policy == 'no' or (policy == 'on-failure' and code == 0):
            if code == 0 and self.spec['type'] == 'oneshot':
                self.wanted = False
            return
        self.state = 'activating'
        generation = self.generation
        def later():
            time.sleep(self.spec['restart_sec'])
            with self.lock:
                if self.wanted and generation == self.generation and self.proc is None:
                    self.restarts += 1
                    self._spawn()
        threading.Thread(target=later, daemon=True).start()

    def stop(self):
        with self.lock:
            self.wanted = False
            proc = self.proc
            if not proc:
                if self.state in ('activating', 'failed'):
                    self.state = 'inactive'
                self.generation += 1
                return
            self.state = 'deactivating'
            try:
                os.killpg(proc.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        try:
            proc.wait(timeout=self.spec['stop_sec'])
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.wait()
        with self.lock:
            self.state = 'inactive'

    def restart(self):
        self.stop()
        with self.lock:
            self.wanted = True
            return self._spawn()

    def kill(self, sig):
        with self.lock:
            if self.proc and self.proc.poll() is None:
                os.kill(self.proc.pid, sig)

    def run_oneshot(self, timeout=600):
        """systemctl start of a Type=oneshot unit blocks until it finishes."""
        self.start()
        deadline = time.monotonic() + timeout
        with self.lock:
            while self.proc is not None and time.monotonic() < deadline:
                self.cond.wait(timeout=1)
            return self.exit_status == 0

    def properties(self):
        with self.lock:
            pid = self.proc.pid if self.proc and self.proc.poll() is None else 0
            sub = {'active': 'running', 'activating': 'auto-restart', 'failed': 'failed',
                   'deactivating': 'stop-sigterm'}.get(self.state, 'dead')
            memory = tasks = ''
            if pid:
                memory = read_cgroup('memory.current')
                tasks = read_cgroup('pids.current')
            return {
                'Id': self.name, 'Description': self.spec['description'],
                'ActiveState': self.state, 'SubState': sub, 'Result': self.result,
                'MainPID': str(pid), 'ExecMainStatus': str(self.exit_status),
                'NRestarts': str(self.restarts), 'User': self.spec['user'],
                'ExecMainStartTimestampMonotonic': str(self.start_us if pid else 0),
                'MemoryCurrent': memory or '[not set]', 'TasksCurrent': tasks or '[not set]',
                'FragmentPath': self.spec['path'],
            }


def read_cgroup(name):
    try:
        return Path('/sys/fs/cgroup', name).read_text().strip()
    except OSError:
        return ''


class Agent:
    def __init__(self):
        self.units = {}
        self.timers = {}
        self.lock = threading.RLock()
        self.enabled = self._load_state()

    def _load_state(self):
        try:
            value = json.loads(STATE_FILE.read_text(encoding='utf-8'))
            return {'enabled': set(value.get('enabled', [])), 'disabled': set(value.get('disabled', []))}
        except (OSError, ValueError):
            return {'enabled': set(), 'disabled': set()}

    def _save_state(self):
        tmp = STATE_FILE.with_suffix('.tmp')
        tmp.write_text(json.dumps({k: sorted(v) for k, v in self.enabled.items()}), encoding='utf-8')
        os.chmod(tmp, 0o600)
        os.replace(tmp, STATE_FILE)

    def discover(self):
        found = {}
        for directory in (STATIC_DIR, DYNAMIC_DIR):
            if not directory.is_dir():
                continue
            for path in sorted(directory.glob('*.service')):
                if owned(path.name):
                    found[path.name] = path
        timers = {}
        if STATIC_DIR.is_dir():
            for path in STATIC_DIR.glob('*.timer'):
                timers[path.name] = parse_timer(path)
        return found, timers

    def daemon_reload(self):
        found, timers = self.discover()
        with self.lock:
            for name, path in found.items():
                try:
                    spec = parse_unit(path)
                except Exception as exc:
                    log(f'cannot parse {path}: {exc}')
                    continue
                if name in self.units:
                    self.units[name].spec = spec   # applies on next (re)start, like systemd
                else:
                    self.units[name] = Unit(name, spec)
            for name in list(self.units):
                if name not in found and not self.units[name].wanted:
                    del self.units[name]
            self.timers = timers

    def is_enabled(self, name):
        unit = self.units.get(name)
        if name in self.enabled['disabled']:
            return False
        return name in self.enabled['enabled'] or bool(unit and unit.spec['default_enabled'] and
                                                       unit.spec['path'].startswith(str(STATIC_DIR)))

    def set_enabled(self, name, value):
        with self.lock:
            (self.enabled['enabled'] if value else self.enabled['disabled']).add(name)
            (self.enabled['disabled'] if value else self.enabled['enabled']).discard(name)
            self._save_state()

    def boot(self):
        self.daemon_reload()
        for name, unit in list(self.units.items()):
            if self.is_enabled(name) and unit.spec['type'] != 'oneshot':
                unit.start()
        for timer in self.timers.values():
            threading.Thread(target=self._timer_loop, args=(timer,), daemon=True).start()

    def _timer_loop(self, timer):
        time.sleep(timer['first'] or timer['every'])
        while True:
            unit = self.units.get(timer['unit'])
            if unit:
                unit.run_oneshot(timeout=max(60, timer['every'] * 3))
            time.sleep(timer['every'] or 3600)

    def unit(self, name):
        with self.lock:
            unit = self.units.get(name)
            if unit is None:
                self.daemon_reload()
                unit = self.units.get(name)
            if unit is None:
                raise KeyError(name)
            return unit

    def action(self, verb, name, options):
        if verb == 'daemon-reload':
            self.daemon_reload()
            return {}
        if verb == 'reset-failed':
            if name in self.units and self.units[name].state == 'failed':
                self.units[name].state = 'inactive'
            return {}
        if verb == 'is-enabled':
            return {'enabled': name in self.units and self.is_enabled(name)}
        unit = self.unit(name)
        if verb in ('enable', 'disable'):
            self.set_enabled(name, verb == 'enable')
            if options.get('now'):
                unit.start() if verb == 'enable' else unit.stop()
        elif verb == 'start':
            ok = unit.run_oneshot() if unit.spec['type'] == 'oneshot' else unit.start()
            if not ok:
                raise RuntimeError(f'Job for {name} failed.')
        elif verb == 'stop':
            unit.stop()
        elif verb == 'restart':
            unit.restart()
        elif verb == 'try-restart':
            if unit.state in ('active', 'activating'):
                unit.restart()
        elif verb in ('reload', 'reload-or-restart'):
            unit.restart() if verb == 'reload-or-restart' or unit.state == 'active' else None
        elif verb == 'kill':
            unit.kill(getattr(signal, options.get('signal', 'SIGTERM'), signal.SIGTERM))
        elif verb == 'show':
            return {'properties': unit.properties()}
        elif verb == 'logs':
            lines = list(unit.lines)
            return {'lines': lines[-int(options.get('n', 50)):]}
        else:
            raise ValueError(f'unsupported verb {verb}')
        if verb in ('start', 'restart') and unit.spec['type'] != 'oneshot':
            # systemd returns once the process is started; report quick crashes.
            time.sleep(0.2)
            if unit.state == 'failed':
                raise RuntimeError(f'Job for {name} failed because the control process exited with error code.')
        return {}

    def list_units(self):
        with self.lock:
            return {name: {'state': u.state, 'enabled': self.is_enabled(name)} for name, u in self.units.items()}

    def shutdown(self):
        for unit in list(self.units.values()):
            unit.stop()


AGENT = Agent()


def token():
    try:
        return TOKEN_FILE.read_text(encoding='ascii').strip()
    except OSError:
        return ''


class Handler(BaseHTTPRequestHandler):
    server_version = 'wpp-agent'

    def log_message(self, *args):
        pass

    def reply(self, status, value):
        body = json.dumps(value).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        expected = token()
        if not expected or not hmac.compare_digest(self.headers.get('X-WPP-Token', ''), expected):
            return self.reply(403, {'error': 'forbidden'})
        try:
            request = json.loads(self.rfile.read(min(int(self.headers.get('Content-Length', 0)), 65536)) or b'{}')
            if self.path == '/v1/units':
                return self.reply(200, {'units': AGENT.list_units()})
            if self.path != '/v1/action':
                return self.reply(404, {'error': 'not found'})
            result = AGENT.action(request['verb'], request.get('unit', ''), request.get('options', {}))
            self.reply(200, result)
        except KeyError as exc:
            self.reply(404, {'error': f'Unit {exc.args[0]} not found.'})
        except Exception as exc:
            self.reply(500, {'error': str(exc)})


def main():
    CONTROL.mkdir(parents=True, exist_ok=True)
    log(f'waiting for {TOKEN_FILE} (created by the panel on first start)')
    while not token():
        time.sleep(1)
    server = ThreadingHTTPServer(('127.0.0.1', PORT), Handler)
    def stop(*_):
        log('stopping units')
        AGENT.shutdown()
        threading.Thread(target=server.shutdown, daemon=True).start()
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    AGENT.boot()
    log(f'listening on 127.0.0.1:{PORT}, units: {", ".join(sorted(AGENT.units)) or "none yet"}')
    server.serve_forever()


if __name__ == '__main__':
    sys.exit(main())
