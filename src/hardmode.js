'use strict';
// Hard mode (layer 5). For the length of a lock, your account stops being an admin,
// so you can't sudo your way around the blocker. A hidden "timekeeper" admin account
// stays on the Mac as the fallback; its password is random and time-lock encrypted
// with drand, so nobody can decrypt it until the lock's end time. The service itself
// runs as root and puts you back in the admin group when the lock ends.
const { execFile } = require('child_process');
const { promisify } = require('util');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { DEV, paths } = require('./config');

const run = promisify(execFile);
const KEEPER = 'timekeeper';

let tlock;
function tl() {
  if (!tlock) tlock = require('tlock-js');
  return tlock;
}

function randomPassword() {
  return crypto.randomBytes(24).toString('base64').replace(/[+/=]/g, '').slice(0, 28);
}

async function sh(cmd, args) {
  if (DEV) return { stdout: '', stderr: '' };
  return run(cmd, args);
}

async function isAdmin(user) {
  if (DEV) return devAdmin.get(user) ?? true;
  try {
    const { stdout } = await run('/usr/sbin/dseditgroup', ['-o', 'checkmember', '-m', user, 'admin']);
    return stdout.startsWith('yes');
  } catch {
    return false;
  }
}
const devAdmin = new Map();

async function keeperExists() {
  if (DEV) return true;
  try {
    await run('/usr/bin/dscl', ['.', '-read', `/Users/${KEEPER}`, 'UniqueID']);
    return true;
  } catch {
    return false;
  }
}

async function setKeeperPassword(pw) {
  await sh('/usr/bin/dscl', ['.', '-passwd', `/Users/${KEEPER}`, pw]);
  // Confirm the new password actually took before anything depends on it.
  await sh('/usr/bin/dscl', ['.', '-authonly', KEEPER, pw]);
}

// Encrypts `secret` so it can only be decrypted once drand publishes the round for `unlockAtMs`.
async function timelock(secret, unlockAtMs) {
  const { timelockEncrypt, mainnetClient, roundAt, Buffer } = tl();
  const client = mainnetClient();
  const info = await client.chain().info();
  const round = roundAt(unlockAtMs, info);
  const ciphertext = await timelockEncrypt(round, Buffer.from(secret), client);
  return { round, ciphertext };
}

async function timeunlock(ciphertext) {
  const { timelockDecrypt, mainnetClient } = tl();
  return (await timelockDecrypt(ciphertext, mainnetClient())).toString();
}

function saveRecovery(obj) {
  fs.mkdirSync(path.dirname(paths.recovery), { recursive: true });
  // Safe to leave readable: it's useless until the unlock time.
  fs.writeFileSync(paths.recovery, JSON.stringify(obj, null, 2), { mode: 0o644 });
}

// Rotates the timekeeper password to a new random one that unlocks at `unlockAtMs`.
async function rotateKeeper(unlockAtMs) {
  const pw = randomPassword();
  const { round, ciphertext } = await timelock(pw, unlockAtMs); // throws if offline: then nothing changes
  await setKeeperPassword(pw);
  saveRecovery({ account: KEEPER, unlocksAt: new Date(unlockAtMs).toISOString(), round, ciphertext });
  return round;
}

async function demote(user) {
  if (DEV) { devAdmin.set(user, false); return; }
  await run('/usr/sbin/dseditgroup', ['-o', 'edit', '-d', user, '-t', 'user', 'admin']);
  await run('/usr/bin/dscacheutil', ['-flushcache']).catch(() => {});
}

async function promote(user) {
  if (DEV) { devAdmin.set(user, true); return; }
  await run('/usr/sbin/dseditgroup', ['-o', 'edit', '-a', user, '-t', 'user', 'admin']);
  await run('/usr/bin/dscacheutil', ['-flushcache']).catch(() => {});
}

// Root shells opened before the lock (e.g. a `sudo -s` left running) would survive
// the demotion, so while hard mode is on, any sudo/su session gets closed.
async function killElevatedSessions(log) {
  if (DEV) return;
  const { stdout } = await run('/bin/ps', ['-axww', '-o', 'pid=,ppid=,comm=']);
  const procs = stdout.split('\n').map((l) => l.trim().match(/^(\d+)\s+(\d+)\s+(.+)$/)).filter(Boolean)
    .map((m) => ({ pid: +m[1], ppid: +m[2], comm: m[3] }));
  const roots = procs.filter((p) => /(^|\/)(sudo|su)$/.test(p.comm)).map((p) => p.pid);
  if (!roots.length) return;
  const kill = new Set(roots);
  let grew = true;
  while (grew) {
    grew = false;
    for (const p of procs) if (kill.has(p.ppid) && !kill.has(p.pid)) { kill.add(p.pid); grew = true; }
  }
  for (const pid of kill) { try { process.kill(pid, 'SIGKILL'); } catch {} }
  log(`hard mode: closed ${kill.size} elevated process(es)`);
}

async function begin(user, endsAtMs, log) {
  if (!(await keeperExists())) throw new Error('The timekeeper account is missing. Re-run the installer.');
  if (!(await isAdmin(user))) throw new Error(`${user} is not currently an admin, so there's nothing to take away.`);
  await rotateKeeper(endsAtMs);
  await demote(user);
  if (await isAdmin(user)) throw new Error('Could not remove admin rights.');
  log(`hard mode: ${user} demoted until ${new Date(endsAtMs).toISOString()}`);
}

async function end(user, log) {
  await promote(user);
  if (!(await isAdmin(user))) throw new Error('Could not restore admin rights.');
  log(`hard mode: ${user} is an admin again`);
}

module.exports = { begin, end, isAdmin, keeperExists, rotateKeeper, timelock, timeunlock, killElevatedSessions, randomPassword, KEEPER };
