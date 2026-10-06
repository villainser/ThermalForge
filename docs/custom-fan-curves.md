# Custom fan curves

A custom curve is a fan profile you draw yourself: any number of temperature points, each with
a fan speed, with the speed interpolated between them. It is an extra mode next to Silent,
Balanced, Performance, Max and Smart. It does not replace them or change how they behave, and it
never outranks the 95 °C safety override.

## Using it

Open the ThermalForge menu and choose **Edit fan curves…**.

- **New curve** starts from an example (minimum RPM at 45 °C, 30% at 55, 50% at 65, 75% at 75,
  100% at 85). Save as many as you like; each has its own name.
- **Drag a point** to move it. **Click an empty spot** to add one. Select a point to set its
  temperature and speed exactly, or to remove it.
- **Save**, or **Save & use** to make it the active profile at once. Curves you save appear under
  **Custom curves** in the menu. Editing the curve that is running updates it in place without
  letting go of the fans.
- **Delete** removes a curve. If it was the active one the fans go back to the system, as if you
  had pressed Default.

The red line at 95 °C is the safety limit. It is always above every curve.

## What a curve means

- A point's speed is a **percentage of the fan's maximum RPM**, so a curve means the same thing on
  any Mac. **0% means the fan's minimum RPM.** Anything below the hardware minimum is raised to
  it, and nothing can go above the maximum, whatever the curve says.
- Between two points the speed is a straight line; the point that says "minimum" starts the climb
  from the real minimum. Below the first point the curve holds the first point's speed, and above
  the last it holds the last's.
- A curve has **2 to 16 points**, between **30 °C and 94 °C**, at least 1 °C apart, and the speed
  **never decreases as the temperature rises**. The editor won't let you draw otherwise, and a
  file that does is repaired when it's loaded.
- Fans **engage** once the temperature has stayed at or above the first point for the engage delay
  (3 s), and are **handed back to the system** when it is 5 °C below the first point, so a
  start/stop cycle never happens at a single temperature.

## Keeping the fans from hunting

Four things stand between the sensor reading and the fan speed:

| Setting | Default | What it does |
|---|---|---|
| Hysteresis | 2 °C | The curve is read at the highest recent temperature until the reading has stayed more than this far below it |
| Cool-down delay | 8 s | ...for this long, without once climbing back into the band, before the curve follows it down |
| Speed-up limit | 8% of max RPM per second | The fastest the fans may speed up. Lifted at 85 °C and above, where getting there quickly matters more than a gentle ramp |
| Slow-down limit | 3% per second | The fastest the fans may slow down |

A rising temperature is always followed at once. A reading that flips by ±0.5 to ±3 °C on every
poll causes **one** speed change (up to the peak) and then none, where without the cool-down delay
it would change the speed on every poll. A real cool-down stays low, so it is followed once the
delay has passed. Changes smaller than 1% of max RPM are not sent.

## Safety

- The **95 °C override** is checked on every poll, before any profile logic, for every profile
  including custom curves. At 95 °C the fans go to maximum and the curve is not consulted; once the
  temperature has dropped below 90 °C the curve eases the fans down from maximum at its slow-down
  limit instead of dropping them in one step.
- The **daemon's thermal floor** still overrides any hold below maximum when a sensor crosses
  95 °C, with the menu bar app closed.
- **Fan limits** come from the hardware's own reported minimum and maximum, and the daemon clamps
  every request to them again.
- If the app **dies**, the daemon's heartbeat watchdog returns the fans to Apple's control, as for
  any other profile.
- **Handing control back** is unchanged: Default, picking another profile, or deleting the active
  curve all release the fans to the system.

## Where curves are stored

One file per curve: `~/Library/Application Support/ThermalForge/curves/<id>.json`. Nothing in the
file is trusted on load: it is normalised (sorted, clamped to the allowed ranges, speed made
non-decreasing) and validated, and a file that still fails, or whose name doesn't match its id, is
skipped and logged.

```json
{
  "id": "custom-3f9a21bc",
  "name": "Quiet desk",
  "points": [
    { "temp": 45, "percent": 0 },
    { "temp": 55, "percent": 30 },
    { "temp": 65, "percent": 50 },
    { "temp": 75, "percent": 75 },
    { "temp": 85, "percent": 100 }
  ],
  "hysteresisC": 2,
  "coolDownDelaySec": 8,
  "rampUpPerSec": 0.08,
  "rampDownPerSec": 0.03,
  "releaseMarginC": 5,
  "engageDelaySec": 3
}
```

The tuning fields are optional; a file without them uses the defaults. Ids start with `custom-` and
use only lower-case letters, digits and `-`, so a custom id can never be mistaken for a built-in
profile.

## Not included

- Curves are not selectable from the `thermalforge watch` CLI; it still takes the built-in profiles.
- Points are percentages, not absolute RPM; the editor shows the RPM a point resolves to on this Mac.
