# Everhour Widget

A modern desktop widget for Windows that shows the [Everhour](https://everhour.com) timer you're running — live, always on your desktop, styled like an iPhone / Android home-screen widget. Start, stop and switch tasks without opening the browser.

No admin rights. One PowerShell script, a few launchers and some open-source fonts.

<p>
  <img src="docs/wide-running.png" alt="Wide widget with a running timer" width="370">
  <img src="docs/square-running.png" alt="Square widget" width="250">
</p>

## It changes with what you're doing

| | |
| --- | --- |
| <img src="docs/wide-running.png" width="300"> | **Working** — your theme colour. The dots round the edge fill up once a minute, Nothing-phone style. |
| <img src="docs/wide-break.png" width="300"> | **On a break** — calm teal gradient with a steaming cup. The bar shows how much of today's break allowance is used. |
| <img src="docs/wide-overbreak.png" width="300"> | **Break over the limit** — fast red-orange gradient, chasing lights and warning stripes. |
| <img src="docs/wide-stopped.png" width="300"> | **No timer running** — the whole widget turns red, a red dot circles the edge, and the timer counts how long you've been off. |

Colours glide between states. A task counts as a break when its name contains "break" or "lunch" (configurable); the allowance is 1 hour a day by default.

## Features

- **Wide or Square** layout — every feature works in both
- **Edge lights** — a dot-matrix ring that tracks seconds, breaks and idle time
- **One-click start / stop** — the round button resumes your last task
- **Expanded view** — today's time per task, this week's total, Start / Stop / Settings
- **Task picker** — recent tasks, live search, an optional note, confirm before switching
- **Global shortcut** — `Ctrl+Alt+E` starts or stops the timer from anywhere
- **Hidden from screen sharing** — Teams, Zoom, Meet and screenshots don't see it (toggle)
- **Modern fonts** — Inter (iPhone style), Doto (Nothing dot-matrix), Space Grotesk, Geist, Poppins, Manrope, Outfit, Sora and more; the timer can use its own font
- **Themes** — Graphite, Ocean, Midnight, Forest, Sunset, Light, or any colours you like
- **Never freezes** — Everhour calls run in the background; offline shows a tag and keeps counting
- **Silent start** — no console windows flash at login
- **High-DPI and multi-monitor** aware; API token stored encrypted (Windows DPAPI)

## First run: an animated setup guide

The guide shows exactly where your API token lives in Everhour, then checks it and asks a few questions (theme, font, shape, daily target, break allowance).

<p>
  <img src="docs/guide-1.png" alt="Guide: open your profile" width="270">
  <img src="docs/guide-2.png" alt="Guide: copy the API token" width="270">
  <img src="docs/guide-3.png" alt="Guide: paste it" width="270">
</p>

## Install

1. Download this repository (Code → Download ZIP) and unzip it.
2. Double-click **`Install Everhour Widget.vbs`** (if Windows asks, click *Open*).
3. Follow the guide.

The widget installs to `%LOCALAPPDATA%\Programs\EverhourWidget` for your Windows user, starts automatically at login, and keeps working if you delete the download.

Prefer to run it in place? Double-click **`Start Everhour Widget.vbs`** instead.

### Share it with someone

Run **`Build Share Folder.bat`**. It creates `Share\Everhour Widget` and `Share\Everhour Widget.zip` — send either. Your token is never included.

## Using it

| Action | What it does |
| --- | --- |
| Round button | Start / stop (resumes your last task) |
| Click the widget | Expand / collapse |
| Drag | Move it — position is remembered |
| Right-click | Start, resume, stop, refresh, wide/square, settings, setup guide, exit |
| `Ctrl+Alt+E` | Start / stop from anywhere |

## Settings

Right-click → **Settings**. Changes preview live; **Save** keeps them, **Cancel** reverts.

<img src="docs/settings-top.png" alt="Settings window" width="400">

## Files

| File | Purpose |
| --- | --- |
| `EverhourWidget.ps1` | The widget |
| `Install Everhour Widget.vbs` | Installs for this user and starts it |
| `Start Everhour Widget.vbs` | Runs it from this folder |
| `Build Share Folder.bat` | Makes a folder + zip to give to others |
| `Stop Widget.bat` | Closes it for this session |
| `Test Autostart Now.bat` | Proves it will start at login — no reboot needed |
| `Troubleshoot.bat` | Checks the PC, autostart and your token; writes `troubleshoot-log.txt` |
| `fonts/` | Open-source fonts (SIL OFL 1.1), loaded privately |

Settings and the encrypted token live in `%APPDATA%\EverhourWidget\config.json`; errors go to `error.log` in the same folder.

## Requirements

Windows 10 (2004 or later) or Windows 11, with Windows PowerShell 5.1 (built in). Hiding from screen sharing needs Windows 10 2004+.

## For developers

```powershell
# Draw sample images of every widget state, the dialogs and the guide, then exit
powershell -NoProfile -ExecutionPolicy Bypass -File .\EverhourWidget.ps1 -RenderPreview .\preview
```
