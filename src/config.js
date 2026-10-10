'use strict';
const path = require('path');

const DEV = process.env.TIME_DEV === '1';
const INSTALL_DIR = '/Library/Application Support/Time';

const paths = DEV
  ? {
      root: path.resolve(__dirname, '..'),
      state: path.resolve(__dirname, '..', '.dev-state', 'state.json'),
      recovery: path.resolve(__dirname, '..', '.dev-state', 'timekeeper.tlock'),
      hosts: path.resolve(__dirname, '..', '.dev-state', 'hosts'),
      installConfig: path.resolve(__dirname, '..', '.dev-state', 'install.json'),
    }
  : {
      root: INSTALL_DIR,
      state: path.join(INSTALL_DIR, 'state', 'state.json'),
      recovery: path.join(INSTALL_DIR, 'recovery', 'timekeeper.tlock'),
      hosts: '/etc/hosts',
      installConfig: path.join(INSTALL_DIR, 'install.json'),
    };

const PORT = DEV ? 7778 : 7777;

// Apps that are never closed and never time-limited, no matter what is toggled.
const NEVER_LOCK = [
  { name: 'Phone', bundleId: 'com.apple.mobilephone' },
  { name: 'Messages', bundleId: 'com.apple.MobileSMS' },
  { name: 'Calendar', bundleId: 'com.apple.iCal' },
];

// Things that must keep working for the Mac (and this app) to function.
const CRITICAL_BUNDLE_IDS = new Set([
  'com.apple.finder', 'com.apple.loginwindow', 'com.apple.systempreferences',
  'com.apple.Settings', 'com.apple.dock', 'com.apple.SystemUIServer',
  'com.apple.controlcenter', 'com.apple.Terminal', 'com.apple.ActivityMonitor',
]);
const PROTECTED_PATH_PREFIXES = ['/System/Library/', '/usr/', '/Library/Application Support/Time/'];

// Domains we refuse to block: Apple/iCloud (Messages, Calendar, Screen Time sync),
// Google sign-in/calendar sync, and the time servers the lock timer relies on.
const PROTECTED_DOMAIN_SUFFIXES = [
  'apple.com', 'icloud.com', 'icloud-content.com', 'apple-cloudkit.com', 'mzstatic.com',
  'drand.sh', 'drand.love',
];
const PROTECTED_DOMAINS_EXACT = new Set([
  'google.com', 'www.google.com', 'calendar.google.com', 'accounts.google.com',
  'googleapis.com', 'www.googleapis.com', 'oauth2.googleapis.com',
]);

const PRESETS = [
  { id: 'instagram', name: 'Instagram', bundleIds: [], domains: ['instagram.com', 'cdninstagram.com', 'i.instagram.com', 'graph.instagram.com', 'scontent.cdninstagram.com'] },
  { id: 'youtube', name: 'YouTube', bundleIds: [], domains: ['youtube.com', 'youtu.be', 'youtube-nocookie.com', 'youtubei.googleapis.com', 'ytimg.com', 'i.ytimg.com', 'music.youtube.com'] },
  { id: 'tiktok', name: 'TikTok', bundleIds: [], domains: ['tiktok.com', 'tiktokv.com', 'tiktokcdn.com', 'tiktokcdn-us.com', 'byteoversea.com'] },
  { id: 'x', name: 'X / Twitter', bundleIds: [], domains: ['x.com', 'twitter.com', 't.co', 'twimg.com', 'pbs.twimg.com', 'abs.twimg.com', 'api.x.com', 'api.twitter.com'] },
  { id: 'reddit', name: 'Reddit', bundleIds: [], domains: ['reddit.com', 'old.reddit.com', 'redd.it', 'i.redd.it', 'v.redd.it', 'redditmedia.com', 'redditstatic.com', 'gql.reddit.com', 'oauth.reddit.com'] },
  { id: 'facebook', name: 'Facebook', bundleIds: [], domains: ['facebook.com', 'fb.com', 'fbcdn.net', 'messenger.com', 'web.facebook.com'] },
  { id: 'netflix', name: 'Netflix', bundleIds: [], domains: ['netflix.com', 'nflxvideo.net', 'nflximg.net', 'nflxext.com'] },
  { id: 'discord', name: 'Discord', bundleIds: ['com.hnc.Discord'], domains: ['discord.com', 'discord.gg', 'discordapp.com', 'discordapp.net', 'canary.discord.com', 'ptb.discord.com'] },
  { id: 'steam', name: 'Steam', bundleIds: ['com.valvesoftware.steam'], domains: ['store.steampowered.com', 'steamcommunity.com', 'steampowered.com'] },
  { id: 'spotify', name: 'Spotify', bundleIds: ['com.spotify.client'], domains: ['open.spotify.com', 'spotify.com'] },
  { id: 'whatsapp', name: 'WhatsApp', bundleIds: ['net.whatsapp.WhatsApp'], domains: ['web.whatsapp.com', 'whatsapp.com'] },
  { id: 'slack', name: 'Slack', bundleIds: ['com.tinyspeck.slackmacgap'], domains: ['app.slack.com'] },
];

const LIMITS = {
  maxLockMinutes: 7 * 24 * 60,
  maxHardLockMinutes: 72 * 60,
  emergencyMinTypingSeconds: 90,
  emergencyCooldownMinutes: 20,
};

module.exports = {
  DEV, INSTALL_DIR, paths, PORT, NEVER_LOCK, CRITICAL_BUNDLE_IDS, PROTECTED_PATH_PREFIXES,
  PROTECTED_DOMAIN_SUFFIXES, PROTECTED_DOMAINS_EXACT, PRESETS, LIMITS,
};
