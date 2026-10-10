'use strict';
// The Time service. Runs as root from launchd, enforces blocks, owns the lock timer,
// and serves the control page on http://localhost:7777.
const fs = require('fs');
const path = require('path');
const http = require('http');
const crypto = require('crypto');
const { execFile } = require('child_process');

const cfg = require('./config');
const { TrustedClock } = require('./clock');
const { enforceApps, installedApps, isLockable } = require('./enforce-apps');
const { enforceWeb, expand, normalizeDomain, isValidDomain, isProtectedDomain } = require('./enforce-web');
const hard = require('./hardmode');
const words = require('./words');
const watchdog = require('./watchdog');

const MIN = 60 * 1000;
const VERSION = require('../package.json').version;

function log(msg) {
  console.log(`${new Date().toISOString()} ${msg}`);
}

// ---------- state ----------

function defaultState() {
  return { version: 1, enabled: {}, custom: [], lock: null, hard: null, lastTrusted: 0 };
}

function loadState() {
  try {
    return { ...defaultState(), ...JSON.parse(fs.readFileSync(cfg.paths.state, 'utf8')) };
  } catch {
    return defaultState();
  }
}

const state = loadState();
const clock = new TrustedClock(state.lastTrusted, log);

function save() {
  state.lastTrusted = Math.max(state.lastTrusted || 0, clock.now());
  fs.mkdirSync(path.dirname(cfg.paths.state), { recursive: true, mode: 0o700 });
  const tmp = cfg.paths.state + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(state, null, 2), { mode: 0o600 });
  fs.renameSync(tmp, cfg.paths.state);
}

function installInfo() {
  try {
    return JSON.parse(fs.readFileSync(cfg.paths.installConfig, 'utf8'));
  } catch {
    return { user: process.env.USER, uid: process.getuid() };
  }
}

// ---------- blocks & lock ----------

const allBlocks = () => [...cfg.PRESETS.map((b) => ({ ...b, custom: false })), ...state.custom.map((b) => ({ ...b, custom: true }))];
const findBlock = (id) => allBlocks().find((b) => b.id === id);
const lockActive = () => !!state.lock && clock.now() < state.lock.endsAt;
const isLocked = (id) => lockActive() && state.lock.lockedIds.includes(id);
const enabledBlocks = () => allBlocks().filter((b) => state.enabled[b.id]);

class UserError extends Error {}

function setEnabled(id, on) {
  const b = findBlock(id);
  if (!b) throw new UserError('Unknown block.');
  if (!on && isLocked(id)) throw new UserError(`${b.name} is locked until ${fmt(state.lock.endsAt)}.`);
  state.enabled[id] = !!on;
  // Anything switched on during a lock joins the lock.
  if (on && lockActive() && !state.lock.lockedIds.includes(id)) state.lock.lockedIds.push(id);
  save();
  enforceNow();
}

function fmt(ms) {
  return new Date(ms).toLocaleString('en-US', { hour: 'numeric', minute: '2-digit', month: 'short', day: 'numeric' });
}

let hardBusy = false;

async function startLock({ minutes, hardMode, keepAfter }) {
  minutes = Math.round(Number(minutes));
  if (!Number.isFinite(minutes) || minutes < 1) throw new UserError('Pick a duration.');
  if (lockActive()) throw new UserError('A lock is already running. You can extend it instead.');
  const max = hardMode ? cfg.LIMITS.maxHardLockMinutes : cfg.LIMITS.maxLockMinutes;
  if (minutes > max) throw new UserError(`Longest allowed is ${max / 60} hours${hardMode ? ' in hard mode' : ''}.`);
  const ids = enabledBlocks().map((b) => b.id);
  if (!ids.length) throw new UserError('Turn on at least one block first.');
  if (hardMode && !clock.synced) throw new UserError("Hard mode needs an internet connection to start (the timekeeper password is locked with drand). Try again once you're online.");

  const now = clock.now();
  const endsAt = now + minutes * MIN;
  if (hardMode) {
    if (hardBusy) throw new UserError('Hard mode is busy, try again in a moment.');
    hardBusy = true;
    const { user } = installInfo();
    // Record intent before touching accounts, so a crash mid-way gets repaired on restart.
    state.hard = { active: true, user, since: now };
    save();
    try {
      await hard.begin(user, endsAt, log);
    } catch (e) {
      log(`hard mode failed to start: ${e.message}`);
      try { await hard.end(user, log); } catch {}
      state.hard = null;
      save();
      throw new UserError(`Hard mode couldn't start: ${e.message}`);
    } finally {
      hardBusy = false;
    }
  }
  state.lock = { startedAt: now, endsAt, lockedIds: ids, hard: !!hardMode, keepAfter: !!keepAfter, emergency: null };
  save();
  log(`lock started for ${minutes} min (${ids.join(', ')})${hardMode ? ' [hard mode]' : ''}`);
}

function extendLock(minutes) {
  minutes = Math.round(Number(minutes));
  if (!lockActive()) throw new UserError('No lock is running.');
  if (!Number.isFinite(minutes) || minutes < 1) throw new UserError('Pick how long to extend by.');
  const max = state.lock.hard ? cfg.LIMITS.maxHardLockMinutes : cfg.LIMITS.maxLockMinutes;
  const endsAt = state.lock.endsAt + minutes * MIN;
  if (endsAt - clock.now() > max * MIN) throw new UserError(`A lock can't run more than ${max / 60} hours from now.`);
  if (state.lock.hard) {
    // The timekeeper fallback password must not unlock before the new end time.
    return hard.rotateKeeper(endsAt).then(() => {
      state.lock.endsAt = endsAt;
      save();
    }, (e) => { throw new UserError(`Couldn't extend hard mode (needs internet): ${e.message}`); });
  }
  state.lock.endsAt = endsAt;
  save();
}

async function finishLock(reason) {
  if (!state.lock) return;
  log(`lock ended (${reason})`);
  if (!state.lock.keepAfter) for (const id of state.lock.lockedIds) state.enabled[id] = false;
  state.lock = null;
  save();
  enforceNow();
}

async function repairHardMode() {
  if (!state.hard?.active || hardBusy) return;
  hardBusy = true;
  try {
    if (lockActive() && state.lock.hard) {
      if (await hard.isAdmin(state.hard.user)) {
        log('hard mode: admin rights reappeared during a lock; removing again');
        await hard.begin(state.hard.user, state.lock.endsAt, log);
      }
      await hard.killElevatedSessions(log);
    } else {
      await hard.end(state.hard.user, log);
      state.hard = null;
      save();
      // Leave the timekeeper password decryptable right away now that nothing is locked.
      hard.rotateKeeper(clock.now()).catch(() => {});
    }
  } catch (e) {
    log(`hard mode repair failed (will retry): ${e.message}`);
  } finally {
    hardBusy = false;
  }
}

// ---------- emergency exit (layer 4) ----------

function emergencyStart() {
  if (!lockActive()) throw new UserError('No lock is running.');
  if (state.lock.emergency?.unlockAt) throw new UserError('An emergency unlock is already counting down.');
  state.lock.emergency = { challenge: words.challenge(50), issuedAt: clock.now(), unlockAt: null };
  save();
}

function emergencySubmit(text) {
  const e = state.lock?.emergency;
  if (!lockActive() || !e?.challenge) throw new UserError('Start an emergency unlock first.');
  const norm = (s) => String(s || '').trim().replace(/\s+/g, ' ').toLowerCase();
  if (norm(text) !== norm(e.challenge)) throw new UserError("That doesn't match the text exactly.");
  const typedFor = (clock.now() - e.issuedAt) / 1000;
  if (typedFor < cfg.LIMITS.emergencyMinTypingSeconds) {
    throw new UserError(`That was too fast to have been typed (${Math.round(typedFor)}s). Type it by hand.`);
  }
  state.lock.emergency = { challenge: null, issuedAt: e.issuedAt, unlockAt: clock.now() + cfg.LIMITS.emergencyCooldownMinutes * MIN };
  save();
  log('emergency unlock accepted; cooldown started');
}

function emergencyCancel() {
  if (state.lock) {
    state.lock.emergency = null;
    save();
  }
}

// ---------- custom blocks ----------

function addCustom({ name, bundleIds = [], domains = [] }) {
  name = String(name || '').trim().slice(0, 40);
  if (!name) throw new UserError('Give it a name.');
  const ids = [...new Set(bundleIds.map(String))];
  for (const id of ids) if (!isLockable(id)) throw new UserError(`${id} can't be blocked (it's on the never-lock list or needed by macOS).`);
  const doms = [...new Set(domains.map(normalizeDomain).filter(Boolean))];
  for (const d of doms) {
    if (!isValidDomain(d)) throw new UserError(`"${d}" isn't a valid domain.`);
    if (isProtectedDomain(d)) throw new UserError(`${d} can't be blocked; Messages, Calendar, or the lock timer depend on it.`);
  }
  if (!ids.length && !doms.length) throw new UserError('Pick at least one app or website.');
  const id = 'c-' + crypto.randomBytes(4).toString('hex');
  state.custom.push({ id, name, bundleIds: ids, domains: doms });
  save();
  return id;
}

function removeCustom(id) {
  if (isLocked(id) || state.enabled[id]) throw new UserError('Turn it off before deleting it.');
  state.custom = state.custom.filter((c) => c.id !== id);
  delete state.enabled[id];
  save();
}

// ---------- enforcement loop ----------

const lastNotified = new Map();

function notify(text) {
  if (cfg.DEV) return log(`[notify] ${text}`);
  const { uid, user } = installInfo();
  const script = `display notification ${JSON.stringify(text)} with title "Time"`;
  execFile('/bin/launchctl', ['asuser', String(uid), '/usr/bin/sudo', '-u', user, '/usr/bin/osascript', '-e', script], () => {});
}

let enforcing = false;
async function enforceNow() {
  if (enforcing) return;
  enforcing = true;
  try {
    const blocks = enabledBlocks();
    const closed = await enforceApps(blocks.flatMap((b) => b.bundleIds), log);
    for (const name of closed) {
      if (Date.now() - (lastNotified.get(name) || 0) < 30000) continue;
      lastNotified.set(name, Date.now());
      notify(lockActive() ? `${name} is locked until ${fmt(state.lock.endsAt)}.` : `${name} is blocked.`);
    }
    enforceWeb(blocks.flatMap((b) => b.domains), log);
  } catch (e) {
    log(`enforce error: ${e.message}`);
  } finally {
    enforcing = false;
  }
}

async function tick() {
  if (state.lock) {
    const now = clock.now();
    if (now >= state.lock.endsAt) await finishLock('timer finished');
    else if (state.lock.emergency?.unlockAt && now >= state.lock.emergency.unlockAt) await finishLock('emergency unlock');
  }
  await repairHardMode();
  await enforceNow();
}

// ---------- HTTP ----------

function status() {
  const now = clock.now();
  return {
    now,
    clockSynced: clock.synced,
    lock: state.lock && {
      endsAt: state.lock.endsAt,
      startedAt: state.lock.startedAt,
      hard: state.lock.hard,
      keepAfter: state.lock.keepAfter,
      emergency: state.lock.emergency && { challenge: state.lock.emergency.challenge, issuedAt: state.lock.emergency.issuedAt, unlockAt: state.lock.emergency.unlockAt },
    },
    hardActive: !!state.hard?.active,
    blocks: allBlocks().map((b) => ({
      id: b.id, name: b.name, custom: b.custom, bundleIds: b.bundleIds, domains: b.domains,
      enabled: !!state.enabled[b.id], locked: isLocked(b.id),
    })),
    neverLock: cfg.NEVER_LOCK,
    limits: cfg.LIMITS,
    dev: cfg.DEV,
    version: VERSION,
  };
}

const UI_DIR = path.join(__dirname, '..', 'ui');
const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml' };
const ALLOWED_HOSTS = new Set([`localhost:${cfg.PORT}`, `127.0.0.1:${cfg.PORT}`]);

function send(res, code, body) {
  res.writeHead(code, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
  res.end(JSON.stringify(body));
}

async function readJson(req) {
  let raw = '';
  for await (const chunk of req) {
    raw += chunk;
    if (raw.length > 100000) throw new UserError('Request too large.');
  }
  return raw ? JSON.parse(raw) : {};
}

let appsCache = null;

async function handle(req, res) {
  // Only this machine's browser, on this exact origin, may talk to the service. This blocks
  // other websites from flipping toggles or starting locks through your browser.
  if (!ALLOWED_HOSTS.has(req.headers.host)) return send(res, 403, { error: 'Forbidden host.' });
  const origin = req.headers.origin;
  if (origin && !ALLOWED_HOSTS.has(origin.replace(/^https?:\/\//, ''))) return send(res, 403, { error: 'Forbidden origin.' });

  const url = new URL(req.url, `http://${req.headers.host}`);
  const p = url.pathname;

  if (req.method === 'GET' && !p.startsWith('/api/')) {
    const file = p === '/' ? 'index.html' : p.slice(1);
    if (!/^[a-z0-9._-]+$/i.test(file)) return send(res, 404, { error: 'Not found' });
    try {
      const data = fs.readFileSync(path.join(UI_DIR, file));
      res.writeHead(200, { 'Content-Type': MIME[path.extname(file)] || 'application/octet-stream', 'Cache-Control': 'no-store' });
      return res.end(data);
    } catch {
      return send(res, 404, { error: 'Not found' });
    }
  }

  if (req.method === 'GET' && p === '/api/status') return send(res, 200, status());
  if (req.method === 'GET' && p === '/api/apps') {
    appsCache = appsCache || (await installedApps());
    return send(res, 200, appsCache);
  }

  if (req.method !== 'POST' || req.headers['x-time'] !== '1') return send(res, 404, { error: 'Not found' });
  const body = await readJson(req);
  let m;
  if ((m = p.match(/^\/api\/blocks\/([\w-]+)$/))) setEnabled(m[1], body.enabled);
  else if (p === '/api/custom') addCustom(body);
  else if ((m = p.match(/^\/api\/custom\/([\w-]+)\/delete$/))) removeCustom(m[1]);
  else if (p === '/api/lock') await startLock(body);
  else if (p === '/api/lock/extend') await extendLock(body.minutes);
  else if (p === '/api/emergency/start') emergencyStart();
  else if (p === '/api/emergency/submit') emergencySubmit(body.text);
  else if (p === '/api/emergency/cancel') emergencyCancel();
  else return send(res, 404, { error: 'Not found' });
  return send(res, 200, status());
}

function main() {
  if (!cfg.DEV && process.getuid() !== 0) {
    console.error('The Time service must run as root (it is started by launchd).');
    process.exit(1);
  }
  log(`Time service starting${cfg.DEV ? ' in DEV mode (nothing is really blocked)' : ''}`);
  const server = http.createServer((req, res) => {
    handle(req, res).catch((e) => {
      if (!(e instanceof UserError)) log(`request error: ${e.stack || e.message}`);
      send(res, e instanceof UserError ? 400 : 500, { error: e instanceof UserError ? e.message : 'Something went wrong.' });
    });
  });
  server.listen(cfg.PORT, '127.0.0.1', () => log(`control page on http://localhost:${cfg.PORT}`));

  clock.sync().finally(() => save());
  setInterval(() => clock.sync(), 60 * 1000);
  setInterval(() => tick().catch((e) => log(`tick error: ${e.message}`)), 1000);
  setInterval(save, 15 * 1000);
  if (!cfg.DEV) setInterval(() => watchdog.ensure('com.time.watchdog', log), 5000);
  for (const sig of ['SIGTERM', 'SIGINT']) process.on(sig, () => { save(); process.exit(0); });
}

if (require.main === module) main();

module.exports = { expand };
