'use strict';
const $ = (id) => document.getElementById(id);
const DURATIONS = [[30, '30 min'], [60, '1 h'], [120, '2 h'], [240, '4 h'], [480, '8 h'], [1440, '1 day']];

let S = null;            // last status from the service
let offset = 0;          // service's trusted time minus this browser's clock
let chosen = 120;
let appsLoaded = false;

const serverNow = () => Date.now() + offset;

async function api(path, body) {
  const res = await fetch(path, body === undefined ? {} : {
    method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Time': '1' }, body: JSON.stringify(body),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || `Request failed (${res.status}).`);
  return data;
}

function toast(msg, ok = false) {
  const t = $('toast');
  t.textContent = msg;
  t.classList.toggle('ok', ok);
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => (t.textContent = ''), 6000);
}

async function act(path, body, okMsg) {
  try {
    apply(await api(path, body));
    if (okMsg) toast(okMsg, true);
    return true;
  } catch (e) {
    toast(e.message);
    return false;
  }
}

function hms(ms) {
  const s = Math.max(0, Math.ceil(ms / 1000));
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60;
  const pad = (n) => String(n).padStart(2, '0');
  return h ? `${h}:${pad(m)}:${pad(sec)}` : `${pad(m)}:${pad(sec)}`;
}

function when(ms) {
  return new Date(ms).toLocaleString([], { weekday: 'short', hour: 'numeric', minute: '2-digit' });
}

function lockMinutes() {
  const h = parseFloat($('customHours').value);
  return Number.isFinite(h) && h > 0 ? Math.round(h * 60) : chosen;
}

// ---------- rendering ----------

function drawTicks() {
  const g = $('ticks');
  for (let i = 0; i < 60; i++) {
    const a = (i / 60) * Math.PI * 2;
    const major = i % 5 === 0;
    const r1 = 92, r2 = major ? 84 : 88;
    const l = document.createElementNS('http://www.w3.org/2000/svg', 'line');
    l.setAttribute('x1', 100 + r1 * Math.sin(a)); l.setAttribute('y1', 100 - r1 * Math.cos(a));
    l.setAttribute('x2', 100 + r2 * Math.sin(a)); l.setAttribute('y2', 100 - r2 * Math.cos(a));
    l.setAttribute('class', major ? 'tick major' : 'tick');
    g.appendChild(l);
  }
}

function renderChips() {
  const box = $('chips');
  box.innerHTML = '';
  for (const [min, label] of DURATIONS) {
    const b = document.createElement('button');
    b.className = 'chip';
    b.type = 'button';
    b.setAttribute('role', 'radio');
    b.setAttribute('aria-checked', String(min === chosen && !$('customHours').value));
    b.textContent = label;
    b.onclick = () => { chosen = min; $('customHours').value = ''; renderChips(); renderDial(); };
    box.appendChild(b);
  }
}

function renderDial() {
  if (!S) return;
  const vault = document.querySelector('.vault');
  const lock = S.lock;
  const arc = $('dialArc');
  if (lock) {
    const left = lock.endsAt - serverNow();
    const frac = Math.max(0, Math.min(1, left / (lock.endsAt - lock.startedAt)));
    vault.classList.add('is-locked');
    $('dialLabel').textContent = lock.hard ? 'Locked · hard mode' : 'Locked';
    $('dialTime').textContent = hms(left);
    $('dialSub').textContent = `opens ${when(lock.endsAt)}`;
    arc.style.strokeDasharray = `${frac * 1000} 1000`;
  } else {
    vault.classList.remove('is-locked');
    const on = S.blocks.filter((b) => b.enabled).length;
    $('dialLabel').textContent = 'Open';
    $('dialTime').textContent = hms(lockMinutes() * 60000);
    $('dialSub').textContent = on ? `${on} block${on > 1 ? 's' : ''} on, not locked` : 'nothing blocked';
    arc.style.strokeDasharray = '0 1000';
  }
}

const PER_GROUP = 6;
const openGroups = new Set();
const inApp = !!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.time);

function usage(sec) {
  if (sec == null) return '';
  const h = Math.floor(sec / 3600), m = Math.round((sec % 3600) / 60);
  if (h) return `${h} h${m ? ` ${m} min` : ''}`;
  return m ? `${m} min` : '< 1 min';
}

function coverage(b) {
  const parts = [];
  if (b.bundleIds.length) parts.push('Mac app');
  if (b.domains.length) parts.push(b.domains.length === 1 ? b.domains[0] : `${b.domains[0]} +${b.domains.length - 1}`);
  return parts.length ? parts.join(' · ') : 'not on this Mac';
}

function ago(ms) {
  const min = Math.round((serverNow() - ms) / 60000);
  if (min < 1) return 'just now';
  if (min < 60) return `${min} min ago`;
  const h = Math.round(min / 60);
  return h < 48 ? `${h} h ago` : `${Math.round(h / 24)} days ago`;
}

function blockRow(b) {
  const li = document.createElement('li');
  li.className = 'block' + (b.locked ? ' is-locked' : '');

  const text = document.createElement('div');
  text.className = 'block-text';
  const name = document.createElement('div');
  name.className = 'block-name';
  name.textContent = b.name;
  if (b.locked) {
    const tag = document.createElement('span');
    tag.className = 'lock-tag';
    tag.textContent = 'locked';
    name.appendChild(tag);
  }
  const sub = document.createElement('div');
  sub.className = 'block-what';
  sub.textContent = [b.seconds ? usage(b.seconds) : null, coverage(b)].filter(Boolean).join(' · ');
  text.append(name, sub);
  if (b.custom && !b.enabled) {
    const del = document.createElement('button');
    del.className = 'del';
    del.textContent = 'Delete';
    del.onclick = () => act(`/api/custom/${b.id}/delete`, {}, `Deleted ${b.name}.`);
    text.appendChild(del);
  }

  const bolt = document.createElement('button');
  bolt.className = 'bolt';
  bolt.setAttribute('role', 'switch');
  bolt.setAttribute('aria-checked', String(b.enabled));
  bolt.setAttribute('aria-label', `Block ${b.name}`);
  bolt.disabled = b.locked;
  bolt.title = b.locked ? `Locked until ${when(S.lock.endsAt)}` : b.enabled ? `Unblock ${b.name}` : `Block ${b.name}`;
  bolt.onclick = () => act(`/api/blocks/${b.id}`, { enabled: !b.enabled });

  li.append(text, bolt);
  return li;
}

function renderBlocks() {
  const imported = S.screenTime && S.screenTime.importedAt;
  $('stSource').textContent = imported
    ? `From your Screen Time, all devices, this week. Updated ${ago(S.screenTime.importedAt)}.`
    : inApp ? 'Reading your Screen Time list…' : 'Open the Time app to load your apps from Screen Time. Showing common apps until then.';
  $('stRefresh').hidden = !inApp;
  $('stNote').textContent = imported
    ? phoneNote || 'Toggles close Mac apps and block websites on this Mac. Locking an app also blocks it on your iPhone and iPad: Time turns on a Screen Time passcode nobody knows until the lock ends and gives the app a 1-minute daily limit that blocks when it runs out, with no Ignore Limit. Both are removed when the lock ends.'
    : '';

  const q = $('filter').value.trim().toLowerCase();
  const groups = new Map();
  for (const b of S.blocks) {
    if (q && !b.name.toLowerCase().includes(q)) continue;
    if (!groups.has(b.category)) groups.set(b.category, []);
    groups.get(b.category).push(b);
  }
  const total = (list) => list.reduce((n, b) => n + (b.seconds || 0), 0);
  const order = [...groups.entries()].sort((x, y) => total(y[1]) - total(x[1]) || x[0].localeCompare(y[0]));

  const root = $('groups');
  root.innerHTML = '';
  if (!order.length) {
    const p = document.createElement('p');
    p.className = 'hint';
    p.textContent = q ? `Nothing matches "${$('filter').value}".` : 'No apps yet.';
    root.appendChild(p);
  }
  for (const [cat, all] of order) {
    all.sort((x, y) => (y.seconds || 0) - (x.seconds || 0) || x.name.localeCompare(y.name));
    // Collapsed: the apps you actually used (top few) plus anything that's on.
    const expanded = !!q || openGroups.has(cat);
    let list = expanded ? all : all.filter((b, i) => b.enabled || (b.seconds > 0 && i < PER_GROUP));
    if (!list.length) list = all.slice(0, Math.min(3, all.length));

    const sec = document.createElement('section');
    sec.className = 'group';
    const head = document.createElement('div');
    head.className = 'group-head';
    const h = document.createElement('h3');
    h.textContent = cat;
    const meta = document.createElement('span');
    meta.className = 'group-meta';
    const t = total(all);
    meta.textContent = [t ? `${usage(t)} this week` : null, `${all.length} app${all.length === 1 ? '' : 's'}`].filter(Boolean).join(' · ');
    const on = all.filter((b) => b.enabled).length;
    if (on) {
      const span = document.createElement('span');
      span.className = 'on';
      span.textContent = ` · ${on} blocked`;
      meta.appendChild(span);
    }
    head.append(h, meta);

    const ul = document.createElement('ul');
    ul.className = 'block-list';
    for (const b of list) ul.appendChild(blockRow(b));
    sec.append(head, ul);

    const hidden = all.length - list.length;
    if (!q && (hidden > 0 || openGroups.has(cat))) {
      const more = document.createElement('button');
      more.className = 'ghost more';
      more.textContent = openGroups.has(cat) ? 'Show fewer' : `Show ${hidden} more`;
      more.onclick = () => { openGroups.has(cat) ? openGroups.delete(cat) : openGroups.add(cat); renderBlocks(); };
      sec.appendChild(more);
    }
    root.appendChild(sec);
  }
  $('neverLock').textContent = 'Never locked: Phone, Messages, FaceTime, and calendar apps. They are left out of this list on purpose.';
}

// Called by Time.app around a Screen Time read.
window.screenTimeBusy = (busy) => {
  $('stRefresh').disabled = busy;
  $('stRefresh').textContent = busy ? 'Reading Screen Time (about a minute)…' : 'Refresh from Screen Time';
};
window.screenTimeDone = (err, n) => {
  window.screenTimeBusy(false);
  if (err) toast(err); else toast(`Loaded ${n} apps from Screen Time.`, true);
  refresh();
};
// Called by Time.app while it adds or removes Screen Time limits for locked apps.
let phoneNote = '';
window.phoneSyncBusy = () => {
  phoneNote = 'Setting up Screen Time on your iPhone and iPad. System Settings comes up for about 30 seconds; please don’t touch the mouse or keyboard until it closes.';
  if (S) renderBlocks();
};
window.phoneSyncDone = (err, ok) => {
  phoneNote = '';
  if (err) toast(err); else if (ok) toast(ok, true);
  if (S) renderBlocks();
};
$('stRefresh').onclick = () => window.webkit.messageHandlers.time.postMessage('refreshScreenTime');
$('filter').addEventListener('input', () => renderBlocks());

function renderLock() {
  const lock = S.lock;
  $('lockPanel').hidden = !!lock;
  $('lockedPanel').hidden = !lock;
  $('emergency').hidden = !lock;
  $('emCooldown').textContent = S.limits.emergencyCooldownMinutes;
  if (lock) {
    $('lockedTitle').textContent = lock.hard ? 'Locked in hard mode' : 'Locked';
    $('lockedHint').textContent = `Until ${when(lock.endsAt)}. You can turn more blocks on, but nothing that's on can be turned off.`
      + (lock.keepAfter ? ' They stay on after the timer ends.' : ' They turn off when the timer ends.')
      + (lock.hard ? ' Your account is not an admin until then.' : '')
      + (S.screenTime && S.screenTime.passcodeHeld ? ' Screen Time is passcode-locked until then; apps you turn on now stay blocked on this Mac only.' : '');
    const em = lock.emergency;
    $('emIdle').hidden = !!em;
    renderEmTarget();
    if (em) {
      $('emTypingFor').textContent = em.blockId
        ? `Unlocking ${em.blockName || 'one app'} on this Mac only. Everything else stays locked.`
          + (S.screenTime && S.screenTime.passcodeHeld ? ' Its limit on your iPhone and iPad stays until the lock ends, because the Screen Time passcode does.' : '')
        : 'Unlocking everything.';
    }
    $('emTyping').hidden = !(em && em.challenge);
    $('emWaiting').hidden = !(em && em.unlockAt);
    if (em && em.challenge && $('emChallenge').textContent !== em.challenge) {
      $('emChallenge').textContent = em.challenge;
      $('emInput').value = '';
      updateProgress();
    }
  }
  const on = S.blocks.some((b) => b.enabled);
  $('lockBtn').disabled = !on;
  $('lockBtn').textContent = on ? `Lock for ${lockLabel()}` : 'Turn a block on to lock it';
  $('lockHint').textContent = on
    ? "While locked, nothing that's on can be turned off until the timer runs out."
    : 'Turn on at least one block below, then lock it.';
  const c = $('clockState');
  c.textContent = S.dev ? 'dev mode · nothing is really blocked' : S.clockSynced ? 'time checked online' : 'offline · lock time only counts while awake';
  c.classList.toggle('offline', !S.clockSynced);
}

// "Everything" or one locked app; keeps the choice across refreshes while that app is still locked.
function renderEmTarget() {
  const sel = $('emTarget');
  const locked = S.blocks.filter((b) => b.locked).sort((x, y) => x.name.localeCompare(y.name));
  const key = locked.map((b) => b.id).join(',');
  if (sel.dataset.key === key) return;
  const prev = sel.value;
  sel.dataset.key = key;
  sel.innerHTML = '';
  const all = document.createElement('option');
  all.value = '';
  all.textContent = 'Everything';
  sel.appendChild(all);
  for (const b of locked) {
    const o = document.createElement('option');
    o.value = b.id;
    o.textContent = `Only ${b.name}`;
    sel.appendChild(o);
  }
  sel.value = locked.some((b) => b.id === prev) ? prev : '';
}

function renderEmergencyWait() {
  const em = S?.lock?.emergency;
  if (em && em.unlockAt) {
    const what = em.blockId ? `${em.blockName || 'This app'} unlocks` : 'Blocks lift';
    $('emWaitText').textContent = `${what} in ${hms(em.unlockAt - serverNow())}. Cancel any time to stay locked.`;
  }
}

function lockLabel() {
  const m = lockMinutes();
  const h = Math.floor(m / 60), mm = m % 60;
  return h && mm ? `${h} h ${mm} min` : h ? `${h} h` : `${mm} min`;
}

let autoImportTried = false;
function apply(status) {
  S = status;
  // First open inside Time.app: fill the list from Screen Time automatically.
  if (inApp && !autoImportTried && S.screenTime && S.screenTime.needsRefresh) {
    autoImportTried = true;
    window.webkit.messageHandlers.time.postMessage('refreshScreenTime');
  }
  offset = S.now - Date.now();
  renderBlocks();
  renderLock();
  renderDial();
  renderEmergencyWait();
}

// ---------- emergency typing ----------

function norm(s) { return s.trim().replace(/\s+/g, ' ').toLowerCase(); }

function updateProgress() {
  const target = norm($('emChallenge').textContent);
  const typed = norm($('emInput').value);
  let i = 0;
  while (i < typed.length && typed[i] === target[i]) i++;
  const wrong = i < typed.length;
  $('emProgress').textContent = wrong
    ? `Typo after "${typed.slice(Math.max(0, i - 12), i)}". Fix it to continue.`
    : `${Math.floor((i / target.length) * 100)}% typed`;
}

for (const ev of ['paste', 'drop']) $('emInput').addEventListener(ev, (e) => { e.preventDefault(); toast('Pasting is off here. Type it out.'); });
$('emInput').addEventListener('input', (e) => {
  if (e.inputType && /insertFromPaste|insertFromDrop|insertReplacementText/.test(e.inputType)) $('emInput').value = '';
  updateProgress();
});
$('emChallenge').addEventListener('copy', (e) => e.preventDefault());
$('emStart').onclick = () => act('/api/emergency/start', $('emTarget').value ? { blockId: $('emTarget').value } : {});
$('emSubmit').onclick = () => act('/api/emergency/submit', { text: $('emInput').value }, 'Accepted. The cooldown has started.');
$('emCancel').onclick = $('emCancel2').onclick = () => act('/api/emergency/cancel', {}, 'Staying locked.');

// ---------- lock controls ----------

$('customHours').addEventListener('input', () => { renderChips(); apply(S); });
$('hardMode').addEventListener('change', (e) => {
  if (e.target.checked && lockMinutes() > S.limits.maxHardLockMinutes) toast('Hard mode is capped at 72 hours.');
});
$('lockBtn').onclick = async () => {
  const hard = $('hardMode').checked;
  const label = lockLabel();
  const msg = hard
    ? `Lock for ${label} in hard mode?\n\nYour account won't be an admin until it ends. The only early way out is the emergency unlock.`
    : `Lock for ${label}?\n\nYou won't be able to turn these blocks off until it ends.`;
  if (!confirm(msg)) return;
  $('lockBtn').disabled = true;
  await act('/api/lock', { minutes: lockMinutes(), hardMode: hard, keepAfter: $('keepAfter').checked }, `Locked for ${label}.`);
};
document.querySelectorAll('[data-extend]').forEach((b) => {
  b.onclick = () => act('/api/lock/extend', { minutes: +b.dataset.extend }, `Added ${b.textContent.slice(1)}.`);
});

// ---------- custom blocks ----------

$('addDetails').addEventListener('toggle', async () => {
  if (!$('addDetails').open || appsLoaded) return;
  try {
    const apps = await api('/api/apps');
    const sel = $('addApps');
    for (const a of apps.filter((x) => x.lockable)) {
      const o = document.createElement('option');
      o.value = a.bundleId;
      o.textContent = a.name;
      sel.appendChild(o);
    }
    appsLoaded = true;
  } catch (e) { toast(e.message); }
});
$('addForm').onsubmit = async (e) => {
  e.preventDefault();
  const ok = await act('/api/custom', {
    name: $('addName').value,
    bundleIds: [...$('addApps').selectedOptions].map((o) => o.value),
    domains: $('addDomains').value.split(/[\s,]+/).filter(Boolean),
  }, `Added ${$('addName').value}. Turn it on below.`);
  if (ok) { $('addForm').reset(); }
};

// ---------- boot ----------

drawTicks();
renderChips();
async function refresh() {
  try { apply(await api('/api/status')); }
  catch { $('clockState').textContent = 'The Time service is not running'; $('clockState').classList.add('offline'); }
}
refresh();
setInterval(refresh, 5000);
setInterval(() => { renderDial(); renderEmergencyWait(); }, 1000);
