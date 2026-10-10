#!/bin/bash
# Removes the Time service. Refuses while a lock is running.  sudo ./uninstall.sh
set -euo pipefail

DEST="/Library/Application Support/Time"
LABELS=(com.time.blocker com.time.watchdog)
die() { echo "Error: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run it with sudo:  sudo ./uninstall.sh"
[ -d "$DEST" ] || die "Time isn't installed."

if [ -f "$DEST/state/state.json" ] && "$DEST/bin/node" -e '
  const s = require(process.argv[1]);
  process.exit(s.lock && s.lock.endsAt > Math.max(Date.now(), s.lastTrusted || 0) ? 0 : 1);
' "$DEST/state/state.json" 2>/dev/null; then
  die "a lock is running. You can uninstall after it ends."
fi

USER_NAME="$("$DEST/bin/node" -p 'require(process.argv[1]).user' "$DEST/install.json" 2>/dev/null || echo "${SUDO_USER:-}")"

touch "$DEST/state/uninstalling"
for l in "${LABELS[@]}"; do launchctl bootout "system/$l" 2>/dev/null || true; done
chflags -R noschg "$DEST" /Library/LaunchDaemons/com.time.*.plist 2>/dev/null || true
rm -f /Library/LaunchDaemons/com.time.blocker.plist /Library/LaunchDaemons/com.time.watchdog.plist

# Take the managed section back out of /etc/hosts.
"$DEST/bin/node" -e 'require(process.argv[1]).enforceWeb([], console.log)' "$DEST/src/enforce-web.js"

# Never leave you without admin rights.
if [ -n "$USER_NAME" ]; then dseditgroup -o edit -a "$USER_NAME" -t user admin; fi

if dscl . -read /Users/timekeeper UniqueID >/dev/null 2>&1; then
  sysadminctl -deleteUser timekeeper 2>&1 | grep -v -i 'secure token' || true
fi

rm -rf "$DEST"
echo "Time is uninstalled."
