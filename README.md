# AudioPilot Spoon

[![MIT License](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Hammerspoon Spoon](https://img.shields.io/badge/Hammerspoon-Spoon-FFA500.svg)](https://www.hammerspoon.org/docs/index.html)
[![Documentation](https://img.shields.io/badge/docs-GitHub%20Pages-blue)](https://hugoh.github.io/AudioPilot.spoon/)

A Hammerspoon Spoon that automatically switches audio devices based on a priority list. When devices are connected or disconnected, it selects the highest-priority available device for both input and output.

**Repository**: [https://github.com/hugoh/AudioPilot.spoon](https://github.com/hugoh/AudioPilot.spoon)

## Features

- Automatically selects the best available audio device based on your priority list
- Separate priority lists for output (speakers/headphones) and input (microphones)
- Detects when macOS auto-switches to a priority device on connect and sends a notification
- Tracks all devices you have ever connected for easy priority management
- Pre-discovers paired Bluetooth devices (even while disconnected) via a background scan at startup
- Shows a 🔊 menu bar icon with current device status and priority lists
- Sends a system notification whenever a device switch occurs; rapid changes are coalesced into one
- Config file is human-editable JSON, with menu items to edit priorities visually or open the raw file

## Alternatives

If you're looking for other solutions in this space, consider:

- [AudioSwitcher](https://audioswitcher.macupdate.com) - Native macOS app
- [Ears](https://retina.studio/ears/) - Lightweight audio device switcher

AudioPilot aims to provide a Hammerspoon-powered, priority-driven, fully configurable option.

## Installation

Ensure you have [Hammerspoon](https://www.hammerspoon.org) installed, then choose a method:

### Release zip (recommended)

1. Download `AudioPilot.spoon.zip` from the [latest release](https://github.com/hugoh/AudioPilot.spoon/releases/latest)
2. Unzip — this produces an `AudioPilot.spoon` folder
3. Move it to `~/.hammerspoon/Spoons/`
4. Reload Hammerspoon (menu bar icon → Reload Config, or run `hs.reload()` in the console)

### SpoonInstall (if you already use it)

```lua
spoon.SpoonInstall:installSpoonFromZip(
  "https://github.com/hugoh/AudioPilot.spoon/releases/latest/download/AudioPilot.spoon.zip"
)
```

### Clone from git (for development or latest changes)

```bash
cd ~/.hammerspoon/Spoons
git clone https://github.com/hugoh/AudioPilot.spoon.git
```

## Configuration

Add the following to your `~/.hammerspoon/init.lua`:

```lua
hs.loadSpoon("AudioPilot")
spoon.AudioPilot:start()
```

On first launch, a default config file is created at `~/.config/AudioPilot/config.json`. The config is keyed by CoreAudio device UIDs (opaque strings assigned by macOS) rather than by name, so the priority lists are best managed through the **Edit Priorities...** menu item rather than edited by hand.

A typical config looks like this:

```json
{
  "outputPriority": ["5C-52-30-DB-6E-80:output", "AppleHAD:1:0"],
  "inputPriority": ["5C-52-30-DB-6E-80:input", "AppleHAD:1:1"],
  "knownDevices": {
    "output": [
      { "uid": "5C-52-30-DB-6E-80:output", "name": "AirPods Pro" },
      { "uid": "AppleHAD:1:0", "name": "MacBook Pro Speakers" }
    ],
    "input": [
      { "uid": "5C-52-30-DB-6E-80:input", "name": "AirPods Pro Microphone" },
      { "uid": "AppleHAD:1:1", "name": "Built-in Microphone" }
    ]
  }
}
```

- **`outputPriority`** — ordered list of output device UIDs, most preferred first
- **`inputPriority`** — ordered list of input device UIDs, most preferred first
- **`knownDevices`** — all devices ever seen, stored as `{uid, name}` objects (auto-updated; used to show disconnected devices in the menu and editor)

To change the config file location:

```lua
spoon.AudioPilot.configPath = "/path/to/your/config.json"
spoon.AudioPilot:start()
```

To change how long AudioPilot waits before emitting a coalesced notification (default 5 seconds):

```lua
spoon.AudioPilot.notifyDelay = 3
spoon.AudioPilot:start()
```

## Menu Bar

Click the 🔊 icon to see:

1. **Current devices** — the active output and input device
2. **Output Priority** — your priority list with `*` marking the active device and `(disconnected)` for unavailable ones
3. **Input Priority** — same for input
4. **Refresh** — re-evaluates priorities and switches if needed
5. **Rescan Bluetooth Devices** — re-runs the background Bluetooth scan to discover newly paired devices
6. **Edit Priorities...** — opens a visual drag-and-drop editor to reorder device priorities and remove stale entries
7. **Edit Config File...** — opens the raw JSON config file in your default editor

## How It Works

- On startup, AudioPilot loads your config, enforces your priorities immediately, and runs a background Bluetooth scan (`system_profiler SPBluetoothDataType`) to pre-populate `knownDevices` with all paired audio devices — even ones that are not currently connected
- Whenever a device is connected or disconnected, it walks the priority list and switches to the first available device
- If macOS auto-switches to a priority device before AudioPilot's watcher fires (common with Bluetooth headphones), AudioPilot detects this and sends a notification for the change
- Rapid connect/disconnect events within the coalesce window (`notifyDelay`, default 5 s) are collapsed into a single notification showing the net change
- Manual changes (via System Settings or another app) are respected until the next connect/disconnect event
- New devices are automatically added to `knownDevices` in the config so you can later add them to a priority list; the **Edit Priorities...** editor lets you remove stale entries you no longer need

## Security & Permissions

This Spoon does not require Accessibility API access. It uses Hammerspoon's built-in `hs.audiodevice` API, which may require allowing Hammerspoon in System Settings → Privacy & Security → Microphone (for input device control).

## API documentation

Full API reference is available at **<https://hugoh.github.io/AudioPilot.spoon/>**.
