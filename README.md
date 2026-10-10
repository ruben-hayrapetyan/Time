# Time

A Mac app and website blocker with a lock timer you can't click past. The control page runs locally at **http://localhost:7777**.

- **Toggle a block** to close that app on your Mac and block its websites in every browser.
- **Lock** the blocks that are on for a set time. Until the timer ends, they can't be turned off.
- **Phone, Messages, and Calendar never lock.** They can't be added to a block, and the service never closes them.

## Install

```sh
sudo ./install.sh      # installs or updates; refuses while a lock is running
sudo ./uninstall.sh    # removes everything; refuses while a lock is running
```

Logs are written to `/Library/Logs/Time.log`.

## How the lock resists being bypassed

1. **No off switch.** While a lock runs, the page and the service both refuse to turn locked blocks off. The lock survives restarts.
2. **Self-protection.** A root service and a watchdog each reload the other if it's stopped, restoring deleted launchd files from a backup. `/etc/hosts` edits get reverted within seconds, and the program files are marked immutable (`chflags schg`).
3. **Clock-proof timer.** The timer gets its time from the [drand](https://drand.love) beacon network (with HTTPS `Date` headers as a fallback) instead of the system clock. Setting the clock forward does nothing. When offline, time only counts while the Mac is awake, so an offline lock can run long but never short.
4. **Emergency unlock.** Type a 50-word passage by hand. Pasting is blocked, and the attempt is rejected if it takes under 90 seconds. Then wait 20 more minutes with the blocks still on.
5. **Hard mode** (optional per lock, up to 72 h). Your account is removed from the `admin` group until the timer ends, and any open `sudo`/`su` sessions are closed. A hidden `timekeeper` admin account stays on the Mac as a fallback. Its password is random and [time-lock encrypted](https://github.com/drand/tlock) to the lock's end time, so nobody can read it until then. The service restores your admin rights when the timer ends or the emergency unlock finishes.

If the service ever breaks while you're in hard mode, run this once the lock's end time has passed:

```sh
"/Library/Application Support/Time/bin/node" "/Library/Application Support/Time/src/recover.js"
```

It prints the timekeeper password and the command that makes you an admin again.

**Honest limits.** On your own Mac, determined effort always wins: Recovery Mode, resetting your password through your Apple Account, or (outside hard mode) `sudo` plus enough patience. The goal is to make every way out slower and more deliberate than waiting.

## Development

```sh
npm install
TIME_DEV=1 node src/daemon.js   # http://localhost:7778, dry run: nothing is closed, hosts goes to .dev-state/
```
