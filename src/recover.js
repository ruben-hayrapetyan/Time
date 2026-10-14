'use strict';
// Last-resort fallback if the Time service is broken. Once a lock's end time has passed, prints
// the hidden "timekeeper" admin password (hard mode) and the Screen Time passcode Time set.
// Run:  "/Library/Application Support/Time/bin/node" "/Library/Application Support/Time/src/recover.js"
const fs = require('fs');
const { paths } = require('./config');
const { timeunlock, KEEPER } = require('./hardmode');

async function open(file) {
  let rec;
  try {
    rec = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return null;
  }
  try {
    return await timeunlock(rec.ciphertext);
  } catch (e) {
    if (/too early/i.test(e.message)) throw new Error(`Still locked. This can be decrypted after ${new Date(rec.unlocksAt).toLocaleString()}.`);
    throw new Error(`Couldn't decrypt (are you online?): ${e.message}`);
  }
}

(async () => {
  let found = false;
  try {
    const pw = await open(paths.recovery);
    if (pw) {
      found = true;
      console.log(`Admin account: ${KEEPER}\nPassword: ${pw}\n`);
      console.log(`To get your admin rights back:\n  su ${KEEPER} -c "sudo dseditgroup -o edit -a ${process.env.USER} -t user admin"\n`);
    }
    const code = await open(paths.passcodeRecovery);
    if (code) {
      found = true;
      console.log(`Screen Time passcode: ${code}\nTurn it off in System Settings → Screen Time → Lock Screen Time Settings.`);
    }
  } catch (e) {
    console.error(e.message);
    process.exit(1);
  }
  if (!found) {
    console.error(`No recovery files at ${paths.recovery} or ${paths.passcodeRecovery}.`);
    process.exit(1);
  }
})();
