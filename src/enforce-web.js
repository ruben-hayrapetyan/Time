'use strict';
// Blocks websites by pointing their domains at nowhere in /etc/hosts. The managed
// section is rewritten every few seconds, so hand edits to /etc/hosts get reverted.
const fs = require('fs');
const { execFile } = require('child_process');
const { DEV, paths, PROTECTED_DOMAIN_SUFFIXES, PROTECTED_DOMAINS_EXACT } = require('./config');

const BEGIN = '# >>> Time blocker (managed; manual edits are reverted) >>>';
const END = '# <<< Time blocker <<<';

function normalizeDomain(d) {
  return String(d).trim().toLowerCase()
    .replace(/^[a-z]+:\/\//, '').replace(/\/.*$/, '').replace(/:\d+$/, '').replace(/^\*\./, '').replace(/\.$/, '');
}

function isValidDomain(d) {
  return /^(?=.{1,253}$)([a-z0-9-]{1,63}\.)+[a-z]{2,63}$/.test(d);
}

function isProtectedDomain(d) {
  return PROTECTED_DOMAINS_EXACT.has(d) || PROTECTED_DOMAIN_SUFFIXES.some((s) => d === s || d.endsWith('.' + s));
}

// /etc/hosts has no wildcards, so cover the common host variants of each domain.
function expand(domains) {
  const out = new Set();
  for (const raw of domains) {
    const d = normalizeDomain(raw);
    if (!isValidDomain(d) || isProtectedDomain(d)) continue;
    out.add(d);
    const bare = d.replace(/^(www|m|mobile)\./, '');
    if (bare.split('.').length === 2) {
      for (const sub of ['www', 'm', 'mobile', 'web', 'api']) {
        const h = `${sub}.${bare}`;
        if (!isProtectedDomain(h)) out.add(h);
      }
      out.add(bare);
    }
  }
  return [...out].sort();
}

function render(hosts) {
  if (!hosts.length) return '';
  const lines = [BEGIN];
  for (const h of hosts) lines.push(`0.0.0.0 ${h}`, `:: ${h}`);
  lines.push(END);
  return lines.join('\n') + '\n';
}

function stripManaged(text) {
  const re = new RegExp(`\\n?${BEGIN.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}[\\s\\S]*?${END.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\n?`, 'g');
  return text.replace(re, '\n').replace(/\n{3,}$/, '\n\n');
}

function flushDns() {
  if (DEV) return;
  execFile('/usr/bin/dscacheutil', ['-flushcache'], () => {});
  execFile('/usr/bin/killall', ['-HUP', 'mDNSResponder'], () => {});
}

// Returns true if /etc/hosts had to be rewritten.
function enforceWeb(domains, log) {
  let current = '';
  try { current = fs.readFileSync(paths.hosts, 'utf8'); } catch {}
  if (!domains.length && !current.includes(BEGIN)) return false;
  const base = stripManaged(current).replace(/\s*$/, '\n');
  const block = render(expand(domains));
  const desired = block ? `${base}\n${block}` : base;
  if (desired === current) return false;
  const tmp = paths.hosts + '.time-tmp';
  fs.writeFileSync(tmp, desired, { mode: 0o644 });
  fs.renameSync(tmp, paths.hosts);
  flushDns();
  log(`hosts updated (${block ? expand(domains).length : 0} hosts blocked)`);
  return true;
}

module.exports = { enforceWeb, expand, normalizeDomain, isValidDomain, isProtectedDomain };
