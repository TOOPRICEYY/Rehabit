"""End-to-end checks for Rehabit Bridge, with no network beyond 127.0.0.1.

    /opt/homebrew/opt/python@3.13/bin/python3.13 -m unittest service/bridge/test_bridge.py

Each test runs in its own temporary folder with a throwaway passcode that is
generated here and never written anywhere else.
"""
from __future__ import annotations

import base64
import hashlib
import json
import os
import secrets
import shutil
import socket
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))

import rebuild  # noqa: E402
import server  # noqa: E402

CALLBACK = 'https://claude.ai/api/mcp/auth_callback'


def export(**changes) -> dict:
    """A small export in the shape the app writes."""
    data = {
        "schemaVersion": 1, "exportedAt": "2026-11-17T15:00:00.000Z",
        "profile": {"bodyweightKg": 80.0, "unit": "lb"},
        "workouts": [{"id": "W1", "title": "Legs", "start": "2026-11-10T22:00:00.000Z",
                      "end": "2026-11-10T22:45:00.000Z", "startDay": "2026-11-10", "notes": "",
                      "updatedAt": "2026-11-10T22:45:00.000Z"}],
        "sets": [{"id": f"S{i}", "workoutID": "W1", "workoutDay": "2026-11-10", "position": i,
                  "exercise": "Single-Leg Extension (Machine)", "pattern": "leg_extension",
                  "side": side, "kind": "reps", "reps": 10, "loadValue": load, "loadUnit": "lb",
                  "convention": "total", "isWarmup": False, "notes": "",
                  "updatedAt": "2026-11-10T22:10:00.000Z"}
                 for i, (side, load) in enumerate([("left", 15), ("right", 25)])],
        "injuries": [{"id": "I1", "label": "Left quad", "side": "left", "onset": "2026-10-01",
                      "onsetPrecision": "day", "tissues": ["quads"], "mechanism": "", "notes": "",
                      "updatedAt": "2026-10-02T00:00:00.000Z"}],
        "painChecks": [{"id": "P1", "injuryID": "I1", "workoutID": "W1", "moment": "after_session",
                        "dueAt": "2026-11-10T22:45:00.000Z", "dueDay": "2026-11-10",
                        "answeredAt": "2026-11-10T22:50:00.000Z", "pain": 2.0, "painType": "ache",
                        "notes": "", "updatedAt": "2026-11-10T22:50:00.000Z"}],
        "dailyMetrics": [], "tombstones": [],
    }
    data.update(changes)
    return data


def passcode_hash(passcode: str) -> str:
    salt, iters = secrets.token_bytes(16), 1000
    return f'pbkdf2-sha256${iters}${salt.hex()}${hashlib.pbkdf2_hmac("sha256", passcode.encode(), salt, iters).hex()}'


class Folder(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix='rehabit-bridge-test-')
        self.export_path = os.path.join(self.dir, 'icloud', 'rehabit-export.json')
        os.makedirs(os.path.dirname(self.export_path))
        self.config = os.path.join(self.dir, 'config.json')
        self.write_config()

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def write_config(self, **extra):
        with socket.socket() as s:
            s.bind(('127.0.0.1', 0))
            self.port = s.getsockname()[1]
        cfg = {'port': self.port, 'bind': '127.0.0.1', 'token': secrets.token_hex(24),
               'export_paths': [self.export_path], **extra}
        with open(self.config, 'w') as f:
            json.dump(cfg, f)

    def write_export(self, **changes):
        with open(self.export_path, 'w') as f:
            json.dump(export(**changes), f)


class RebuildTests(Folder):
    def test_builds_skips_unchanged_rebuilds_on_change_and_keeps_the_old_db_on_garbage(self):
        self.assertEqual(rebuild.rebuild(self.config)['status'], 'no export')
        self.write_export()
        first = rebuild.rebuild(self.config)
        self.assertEqual(first['status'], 'rebuilt')
        self.assertEqual((first['sessions'], first['sets']), (1, 2))
        db = os.path.join(self.dir, 'data', 'rehabit.db')
        self.assertTrue(os.path.exists(db))
        self.assertFalse(os.path.exists(db + '.building'))
        self.assertEqual(os.stat(db).st_mode & 0o777, 0o600)
        self.assertEqual(rebuild.rebuild(self.config)['status'], 'unchanged')

        self.write_export(exportedAt='2026-11-18T09:00:00.000Z')
        second = rebuild.rebuild(self.config)
        self.assertEqual(second['status'], 'rebuilt')
        self.assertEqual(second['export_written_at'], '2026-11-18T09:00:00.000Z')

        with open(self.export_path, 'w') as f:
            f.write('{not json')
        rebuild.read_export.__defaults__  # noqa: B018 - nothing to configure
        original = rebuild.time.sleep
        rebuild.time.sleep = lambda _s: None
        try:
            self.assertEqual(rebuild.rebuild(self.config)['status'], 'unreadable')
        finally:
            rebuild.time.sleep = original
        self.assertTrue(os.path.exists(db))                      # the last good build stays
        with open(os.path.join(self.dir, 'data', 'rebuild.log')) as f:
            log = f.read()
        self.assertNotIn('Left quad', log)
        self.assertNotIn('Single-Leg', log)


class ServerTests(Folder):
    def start(self, passcode: str | None):
        self.write_config(passcode_hash=passcode_hash(passcode) if passcode else None,
                          public_url=None)
        self.write_export()
        rebuild.rebuild(self.config)
        bridge = server.make_bridge(self.config)
        threading.Thread(target=bridge.run, daemon=True).start()
        self.base = f'http://127.0.0.1:{self.port}'
        for _ in range(50):
            try:
                socket.create_connection(('127.0.0.1', self.port), timeout=0.2).close()
                break
            except OSError:
                time.sleep(0.05)
        return bridge

    def request(self, method, path, body=None, headers=None, form=False):
        data = None
        headers = {'cf-connecting-ip': '203.0.113.9', **(headers or {})}    # as if through the tunnel
        if body is not None:
            if form:
                data = urllib.parse.urlencode(body).encode()
                headers['Content-Type'] = 'application/x-www-form-urlencoded'
            else:
                data = json.dumps(body).encode()
                headers['Content-Type'] = 'application/json'
        req = urllib.request.Request(self.base + path, data=data, method=method, headers=headers)

        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *a, **k):
                return None
        try:
            with urllib.request.build_opener(NoRedirect).open(req, timeout=5) as r:
                return r.status, dict(r.headers), r.read()
        except urllib.error.HTTPError as e:
            return e.code, dict(e.headers), e.read()

    def register(self):
        status, _, body = self.request('POST', '/register', {'redirect_uris': [CALLBACK], 'client_name': 'Claude'})
        self.assertEqual(status, 201)
        return json.loads(body)['client_id']

    def authorize(self, client, passcode):
        verifier = secrets.token_urlsafe(48)
        challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b'=').decode()
        status, headers, page = self.request('POST', '/authorize', {
            'response_type': 'code', 'client_id': client, 'redirect_uri': CALLBACK,
            'code_challenge': challenge, 'code_challenge_method': 'S256', 'state': 'xyz', 'passcode': passcode,
        }, form=True)
        return status, headers, page, verifier

    def rpc(self, token, method, params=None):
        status, _, body = self.request('POST', '/mcp', {'jsonrpc': '2.0', 'id': 1, 'method': method,
                                                        'params': params or {}},
                                       {'Authorization': f'Bearer {token}'})
        self.assertEqual(status, 200, body)
        return json.loads(body)['result']

    def test_unauthenticated_requests_get_401_and_metadata_only(self):
        self.start(passcode=None)
        status, headers, body = self.request('POST', '/mcp', {'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'})
        self.assertEqual(status, 401)
        self.assertIn('resource_metadata=', headers['WWW-Authenticate'])
        self.assertNotIn(b'tools', body)
        for path in ('/.well-known/oauth-protected-resource', '/.well-known/oauth-authorization-server'):
            self.assertEqual(self.request('GET', path)[0], 200)
        # The static token URL works only from this Mac, never through the tunnel.
        with open(self.config) as f:
            local_token = json.load(f)['token']
        self.assertEqual(self.request('POST', f'/mcp/{local_token}', {'jsonrpc': '2.0', 'id': 1,
                                                                      'method': 'tools/list'})[0], 401)

    def test_registration_outside_the_allowlist_is_refused(self):
        self.start(passcode=None)
        status, _, body = self.request('POST', '/register', {'redirect_uris': ['https://evil.example/cb']})
        self.assertEqual(status, 400)
        self.assertIn(b'invalid_redirect_uri', body)

    def test_without_a_passcode_every_sign_in_fails(self):
        self.start(passcode=None)
        client = self.register()
        for guess in ('', 'anything', 'None'):
            status, headers, page, _ = self.authorize(client, guess)
            self.assertEqual(status, 200)                        # the form again, not a redirect
            self.assertNotIn('Location', headers)

    def test_full_sign_in_token_and_tool_calls(self):
        passcode = secrets.token_urlsafe(16)
        self.start(passcode=passcode)
        client = self.register()
        status, headers, _, verifier = self.authorize(client, passcode)
        self.assertEqual(status, 302)
        location = urllib.parse.urlsplit(headers['Location'])
        code = dict(urllib.parse.parse_qsl(location.query))['code']
        # The wrong verifier is refused; the right one gets tokens.
        self.assertEqual(self.request('POST', '/token', {'grant_type': 'authorization_code', 'code': code,
                                                         'client_id': client, 'redirect_uri': CALLBACK,
                                                         'code_verifier': 'x' * 50}, form=True)[0], 400)
        status, headers, page, verifier = self.authorize(client, passcode)
        code = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(headers['Location']).query))['code']
        status, _, body = self.request('POST', '/token', {'grant_type': 'authorization_code', 'code': code,
                                                          'client_id': client, 'redirect_uri': CALLBACK,
                                                          'code_verifier': verifier}, form=True)
        self.assertEqual(status, 200)
        tokens = json.loads(body)
        self.assertEqual(tokens['expires_in'], 3600)
        access = tokens['access_token']

        names = {t['name'] for t in self.rpc(access, 'tools/list')['tools']}
        self.assertTrue({'get_overview', 'get_pain_checks', 'run_query', 'get_tissue_load'} <= names)
        overview = self.rpc(access, 'tools/call', {'name': 'get_overview', 'arguments': {}})
        fresh = overview['structuredContent']['data_freshness']
        self.assertEqual(fresh['export_written_at'], '2026-11-17T15:00:00.000Z')
        pain = self.rpc(access, 'tools/call', {'name': 'get_pain_checks', 'arguments': {
            'start_day': '2026-11-01', 'end_day': '2026-11-30'}})
        self.assertEqual(pain['structuredContent']['count'], 1)

        # run_query: one SELECT, read only, no ATTACH, no PRAGMA, capped.
        def query(sql):
            return self.rpc(access, 'tools/call', {'name': 'run_query', 'arguments': {'sql': sql}})['structuredContent']
        self.assertEqual(query('SELECT COUNT(*) AS n FROM set_entry')['rows'][0]['n'], 2)
        for bad in ("SELECT 1; DELETE FROM set_entry", "ATTACH DATABASE '/tmp/x.db' AS x",
                    "WITH x AS (SELECT 1) DELETE FROM set_entry", "SELECT * FROM pragma_table_info('set_entry')",
                    "SELECT load_extension('x')"):
            self.assertIn('error', query(bad), bad)
        self.assertIn('error', query('WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n) '
                                     'SELECT COUNT(*) FROM n'))
        self.assertEqual(len(query('WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n LIMIT 900) '
                                   'SELECT i FROM n')['rows']), 500)
        self.assertEqual(query('SELECT COUNT(*) AS n FROM set_entry')['rows'][0]['n'], 2)

        # Unknown arguments are refused, not passed through.
        bad = self.rpc(access, 'tools/call', {'name': 'get_overview', 'arguments': {'x': 1}})
        self.assertTrue(bad['isError'])

        # Refresh tokens rotate: the old one stops working.
        status, _, body = self.request('POST', '/token', {'grant_type': 'refresh_token',
                                                          'refresh_token': tokens['refresh_token']}, form=True)
        self.assertEqual(status, 200)
        self.assertEqual(self.request('POST', '/token', {'grant_type': 'refresh_token',
                                                         'refresh_token': tokens['refresh_token']}, form=True)[0], 400)

        # Nothing private reaches the log.
        with open(os.path.join(self.dir, 'access.log')) as f:
            log = f.read()
        for secret in (passcode, access, tokens['refresh_token'], code, 'ache', 'Left quad', '2026-11-01',
                       'set_entry'):
            self.assertNotIn(secret, log)
        self.assertIn('tool get_pain_checks', log)

    def test_five_wrong_passcodes_lock_the_page(self):
        passcode = secrets.token_urlsafe(16)
        self.start(passcode=passcode)
        client = self.register()
        for _ in range(5):
            self.assertEqual(self.authorize(client, 'wrong')[0], 200)
        status, _, page, _ = self.authorize(client, passcode)
        self.assertEqual(status, 200)                            # locked even with the right one
        self.assertIn(b'Too many wrong passcodes', page)


if __name__ == '__main__':
    unittest.main()
