'use strict';
// Turns the list Time.app reads from Screen Time (App & Website Activity, all devices,
// this week) into blocks. Each one gets whatever Mac enforcement we can find for it:
// the Mac app with the same name, and known websites for that service.
const { PRESETS } = require('./config');

// Apple's own names for the apps that must never lock. Anything with "Calendar" in its
// name counts, so Google Calendar and other calendar apps are covered too.
function isNeverLock(name) {
  return name === 'Phone' || name === 'Messages' || name === 'FaceTime' || /calendar/i.test(name);
}

// System pieces that show up in Screen Time but aren't things you'd block (and Settings
// must stay usable, because Time works through it).
function isSystem(name) {
  return /^com\.apple\./.test(name) || ['Finder', 'Settings', 'System Settings', 'Time', 'Clock', 'Find My'].includes(name);
}

function isDomain(name) {
  return /^(?!com\.)[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}$/i.test(name);
}

// "Discord - Talk, Play, Hang Out" → "Discord"; "Strava: Run, Bike, Walk" → "Strava".
function baseName(name) {
  return name.split(/ [-–—] |: | by /)[0].replace(/[^\p{L}\p{N}.&' +]/gu, '').trim();
}

const slug = (s) => s.toLowerCase().normalize('NFKD').replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 48) || 'app';

function hintDomains(base) {
  const b = base.toLowerCase();
  const preset = PRESETS.find((p) => p.id === b || p.name.toLowerCase() === b || p.name.toLowerCase().split(' / ').includes(b));
  if (preset) return preset.domains;
  if (isDomain(base)) return [base.toLowerCase()];
  return [];
}

function macBundleIds(base, full, installed) {
  const want = new Set([base.toLowerCase(), full.toLowerCase()]);
  return installed.filter((a) => a.lockable && want.has(a.name.toLowerCase())).map((a) => a.bundleId);
}

function toBlock(item, installed) {
  const domainItem = isDomain(item.name);
  const base = domainItem ? item.name : baseName(item.name);
  return {
    id: 'st-' + slug(item.name),
    name: item.name,
    shortName: base || item.name,
    source: 'screentime',
    seconds: item.seconds,
    hasLimit: !!item.hasLimit,
    bundleIds: domainItem ? [] : macBundleIds(base, item.name, installed),
    domains: domainItem ? [item.name.toLowerCase()] : hintDomains(base),
    custom: false,
  };
}

function sanitizeItems(raw) {
  if (!Array.isArray(raw)) throw new Error('items must be a list');
  const out = [];
  for (const it of raw.slice(0, 1000)) {
    const name = String(it?.name ?? '').trim().slice(0, 200);
    if (!name) continue;
    out.push({ name, seconds: Math.max(0, Math.floor(Number(it.seconds) || 0)), hasLimit: !!it.hasLimit });
  }
  return out;
}

module.exports = { isNeverLock, isSystem, isDomain, baseName, toBlock, sanitizeItems, slug };
