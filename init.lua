local _spoonPath = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"

local obj = {}
obj.__index = obj

obj.name = "AudioPilot"
obj.version = "dev"
obj.author = "Hugo Haas"
obj.license = "MIT"
obj.homepage = "https://github.com/hugoh/AudioPilot.spoon"

obj.configPath = os.getenv("HOME") .. "/.config/AudioPilot/config.json"

obj._menu = nil
obj._config = nil
obj._editor = nil
obj.log = hs.logger.new("AudioPilot", "info")

-- hs.json.read returns the *same* shared table instance for every empty array,
-- so copy each list into its own table to avoid aliasing fields together.
local function copyList(t)
	local out = {}
	if t then
		for _, v in ipairs(t) do
			out[#out + 1] = v
		end
	end
	return out
end

-- knownDevices entries are { uid = ..., name = ... } objects; copy them into
-- fresh tables (same anti-aliasing reason as copyList) and drop any malformed
-- entries.
local function copyKnown(t)
	local out = {}
	if t then
		for _, v in ipairs(t) do
			if type(v) == "table" and v.uid then out[#out + 1] = { uid = v.uid, name = v.name or v.uid } end
		end
	end
	return out
end

local function findByUid(list, uid)
	for _, v in ipairs(list) do
		if v.uid == uid then return v end
	end
	return nil
end

-- A Bluetooth device's CoreAudio UID is its MAC address with ":" replaced by "-"
-- and an ":output"/":input" suffix, e.g. "5C:52:30:DB:6E:80" -> "5C-52-30-DB-6E-80:output".
local function uidFromAddress(addr, dir) return (addr:gsub(":", "-")) .. ":" .. dir end

-- Legacy (pre-uid) configs stored plain name strings in knownDevices; uid-keyed
-- configs store { uid, name } tables.
local function isLegacyConfig(config)
	local known = config.knownDevices or {}
	for _, listName in ipairs({ "output", "input" }) do
		for _, v in ipairs(known[listName] or {}) do
			if type(v) == "string" then return true end
		end
	end
	return false
end

-- One-time best-effort migration of a name-based config to the uid-keyed schema.
-- Names are resolved to uids via currently-connected devices; entries for
-- disconnected devices can't be resolved and are dropped (they are re-added by
-- getAvailableDevices / the Bluetooth scan once seen again).
function obj:migrateConfig(raw)
	self.log.i("Migrating name-based config to uid-based config")
	local outMap, inMap = {}, {}
	for _, d in ipairs(hs.audiodevice.allOutputDevices()) do
		outMap[d:name()] = d:uid()
	end
	for _, d in ipairs(hs.audiodevice.allInputDevices()) do
		inMap[d:name()] = d:uid()
	end

	local function migrateKnown(list, nameMap)
		local result = {}
		for _, v in ipairs(list or {}) do
			if type(v) == "table" and v.uid then
				result[#result + 1] = { uid = v.uid, name = v.name or v.uid }
			elseif type(v) == "string" then
				local uid = nameMap[v]
				if uid then
					result[#result + 1] = { uid = uid, name = v }
				else
					self.log.w("Dropping unresolvable known device during migration: " .. v)
				end
			end
		end
		return result
	end

	local function migratePriority(list, nameMap, known)
		local result = {}
		for _, v in ipairs(list or {}) do
			if findByUid(known, v) then
				result[#result + 1] = v -- already a known uid
			else
				local uid = nameMap[v]
				if uid then
					result[#result + 1] = uid
				else
					self.log.w("Dropping unresolvable priority device during migration: " .. v)
				end
			end
		end
		return result
	end

	local known = raw.knownDevices or {}
	local newKnown = {
		output = migrateKnown(known.output, outMap),
		input = migrateKnown(known.input, inMap),
	}
	return {
		outputPriority = migratePriority(raw.outputPriority, outMap, newKnown.output),
		inputPriority = migratePriority(raw.inputPriority, inMap, newKnown.input),
		knownDevices = newKnown,
	}
end

function obj:loadConfig()
	local config = hs.json.read(self.configPath) or {}
	if isLegacyConfig(config) then
		self._config = self:migrateConfig(config)
	else
		local known = config.knownDevices or {}
		self._config = {
			outputPriority = copyList(config.outputPriority),
			inputPriority = copyList(config.inputPriority),
			knownDevices = {
				output = copyKnown(known.output),
				input = copyKnown(known.input),
			},
		}
	end
	self:saveConfig()
	self.log.i("Config loaded from " .. self.configPath)
end

function obj:saveConfig()
	local dir = string.match(self.configPath, "^(.*)/[^/]+$")
	if dir then hs.fs.mkdir(dir) end
	hs.json.write(self._config, self.configPath, true, true)
	self.log.i("Config saved to " .. self.configPath)
end

function obj:getAvailableDevices()
	local outputSet = {}
	local inputSet = {}
	local changed = false

	local function scan(devices, knownList, set)
		for _, dev in ipairs(devices) do
			local uid = dev:uid()
			local name = dev:name()
			set[uid] = name
			local entry = findByUid(knownList, uid)
			if not entry then
				table.insert(knownList, { uid = uid, name = name })
				changed = true
			elseif entry.name ~= name then
				entry.name = name -- refresh display name if the device was renamed
				changed = true
			end
		end
	end

	scan(hs.audiodevice.allOutputDevices(), self._config.knownDevices.output, outputSet)
	scan(hs.audiodevice.allInputDevices(), self._config.knownDevices.input, inputSet)

	if changed then self:saveConfig() end

	return { output = outputSet, input = inputSet }
end

-- Bluetooth minor types that are audio devices, mapped to the CoreAudio
-- direction(s) they expose. "both" covers devices with a mic and a speaker.
local BT_AUDIO_TYPES = {
	["Headphones"] = "both",
	["Headset"] = "both",
	["Hands-free Device"] = "both",
	["Car audio"] = "both",
	["Speaker"] = "output",
	["Loudspeaker"] = "output",
	["Portable Audio"] = "output",
	["HiFi Audio"] = "output",
	["Microphone"] = "input",
}

local BT_DIRECTIONS = {
	output = { "output" },
	input = { "input" },
	both = { "output", "input" },
}

-- Parse `system_profiler SPBluetoothDataType -json` output and add paired audio
-- devices (connected or not) to knownDevices, keyed by their MAC-derived
-- CoreAudio uid so they match the device when it later connects. Pure function:
-- takes the JSON string, so it is unit-testable without hs.task.
function obj:mergeBluetoothDevices(jsonStr)
	local ok, data = pcall(hs.json.decode, jsonStr)
	if not ok or type(data) ~= "table" then
		self.log.w("Could not parse Bluetooth device data")
		return
	end

	local changed = false

	local function addDevice(name, info)
		local dir = BT_AUDIO_TYPES[info.device_minorType]
		if not dir then return end
		local addr = info.device_address
		if not addr then return end
		for _, d in ipairs(BT_DIRECTIONS[dir]) do
			local uid = uidFromAddress(addr, d)
			local knownList = self._config.knownDevices[d]
			local entry = findByUid(knownList, uid)
			if not entry then
				table.insert(knownList, { uid = uid, name = name })
				changed = true
			elseif entry.name ~= name then
				entry.name = name
				changed = true
			end
		end
	end

	for _, block in ipairs(data.SPBluetoothDataType or {}) do
		for _, key in ipairs({ "device_connected", "device_not_connected" }) do
			for _, entry in ipairs(block[key] or {}) do
				for name, info in pairs(entry) do
					if type(info) == "table" then addDevice(name, info) end
				end
			end
		end
	end

	if changed then
		self:saveConfig()
		self:updateMenu()
	end
end

-- Asynchronously enumerate paired Bluetooth audio devices (the scan takes ~1-2s,
-- so it must not block); the merge happens in the completion callback.
function obj:scanBluetoothDevices()
	local self_ref = self
	local task = hs.task.new("/usr/sbin/system_profiler", function(code, stdout, _stderr)
		if code ~= 0 then
			self_ref.log.w("system_profiler exited with code " .. tostring(code))
			return
		end
		self_ref:mergeBluetoothDevices(stdout)
	end, { "SPBluetoothDataType", "-json" })
	if task then task:start() end
end

function obj:selectBestDevice(deviceType)
	local available = self:getAvailableDevices()
	local priorities = self._config[deviceType .. "Priority"] or {}
	local availableSet = available[deviceType]

	for _, uid in ipairs(priorities) do
		local name = availableSet[uid]
		if name then
			local current
			if deviceType == "output" then
				current = hs.audiodevice.defaultOutputDevice()
			else
				current = hs.audiodevice.defaultInputDevice()
			end

			if current and current:uid() == uid then
				self.log.d(deviceType .. " already set to best: " .. name)
				return
			end

			local allDevices
			if deviceType == "output" then
				allDevices = hs.audiodevice.allOutputDevices()
			else
				allDevices = hs.audiodevice.allInputDevices()
			end

			for _, dev in ipairs(allDevices) do
				if dev:uid() == uid then
					if deviceType == "output" then
						dev:setDefaultOutputDevice()
					else
						dev:setDefaultInputDevice()
					end
					self.log.i("Switched " .. deviceType .. " to: " .. name)
					hs.notify.new({ title = "AudioPilot", informativeText = deviceType .. " → " .. name }):send()
					self:updateMenu()
					return
				end
			end

			return
		end
	end

	self.log.w("No priority " .. deviceType .. " device available")
end

function obj:onDeviceChange(event)
	if event == "dev#" then
		self:selectBestDevice("output")
		self:selectBestDevice("input")
	elseif event == "dOut" or event == "dIn" then
		self:updateMenu()
	end
end

function obj:updateMenu()
	if not self._menu then return end

	local available = self:getAvailableDevices()

	local currentOutput = hs.audiodevice.defaultOutputDevice()
	local currentInput = hs.audiodevice.defaultInputDevice()
	local currentOutputName = currentOutput and currentOutput:name() or "Unknown"
	local currentInputName = currentInput and currentInput:name() or "Unknown"
	local currentOutputUid = currentOutput and currentOutput:uid()
	local currentInputUid = currentInput and currentInput:uid()

	local items = {}

	table.insert(items, { title = "Output: " .. currentOutputName, disabled = true })
	table.insert(items, { title = "Input:  " .. currentInputName, disabled = true })
	table.insert(items, { title = "-" })

	local function addPriority(label, priority, knownList, availableSet, currentUid)
		table.insert(items, { title = label, disabled = true })
		for _, uid in ipairs(priority) do
			local entry = findByUid(knownList, uid)
			local name = entry and entry.name or uid
			local prefix = (uid == currentUid) and "* " or "  "
			local suffix = availableSet[uid] and "" or " (disconnected)"
			table.insert(items, { title = prefix .. name .. suffix, disabled = true })
		end
		table.insert(items, { title = "-" })
	end

	addPriority(
		"Output Priority:",
		self._config.outputPriority,
		self._config.knownDevices.output,
		available.output,
		currentOutputUid
	)
	addPriority(
		"Input Priority:",
		self._config.inputPriority,
		self._config.knownDevices.input,
		available.input,
		currentInputUid
	)

	local self_ref = self
	table.insert(items, {
		title = "Refresh",
		fn = function()
			self_ref:selectBestDevice("output")
			self_ref:selectBestDevice("input")
		end,
	})
	table.insert(items, {
		title = "Rescan Bluetooth Devices",
		fn = function() self_ref:scanBluetoothDevices() end,
	})
	table.insert(items, {
		title = "Edit Priorities...",
		fn = function() self_ref:openEditor() end,
	})
	table.insert(items, {
		title = "Edit Config File...",
		fn = function() self_ref:openConfig() end,
	})

	self._menu:setTitle("🔊")
	self._menu:setMenu(items)
end

function obj:_buildEditorHTML()
	-- Each list is emitted as { uid, name } objects: priority entries in rank
	-- order, unranked = known devices not in the priority list.
	local function buildLists(priority, known)
		local prioritySet = {}
		for _, uid in ipairs(priority) do
			prioritySet[uid] = true
		end

		local priorityList = {}
		for _, uid in ipairs(priority) do
			local entry = findByUid(known, uid)
			priorityList[#priorityList + 1] = { uid = uid, name = entry and entry.name or uid }
		end

		local unranked = {}
		for _, entry in ipairs(known) do
			if not prioritySet[entry.uid] then unranked[#unranked + 1] = { uid = entry.uid, name = entry.name } end
		end

		return { priority = priorityList, unranked = unranked }
	end

	local initScript = "<script>window.__initialState="
		.. hs.json.encode({
			output = buildLists(self._config.outputPriority, self._config.knownDevices.output),
			input = buildLists(self._config.inputPriority, self._config.knownDevices.input),
		})
		.. ";</script>"

	local f = io.open(_spoonPath .. "editor.html")
	if not f then
		self.log.e("editor.html not found at " .. _spoonPath)
		return ""
	end
	local html = f:read("*all")
	f:close()

	-- WKWebView's loadHTMLString does not grant file access to subresources, so
	-- the relative <script src="vendor/..."> tag is blocked. Inline the source.
	local sortableTag = '<script src="vendor/Sortable.min.js"></script>'
	local sf = io.open(_spoonPath .. "vendor/Sortable.min.js")
	if sf then
		local sortable = sf:read("*all")
		sf:close()
		local s, e = html:find(sortableTag, 1, true)
		if s then html = html:sub(1, s - 1) .. "<script>" .. sortable .. "</script>" .. html:sub(e + 1) end
	else
		self.log.e("Sortable.min.js not found at " .. _spoonPath .. "vendor/")
	end

	local hs1 = html:find("</head>", 1, true)
	if hs1 then html = html:sub(1, hs1 - 1) .. initScript .. html:sub(hs1) end
	return html
end

function obj:focusEditor()
	-- Hammerspoon runs as a background accessory app, so a shown webview does
	-- not come to the foreground on its own. Raise it and focus the window
	-- (which also activates Hammerspoon) so it gets keyboard focus.
	self._editor:show()
	self._editor:bringToFront(true)
	local win = self._editor:hswindow()
	if win then win:focus() end
end

function obj:openEditor()
	if self._editor then
		self:focusEditor()
		return
	end

	local controller = hs.webview.usercontent.new("AudioPilotEditor")
	local sf = hs.screen.mainScreen():frame()
	local w, h = 480, 620
	local frame = { x = sf.x + (sf.w - w) / 2, y = sf.y + (sf.h - h) / 2, w = w, h = h }

	self._editor = hs.webview.new(frame, {}, controller)
	self._editor:windowStyle(hs.webview.windowMasks.titled + hs.webview.windowMasks.closable)
	-- Webviews reject keyboard input and cannot become the key window unless
	-- text entry is allowed; without this the window never takes focus and
	-- drag-to-reorder does not work.
	self._editor:allowTextEntry(true)

	local self_ref = self
	self._editor:windowCallback(function(action)
		if action == "closing" then self_ref._editor = nil end
	end)

	controller:setCallback(function(message)
		local body = message.body
		if body.action == "save" then
			self_ref._config.outputPriority = body.outputPriority
			self_ref._config.inputPriority = body.inputPriority
			self_ref:saveConfig()
			self_ref:selectBestDevice("output")
			self_ref:selectBestDevice("input")
			self_ref._editor:delete()
			self_ref._editor = nil
		elseif body.action == "cancel" then
			self_ref._editor:delete()
			self_ref._editor = nil
		end
	end)

	-- Show a lightweight placeholder immediately so the window appears at once.
	-- hs.webview:html() returns instantly but WKWebView paints asynchronously,
	-- so swap in the full editor (inlined Sortable) only once the placeholder
	-- has actually finished rendering -- otherwise it is replaced before it is
	-- ever visible.
	local loadingHTML = [[<!DOCTYPE html><html><head><meta charset="UTF-8"><style>
		:root{color-scheme:light dark}
		body{font:-apple-system-body;display:flex;height:100vh;margin:0;
		align-items:center;justify-content:center;color:GrayText}</style></head>
		<body>Loading…</body></html>]]

	local swapped = false
	self._editor:navigationCallback(function(action)
		if action == "didFinishNavigation" and not swapped and self_ref._editor then
			swapped = true
			self_ref._editor:html(self_ref:_buildEditorHTML(), "file://" .. _spoonPath)
		end
	end)

	self._editor:html(loadingHTML)
	self:focusEditor()
end

function obj:openConfig() hs.open(self.configPath) end

function obj:start()
	self:loadConfig()
	self._menu = hs.menubar.new()
	self._menu:setTitle("🔊")
	self:selectBestDevice("output")
	self:selectBestDevice("input")
	self:updateMenu()
	self:scanBluetoothDevices()
	local self_ref = self
	hs.audiodevice.watcher.start(function(event) self_ref:onDeviceChange(event) end)
	self.log.i("AudioPilot started")
end

function obj:stop()
	hs.audiodevice.watcher.stop()
	if self._menu then
		self._menu:delete()
		self._menu = nil
	end
	self.log.i("AudioPilot stopped")
end

return obj
