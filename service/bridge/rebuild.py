#!/opt/homebrew/opt/python@3.13/bin/python3.13
"""Rebuild the Rehabit Bridge database from the app's export file.

launchd runs this whenever a watched folder changes (see install.sh). It finds
the newest export among `export_paths` in config.json, skips the work if that
exact file was already built, and otherwise runs `rehabit build` into a
temporary file that is renamed into place, so the server never opens a
half-built database. Only counts and times are logged, never records.
"""
from __future__ import annotations

import contextlib
import fcntl
import glob
import hashlib
import io
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
for candidate in (HERE, os.path.dirname(HERE)):
    if os.path.isdir(os.path.join(candidate, 'rehabit')):
        sys.path.insert(0, candidate)
        break
sys.path.insert(0, HERE)

from bridge_core import write_private  # noqa: E402

DEFAULT_EXPORTS = [
    # The app's own iCloud Drive folder.
    '~/Library/Mobile Documents/iCloud~com~gabrielprice~rehabit/Documents/rehabit-export.json',
    # Or a folder chosen in the app's Settings, anywhere in iCloud Drive.
    '~/Library/Mobile Documents/com~apple~CloudDocs/Rehabit/rehabit-export.json',
    # Or the top of iCloud Drive itself, which is what picking "iCloud Drive"
    # without opening a folder gives.
    '~/Library/Mobile Documents/com~apple~CloudDocs/rehabit-export.json',
]


def load_config(path: str) -> dict:
    with open(path, encoding='utf-8') as f:
        cfg = json.load(f)
    here = os.path.dirname(path)
    cfg.setdefault('db_path', os.path.join(here, 'data', 'rehabit.db'))
    cfg.setdefault('meta_path', os.path.join(here, 'data', 'build.json'))
    cfg.setdefault('rebuild_log', os.path.join(here, 'data', 'rebuild.log'))
    cfg.setdefault('export_paths', DEFAULT_EXPORTS)
    return cfg


def log(cfg: dict, line: str) -> None:
    os.makedirs(os.path.dirname(cfg['rebuild_log']), exist_ok=True)
    with open(cfg['rebuild_log'], 'a', encoding='utf-8') as f:
        f.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S%z')} {line}\n")


def newest_export(patterns: list[str]) -> str | None:
    found = []
    for pattern in patterns:
        found += [p for p in glob.glob(os.path.expanduser(pattern)) if os.path.isfile(p)]
    return max(found, key=os.path.getmtime) if found else None


def read_export(path: str) -> bytes:
    """The file's bytes. iCloud may keep only a placeholder on the Mac; ask for
    the real file and wait a little for it."""
    for attempt in range(6):
        try:
            with open(path, 'rb') as f:
                data = f.read()
            json.loads(data)
            return data
        except (OSError, ValueError):
            if attempt == 0:
                subprocess.run(['/usr/bin/brctl', 'download', path], capture_output=True, timeout=30)
            time.sleep(2 + attempt * 2)
    raise ValueError('the export file could not be read as JSON')


def rebuild(config_path: str, force: bool = False) -> dict:
    cfg = load_config(config_path)
    data_dir = os.path.dirname(cfg['db_path'])
    os.makedirs(data_dir, mode=0o700, exist_ok=True)
    with open(os.path.join(data_dir, '.rebuild.lock'), 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        source = newest_export(cfg['export_paths'])
        if not source:
            log(cfg, 'no export file found yet')
            return {'status': 'no export'}
        try:
            data = read_export(source)
        except ValueError as e:
            log(cfg, f'skipped: {e}')
            return {'status': 'unreadable'}
        digest = hashlib.sha256(data).hexdigest()
        try:
            with open(cfg['meta_path'], encoding='utf-8') as f:
                previous = json.load(f)
        except (OSError, ValueError):
            previous = {}
        if not force and previous.get('export_sha256') == digest and os.path.exists(cfg['db_path']):
            return {'status': 'unchanged'}

        # Work from a private copy, so a sync landing mid-build cannot mix two exports.
        snapshot = os.path.join(data_dir, 'app-export.json')
        write_private(snapshot, data.decode('utf-8'))
        building = cfg['db_path'] + '.building'
        for leftover in (building, building + '-journal', building + '-wal'):
            with contextlib.suppress(FileNotFoundError):
                os.remove(leftover)
        from rehabit import cli
        out = io.StringIO()
        argv = ['build', '--db', building, '--app-export', snapshot]
        if cfg.get('doestrack_backup') and os.path.exists(os.path.expanduser(cfg['doestrack_backup'])):
            argv += ['--doestrack', os.path.expanduser(cfg['doestrack_backup'])]
        started = time.time()
        with contextlib.redirect_stdout(out):
            cli.main(argv)
        summary = json.loads(out.getvalue() or '{}')
        os.chmod(building, 0o600)
        os.replace(building, cfg['db_path'])

        exported = json.loads(data).get('exportedAt')
        app = summary.get('app') or {}
        meta = {
            'export_sha256': digest,
            'export_written_at': exported,
            'export_file_modified_at': datetime.fromtimestamp(os.path.getmtime(source), timezone.utc).isoformat(timespec='seconds'),
            'rebuilt_at': datetime.now(timezone.utc).isoformat(timespec='seconds'),
            'source': 'app folder' if 'iCloud~' in source else 'chosen folder',
            'sessions': app.get('sessions'),
            'sets': app.get('sets'),
        }
        write_private(cfg['meta_path'], json.dumps(meta, indent=2, sort_keys=True) + '\n')
        log(cfg, f"rebuilt from the {meta['source']} in {time.time() - started:.1f}s: "
                 f"{meta['sessions']} sessions, {meta['sets']} sets")
        return {'status': 'rebuilt', **meta}


if __name__ == '__main__':
    path = os.environ.get('BRIDGE_CONFIG') or os.path.join(HERE, 'config.json')
    result = rebuild(path, force='--force' in sys.argv)
    print(json.dumps({k: result.get(k) for k in ('status', 'sessions', 'sets', 'rebuilt_at')}))
