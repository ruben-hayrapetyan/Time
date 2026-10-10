'use strict';
// Turns the list Time.app reads from Screen Time (App & Website Activity, all devices,
// this week) into blocks. Each one gets whatever Mac enforcement we can find for it:
// the Mac app with the same name, and known websites for that service.
const { PRESETS } = require('./config');

// Apple's own names for the apps that must never lock. Anything with "Calendar" in its
// name counts, so Google Calendar and other calendar apps are covered too.
function isNeverLock(name) {
  name = displayName(name);
  return name === 'Phone' || name === 'Messages' || name === 'FaceTime' || /calendar/i.test(name);
}

// System pieces that show up in Screen Time but aren't things you'd block (and Settings
// must stay usable, because Time works through it).
function isSystem(name) {
  return /^com\.apple\./.test(name) || ['Finder', 'Settings', 'System Settings', 'Time', 'Clock', 'Find My'].includes(name);
}

const WEB_TLDS = new Set(['com', 'org', 'net', 'edu', 'gov', 'io', 'co', 'us', 'app', 'dev', 'ai', 'tv', 'me', 'gg', 'ly', 'uk', 'de', 'fr', 'jp', 'ca', 'info', 'xyz']);

// Website names are lowercase with a web ending ("gradescope.com"); anything else dotted and
// spaceless is an app ID, like "com.flowerave.sidechat" or "doordash.DoorDashConsumer".
function isDomain(name) {
  if (/\s/.test(name) || !name.includes('.') || name !== name.toLowerCase()) return false;
  const parts = name.split('.');
  if (['com', 'org', 'net', 'io', 'gov'].includes(parts[0]) && parts.length > 2) return false;
  return WEB_TLDS.has(parts[parts.length - 1]);
}

function isBundleId(name) {
  return !/\s/.test(name) && name.includes('.') && !isDomain(name);
}

const GENERIC = /^(app|ios|iphone|ipad|mobile|mobileapp|official|prod|client|en|us|phone|ver\d*|v\d+|\d+)$/i;
const NOISE = /iphone|ipad|ios|prod|mobile|app$/gi;

// "com.flowerave.sidechat" → "Sidechat"; "doordash.DoorDashConsumer" → "Door Dash Consumer".
function displayName(name) {
  if (!isBundleId(name)) return name;
  const parts = name.split('.').slice(1).map((p) => p.replace(NOISE, '')).filter((p) => p.length > 1 && !GENERIC.test(p));
  const pick = parts[parts.length - 1] || name.split('.')[1] || name;
  if (pick.length <= 3) return pick.toUpperCase();
  const spaced = pick.replace(/([a-z])([A-Z])/g, '$1 $2').replace(/[-_]+/g, ' ');
  return spaced.charAt(0).toUpperCase() + spaced.slice(1);
}

// "Discord - Talk, Play, Hang Out" → "Discord"; "Strava: Run, Bike, Walk" → "Strava".
function baseName(name) {
  if (isBundleId(name)) return displayName(name);
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
  return installed.filter((a) => a.lockable && (want.has(a.name.toLowerCase()) || a.bundleId === full)).map((a) => a.bundleId);
}

function toBlock(item, installed) {
  const domainItem = isDomain(item.name);
  const base = domainItem ? item.name : baseName(item.name);
  return {
    id: 'st-' + slug(item.name),
    name: displayName(item.name),
    screenTimeName: item.name,
    category: item.category || (domainItem ? 'Websites' : 'Other'),
    used: item.source !== 'limits',
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
    out.push({
      name,
      seconds: Math.max(0, Math.floor(Number(it.seconds) || 0)),
      hasLimit: !!it.hasLimit,
      category: it.category ? String(it.category).slice(0, 60) : null,
      source: it.source === 'limits' ? 'limits' : 'activity',
    });
  }
  return out;
}

module.exports = { isNeverLock, isSystem, isDomain, isBundleId, displayName, baseName, toBlock, sanitizeItems, slug };
