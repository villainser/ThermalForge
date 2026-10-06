# Adaptive polling and idle CPU

ThermalForge used to read every sensor ten times a second, always. It now polls at the rate
the situation needs, and builds the full sensor picture only while someone is looking at it.
This page says what the rates are, why the slow ones are safe, what each state costs in SMC
calls, and how to measure the result on your own Mac.

It supersedes the conclusion of [idle-cpu-experiments.md](idle-cpu-experiments.md) ("nothing
to change"). That investigation measured the cost of the guarantees it kept; this change
keeps them in a bounded form instead (see "What was kept" below) and takes the saving.

## The rates

| State | Poll interval | What is read each poll |
|---|---|---|
| Fans being controlled, ramping, engaging, or anything heating up | **1 s** | CPU/GPU sensors (plus fans and the rest while the menu is open) |
| A fan-controlling profile holding a steady speed (after 10 s of quiet) | **2 s** | CPU/GPU sensors |
| Silent (Apple's own control), cool and quiet, below 70 °C (after 10 s of quiet) | **5 s** | CPU/GPU sensors |
| Silent between 70 °C and 85 °C | **2 s** | CPU/GPU sensors |
| 85 °C or above, or the 95 °C override active | **1 s** | CPU/GPU sensors |
| Menu open | never slower than **1 s** | everything: fans, CPU, GPU, memory, SSD, ambient |
| Daemon, nothing held | **no SMC reads**; loops wake every 10 s / 30 s | none |
| Daemon, a hold active | thermal floor every **1 s**, watchdog every **5 s** | the 36 CPU/GPU safety keys |

The rates live in `PollCadence` (pure logic, no timers), which `ThermalMonitor` consults after
every poll. Both the active rate and the 2 s / 5 s tiers are in `PollCadence.Tuning`.

### What snaps a slow poll back to 1 s, at once

- the peak CPU/GPU temperature is at or above **85 °C**, or the **95 °C override** is on
- the peak **rose by 3 °C** since the previous poll (it then stays at 1 s for 10 s)
- a fan-controlling profile is **engaging**, or has just **changed the fan speed**
- the **menu opens** (a live readout shouldn't update every 5 s; the monitor also polls
  immediately on open, so the menu never waits out a slow interval)
- a **sensor read failed** (it stays at 1 s until things have been quiet for 10 s)
- a profile switch, and every launch (a fresh start polls at 1 s until it has seen 10 s of quiet)

### Why the slow rates are safe, and what they cost

Two separate things protect against overheating, and only one of them got slower:

- **While ThermalForge is holding the fans at a manual speed, the daemon's thermal floor is the
  protection that matters** (a hold pinning fans low is the only way ThermalForge can make a hot
  machine worse). It samples the CPU/GPU safety keys **every 1 s while any hold is active,
  independently of the app, and that is unchanged.** A new hold wakes it immediately.
- **The app's own 95 °C override** (the primary governor while it controls the fans) polls at the
  rates in the table above. This is the part that got slower: it used to read every 100 ms.

The slow rates only apply after 10 s of quiet, and the interval tightens with temperature. The worst
case before the app's override can see a reading, including the timer's leeway (10% at 1 s, 20% at
the slower rates):

| Peak at the last read | Interval | Worst case until the next read |
|---|---|---|
| 85 °C or above | 1 s | about 1.1 s |
| 70 to 85 °C | 2 s | about 2.4 s |
| below 70 °C, Silent | 5 s | about 6 s |
| below 85 °C, fan-controlling profile, steady | 2 s | about 2.4 s |

A sudden jump can skip tiers, so these are bounds, not typical times: the worst case for noticing
95 °C has gone from about 0.1 s to about 1.1 s once the peak is at 85 °C, and up to about 6 s for a
jump of more than 25 °C between two reads while Silent is relaxed. In Silent, Apple's own thermal
management is the primary protection and the override is a backup. A rise of 3 °C between two reads
moves the poll to 1 s at once, so any climb that is visible between reads brings the fast rate in
before the temperature gets near the limit.

`PollCadenceTests` asserts every rule above, including a sweep from 45 °C to 94 °C that checks the
interval in force at each step.

## What each state costs in SMC calls

One SMC read is one `IOConnectCallStructMethod` call when the key's size is remembered, two
when it isn't. Counts below assume 2 fans and, as a typical Apple Silicon Mac, about 27 live
thermal keys of which about 20 are CPU/GPU (these vary by chip; `thermalforge discover` shows
yours). They are call counts, not CPU: use the script below for CPU.

| State | Before | After |
|---|---|---|
| Idle, Silent, menu closed, quiet | 10 polls/s x about 120 calls = **~1,200 calls/s** | 1 poll / 5 s x ~20 calls = **~4 calls/s** |
| Fan-controlling profile, steady, menu closed | ~1,200 calls/s | 1 poll / 2 s x ~20 = **~10 calls/s** |
| Actively controlling (ramping, hot), menu closed | ~1,200 calls/s | 1 poll / s x ~20 = **~20 calls/s** (+ fan writes) |
| Menu open | ~1,200 calls/s | 1 poll / s x ~33 = **~33 calls/s** |
| Daemon, no hold | 0 | 0 |
| Daemon, hold active (thermal floor) | 1 s x 36 keys x 2 calls = ~72 calls/s | 1 s x 36 keys x 1 call = **~36 calls/s** |

Each poll in the "After" column is also cheaper than before for a second reason: keys that
don't exist on your machine are found once and no longer asked about every poll.

## Where the CPU went, and what changed

1. **The sensor sweep (about 64% of idle CPU, per the earlier investigation).** 10 Hz x all
   keys x two calls each. Now: the poll rate above, only the CPU/GPU sensors when the menu is
   closed, only keys that exist, and one call per key instead of two (remembered key sizes).
2. **The menu bar view (up to about 1.1 percentage points).** The hidden dropdown re-rendered
   on every status. Now the full status is built and published only while the dropdown is
   actually on screen; the label updates only when the whole-degree temperature or the state
   changes; every published property is assigned only on a real change (the heartbeat used to
   rewrite three of them every 5 s).
3. **The app's heartbeat.** Three or four daemon round trips every 5 s, always. Now: 5 s while
   the app controls the fans or the menu is open (the daemon's watchdog needs it then), 30 s
   otherwise; the daemon version is read every 5 minutes instead of every beat.
4. **The daemon's idle loops and logging.** The thermal floor and the watchdog woke every 1 s and
   5 s forever to find nothing to do, and every request, heartbeat included, was logged to the
   system log as root. Now they sleep 10 s / 30 s with nothing held and a new hold wakes them
   immediately; heartbeat, state and version are no longer logged when they succeed, and no
   longer wait behind a fan command for the SMC lock.
5. **The process capture.** A fresh process-table allocation (a few hundred KB) every 2 s. It is
   now reused.
6. **Timer wake-ups.** The monitor timer had no leeway and default priority. It now has leeway
   (10% at the fast rate, 20% at slow rates) and runs at utility priority.
7. **The unlock on every speed change.** Each speed command wrote Ftst and waited half a second
   before it wrote the speed. The unlock is now skipped when every fan is already in manual mode
   and (where it exists) Ftst is set, both read from the SMC at that moment, so a fan the system
   took back is unlocked again.

## What was kept

The earlier investigation rejected remembered key sizes because they remove the per-read
validation of each key. That guarantee is kept in a bounded form:

- a remembered size is dropped the moment a read through it fails or the SMC reports an error,
  and the next read goes the full, validated way;
- a remembered size expires after 10 minutes and the next read re-asks the SMC;
- only a key that was read completely and without error is ever remembered, so a sensor that
  fails is always asked about again;
- **writes always re-validate**: remembered sizes are used for reads only;
- all sensors are still read and shown while the menu is open, and `thermalforge log` and
  `status` read everything every time;
- the set of live sensors is not frozen: keys that were absent at the first probe are asked about
  again every 5 minutes, and immediately if no CPU or GPU sensor can be read, so a sensor that
  failed at startup or around a wake comes back instead of being dropped until restart; the
  daemon also forgets what it learned on wake.

What does change, and is accepted: the temperature-spike log (`Instant spike`, 5 °C between two
samples) now compares samples at the poll interval (2 s at the fast rate, 5 s in Silent) and says
so in the message, and the pre-spike process buffer keeps the same 15 snapshots, as far apart as
the poll allows.

## What was not done, and why

- **`ProcessType=Adaptive` / `LowPriorityIO` on the daemon.** It would let the system deprioritise
  the thermal-safety daemon exactly when the machine is saturated, it only takes effect after a
  reinstall, and with the idle wake-ups gone there is nothing left for it to save.
- **Skipping the process capture below 50 °C.** Apple Silicon idles at 45–60 °C, so it would
  rarely apply, and it would lose the pre-spike history that the anomaly log exists to give.
- **Migrating the app state to `@Observable`.** A large rewrite for a gain that gating the
  hidden panel and assigning only on change already capture.

## Measure it on your Mac

```
Scripts/measure-idle-cpu.sh            # 120 s window, app and daemon
Scripts/measure-idle-cpu.sh 300        # a longer window
```

It follows the method in [idle-cpu-experiments.md](idle-cpu-experiments.md): per-process (never
system-wide), the app's menu closed and untouched, the `ps` user/system CPU-time delta over the
window, and the number of `Instant spike` log lines during it (spike logging costs CPU, so a
number without its spike rate isn't comparable). Quit and relaunch the app, leave the menu
closed, wait two minutes, then run it. To compare with the old behaviour, check out the commit
before this change, build, and run the same thing.

Targets, from the request this was built for, **not yet measured**: app idle with the menu
closed under 0.5% of a core, daemon with nothing held close to 0%.

## Needs checking on a Mac

- The idle numbers above (CPU % before and after).
- That the dropdown shows live values the moment it opens and stops updating when it closes (the
  visibility signal comes from the panel's window; see `PanelVisibility.swift`).
- That Silent shows the temperature in the menu bar label within about 5 s of a load starting, and
  that a fan-controlling profile still ramps as before.
- The daemon's `log stream --predicate 'subsystem == "com.thermalforge.daemon"'` is quiet with
  nothing held.
