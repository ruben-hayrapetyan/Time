'use strict';
// Last-resort fallback if the Time service is broken while you're demoted in hard mode.
// Prints the hidden "timekeeper" admin password once its unlock time has passed.
// Run:  "/Library/Application Support/Time/bin/node" "/Library/Application Support/Time/src/recover.js"
const fs = require('fs');
const { paths } = require('./config');
const { timeunlock, KEEPER } = require('./hardmode');

(async () => {
  let rec;
  try {
    rec = JSON.parse(fs.readFileSync(paths.recovery, 'utf8'));
  } catch {
    console.error(`No recovery file at ${paths.recovery}.`);
    process.exit(1);
  }
  try {
    const pw = await timeunlock(rec.ciphertext);
    console.log(`Admin account: ${KEEPER}\nPassword: ${pw}\n`);
    console.log(`To get your admin rights back:\n  su ${KEEPER} -c "sudo dseditgroup -o edit -a ${process.env.USER} -t user admin"`);
  } catch (e) {
    if (/too early/i.test(e.message)) {
      console.error(`Still locked. This can be decrypted after ${new Date(rec.unlocksAt).toLocaleString()}.`);
    } else {
      console.error(`Couldn't decrypt (are you online?): ${e.message}`);
    }
    process.exit(1);
  }
})();
