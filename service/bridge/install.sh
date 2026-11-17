#!/bin/zsh
# Installs or updates Rehabit Bridge on this Mac from the repository:
#   zsh service/bridge/install.sh [hostname]
# e.g. zsh service/bridge/install.sh rehabit.example.com
#
# - copies the bridge and the rehabit package to ~/Rehabit-Bridge (the
#   repository can then change branch without touching the running copy);
# - creates ~/Rehabit-Bridge/config.json on the first run (mode 600: the
#   local-only token, the public address; no passcode until you set one);
# - publishes the bridge through its own Cloudflare tunnel at the hostname, if
#   one is given and cloudflared is logged in on this Mac;
# - installs three login agents: the server, the tunnel, and the rebuild job
#   that watches for the app's export file.
# Safe to re-run. Your passcode is set separately, by you:
#   /opt/homebrew/opt/python@3.13/bin/python3.13 ~/Rehabit-Bridge/set_passcode.py
set -eu
SRC=${0:A:h}
DEST=$HOME/Rehabit-Bridge
PY=/opt/homebrew/opt/python@3.13/bin/python3.13
CF=/opt/homebrew/bin/cloudflared
HOST=${1:-}
PORT=8768
NAME=rehabit-bridge

mkdir -p "$DEST/data" "$DEST/launchd"
chmod 700 "$DEST" "$DEST/data"
cp "$SRC/bridge_core.py" "$SRC/server.py" "$SRC/rebuild.py" "$SRC/set_passcode.py" "$SRC/bridgectl.sh" "$DEST/"
rsync -a --delete --exclude '__pycache__' "$SRC/../rehabit/" "$DEST/rehabit/"

# The folder a phone can pick in Rehabit's Settings if the app's own iCloud
# folder is not available. It appears in iCloud Drive as "Rehabit".
mkdir -p "$HOME/Library/Mobile Documents/com~apple~CloudDocs/Rehabit"

# First run: create config.json (and its local-only token) without starting the server.
$PY -E -s -c "
import json, os, sys
sys.path.insert(0, '$DEST')
from bridge_core import load_config, write_private
path = '$DEST/config.json'
cfg = load_config(path, {'port': $PORT, 'bind': '127.0.0.1'})
with open(path) as f: saved = json.load(f)
saved.setdefault('port', $PORT)
saved.setdefault('bind', '127.0.0.1')
saved.setdefault('log_tool_args', False)
if '$HOST': saved['public_url'] = 'https://$HOST'
write_private(path, json.dumps(saved, indent=2, sort_keys=True) + '\n')
"

if [[ -n "$HOST" ]]; then
  if ! $CF tunnel info $NAME >/dev/null 2>&1; then
    echo "Creating Cloudflare tunnel '$NAME'..."
    $CF tunnel create $NAME
  fi
  ID=$($CF tunnel list --name $NAME --output json | $PY -c 'import json,sys; print(json.load(sys.stdin)[0]["id"])')
  $CF tunnel route dns $NAME $HOST 2>&1 | tail -1 || true
  cat > "$DEST/cloudflared.yml" <<EOF
# Cloudflare tunnel for Rehabit Bridge (written by install.sh).
tunnel: $ID
credentials-file: $HOME/.cloudflared/$ID.json
no-autoupdate: true
ingress:
  - hostname: $HOST
    service: http://127.0.0.1:$PORT
    originRequest:
      connectTimeout: 10s
  - service: http_status:404
EOF
  $CF tunnel --config "$DEST/cloudflared.yml" ingress validate
fi

plist() {  # label, program arguments (as <string> lines), extra keys
  cat > "$DEST/launchd/$1.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$1</string>
  <key>ProgramArguments</key><array>$2</array>
  <key>WorkingDirectory</key><string>$DEST</string>
  <key>ProcessType</key><string>Background</string>
$3
</dict></plist>
EOF
}
plist local.rehabit-bridge.server "<string>$PY</string><string>-E</string><string>-s</string><string>$DEST/server.py</string>" \
  "  <key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ThrottleInterval</key><integer>15</integer>
  <key>StandardOutPath</key><string>$DEST/server.log</string><key>StandardErrorPath</key><string>$DEST/server.log</string>"
plist local.rehabit-bridge.rebuild "<string>$PY</string><string>-E</string><string>-s</string><string>$DEST/rebuild.py</string>" \
  "  <key>RunAtLoad</key><true/><key>StartInterval</key><integer>600</integer>
  <key>WatchPaths</key><array>
    <string>$HOME/Library/Mobile Documents/iCloud~com~gabrielprice~rehabit/Documents</string>
    <string>$HOME/Library/Mobile Documents/com~apple~CloudDocs/Rehabit</string>
    <string>$HOME/Library/Mobile Documents/com~apple~CloudDocs/rehabit-export.json</string>
  </array>
  <key>StandardOutPath</key><string>$DEST/data/rebuild.out</string><key>StandardErrorPath</key><string>$DEST/data/rebuild.out</string>"
AGENTS=(local.rehabit-bridge.server local.rehabit-bridge.rebuild)
if [[ -f "$DEST/cloudflared.yml" ]]; then
  plist local.rehabit-bridge.tunnel "<string>$CF</string><string>tunnel</string><string>--config</string><string>$DEST/cloudflared.yml</string><string>run</string>" \
    "  <key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ThrottleInterval</key><integer>15</integer>
  <key>StandardOutPath</key><string>$DEST/tunnel.log</string><key>StandardErrorPath</key><string>$DEST/tunnel.log</string>"
  AGENTS+=(local.rehabit-bridge.tunnel)
fi
for a in $AGENTS; do cp "$DEST/launchd/$a.plist" ~/Library/LaunchAgents/; done
zsh "$DEST/bridgectl.sh" restart
sleep 4
zsh "$DEST/bridgectl.sh" status
