#!/bin/bash
# Installs (or updates) the Time service. Run from the repo:  sudo ./install.sh
set -euo pipefail

DEST="/Library/Application Support/Time"
NODE_VERSION="v22.12.0"
LABELS=(com.time.blocker com.time.watchdog)

die() { echo "Error: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run it with sudo:  sudo ./install.sh"
USER_NAME="${SUDO_USER:-}"
[ -n "$USER_NAME" ] && [ "$USER_NAME" != root ] || die "run it from your own account with sudo, not as root."
USER_UID="$(id -u "$USER_NAME")"
REPO="$(cd "$(dirname "$0")" && pwd)"

# Updating mid-lock would be a way around the lock.
if [ -f "$DEST/state/state.json" ] && "$DEST/bin/node" -e '
  const s = require(process.argv[1]);
  process.exit(s.lock && s.lock.endsAt > Math.max(Date.now(), s.lastTrusted || 0) ? 0 : 1);
' "$DEST/state/state.json" 2>/dev/null; then
  die "a lock is running. Install updates after it ends."
fi

echo "==> Installing Time for $USER_NAME"

# Stop any running copy (the watchdog stands down while this flag exists).
if [ -d "$DEST/state" ]; then touch "$DEST/state/uninstalling"; fi
for l in "${LABELS[@]}"; do launchctl bootout "system/$l" 2>/dev/null || true; done
chflags -R noschg "$DEST" /Library/LaunchDaemons/com.time.*.plist 2>/dev/null || true

mkdir -p "$DEST"/{bin,state,recovery,launchd}
chmod 755 "$DEST" "$DEST/recovery"
chmod 700 "$DEST/state"

# A self-contained Node, so the service doesn't depend on Homebrew.
if [ ! -x "$DEST/bin/node" ] || [ "$("$DEST/bin/node" -v 2>/dev/null)" != "$NODE_VERSION" ]; then
  case "$(uname -m)" in arm64) ARCH=arm64 ;; x86_64) ARCH=x64 ;; *) die "unsupported CPU $(uname -m)" ;; esac
  TARBALL="node-$NODE_VERSION-darwin-$ARCH.tar.gz"
  TMP="$(mktemp -d)"
  echo "==> Downloading Node $NODE_VERSION"
  curl -fsSL "https://nodejs.org/dist/$NODE_VERSION/$TARBALL" -o "$TMP/$TARBALL"
  curl -fsSL "https://nodejs.org/dist/$NODE_VERSION/SHASUMS256.txt" -o "$TMP/SHASUMS256.txt"
  (cd "$TMP" && grep " $TARBALL\$" SHASUMS256.txt | shasum -a 256 -c -) >/dev/null || die "Node download failed its checksum."
  tar -xzf "$TMP/$TARBALL" -C "$TMP"
  install -m 755 "$TMP/node-$NODE_VERSION-darwin-$ARCH/bin/node" "$DEST/bin/node"
  rm -rf "$TMP"
fi

echo "==> Copying the app"
if [ ! -d "$REPO/node_modules/tlock-js" ]; then
  sudo -u "$USER_NAME" /bin/zsh -lc "cd \"$REPO\" && npm install --omit=dev"
fi
rm -rf "$DEST/src" "$DEST/ui" "$DEST/node_modules"
cp -R "$REPO/src" "$REPO/ui" "$REPO/node_modules" "$REPO/package.json" "$DEST/"
printf '{ "user": "%s", "uid": %s }\n' "$USER_NAME" "$USER_UID" > "$DEST/install.json"
chown -R root:wheel "$DEST"
chmod -R go-w "$DEST"

echo "==> Setting up the hidden timekeeper admin account (hard mode's fallback)"
if ! dscl . -read /Users/timekeeper UniqueID >/dev/null 2>&1; then
  sysadminctl -addUser timekeeper -fullName "Time Keeper" -password "$(openssl rand -base64 24)" \
    -home /private/var/timekeeper -admin 2>&1 | grep -v -i 'secure token' || true
  dscl . -read /Users/timekeeper UniqueID >/dev/null 2>&1 || die "could not create the timekeeper account."
fi
dscl . -create /Users/timekeeper IsHidden 1
dseditgroup -o edit -a timekeeper -t user admin
# Fresh random password, time-locked to "now" so it can be recovered whenever no lock is running.
"$DEST/bin/node" -e '
  require(process.argv[1]).rotateKeeper(Date.now()).then(() => process.exit(0), (e) => { console.error(e.message); process.exit(1); });
' "$DEST/src/hardmode.js" || die "could not set the timekeeper password (are you online?)."

echo "==> Registering the background service"
plist() {
  local label="$1" script="$2"
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array><string>$DEST/bin/node</string><string>$DEST/src/$script</string></array>
  <key>WorkingDirectory</key><string>$DEST</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>2</integer>
  <key>StandardOutPath</key><string>/Library/Logs/Time.log</string>
  <key>StandardErrorPath</key><string>/Library/Logs/Time.log</string>
</dict>
</plist>
EOF
}
plist com.time.blocker daemon.js > "$DEST/launchd/com.time.blocker.plist"
plist com.time.watchdog watchdog.js > "$DEST/launchd/com.time.watchdog.plist"
for l in "${LABELS[@]}"; do
  install -o root -g wheel -m 644 "$DEST/launchd/$l.plist" "/Library/LaunchDaemons/$l.plist"
done
rm -f "$DEST/state/uninstalling"
for l in "${LABELS[@]}"; do launchctl bootstrap system "/Library/LaunchDaemons/$l.plist"; done

# Make the program files undeletable without first clearing this flag (layer 2 friction).
chflags -R schg "$DEST/src" "$DEST/ui" "$DEST/bin" "$DEST/node_modules" "$DEST/launchd" \
  /Library/LaunchDaemons/com.time.blocker.plist /Library/LaunchDaemons/com.time.watchdog.plist

for i in $(seq 1 20); do
  curl -fs --max-time 1 http://localhost:7777/api/status >/dev/null && break
  sleep 0.5
done
curl -fs --max-time 1 http://localhost:7777/api/status >/dev/null || die "the service didn't start. See /Library/Logs/Time.log"

echo
echo "Installed. Open http://localhost:7777"
[ -n "${TIME_NO_OPEN:-}" ] || sudo -u "$USER_NAME" open "http://localhost:7777" || true
