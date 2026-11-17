#!/bin/zsh
# Rehabit Bridge login agents: zsh ~/Rehabit-Bridge/bridgectl.sh status|start|stop|restart|logs
set -u
HERE=${0:A:h}
AGENTS=(local.rehabit-bridge.server local.rehabit-bridge.rebuild local.rehabit-bridge.tunnel)
D=gui/$(id -u)
case ${1:-status} in
  start)   for a in $AGENTS; do [[ -f ~/Library/LaunchAgents/$a.plist ]] && launchctl bootstrap $D ~/Library/LaunchAgents/$a.plist 2>/dev/null; done ;;
  stop)    for a in $AGENTS; do launchctl bootout $D/$a 2>/dev/null; done ;;
  restart) zsh "$0" stop; sleep 1; zsh "$0" start ;;
  logs)    tail -n 20 "$HERE/access.log" "$HERE/data/rebuild.log" 2>/dev/null ;;
  status)
    for a in $AGENTS; do
      if launchctl print $D/$a >/dev/null 2>&1; then
        state=$(launchctl print $D/$a | awk -F'= ' '/^\tstate/{print $2; exit}')
        echo "$a: loaded (${state:-?})"
      else
        echo "$a: not loaded"
      fi
    done ;;
  *) echo "usage: bridgectl.sh status|start|stop|restart|logs"; exit 2 ;;
esac
