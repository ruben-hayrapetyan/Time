'use strict';
// Closes blocked Mac apps. Matches by bundle ID (read from each running app's
// Info.plist), so renaming or moving an app doesn't get it past the block.
const { execFile } = require('child_process');
const { promisify } = require('util');
const fs = require('fs');
const path = require('path');
const { DEV, NEVER_LOCK, CRITICAL_BUNDLE_IDS, PROTECTED_PATH_PREFIXES } = require('./config');

const run = promisify(execFile);
const NEVER = new Set([...NEVER_LOCK.map((a) => a.bundleId), ...CRITICAL_BUNDLE_IDS]);
const bundleIdCache = new Map();

function isLockable(bundleId) {
  return !!bundleId && !NEVER.has(bundleId);
}

async function readBundleId(appPath) {
  if (bundleIdCache.has(appPath)) return bundleIdCache.get(appPath);
  let id = null;
  // Mac apps keep Info.plist in Contents/; iPhone/iPad apps on Apple silicon keep it at the bundle root.
  for (const plist of [path.join(appPath, 'Contents', 'Info.plist'), path.join(appPath, 'Info.plist')]) {
    if (!fs.existsSync(plist)) continue;
    try {
      const { stdout } = await run('/usr/bin/plutil', ['-extract', 'CFBundleIdentifier', 'raw', '-o', '-', plist]);
      id = stdout.trim() || null;
      if (id) break;
    } catch {}
  }
  bundleIdCache.set(appPath, id);
  return id;
}

// Every ".app" bundle enclosing an executable path, outermost first.
function enclosingApps(exePath) {
  const out = [];
  let idx = exePath.indexOf('.app/');
  while (idx !== -1) {
    out.push(exePath.slice(0, idx + 4));
    idx = exePath.indexOf('.app/', idx + 5);
  }
  return out;
}

async function runningApps() {
  const { stdout } = await run('/bin/ps', ['-axww', '-o', 'pid=,comm='], { maxBuffer: 16 * 1024 * 1024 });
  const procs = [];
  for (const line of stdout.split('\n')) {
    const m = line.match(/^\s*(\d+)\s+(\/.+)$/);
    if (!m) continue;
    const exe = m[2];
    if (PROTECTED_PATH_PREFIXES.some((p) => exe.startsWith(p))) continue;
    const apps = enclosingApps(exe);
    if (!apps.length) continue;
    const ids = [];
    for (const a of apps) {
      const id = await readBundleId(a);
      if (id) ids.push(id);
    }
    procs.push({ pid: Number(m[1]), exe, appPath: apps[0], ids });
  }
  return procs;
}

// Returns the processes it closed, grouped by app name, for notifications.
async function enforceApps(blockedBundleIds, log) {
  const blocked = new Set([...blockedBundleIds].filter(isLockable));
  if (!blocked.size) return [];
  const victims = (await runningApps()).filter(
    (p) => p.ids.some((id) => blocked.has(id)) && !p.ids.some((id) => NEVER.has(id)),
  );
  const closed = new Set();
  for (const p of victims) {
    closed.add(path.basename(p.appPath, '.app'));
    if (DEV) {
      log(`[dry-run] would close ${p.exe} (pid ${p.pid})`);
      continue;
    }
    try { process.kill(p.pid, 'SIGTERM'); } catch {}
    setTimeout(() => { try { process.kill(p.pid, 'SIGKILL'); } catch {} }, 1500);
  }
  return [...closed];
}

async function installedApps() {
  const dirs = ['/Applications', '/Applications/Utilities', '/System/Applications'];
  const out = [];
  for (const d of dirs) {
    let entries = [];
    try { entries = fs.readdirSync(d); } catch { continue; }
    for (const e of entries) {
      if (!e.endsWith('.app')) continue;
      const p = path.join(d, e);
      let id = await readBundleId(p);
      if (!id) {
        // iPhone/iPad apps installed on the Mac are wrapped one level deeper.
        try {
          const inner = fs.readdirSync(path.join(p, 'Wrapper')).find((x) => x.endsWith('.app'));
          if (inner) id = await readBundleId(path.join(p, 'Wrapper', inner));
        } catch {}
      }
      if (id) out.push({ name: e.slice(0, -4), bundleId: id, lockable: isLockable(id) });
    }
  }
  return out.sort((a, b) => a.name.localeCompare(b.name));
}

module.exports = { enforceApps, installedApps, isLockable };
