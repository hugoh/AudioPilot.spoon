# AutoAudioSwitcher Spoon

[![MIT License](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Hammerspoon Spoon](https://img.shields.io/badge/Hammerspoon-Spoon-FFA500.svg)](https://www.hammerspoon.org/docs/index.html)

A Hammerspoon Spoon that automatically switches audio devices based on a priority list. When devices are connected or disconnected, it selects the highest-priority available device for both input and output.

**Repository**: [https://github.com/hugoh/AutoAudioSwitcher.spoon](https://github.com/hugoh/AutoAudioSwitcher.spoon)

## Features

- Automatically selects the best available audio device based on your priority list
- Separate priority lists for output (speakers/headphones) and input (microphones)
- Tracks all devices you have ever connected for easy priority management
- Shows a 🔊 menu bar icon with current device status and priority lists
- Sends a system notification whenever a device switch occurs
- Config file is human-editable JSON; "Edit Config…" menu item opens it in your default editor

## Alternatives

If you're looking for other solutions in this space, consider:

- [AudioSwitcher](https://audioswitcher.macupdate.com) - Native macOS app
- [Ears](https://retina.studio/ears/) - Lightweight audio device switcher

AutoAudioSwitcher aims to provide a Hammerspoon-powered, priority-driven, fully configurable option.

## Installation

1. Ensure you have [Hammerspoon](https://www.hammerspoon.org) installed
2. Clone this repository to your Spoons directory:

```bash
cd ~/.hammerspoon/Spoons
git clone https://github.com/hugoh/AutoAudioSwitcher.spoon.git
```

## Configuration

Add the following to your `~/.hammerspoon/init.lua`:

```lua
hs.loadSpoon("AutoAudioSwitcher")
spoon.AutoAudioSwitcher:start()
```

On first launch, a default config file is created at `~/.config/AutoAudioSwitcher/config.json`. Edit it to set your device priorities:

```json
{
  "outputPriority": ["AirPods Pro", "Sony WH-1000XM5", "MacBook Pro Speakers"],
  "inputPriority": ["AirPods Pro Microphone", "Built-in Microphone"],
  "knownDevices": {
    "output": ["AirPods Pro", "Sony WH-1000XM5", "MacBook Pro Speakers"],
    "input": ["AirPods Pro Microphone", "Built-in Microphone"]
  }
}
```

- **`outputPriority`** — ordered list of output devices, most preferred first
- **`inputPriority`** — ordered list of input devices, most preferred first
- **`knownDevices`** — all devices ever seen (auto-updated; used to show disconnected devices in the menu)

To change the config file location:

```lua
spoon.AutoAudioSwitcher.configPath = "/path/to/your/config.json"
spoon.AutoAudioSwitcher:start()
```

## Menu Bar

Click the 🔊 icon to see:

1. **Current devices** — the active output and input device
2. **Output Priority** — your priority list with `*` marking the active device and `(disconnected)` for unavailable ones
3. **Input Priority** — same for input
4. **Refresh** — re-evaluates priorities and switches if needed
5. **Edit Config…** — opens the config file in your default editor

## How It Works

- On startup, AutoAudioSwitcher loads your config and immediately enforces your priorities
- Whenever a device is connected or disconnected, it walks the priority list and switches to the first available device
- Manual changes (via System Settings or another app) are respected until the next connect/disconnect event
- New devices are automatically added to `knownDevices` in the config so you can later add them to a priority list

## Security & Permissions

This Spoon does not require Accessibility API access. It uses Hammerspoon's built-in `hs.audiodevice` API, which may require allowing Hammerspoon in System Settings → Privacy & Security → Microphone (for input device control).
