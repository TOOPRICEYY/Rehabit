#!/opt/homebrew/opt/python@3.13/bin/python3.13
"""Set the passcode you type on the bridge's "Allow access" page. Run it yourself in Terminal:

    /opt/homebrew/opt/python@3.13/bin/python3.13 set_passcode.py

Only a salted PBKDF2-SHA256 hash is stored in config.json; the passcode itself is never saved or printed.
Takes effect at the next sign-in, no restart needed.
"""
import getpass
import hashlib
import json
import os
import secrets
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bridge_core import write_private  # noqa: E402

path = os.environ.get('BRIDGE_CONFIG') or os.path.join(os.path.dirname(os.path.abspath(__file__)), 'config.json')
if not os.path.exists(path):
    sys.exit(f'No {path} yet. Start the bridge once first.')


def ask(prompt):
    if sys.stdin.isatty():
        return getpass.getpass(prompt)
    print(prompt, end='', file=sys.stderr)
    return sys.stdin.readline().rstrip('\n')


a = ask('New bridge passcode (at least 12 characters): ')
if len(a) < 12:
    sys.exit('Too short. Use at least 12 characters.')
if ask('Type it again: ') != a:
    sys.exit("They don't match. Nothing changed.")
salt, iters = secrets.token_bytes(16), 200_000
digest = hashlib.pbkdf2_hmac('sha256', a.encode(), salt, iters).hex()
with open(path, encoding='utf-8') as f:
    cfg = json.load(f)
cfg['passcode_hash'] = f'pbkdf2-sha256${iters}${salt.hex()}${digest}'
write_private(path, json.dumps(cfg, indent=2, sort_keys=True) + '\n')
print('\nPasscode saved. It takes effect at the next sign-in; no restart needed.', file=sys.stderr)
