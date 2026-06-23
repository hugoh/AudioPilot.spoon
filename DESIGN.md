# AutoAudioSwitcher

This repo is a Hammerspoon Spoon that allows to prioritize audio devices for both input and output.

The user specifies a prioritized list of audio devices for input and output. When new audio devices are connected or disconnected, the code will automatically review the prioritized list and adjust the input and output devices accordingly.

The configuration is stored in .config/AutoAudioSwitcher in a human-editable format. The Spoon should keep track of all the audio devices that have been connected and disconnected, and allow the user to set their priorities. A configuration editor would be nice.

A sound-related icon should be shown in the menu bar. When clicked, the menu should:

1. Display the current devices used
2. Show the prioritized lists and highlight the current devices
3. Force a detection refresh
4. Edit the config, either via a visual editor or be opening up the config file in an editor (or both).

Inspiration:

* https://audioswitcher.macupdate.com
* https://retina.studio/ears/

## Code

The code should use mise for tools, have some tests, and have Github workflows. See ~/Code/AppBadgeWatcher.spoon for an example.