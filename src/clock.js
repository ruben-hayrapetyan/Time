'use strict';
// Trusted time (layer 3). The lock timer never reads the system clock directly, so
// moving the clock forward does nothing. Time comes from the drand beacon network
// (or HTTPS Date headers as a fallback) and is carried forward between syncs with a
// monotonic counter. When offline, time only advances while the Mac is awake, so an
// offline lock can only run long, never short.

const DRAND_CHAIN = '52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971';
const DRAND_GENESIS_MS = 1692803367 * 1000;
const DRAND_PERIOD_MS = 3000;
const DRAND_URLS = ['https://api.drand.sh', 'https://drand.cloudflare.com', 'https://api2.drand.sh'];
const DATE_URLS = ['https://www.apple.com', 'https://www.google.com'];

const monoMs = () => Number(process.hrtime.bigint() / 1000000n);

class TrustedClock {
  constructor(lastTrustedMs, log = () => {}) {
    // Before the first network sync, resume from the last persisted trusted time.
    this.anchorTrusted = lastTrustedMs || Date.now();
    this.anchorMono = monoMs();
    this.synced = false;
    this.lastSyncSource = null;
    this.log = log;
  }

  now() {
    return this.anchorTrusted + (monoMs() - this.anchorMono);
  }

  async fetchWithTimeout(url, opts = {}) {
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), 5000);
    try {
      return await fetch(url, { ...opts, signal: ctrl.signal, cache: 'no-store' });
    } finally {
      clearTimeout(t);
    }
  }

  async networkTime() {
    for (const base of DRAND_URLS) {
      try {
        const res = await this.fetchWithTimeout(`${base}/${DRAND_CHAIN}/public/latest`);
        if (!res.ok) continue;
        const { round } = await res.json();
        // A beacon for round r is published at genesis + (r-1)*period; we are within one period of it.
        if (Number.isInteger(round)) return { ms: DRAND_GENESIS_MS + (round - 1) * DRAND_PERIOD_MS + DRAND_PERIOD_MS / 2, source: 'drand' };
      } catch {}
    }
    for (const url of DATE_URLS) {
      try {
        const res = await this.fetchWithTimeout(url, { method: 'HEAD' });
        const d = Date.parse(res.headers.get('date'));
        if (!Number.isNaN(d)) return { ms: d + 500, source: new URL(url).host };
      } catch {}
    }
    return null;
  }

  async sync() {
    const t = await this.networkTime();
    if (!t) return false;
    // Never let a sync move time backwards by more than a few seconds of jitter;
    // a backwards jump would only lengthen a lock, but keep the clock stable.
    const current = this.now();
    const next = this.synced ? Math.max(t.ms, current - 5000) : Math.max(t.ms, this.anchorTrusted);
    this.anchorTrusted = next;
    this.anchorMono = monoMs();
    if (!this.synced) this.log(`clock synced via ${t.source} (system clock off by ${Math.round((Date.now() - t.ms) / 1000)}s)`);
    this.synced = true;
    this.lastSyncSource = t.source;
    return true;
  }
}

module.exports = { TrustedClock, DRAND_CHAIN };
