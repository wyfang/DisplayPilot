# Display Pilot

[简体中文](README.zh-CN.md) · English

[![Build](https://github.com/wyfang/DisplayPilot/actions/workflows/build.yml/badge.svg)](https://github.com/wyfang/DisplayPilot/actions/workflows/build.yml)

Display Pilot is a lightweight macOS menu bar app for switching an entire multi-display setup with one click. Each of its two presets stores the enabled displays, brightness, contrast adjustment, and resolution for every known display.

## Features

- Two complete per-display presets with user-editable names.
- Independent brightness, contrast adjustment, resolution, and connection state for each display.
- One-click switching from the menu bar, with `⌘1` and `⌘2` shortcuts.
- An optional launch-at-login setting in the menu.
- Remembers disconnected displays so a preset can reconnect them later.
- Applies changes in a safe order: connect and wait for displays to stabilize, verify and retry resolutions, resend image settings, then disconnect unused displays.
- Refuses to disconnect the last active display.
- Migrates the brightness values used by the earlier brightness-only version.

## Requirements

- macOS 13 or later.
- Xcode Command Line Tools for building from source.
- [BetterDisplay](https://github.com/waydabber/BetterDisplay) running with integration enabled for brightness and contrast control. Display connection and resolution switching do not depend on BetterDisplay.

In BetterDisplay, integration can be checked under **Settings → Application → Integration**. Notification-based integration is enabled by default in current BetterDisplay versions.

## Build

```bash
git clone https://github.com/wyfang/DisplayPilot.git
cd DisplayPilot
./build.sh
```

The ad-hoc signed app is written to:

```text
dist/Display Pilot.app
```

To choose a different output folder:

```bash
DISPLAYPILOT_OUTPUT_DIR=/path/to/output ./build.sh
```

This project is not notarized. On first launch, macOS may require you to right-click the app and choose **Open**.

## Usage

1. Start BetterDisplay and Display Pilot.
2. Click the Display Pilot icon in the menu bar.
3. Choose **Edit Presets…**.
4. Select a preset, optionally edit its name, then configure every display:
   - whether the display should be enabled;
   - brightness from 0% to 100%;
   - software contrast adjustment from -90% to +90%, where 0% is neutral;
   - one of the display modes currently reported by macOS.
5. Save, then choose the menu item bearing the preset's custom name. The menu shows only that name; you can also press `⌘1` or `⌘2` while it is open.

Individual displays can still be connected or disconnected directly from the first section of the menu.

Use **Launch at Login** in the menu to register or remove the macOS login item. If approval is required, Display Pilot opens the appropriate System Settings page.

## How it works

### Display discovery and identity

Display Pilot enumerates displays with `CGGetOnlineDisplayList`. It derives a persistent hardware identity from the built-in/external flag plus vendor, model, and serial numbers, deliberately excluding the unit number macOS may change after a restart or dock reconnect. Known displays and both presets are encoded as JSON in `UserDefaults`; duplicate records produced by earlier versions are merged automatically when read.

### Connection switching

Display connection state is changed inside a Core Graphics display configuration transaction. The actual enable/disable operation uses the private `CGSConfigureDisplayEnabled` API, and the transaction is committed permanently.

### Resolution switching

Available modes come from `CGDisplayCopyAllDisplayModes`. A preset stores the logical size, backing pixel size, refresh rate, and mode identifier. When applied, Display Pilot finds the closest matching current mode and commits it with `CGConfigureDisplayWithDisplayMode`.

### Brightness and contrast

For each active target display, Display Pilot sends a JSON request through `DistributedNotificationCenter` to `pro.betterdisplay.BetterDisplay.request`. The request uses the macOS display ID and BetterDisplay's `brightness` and software `contrast` parameters. This follows BetterDisplay's [integration interface](https://github.com/waydabber/BetterDisplay/wiki/Integration-features,-CLI).

### Preset application order

```text
Connect target displays
        ↓
Wait for macOS enumeration to stabilize
        ↓
Apply and verify resolution (retry if needed)
        ↓
Apply brightness and contrast twice
        ↓
Disconnect displays disabled by the preset
```

If no target display can be activated, Display Pilot leaves the existing screens connected instead of risking a black screen.

## Project layout

```text
DisplayPilot.swift          App and menu bar UI
Info.plist                  macOS app bundle metadata
build.sh                    Standalone build and ad-hoc signing script
README.md                   English documentation
README.zh-CN.md             Simplified Chinese documentation
```

## Important limitations

- `CGSConfigureDisplayEnabled` is a private macOS API. This makes the app unsuitable for the Mac App Store, and a future macOS update may change or remove the behavior.
- BetterDisplay must be running and its integration feature must be enabled for brightness and contrast commands to take effect.
- A physically unplugged display cannot be reconnected by software. It remains visible in the editor only so its last preset configuration is not lost.
- Display mode availability can change with the cable, dock, input, mirroring state, HDR state, or macOS version. When a stored mode is unavailable, the app reports the failure and continues applying the rest of the preset.
- The app is ad-hoc signed for local use and is not notarized.
