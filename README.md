# PROBLIP

<p align="left"><img src="assets/problip.png" width="96" height="96" alt="PROBLIP icon" /></p>

A tiny Windows tray beeper for periodic attention or meditation cues. It sits
quietly in the notification area and plays a short blip on the interval you
choose — a randomized preset, a custom MANUAL range, or the alternating PULSE
pattern — so a glance away or a breath happens on a schedule instead of on
willpower.

## Overview

- Single `Problip.exe` (C# / WinForms, .NET Framework), built directly with
  `csc.exe` — no SDK, no NuGet, no installer.
- Lives in the system tray. No main window until you open settings.
- Portable: everything it needs sits beside the executable.

## Features

- Three interval modes:
  - **Range presets** — 4–7, 5, 10, 15, 20, 30 seconds (randomized across the
    range when it has one).
  - **MANUAL** — your own FROM/TO bounds, 1–3600 seconds each; the values are
    clamped into range and reordered (FROM ≤ TO) automatically. Equal bounds
    behave as a fixed interval.
  - **PULSE** — an alternating pattern: 5 s, then a fresh random 10–20 s, then
    5 s again, and so on.
- The selected interval governs the **first** blip too — there is no separate
  fast startup blip.
- Volume slider with preview on release.
- **Test blip** — an immediate one-shot preview from the tray menu or the
  settings window; it never changes ON/OFF or the pending interval, and works
  while the beeper is OFF.
- **ON/OFF is remembered** across restarts via `RunOnLaunch` (default ON, so
  existing behavior is unchanged). A sound failure shows ERR but never rewrites
  your ON/OFF preference — the next explicit Start recovers.
- The tray caption always shows the real state: `problip — ON`, `problip — OFF`
  or `problip — ERR`, and it updates itself when the engine state changes.
- Optional Windows autostart — **off by default**, opt-in only.
- Survives a missing or corrupt `blip01.wav` without pretending to be running.
- **15 themes** — the Wintage catalog, all free: Golden Default (the default),
  Dark Golden (Win95), Claude Code, Antigravity, K-Lite (MPC-HC), FreeBuff,
  CodeNomad, Default, Golden Vintage, Vintage Dark, Vintage Classic (the one
  light palette), Dark 2 (OLED), Dracula, Nord and Solarized Dark. Pick one
  from the tray **Themes** menu or the **THEME** line in the settings window;
  the switch is instant across every open window and is remembered.
- **Blip Glow** — a soft accent pulse on the main window's background on every
  successful scheduled blip (optional, **on by default**, toggle next to the
  THEME line). TEST/preview blips never glow; a hidden window never animates.
- **Local successful-blip statistics** — Today, This week, This month and
  Total. A compact `BLIPS n` total line sits in the settings window and can be
  hidden; a small Statistics view (tray menu or the `BLIPS` line) shows all
  four counters.

## Requirements

- Windows with the .NET Framework 4.x (the build uses the in-box `csc.exe`
  resolved from `%WINDIR%\Microsoft.NET\...`, wherever Windows is installed).
- `blip01.wav` and `problip.ico` shipped beside the executable.

## Quick start

```
powershell -ExecutionPolicy Bypass -File build.ps1
.\Problip.exe
```

First run creates `problip.ini` next to the executable with defaults. The tray
icon always shows the real state — `problip — ON`, `problip — OFF` or
`problip — ERR`; open settings (double-click the tray icon) to pick an interval
and toggle ON/OFF.

## Controls

- **Open settings** — double-click the tray icon, or the *Open settings* menu.
- **Test blip** — tray menu action: one immediate blip through the preview
  path. Safe at any time — it never flips ON/OFF, never re-arms the pending
  wait, and works while the beeper is OFF. A failed preview surfaces through
  the existing ERR state.
- **Volume** — drag the slider; on release the level is saved and one preview
  blip confirms it. Changing volume never restarts the periodic countdown —
  the pending wait is preserved. While dragging, nothing plays (preview on
  release, not per pixel).
- **TEST** — the settings-window preview button, same one-shot behavior.
- **Interval buttons** — 4-7 / 5s / 10s / 15s / 20s / 30s. The selected range
  governs the *first* blip too, and changes apply immediately even mid-wait
  (an interval change intentionally re-arms; a volume change does not).
  Clicking the already-selected interval or mode again never restarts the
  countdown.
- **MANUAL** — opens the manual-interval editor: FROM and TO in seconds
  (1–3600), APPLY saves the bounds and re-arms from the new range; CANCEL
  changes nothing. The button shows the current bounds when MANUAL is active
  (for example `MANUAL 4-7`).
- **PULSE** — the alternating pattern: 5 s short slot, fresh random 10–20 s
  long slot, forever. Switching into or out of PULSE always begins at the
  short slot; TEST, volume changes and statistics never touch the phase, and
  re-selecting an active PULSE leaves the pending wait untouched.
- **[ ] autostart** — registers/unregisters `Problip` in the Windows Run key;
  the write is verified against the actual stored value before the setting is
  persisted.
- **THEME** — opens the theme picker (same window as the tray **Themes**
  item). Selecting a theme applies it instantly to every open window and
  persists it; if the save fails, the previous theme stays active and one
  warning reports it.
- **[X] GLOW** — toggles Blip Glow. Turning it off immediately stops any
  running pulse and takes effect on the next scheduled blip; audio and
  timing are never affected.
- **ON / OFF** — start or stop the beeper. The choice is remembered in
  `RunOnLaunch` and survives a restart (an unwritable INI is reported; the
  ON/OFF still applies for the running session).
- **Tray Start / Stop** — the same commands; availability follows the state
  (ON: Start disabled; OFF/ERR: Start enabled — the recovery action).

## Portable configuration

All settings live in `problip.ini` beside the executable:

```
[problip]
Volume=0.05
MinMs=4000
MaxMs=7000
IntervalKind=range
ManualFromSec=4
ManualToSec=7
AutoStart=0
RunOnLaunch=1
ShowBlipCounter=1
ThemeId=theme_classic
BlipGlow=1
```

`IntervalKind` selects the active mode: `range` uses the ordinary
`MinMs`/`MaxMs` preset values, `manual` uses `ManualFromSec`/`ManualToSec`
(seconds, clamped to 1–3600 and reordered so FROM ≤ TO), and `pulse` uses the
built-in 5 s / random 10–20 s pattern. An old `problip.ini` without
`IntervalKind` behaves exactly as before (Range).

`ThemeId` is the selected theme (see the list in Features). An old ini
without the key, an unknown value or the removed `theme_wintage_custom` all
resolve to `theme_classic`. `BlipGlow` is the glow preference; anything but
an exact `0` means on.

`problip.ini` is **user state** — it is not part of the source tree and is never
packaged in a release. `problip.example.ini` shows the safe defaults.

## Statistics

Statistics count only **real scheduled blips** — one audible periodic blip is
one count. Preview blips are never counted: the **TEST** button, the tray
**Test blip** action and the volume-change preview all play sound without
changing any counter.

- **Today** follows the local calendar date.
- **This week** is the ISO week (Monday–Sunday).
- **This month** follows the local calendar month.
- **Total** never resets.
- A new period starts at 1 on its first blip; before that, a stale period shows
  0 (no midnight timer, no background work).
- Counters saturate safely and can never go negative.
- Hiding the `BLIPS` line only hides the display — counting continues.

Statistics are stored locally in `problip.stats.ini` beside the executable,
separate from `problip.ini`. There is no account, no server and no telemetry;
nothing leaves the machine. The file is user state, is never packaged, and can
be deleted to reset the counters — **close PROBLIP first**: while it is
running, the in-memory counters remain authoritative and the next flush
recreates the file with the current counts. Snapshots are committed atomically — the
whole file is replaced at once, so a crash or a failed write can never leave a
half-updated mixture behind; a statistics write failure never affects playback
— the counters stay correct in memory and the retry is rate-limited (at most
one attempt per 10 seconds, plus a final attempt on Stop/exit).

## Build

```
powershell -ExecutionPolicy Bypass -File build.ps1
```

This compiles `Problip.cs` to `Problip.exe` using the .NET Framework compiler
resolved from `%WINDIR%`. It prefers `Framework64`, falling back to `Framework`.

## Tests

One canonical runner exercises every regression harness:

```
powershell -ExecutionPolicy Bypass -File tests\run_all.ps1
```

It compiles the real `Problip.cs`, drives `BlipEngine`/`Settings` through
reflection, and exits non-zero if any harness fails. Individual harnesses
(`tests/test_*.ps1`) can be run on their own while debugging:

- `test_wav.ps1` — WAV validation (4-bit/bps=0, float, truncated chunks, PCM
  frame-metadata consistency, the shipped 16-bit file) and the
  zero-step-scale-loop guard.
- `test_engine.ps1` — first-blip timing, range re-arm, idempotent cleanup,
  autostart defaults, preview semantics (while ON/OFF), the scheduled-play
  oracle (three due ticks = three real plays), and countdown preservation
  across a volume reload.
- `test_intervals.ps1` — MANUAL sanitize/clamp/order/fixed semantics, PULSE
  slot alternation and phase-reset contract (Start/Stop/mode switches, and the
  volume/preview immunities), idempotent mode re-selection, and the bounded
  failed-flush retry under a 1-second MANUAL interval with an unwritable
  statistics target.
- `test_runstate.ps1` — remembered `RunOnLaunch` behavior, runtime ON/OFF/ERR
  transitions, and exact-due countdown preservation.
- `test_problip_sound.ps1` — missing/corrupt/repaired sound-asset failure state
  and preview truthfulness against a failing asset.
- `test_problip_repaint.ps1` — GDI/font/repaint regression guard, layout of
  every row including the THEME/GLOW utility line and the theme picker, and
  the manual-editor keyboard contract driven through `ProcessDialogKey`.
- `test_themes.ps1` — the 15-theme catalog (unique stable ids, complete
  palettes, donor-value pins, Golden Default pixel pins, normalization of
  legacy/unknown ids, light-palette readability, OLED black) and theme-switch
  scheduling immunity.
- `test_settings.ps1` — settings round-trip, invariant normalization, and
  persistence-failure rollback, including the preview-once volume-commit
  contract.
- `test_stats.ps1` — pure statistics semantics (period keys, ISO week-year
  boundaries, lazy rollover, saturating counters), the isolated
  `problip.stats.ini` persistence contract, and the atomic snapshot commit
  (a failed replacement leaves the previous complete snapshot on disk; failed
  flushes retry on the bounded 10-second attempt window, never per blip).
- `test_package.ps1` — release ZIP content contract; packaging fails closed
  when a mandatory runtime asset is missing.

## Packaging

```
powershell -ExecutionPolicy Bypass -File package.ps1
```

Builds, then writes `dist/` containing only the runtime files
(`Problip.exe`, `blip01.wav`, `problip.ico`, `README.md`) and a
`problip-portable.zip`. `problip.ini` and any dev/audit files are never
included.

## Repository layout

```
Problip.cs                 the entire application (single source file)
build.ps1                 direct-csc build
package.ps1               clean release ZIP
README.md
problip.stats.ini         local statistics state (generated, never packaged)
assets/problip.png         README logo (derived from the real icon)
blip01.wav                beep asset, shipped beside the exe
problip.ico               tray/window icon
scripts/make_pixel_ico.py icon generator (nearest-neighbour, pixel style)
tests/                    run_all.ps1 + harnesses
.github/workflows/ci.yml  Windows CI
```

## Troubleshooting

- **State reads `ERR`** — `blip01.wav` is missing or corrupt beside the
  executable, or it is not 8/16/24/32-bit integer PCM. Restore the shipped
  `blip01.wav`; the next ON recovers without a restart.
- **No sound** — volume at 0, or the interval simply has not elapsed yet.
- **Autostart did not take** — the Run-key write can fail if your account lacks
  permission; the toggle reports the real outcome rather than hiding it.

## Autostart

Autostart is **opt-in**. A fresh install does **not** register itself on launch;
you enable it from the settings UI, which writes the Run key to point at the
current executable. An existing `AutoStart=1` in `problip.ini` is preserved.

## License

No license is specified for this project. All rights reserved by default; the
code is provided as-is without a grant of rights. See `LICENSE` if one is added.
