"""Shared core for the read-only MCP bridges (iMessage Bridge, Garmin Bridge, Rehabit Bridge).

Config file, access log, OAuth 2.1 sign-in (the MCP authorization spec) and MCP over Streamable HTTP
(stateless JSON). Standard library only. The bridges carry copies of this file, so change them together.
This copy (Rehabit) adds one setting, log_tool_args: when false, the access log names each tool called
but not its arguments, which for health data can say more than they should.

Sign-in: claude.ai registers itself at /register (RFC 7591, redirect allowlist), sends the owner to /authorize,
the owner types the passcode set with set_passcode.py, and claude.ai gets short-lived bearer tokens (PKCE S256).
Only SHA-256 hashes of codes and tokens are stored. The static /mcp/<token> URL works only from this Mac.
"""
import base64
import hashlib
import hmac
import html
import json
import os
import re
import secrets
import sys
import threading
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qsl, quote, urlsplit

CORE_VERSION = '1.0.0'
CLAUDE_CALLBACKS = ['https://claude.ai/api/mcp/auth_callback', 'https://claude.com/api/mcp/auth_callback']


class ToolError(Exception):
    """An error whose message is safe and useful to show the client."""


def clamp(v, default, maximum):
    try:
        v = int(v)
    except (TypeError, ValueError):
        return default
    return default if v <= 0 else min(v, maximum)


def b64url(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b'=').decode()


def ct_eq(a, b):
    return a is not None and b is not None and hmac.compare_digest(str(a).encode(), str(b).encode())


def sha256_hex(s):
    return hashlib.sha256(s.encode()).hexdigest()


def write_private(path, text):
    """Atomically write a file readable only by this user."""
    tmp = f'{path}.tmp'
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w', encoding='utf-8') as f:
        f.write(text)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def load_config(path, defaults):
    if not os.path.exists(path):
        cfg = dict(defaults, token=secrets.token_hex(24))
        write_private(path, json.dumps(cfg, indent=2, sort_keys=True) + '\n')
        print(f'Created {path} with a new secret token.', file=sys.stderr)
    with open(path, encoding='utf-8') as f:
        cfg = {**defaults, **json.load(f)}
    if not re.fullmatch(r'\S{32,}', cfg.get('token') or ''):
        sys.exit('config: token must be at least 32 characters')
    return cfg


def passcode_ok(stored, given):
    try:
        alg, iters, salt, want = (stored or '').split('$')
        if alg != 'pbkdf2-sha256':
            return False
        got = hashlib.pbkdf2_hmac('sha256', (given or '').encode(), bytes.fromhex(salt), int(iters)).hex()
    except ValueError:
        return False
    return hmac.compare_digest(got, want)


PAGE_CSS = """:root{--bg:#f6f5f2;--card:#fff;--fg:#1d1c1a;--muted:#6b6862;--line:#dedbd4;--accent:#1d1c1a;--bad:#a8321f}
@media (prefers-color-scheme:dark){:root{--bg:#191917;--card:#232321;--fg:#ecebe7;--muted:#a19e97;--line:#3a3935;--accent:#ecebe7;--bad:#f08a76}}
body{margin:0;min-height:100vh;display:grid;place-items:center;background:var(--bg);color:var(--fg);font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;padding:16px;box-sizing:border-box}
main{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:28px;max-width:420px;width:100%;box-sizing:border-box}
h1{font-size:20px;margin:0 0 8px}p{margin:0 0 14px;color:var(--muted)}b{color:var(--fg)}
input[type=password]{width:100%;box-sizing:border-box;font:inherit;padding:10px 12px;border:1px solid var(--line);border-radius:8px;background:transparent;color:var(--fg);margin:4px 0 14px}
button{font:inherit;font-weight:600;padding:10px 16px;border-radius:8px;border:0;background:var(--accent);color:var(--bg);cursor:pointer;width:100%}
.err{color:var(--bad);font-weight:600}"""


class Bridge:
    """One read-only MCP server. Register tools with @bridge.tool(...), then call bridge.run()."""

    def __init__(self, *, name, title, version, scope, instructions, consent_title, consent_lines,
                 config_path, defaults, error_hint=None, tool_annotations=None):
        self.name, self.title, self.version, self.scope = name, title, version, scope
        self.instructions, self.consent_title, self.consent_lines = instructions, consent_title, consent_lines
        self.config_path = config_path
        self.error_hint = error_hint          # optional fn(raw_error_text) -> friendlier message or None
        self.tool_annotations = tool_annotations or {}   # extra MCP hints for every tool, e.g. openWorldHint
        base = dict(bind='127.0.0.1', port=8765, token=None, log_path=None, public_url=None, passcode_hash=None,
                    state_path=None, access_ttl=3600, refresh_ttl=30 * 86400, max_limit=100,
                    allowed_redirect_uris=CLAUDE_CALLBACKS, log_tool_args=True)
        here = os.path.dirname(os.path.abspath(config_path))
        base.update(log_path=os.path.join(here, 'access.log'), state_path=os.path.join(here, 'oauth-state.json'))
        base.update(defaults)
        self.cfg = load_config(config_path, base)
        self.tools, self.fns = [], {}
        self._log_lock, self._state_lock = threading.Lock(), threading.Lock()
        self._log = open(self.cfg['log_path'], 'a', encoding='utf-8', buffering=1)

    # ------------------------------------------------------------ helpers

    def log(self, line):
        with self._log_lock:
            self._log.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S%z')} {line}\n")

    def tool(self, name, title, description, properties=None, required=None):
        def register(fn):
            schema = {'type': 'object', 'properties': properties or {}}
            if required:
                schema['required'] = required
            self.tools.append({'name': name, 'title': title, 'description': description, 'inputSchema': schema,
                               'annotations': {'title': title, 'readOnlyHint': True, 'destructiveHint': False,
                                               'idempotentHint': True, **self.tool_annotations}})
            self.fns[name] = fn
            return fn
        return register

    def base_url(self):
        return (self.cfg.get('public_url') or f"http://127.0.0.1:{self.cfg['port']}").rstrip('/')

    def load_state(self):
        p = self.cfg['state_path']
        s = {}
        if os.path.exists(p):
            with open(p, encoding='utf-8') as f:
                s = json.load(f)
        for k in ('clients', 'codes', 'tokens'):
            s.setdefault(k, {})
        s.setdefault('fails', {'count': 0, 'until': 0})
        return s

    def save_state(self, s):
        now = time.time()
        for k in ('codes', 'tokens'):
            s[k] = {h: v for h, v in s[k].items() if v['exp'] >= now}
        write_private(self.cfg['state_path'], json.dumps(s, sort_keys=True))

    def issue_tokens(self, s, client_id):
        at, rt, now = secrets.token_urlsafe(32), secrets.token_urlsafe(32), time.time()
        s['tokens'][sha256_hex(at)] = {'type': 'access', 'client_id': client_id, 'exp': now + self.cfg['access_ttl']}
        s['tokens'][sha256_hex(rt)] = {'type': 'refresh', 'client_id': client_id, 'exp': now + self.cfg['refresh_ttl']}
        return {'access_token': at, 'token_type': 'Bearer', 'expires_in': int(self.cfg['access_ttl']),
                'refresh_token': rt, 'scope': self.scope}

    def reload_passcode(self):
        """Pick up a passcode set (or changed) with set_passcode.py without restarting."""
        try:
            with open(self.config_path, encoding='utf-8') as f:
                self.cfg['passcode_hash'] = json.load(f).get('passcode_hash')
        except (OSError, ValueError):
            pass

    # ------------------------------------------------------------ MCP / JSON-RPC

    def handle_rpc(self, req):
        if not isinstance(req, dict) or req.get('jsonrpc') != '2.0':
            return {'jsonrpc': '2.0', 'id': None, 'error': {'code': -32600, 'message': 'Invalid Request'}}
        if 'id' not in req:
            return None                                  # notification: no response body
        rid, method = req['id'], req.get('method') or ''
        params = req.get('params') if isinstance(req.get('params'), dict) else {}
        ok = lambda result: {'jsonrpc': '2.0', 'id': rid, 'result': result}
        if method == 'initialize':
            return ok({'protocolVersion': params.get('protocolVersion') or '2025-06-18',
                       'capabilities': {'tools': {'listChanged': False}},
                       'serverInfo': {'name': self.name, 'title': self.title, 'version': self.version},
                       'instructions': self.instructions})
        if method == 'ping':
            return ok({})
        if method == 'tools/list':
            return ok({'tools': self.tools})
        if method == 'tools/call':
            name = params.get('name') or ''
            fn = self.fns.get(name)
            if not fn:
                return {'jsonrpc': '2.0', 'id': rid, 'error': {'code': -32602, 'message': f'Unknown tool: {name}'}}
            args = params.get('arguments') if isinstance(params.get('arguments'), dict) else {}
            if self.cfg.get('log_tool_args', True):
                self.log(f'tool {name} {json.dumps(args, sort_keys=True, ensure_ascii=False)}')
            else:
                self.log(f'tool {name}')
            try:
                out = fn(args)
            except ToolError as e:
                self.log(f'tool {name} error' + (f': {e}' if self.cfg.get('log_tool_args', True) else ''))
                return ok({'content': [{'type': 'text', 'text': f'Error: {e}'}], 'isError': True})
            except Exception as e:  # noqa: BLE001 - report, never crash the server
                raw = f'{type(e).__name__}: {e}'
                self.log(f'tool {name} raw error: {raw} | ' + traceback.format_exc().replace('\n', ' | ')[-600:])
                msg = (self.error_hint(raw) if self.error_hint else None) or raw
                return ok({'content': [{'type': 'text', 'text': f'Error: {msg}'}], 'isError': True})
            return ok({'content': [{'type': 'text', 'text': json.dumps(out, indent=2, sort_keys=True, ensure_ascii=False)}],
                       'structuredContent': out})
        return {'jsonrpc': '2.0', 'id': rid, 'error': {'code': -32601, 'message': f'Method not found: {method}'}}

    # ------------------------------------------------------------ HTTP

    def run(self, startup=None):
        bridge = self
        cfg = self.cfg

        class Handler(BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'
            timeout = 15
            server_version = bridge.name
            sys_version = ''

            def log_message(self, *a):           # our own access log replaces the default stderr lines
                pass

            def send(self, code, body=b'', ctype=None, extra=None):
                if isinstance(body, str):
                    body = body.encode()
                self.send_response(code)
                self.send_header('Content-Length', str(len(body)))
                self.send_header('Connection', 'close')
                self.send_header('Cache-Control', 'no-store')
                self.send_header('X-Content-Type-Options', 'nosniff')
                self.send_header('Referrer-Policy', 'no-referrer')
                if ctype:
                    self.send_header('Content-Type', ctype)
                for k, v in sorted((extra or {}).items()):
                    self.send_header(k, v)
                self.end_headers()
                self.wfile.write(body)
                self.close_connection = True

            def json_out(self, code, data, extra=None):
                self.send(code, json.dumps(data, sort_keys=True, ensure_ascii=False, separators=(',', ':')).encode(),
                          'application/json', extra)

            def oauth_err(self, code, err, desc=None):
                self.json_out(code, {'error': err, **({'error_description': desc} if desc else {})})

            def page(self, code, title, inner):
                doc = (f'<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" '
                       f'content="width=device-width,initial-scale=1"><title>{html.escape(title)}</title><style>{PAGE_CSS}'
                       f'</style></head><body><main>{inner}</main></body></html>')
                self.send(code, doc, 'text/html; charset=utf-8', {
                    'Content-Security-Policy': "default-src 'none'; style-src 'unsafe-inline'; form-action 'self' https:; frame-ancestors 'none'",
                    'X-Frame-Options': 'DENY'})

            def is_local(self):
                return (self.client_address[0] in ('127.0.0.1', '::1') and 'cf-connecting-ip' not in self.headers
                        and 'x-forwarded-for' not in self.headers)

            def do_GET(self):
                self.route('GET')

            def do_POST(self):
                self.route('POST')

            def do_PUT(self):
                self.route('PUT')

            def do_DELETE(self):
                self.route('DELETE')

            def do_OPTIONS(self):
                self.route('OPTIONS')

            def route(self, method):
                try:
                    self._route(method)
                except Exception as e:  # noqa: BLE001
                    bridge.log(f'connection error: {type(e).__name__}: {e}')

            def _route(self, method):
                u = urlsplit(self.path)
                path, q = u.path, dict(parse_qsl(u.query, keep_blank_values=True))
                who = self.headers.get('cf-connecting-ip') or self.headers.get('x-forwarded-for') or self.client_address[0]
                shown = re.sub(r'[0-9a-f]{32,}', '<token>', path)
                body = b''
                if method == 'POST':
                    n = self.headers.get('content-length') or '0'
                    if not n.isdigit() or int(n) > 1_000_000:
                        return self.send(413)
                    body = self.rfile.read(int(n))
                base = bridge.base_url()
                prm = f'{base}/.well-known/oauth-protected-resource'

                # --- discovery
                if method == 'GET' and re.fullmatch(r'/\.well-known/oauth-protected-resource(/mcp)?', path):
                    bridge.log(f'{who} GET {path}')
                    return self.json_out(200, {'resource': f'{base}/mcp', 'authorization_servers': [base],
                                               'bearer_methods_supported': ['header'], 'scopes_supported': [bridge.scope],
                                               'resource_name': bridge.title})
                if method == 'GET' and re.fullmatch(r'/\.well-known/(oauth-authorization-server|openid-configuration)(/mcp)?', path):
                    bridge.log(f'{who} GET {path}')
                    return self.json_out(200, {
                        'issuer': base, 'authorization_endpoint': f'{base}/authorize', 'token_endpoint': f'{base}/token',
                        'registration_endpoint': f'{base}/register', 'response_types_supported': ['code'],
                        'grant_types_supported': ['authorization_code', 'refresh_token'],
                        'code_challenge_methods_supported': ['S256'], 'token_endpoint_auth_methods_supported': ['none'],
                        'scopes_supported': [bridge.scope]})

                # --- dynamic client registration
                if method == 'POST' and path == '/register':
                    try:
                        r = json.loads(body)
                    except ValueError:
                        r = None
                    if not isinstance(r, dict):
                        return self.oauth_err(400, 'invalid_client_metadata', 'JSON body required')
                    uris = r.get('redirect_uris') if isinstance(r.get('redirect_uris'), list) else []
                    if not uris or any(x not in cfg['allowed_redirect_uris'] for x in uris):
                        bridge.log(f"{who} register refused: redirect_uris {' '.join(map(str, uris))}")
                        return self.oauth_err(400, 'invalid_redirect_uri', "redirect_uri is not on this bridge's allowlist")
                    with bridge._state_lock:
                        s = bridge.load_state()
                        if len(s['clients']) >= 50:
                            return self.oauth_err(400, 'invalid_client_metadata', 'too many registered clients')
                        cid = 'c_' + b64url(secrets.token_bytes(18))
                        name = str(r.get('client_name') or '')[:80]
                        s['clients'][cid] = {'redirect_uris': uris, 'client_name': name, 'created': int(time.time())}
                        bridge.save_state(s)
                    bridge.log(f'{who} register ok: client {cid} ({name})')
                    return self.json_out(201, {'client_id': cid, 'client_id_issued_at': int(time.time()), 'client_name': name,
                                               'redirect_uris': uris, 'token_endpoint_auth_method': 'none',
                                               'grant_types': ['authorization_code', 'refresh_token'], 'response_types': ['code']})

                # --- authorization (browser)
                if path == '/authorize' and method in ('GET', 'POST'):
                    p = dict(parse_qsl(body.decode('utf-8', 'replace'), keep_blank_values=True)) if method == 'POST' else q
                    bridge.reload_passcode()
                    with bridge._state_lock:
                        s = bridge.load_state()
                        c, err = self.check_authz(s, p)
                        if not c:
                            bridge.log(f'{who} authorize refused: {err}')
                            return self.page(400, 'Cannot connect', f'<h1>Cannot connect</h1><p>{html.escape(err)}</p>')
                        if method == 'GET':
                            return self.authorize_form(p, c)
                        if s['fails']['until'] > time.time():
                            bridge.log(f'{who} authorize locked')
                            mins = 1 + int((s['fails']['until'] - time.time()) / 60)
                            return self.authorize_form(p, c, f'Too many wrong passcodes. Try again in {mins} minutes.')
                        if not passcode_ok(cfg.get('passcode_hash'), p.get('passcode')):
                            s['fails']['count'] += 1
                            if s['fails']['count'] >= 5:
                                s['fails'] = {'count': 0, 'until': time.time() + 900}
                            bridge.save_state(s)
                            bridge.log(f'{who} authorize: wrong passcode')
                            return self.authorize_form(p, c, 'Wrong passcode.')
                        s['fails'] = {'count': 0, 'until': 0}
                        code = secrets.token_urlsafe(32)
                        s['codes'][sha256_hex(code)] = {'client_id': p['client_id'], 'redirect_uri': p['redirect_uri'],
                                                        'challenge': p['code_challenge'], 'exp': time.time() + 300}
                        bridge.save_state(s)
                    bridge.log(f"{who} authorize ok: client {p['client_id']}")
                    ru = p['redirect_uri']
                    loc = (ru + ('&' if '?' in ru else '?') + 'code=' + quote(code, safe='')
                           + (('&state=' + quote(p['state'], safe='')) if 'state' in p else '') + '&iss=' + quote(base, safe=''))
                    return self.send(302, extra={'Location': loc})

                # --- token endpoint
                if method == 'POST' and path == '/token':
                    f = dict(parse_qsl(body.decode('utf-8', 'replace'), keep_blank_values=True))
                    gt = f.get('grant_type') or ''
                    with bridge._state_lock:
                        s = bridge.load_state()
                        if gt == 'authorization_code':
                            c = s['codes'].pop(sha256_hex(f.get('code') or ''), None)   # single use, even if the rest fails
                            bridge.save_state(s)
                            if not c or c['exp'] < time.time():
                                return self.oauth_err(400, 'invalid_grant', 'unknown or expired code')
                            if f.get('client_id') != c['client_id']:
                                return self.oauth_err(400, 'invalid_grant', 'client mismatch')
                            if f.get('redirect_uri') != c['redirect_uri']:
                                return self.oauth_err(400, 'invalid_grant', 'redirect_uri mismatch')
                            if not ct_eq(b64url(hashlib.sha256((f.get('code_verifier') or '').encode()).digest()), c['challenge']):
                                return self.oauth_err(400, 'invalid_grant', 'PKCE verification failed')
                            t = bridge.issue_tokens(s, c['client_id'])
                            bridge.save_state(s)
                            bridge.log(f"{who} token issued (code) for client {c['client_id']}")
                            return self.json_out(200, t)
                        if gt == 'refresh_token':
                            k = sha256_hex(f.get('refresh_token') or '')
                            r = s['tokens'].get(k)
                            if not r or r['type'] != 'refresh' or r['exp'] < time.time():
                                return self.oauth_err(400, 'invalid_grant', 'unknown or expired refresh token')
                            if 'client_id' in f and f['client_id'] != r['client_id']:
                                return self.oauth_err(400, 'invalid_grant', 'client mismatch')
                            del s['tokens'][k]                                           # rotate
                            t = bridge.issue_tokens(s, r['client_id'])
                            bridge.save_state(s)
                            bridge.log(f"{who} token refreshed for client {r['client_id']}")
                            return self.json_out(200, t)
                    return self.oauth_err(400, 'unsupported_grant_type')

                # --- MCP endpoint
                static_path = path == f"/mcp/{cfg['token']}"
                if path == '/mcp' or static_path:
                    authed = False
                    if static_path:
                        authed = self.is_local()          # the static token URL only works from this Mac, never through the tunnel
                    else:
                        m = re.fullmatch(r'Bearer\s+(\S+)', self.headers.get('authorization') or '', re.I)
                        if m:
                            t = m.group(1)
                            if self.is_local() and ct_eq(t, cfg['token']):
                                authed = True
                            else:
                                with bridge._state_lock:
                                    r = bridge.load_state()['tokens'].get(sha256_hex(t))
                                authed = bool(r and r['type'] == 'access' and r['exp'] >= time.time())
                    if not authed:
                        bridge.log(f'{who} {method} {shown} -> 401')
                        return self.json_out(401, {'error': 'invalid_token'}, {'WWW-Authenticate':
                            f'Bearer realm="{bridge.name}", resource_metadata="{prm}", error="invalid_token"'})
                    if method != 'POST':
                        return self.send(405, extra={'Allow': 'POST'})
                    try:
                        req = json.loads(body)
                    except ValueError:
                        bridge.log(f'{who} POST -> parse error')
                        return self.json_out(400, {'jsonrpc': '2.0', 'id': None, 'error': {'code': -32700, 'message': 'Parse error'}})
                    reqs = req if isinstance(req, list) else [req]
                    bridge.log(f"{who} POST " + ','.join((x.get('method') or '?') if isinstance(x, dict) else '?' for x in reqs))
                    out = [o for o in (bridge.handle_rpc(x) for x in reqs) if o is not None]
                    if not out:
                        return self.send(202)
                    return self.json_out(200, out if isinstance(req, list) else out[0])

                bridge.log(f'{who} {method} {shown} -> 404')
                return self.send(404)

            def check_authz(self, s, q):
                c = s['clients'].get(q.get('client_id') or '')
                if not c:
                    return None, 'Unknown client. Remove and re-add the connector in Claude.'
                if q.get('redirect_uri') not in c['redirect_uris']:
                    return None, 'This return address is not registered for the client.'
                if q.get('response_type') != 'code':
                    return None, 'Unsupported response_type.'
                if q.get('code_challenge_method') != 'S256' or not re.fullmatch(r'[A-Za-z0-9\-_]{43,128}', q.get('code_challenge') or ''):
                    return None, 'PKCE (S256) is required.'
                return c, None

            def authorize_form(self, q, c, msg=None):
                dest = re.sub(r'^(https?://[^/]+).*', r'\1', q['redirect_uri'])
                hidden = ''.join(f'<input type="hidden" name="{html.escape(k)}" value="{html.escape(q[k])}">'
                                 for k in ('response_type', 'client_id', 'redirect_uri', 'code_challenge',
                                           'code_challenge_method', 'state', 'scope', 'resource') if k in q)
                if not cfg.get('passcode_hash'):
                    note = '<p class="err">No passcode is set yet. On the Mac, run set_passcode.py, then try again.</p>'
                else:
                    note = f'<p class="err">{html.escape(msg)}</p>' if msg else ''
                who = html.escape(c.get('client_name') or 'An MCP client')
                lines = ''.join(f'<p>{line}</p>' for line in bridge.consent_lines(who, html.escape(dest)))
                self.page(200, f'Allow access to {bridge.consent_title}', f"""<h1>Allow read-only access to {html.escape(bridge.consent_title)}?</h1>
{lines}{note}
<form method="post" action="/authorize">{hidden}
<label for="p">Bridge passcode</label><input id="p" type="password" name="passcode" autocomplete="current-password" required autofocus>
<button type="submit">Allow</button></form>""")

        server = ThreadingHTTPServer((cfg['bind'], int(cfg['port'])), Handler)
        server.daemon_threads = True
        self.log(f"start v{self.version} (core {CORE_VERSION}, Python {sys.version.split()[0]}) on {cfg['bind']}:{cfg['port']}, "
                 f"public {self.base_url()}, passcode {'set' if cfg.get('passcode_hash') else 'NOT set'}")
        if startup:
            try:
                startup()
            except Exception as e:  # noqa: BLE001
                self.log(f'startup check error: {type(e).__name__}: {e}')
        print(f"{self.title} v{self.version} listening on http://{cfg['bind']}:{cfg['port']} (public: {self.base_url()})", file=sys.stderr)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass
