# Display Pilot

A macOS menu bar app for switching an entire multi-display setup with one click.

[简体中文](./README.md) · English · [Latest release](https://github.com/wyfang/display-pilot/releases/latest)

## Features

- Save two named display presets
- Store connection state, brightness, contrast, and resolution per display
- Switch from the menu bar or with `⌘1` and `⌘2`
- Remember temporarily disconnected displays
- Prevent the last active display from being disabled
- Optional launch at login

## Requirements

- macOS 13 or later
- [BetterDisplay](https://github.com/waydabber/BetterDisplay) with integration enabled for brightness and contrast
- Xcode Command Line Tools for source builds

## Build

```bash
git clone https://github.com/wyfang/display-pilot.git
cd display-pilot
./build.sh
```

The app is written to `dist/Display Pilot.app`. It uses local ad-hoc signing and is not notarized by Apple.

## How it works

Display Pilot connects the required displays, waits for their modes to stabilize, switches all resolutions in one Core Graphics transaction, applies brightness and contrast, then disables unused displays.

## Limitations

- Display switching uses the private macOS API `CGSConfigureDisplayEnabled`
- Brightness and contrast require BetterDisplay to be running
- Physically disconnected displays cannot be reconnected by software
- Cables, docks, mirroring, HDR, and macOS updates may invalidate saved modes

## License

Original code and code documentation are licensed under the [Apache License 2.0](./LICENSE). Personal material, branding, screenshots, and third-party components are excluded. See [NOTICE](./NOTICE) and [LICENSE_SCOPE.md](./LICENSE_SCOPE.md).
