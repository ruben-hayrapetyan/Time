'use strict';
// Self-protection (layer 2). The service and this watchdog each check every few
// seconds that the other is loaded in launchd and reload it (restoring its plist
// from the install folder if it was deleted) when it isn't.
const fs = require('fs');
const path = require('path');
const { execFile } = require('child_process');
const { INSTALL_DIR } = require('./config');

const LABELS = ['com.time.blocker', 'com.time.watchdog'];

function plistPath(label) {
  return `/Library/LaunchDaemons/${label}.plist`;
}

function loaded(label) {
  return new Promise((resolve) => execFile('/bin/launchctl', ['print', `system/${label}`], (err) => resolve(!err)));
}

function stopRequested() {
  // The uninstaller drops this file so the pair stands down, but it's ignored while a lock runs.
  if (!fs.existsSync(path.join(INSTALL_DIR, 'state', 'uninstalling'))) return false;
  try {
    const s = JSON.parse(fs.readFileSync(path.join(INSTALL_DIR, 'state', 'state.json'), 'utf8'));
    if (s.lock && s.lock.endsAt > (s.lastTrusted || 0)) return false;
  } catch {}
  return true;
}

async function ensure(label, log) {
  if (stopRequested() || (await loaded(label))) return;
  const dest = plistPath(label);
  const backup = path.join(INSTALL_DIR, 'launchd', `${label}.plist`);
  try {
    if (!fs.existsSync(dest) && fs.existsSync(backup)) fs.copyFileSync(backup, dest);
    // Undo a `launchctl disable` first, or the reload would be refused.
    execFile('/bin/launchctl', ['enable', `system/${label}`], () => {
      execFile('/bin/launchctl', ['bootstrap', 'system', dest], (err) => {
        log(err ? `could not reload ${label}: ${err.message}` : `reloaded ${label}`);
      });
    });
  } catch (e) {
    log(`could not restore ${label}: ${e.message}`);
  }
}

if (require.main === module) {
  const log = (m) => console.log(`${new Date().toISOString()} watchdog: ${m}`);
  setInterval(() => ensure(LABELS[0], log), 5000);
}

module.exports = { ensure, LABELS };
