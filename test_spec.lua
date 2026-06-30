local mock_hs
local AudioPilot

local function makeLogger()
	local l = { _infos = {}, _warnings = {}, _errors = {} }
	l.i = function(msg) table.insert(l._infos, msg) end
	l.w = function(msg) table.insert(l._warnings, msg) end
	l.e = function(msg) table.insert(l._errors, msg) end
	l.d = function() end
	l.v = function() end
	return l
end

local function makeMockDevice(name, isOutput, uid)
	local d = { _name = name, _uid = uid or name }
	function d:name() return self._name end
	function d:uid() return self._uid end
	function d:transportType() return self._transport end
	function d:setDefaultOutputDevice() mock_hs.audiodevice._defaultOutput = self end
	function d:setDefaultInputDevice() mock_hs.audiodevice._defaultInput = self end
	if isOutput then
		table.insert(mock_hs.audiodevice._outputDevices, d)
	else
		table.insert(mock_hs.audiodevice._inputDevices, d)
	end
	return d
end

local function findMenuItem(items, titlePart)
	for _, item in ipairs(items) do
		if item.title and item.title:find(titlePart, 1, true) then return item end
	end
	return nil
end

local function findKnown(list, uid)
	for _, v in ipairs(list) do
		if v.uid == uid then return v end
	end
	return nil
end

before_each(function()
	local config_store = {}

	mock_hs = {
		logger = { new = function() return makeLogger() end },
		json = {
			read = function(path) return config_store[path] end,
			write = function(data, path, _pretty)
				config_store[path] = data
				return true
			end,
			-- Tests that exercise Bluetooth parsing override this to return a
			-- decoded fixture table (real JSON decoding is hs.json's concern).
			decode = function(_s) return nil end,
			encode = function(t)
				local function serialize(v)
					if type(v) == "table" then
						if #v > 0 then
							local parts = {}
							for _, x in ipairs(v) do
								table.insert(parts, serialize(x))
							end
							return "[" .. table.concat(parts, ",") .. "]"
						else
							local parts = {}
							for k, x in pairs(v) do
								table.insert(parts, '"' .. k .. '":' .. serialize(x))
							end
							return "{" .. table.concat(parts, ",") .. "}"
						end
					else
						return '"' .. tostring(v) .. '"'
					end
				end
				return serialize(t)
			end,
		},
		screen = {
			mainScreen = function()
				return { frame = function() return { x = 0, y = 0, w = 1440, h = 900 } end }
			end,
		},
		webview = {
			windowMasks = { titled = 1, closable = 2, resizable = 4 },
			_lastWebview = nil,
			_lastController = nil,
			usercontent = {
				new = function(_name)
					local ctrl = {}
					function ctrl:setCallback(fn) self._callback = fn end
					return ctrl
				end,
			},
		},
		fs = { mkdir = function(_p) return true end },
		task = {
			_lastTask = nil,
			new = function(_path, cb, _args)
				local t = { _cb = cb, _started = false }
				function t:start()
					self._started = true
					return self
				end
				mock_hs.task._lastTask = t
				return t
			end,
		},
		open = function(_p) end,
		notify = {
			_sent = {},
		},
		timer = {
			_pending = nil,
			doAfter = function(_delay, fn)
				local t = { _fn = fn, _cancelled = false }
				function t:stop() self._cancelled = true end
				mock_hs.timer._pending = t
				return t
			end,
		},
		menubar = {
			new = function()
				local m = {}
				function m:setTitle(t) self._title = t end
				function m:setMenu(items) self._menuItems = items end
				function m:delete() self._deleted = true end
				return m
			end,
		},
		audiodevice = {
			_outputDevices = {},
			_inputDevices = {},
			_defaultOutput = nil,
			_defaultInput = nil,
			allOutputDevices = function() return mock_hs.audiodevice._outputDevices end,
			allInputDevices = function() return mock_hs.audiodevice._inputDevices end,
			defaultOutputDevice = function() return mock_hs.audiodevice._defaultOutput end,
			defaultInputDevice = function() return mock_hs.audiodevice._defaultInput end,
			watcher = {
				_callback = nil,
				setCallback = function(cb) mock_hs.audiodevice.watcher._callback = cb end,
				start = function() end,
				stop = function() mock_hs.audiodevice.watcher._callback = nil end,
			},
		},
	}

	mock_hs.notify.new = function(attrs)
		local n = { _attrs = attrs }
		function n:send() table.insert(mock_hs.notify._sent, self._attrs) end
		return n
	end

	mock_hs.webview.new = function(_frame, _prefs, controller)
		local wv = {}
		function wv:html(h, _base) self._html = h end
		function wv:show() self._visible = true end
		function wv:delete() self._deleted = true end
		function wv.windowStyle(_self, _m) end
		function wv:windowCallback(fn) self._windowCb = fn end
		function wv:allowTextEntry(v) self._textEntry = v end
		function wv:navigationCallback(fn) self._navCb = fn end
		function wv:bringToFront(_v) self._front = true end
		function wv.hswindow()
			return { focus = function() end }
		end
		mock_hs.webview._lastWebview = wv
		mock_hs.webview._lastController = controller
		return wv
	end

	mock_hs._setConfig = function(path, cfg) config_store[path] = cfg end

	package.loaded.hs = nil
	_G.hs = mock_hs

	AudioPilot = dofile("init.lua")
end)

-- Fire the pending notify timer (simulates hs.timer.doAfter callback firing).
local function fireNotifyTimer()
	local t = mock_hs.timer._pending
	if t and not t._cancelled then t._fn() end
end

after_each(function()
	if AudioPilot._menu then AudioPilot:stop() end
end)

describe("AudioPilot", function()
	describe("module structure", function()
		it("returns a table", function() assert.is.table(AudioPilot) end)

		it("has name", function() assert.are.equal("AudioPilot", AudioPilot.name) end)

		it("has version string", function() assert.is.string(AudioPilot.version) end)

		it("has configPath ending in config.json", function()
			assert.is.string(AudioPilot.configPath)
			assert.truthy(AudioPilot.configPath:find("config.json$"))
		end)

		it("has required methods", function()
			assert.are.equal("function", type(AudioPilot.loadConfig))
			assert.are.equal("function", type(AudioPilot.saveConfig))
			assert.are.equal("function", type(AudioPilot.getAvailableDevices))
			assert.are.equal("function", type(AudioPilot.selectBestDevice))
			assert.are.equal("function", type(AudioPilot.onDeviceChange))
			assert.are.equal("function", type(AudioPilot.updateMenu))
			assert.are.equal("function", type(AudioPilot.start))
			assert.are.equal("function", type(AudioPilot.stop))
			assert.are.equal("function", type(AudioPilot.openConfig))
			assert.are.equal("function", type(AudioPilot.openEditor))
			assert.are.equal("function", type(AudioPilot._buildEditorHTML))
		end)

		it("initializes with nil menu", function() assert.is_nil(AudioPilot._menu) end)

		it("initializes with nil config", function() assert.is_nil(AudioPilot._config) end)

		it("initializes with nil editor", function() assert.is_nil(AudioPilot._editor) end)

		it("has logger instance", function() assert.is.table(AudioPilot.log) end)
	end)

	describe("loadConfig", function()
		it("creates default config when file missing", function()
			AudioPilot:loadConfig()
			assert.is.table(AudioPilot._config)
			assert.is.table(AudioPilot._config.outputPriority)
			assert.is.table(AudioPilot._config.inputPriority)
			assert.is.table(AudioPilot._config.knownDevices)
			assert.is.table(AudioPilot._config.knownDevices.output)
			assert.is.table(AudioPilot._config.knownDevices.input)
			assert.are.equal(0, #AudioPilot._config.outputPriority)
			assert.are.equal(0, #AudioPilot._config.inputPriority)
		end)

		it("saves config when creating default", function()
			local writeCount = 0
			local orig = mock_hs.json.write
			mock_hs.json.write = function(data, path, pretty)
				writeCount = writeCount + 1
				return orig(data, path, pretty)
			end
			AudioPilot:loadConfig()
			assert.truthy(writeCount > 0)
		end)

		it("reads existing config from disk", function()
			mock_hs._setConfig(AudioPilot.configPath, {
				outputPriority = { "DevA", "DevB" },
				inputPriority = { "MicA" },
				knownDevices = { output = {}, input = {} },
			})
			AudioPilot:loadConfig()
			assert.are.equal(2, #AudioPilot._config.outputPriority)
			assert.are.equal("DevA", AudioPilot._config.outputPriority[1])
			assert.are.equal("DevB", AudioPilot._config.outputPriority[2])
		end)

		it("calls hs.fs.mkdir with config directory", function()
			local mkdirPath = nil
			mock_hs.fs.mkdir = function(p) mkdirPath = p end
			AudioPilot:loadConfig()
			assert.is_not_nil(mkdirPath)
			assert.truthy(mkdirPath:find("AudioPilot"))
		end)
	end)

	describe("saveConfig", function()
		it("calls hs.json.write with configPath", function()
			AudioPilot:loadConfig()
			local writtenPath
			mock_hs.json.write = function(_data, path, _pretty) writtenPath = path end
			AudioPilot:saveConfig()
			assert.are.equal(AudioPilot.configPath, writtenPath)
		end)

		it("calls hs.fs.mkdir before writing", function()
			local callOrder = {}
			mock_hs.fs.mkdir = function(_p) table.insert(callOrder, "mkdir") end
			mock_hs.json.write = function(_d, _p, _pp) table.insert(callOrder, "write") end
			AudioPilot._config = { outputPriority = {}, inputPriority = {}, knownDevices = { output = {}, input = {} } }
			AudioPilot:saveConfig()
			assert.are.equal("mkdir", callOrder[1])
			assert.are.equal("write", callOrder[2])
		end)

		it("logs an error and does not claim success when hs.json.write fails", function()
			AudioPilot._config = { outputPriority = {}, inputPriority = {}, knownDevices = { output = {}, input = {} } }
			mock_hs.json.write = function(_d, _p, _pp) return false end
			AudioPilot:saveConfig()
			assert.truthy(#AudioPilot.log._errors > 0)
			assert.are.equal(0, #AudioPilot.log._infos)
		end)

		it("logs success info when hs.json.write succeeds", function()
			AudioPilot._config = { outputPriority = {}, inputPriority = {}, knownDevices = { output = {}, input = {} } }
			AudioPilot:saveConfig()
			assert.truthy(#AudioPilot.log._infos > 0)
			assert.are.equal(0, #AudioPilot.log._errors)
		end)
	end)

	describe("getAvailableDevices", function()
		before_each(function() AudioPilot:loadConfig() end)

		it("returns output and input keys", function()
			local available = AudioPilot:getAvailableDevices()
			assert.is.table(available.output)
			assert.is.table(available.input)
		end)

		it("returns connected output device names as truthy keys", function()
			makeMockDevice("Speakers", true)
			local available = AudioPilot:getAvailableDevices()
			assert.truthy(available.output["Speakers"])
		end)

		it("returns connected input device names as truthy keys", function()
			makeMockDevice("Microphone", false)
			local available = AudioPilot:getAvailableDevices()
			assert.truthy(available.input["Microphone"])
		end)

		it("updates knownDevices with newly seen output devices", function()
			makeMockDevice("NewSpeakers", true, "uidNewSpeakers")
			AudioPilot:getAvailableDevices()
			local found = false
			for _, v in ipairs(AudioPilot._config.knownDevices.output) do
				if v.uid == "uidNewSpeakers" and v.name == "NewSpeakers" then found = true end
			end
			assert.is_true(found)
		end)

		it("updates knownDevices with newly seen input devices", function()
			makeMockDevice("NewMic", false, "uidNewMic")
			AudioPilot:getAvailableDevices()
			local found = false
			for _, v in ipairs(AudioPilot._config.knownDevices.input) do
				if v.uid == "uidNewMic" and v.name == "NewMic" then found = true end
			end
			assert.is_true(found)
		end)

		it("saves config when new device discovered", function()
			local writeCount = 0
			mock_hs.json.write = function(_d, _p, _pp) writeCount = writeCount + 1 end
			makeMockDevice("BrandNewDevice", true)
			AudioPilot:getAvailableDevices()
			assert.truthy(writeCount > 0)
		end)

		it("does not save config when no new devices found", function()
			makeMockDevice("KnownDevice", true, "uidKnown")
			-- Pre-populate knownDevices
			AudioPilot._config.knownDevices.output = { { uid = "uidKnown", name = "KnownDevice" } }
			local writeCount = 0
			mock_hs.json.write = function(_d, _p, _pp) writeCount = writeCount + 1 end
			AudioPilot:getAvailableDevices()
			assert.are.equal(0, writeCount)
		end)
	end)

	describe("selectBestDevice", function()
		before_each(function() AudioPilot:loadConfig() end)

		it("selects highest-priority available output device", function()
			makeMockDevice("DevB", true)
			AudioPilot._config.outputPriority = { "DevA", "DevB" }
			AudioPilot:selectBestDevice("output")
			assert.are.equal("DevB", mock_hs.audiodevice._defaultOutput:name())
		end)

		it("selects first priority device when connected", function()
			makeMockDevice("DevA", true)
			makeMockDevice("DevB", true)
			AudioPilot._config.outputPriority = { "DevA", "DevB" }
			AudioPilot:selectBestDevice("output")
			assert.are.equal("DevA", mock_hs.audiodevice._defaultOutput:name())
		end)

		it("does not switch if best device is already default", function()
			local devA = makeMockDevice("DevA", true)
			local switchCount = 0
			devA.setDefaultOutputDevice = function(self)
				switchCount = switchCount + 1
				mock_hs.audiodevice._defaultOutput = self
			end
			mock_hs.audiodevice._defaultOutput = devA
			AudioPilot._config.outputPriority = { "DevA" }
			AudioPilot:selectBestDevice("output")
			assert.are.equal(0, switchCount)
		end)

		it("does nothing when no priority device is available", function()
			AudioPilot._config.outputPriority = { "NonExistentDevice" }
			-- Should not error, no switch
			AudioPilot:selectBestDevice("output")
			assert.is_nil(mock_hs.audiodevice._defaultOutput)
		end)

		it("selects highest-priority available input device", function()
			makeMockDevice("MicB", false)
			AudioPilot._config.inputPriority = { "MicA", "MicB" }
			AudioPilot:selectBestDevice("input")
			assert.are.equal("MicB", mock_hs.audiodevice._defaultInput:name())
		end)

		it("does not switch input if best device is already default", function()
			local mic = makeMockDevice("MicA", false)
			local switchCount = 0
			mic.setDefaultInputDevice = function(self)
				switchCount = switchCount + 1
				mock_hs.audiodevice._defaultInput = self
			end
			mock_hs.audiodevice._defaultInput = mic
			AudioPilot._config.inputPriority = { "MicA" }
			AudioPilot:selectBestDevice("input")
			assert.are.equal(0, switchCount)
		end)
	end)

	describe("notifications", function()
		before_each(function()
			AudioPilot:loadConfig()
			AudioPilot._lastAnnounced = { output = nil, input = nil }
			AudioPilot._notifyBuffer = { output = nil, input = nil }
			AudioPilot._notifyTimer = nil
		end)

		it("sends notification when switching output device", function()
			makeMockDevice("DevA", true)
			AudioPilot._config.outputPriority = { "DevA" }
			AudioPilot:selectBestDevice("output")
			fireNotifyTimer()
			assert.are.equal(1, #mock_hs.notify._sent)
			assert.are.equal("AudioPilot", mock_hs.notify._sent[1].title)
			assert.truthy(mock_hs.notify._sent[1].informativeText:find("DevA"))
		end)

		it("sends notification when switching input device", function()
			makeMockDevice("MicA", false)
			AudioPilot._config.inputPriority = { "MicA" }
			AudioPilot:selectBestDevice("input")
			fireNotifyTimer()
			assert.are.equal(1, #mock_hs.notify._sent)
			assert.truthy(mock_hs.notify._sent[1].informativeText:find("MicA"))
		end)

		it("notifies when macOS already set the best device (first observation)", function()
			-- macOS auto-switches to AirPods on connect before our watcher runs, so
			-- the device is already current; we should still report the change once.
			local dev = makeMockDevice("DevA", true)
			mock_hs.audiodevice._defaultOutput = dev
			AudioPilot._config.outputPriority = { "DevA" }
			AudioPilot:selectBestDevice("output")
			fireNotifyTimer()
			assert.are.equal(1, #mock_hs.notify._sent)
			assert.truthy(mock_hs.notify._sent[1].informativeText:find("DevA"))
		end)

		it("does not notify again when the best device is unchanged", function()
			local dev = makeMockDevice("DevA", true)
			mock_hs.audiodevice._defaultOutput = dev
			AudioPilot._config.outputPriority = { "DevA" }
			AudioPilot:selectBestDevice("output")
			fireNotifyTimer()
			AudioPilot:selectBestDevice("output")
			AudioPilot:selectBestDevice("output")
			fireNotifyTimer()
			assert.are.equal(1, #mock_hs.notify._sent)
		end)

		it("does not notify when primed to the current best device", function()
			-- start() primes _lastAnnounced to the current defaults so a reload that
			-- is already correct stays silent.
			local dev = makeMockDevice("DevA", true)
			mock_hs.audiodevice._defaultOutput = dev
			AudioPilot._config.outputPriority = { "DevA" }
			AudioPilot._lastAnnounced = { output = "DevA", input = nil }
			AudioPilot:selectBestDevice("output")
			fireNotifyTimer()
			assert.are.equal(0, #mock_hs.notify._sent)
		end)

		describe("buffering", function()
			it("coalesces output and input changes into one notification", function()
				makeMockDevice("Speaker", true)
				makeMockDevice("Mic", false)
				AudioPilot._config.outputPriority = { "Speaker" }
				AudioPilot._config.inputPriority = { "Mic" }
				AudioPilot:selectBestDevice("output")
				AudioPilot:selectBestDevice("input")
				fireNotifyTimer()
				assert.are.equal(1, #mock_hs.notify._sent)
				local text = mock_hs.notify._sent[1].informativeText
				assert.truthy(text:find("output"))
				assert.truthy(text:find("Speaker"))
				assert.truthy(text:find("input"))
				assert.truthy(text:find("Mic"))
			end)

			it("suppresses notification when net change is zero", function()
				-- A→B then B→A within the window: no net movement.
				makeMockDevice("DevA", true)
				makeMockDevice("DevB", true)
				AudioPilot._lastAnnounced = { output = "DevA", input = nil }
				AudioPilot._config.outputPriority = { "DevB" }
				-- Buffer A→B
				AudioPilot:_bufferNotify("output", "DevA", "DevB", "DevB")
				-- Then buffer back to A (net zero)
				AudioPilot:_bufferNotify("output", "DevA", "DevA", "DevA")
				fireNotifyTimer()
				assert.are.equal(0, #mock_hs.notify._sent)
			end)

			it("updates _lastAnnounced only after flush", function()
				makeMockDevice("DevA", true)
				AudioPilot._config.outputPriority = { "DevA" }
				AudioPilot:selectBestDevice("output")
				assert.is_nil(AudioPilot._lastAnnounced.output) -- not yet announced
				fireNotifyTimer()
				assert.are.equal("DevA", AudioPilot._lastAnnounced.output)
			end)

			it("stop() flushes pending notification and cancels the timer", function()
				AudioPilot._menu = mock_hs.menubar.new()
				AudioPilot:loadConfig()
				makeMockDevice("DevA", true)
				AudioPilot._config.outputPriority = { "DevA" }
				AudioPilot._lastAnnounced = { output = nil, input = nil }
				AudioPilot._notifyBuffer = { output = nil, input = nil }
				AudioPilot._notifyTimer = nil
				AudioPilot:selectBestDevice("output")
				AudioPilot:stop()
				-- stop() flushes the buffer so the notification is sent immediately
				assert.are.equal(1, #mock_hs.notify._sent)
				-- Timer is cancelled so it cannot fire a second notification later
				local t = mock_hs.timer._pending
				assert.is_true(t._cancelled)
			end)
		end)
	end)

	describe("onDeviceChange", function()
		before_each(function()
			AudioPilot:loadConfig()
			AudioPilot._menu = mock_hs.menubar.new()
		end)

		it("calls selectBestDevice for output and input on dev# event", function()
			local calls = {}
			AudioPilot.selectBestDevice = function(_self, deviceType) table.insert(calls, deviceType) end
			AudioPilot:onDeviceChange("dev#")
			local hasOutput, hasInput = false, false
			for _, v in ipairs(calls) do
				if v == "output" then hasOutput = true end
				if v == "input" then hasInput = true end
			end
			assert.is_true(hasOutput)
			assert.is_true(hasInput)
		end)

		it("refreshes the menu on dev# event even when no switch occurs", function()
			-- macOS may auto-switch to the best device first, so selectBestDevice
			-- early-returns without refreshing; the menu must still be rebuilt to
			-- show the new connected/disconnected state.
			local updateCalled = false
			AudioPilot.selectBestDevice = function() end
			AudioPilot.updateMenu = function() updateCalled = true end
			AudioPilot:onDeviceChange("dev#")
			assert.is_true(updateCalled)
		end)

		it("calls updateMenu on dOut event without selectBestDevice", function()
			local updateCalled = false
			local selectCalled = false
			AudioPilot.updateMenu = function() updateCalled = true end
			AudioPilot.selectBestDevice = function() selectCalled = true end
			AudioPilot:onDeviceChange("dOut")
			assert.is_true(updateCalled)
			assert.is_false(selectCalled)
		end)

		it("calls updateMenu on dIn event without selectBestDevice", function()
			local updateCalled = false
			local selectCalled = false
			AudioPilot.updateMenu = function() updateCalled = true end
			AudioPilot.selectBestDevice = function() selectCalled = true end
			AudioPilot:onDeviceChange("dIn")
			assert.is_true(updateCalled)
			assert.is_false(selectCalled)
		end)

		it("ignores unknown events without error", function()
			AudioPilot.selectBestDevice = function() error("should not be called") end
			AudioPilot.updateMenu = function() error("should not be called") end
			assert.has_no.errors(function() AudioPilot:onDeviceChange("unknown") end)
		end)
	end)

	describe("updateMenu", function()
		before_each(function()
			AudioPilot:loadConfig()
			AudioPilot._menu = mock_hs.menubar.new()
			AudioPilot._config.outputPriority = { "Speakers", "Headphones" }
			AudioPilot._config.inputPriority = { "Microphone" }
			makeMockDevice("Speakers", true)
			makeMockDevice("Headphones", true)
			makeMockDevice("Microphone", false)
			mock_hs.audiodevice._defaultOutput = mock_hs.audiodevice._outputDevices[1] -- Speakers
			mock_hs.audiodevice._defaultInput = mock_hs.audiodevice._inputDevices[1] -- Microphone
			AudioPilot:updateMenu()
		end)

		it("sets menu title to sound icon", function() assert.are.equal("🔊", AudioPilot._menu._title) end)

		it("menu contains current output device name", function()
			local item = findMenuItem(AudioPilot._menu._menuItems, "Output:")
			assert.is_not_nil(item)
			assert.truthy(item.title:find("Speakers"))
		end)

		it("menu contains current input device name", function()
			local item = findMenuItem(AudioPilot._menu._menuItems, "Input:")
			assert.is_not_nil(item)
			assert.truthy(item.title:find("Microphone"))
		end)

		it("marks current output device with asterisk", function()
			local item = findMenuItem(AudioPilot._menu._menuItems, "* Speakers")
			assert.is_not_nil(item)
		end)

		it("marks non-current connected device without asterisk", function()
			local item = findMenuItem(AudioPilot._menu._menuItems, "  Headphones")
			assert.is_not_nil(item)
		end)

		it("marks disconnected priority device", function()
			AudioPilot._config.outputPriority = { "Speakers", "DisconnectedDevice" }
			AudioPilot:updateMenu()
			local item = findMenuItem(AudioPilot._menu._menuItems, "DisconnectedDevice")
			assert.is_not_nil(item)
			assert.truthy(item.title:find("disconnected"))
		end)

		it("menu contains Refresh item", function()
			local item = findMenuItem(AudioPilot._menu._menuItems, "Refresh")
			assert.is_not_nil(item)
		end)

		it("menu contains Edit Priorities item", function()
			local item = findMenuItem(AudioPilot._menu._menuItems, "Edit Priorities")
			assert.is_not_nil(item)
		end)

		it("menu contains Edit Config File item", function()
			local item = findMenuItem(AudioPilot._menu._menuItems, "Edit Config File")
			assert.is_not_nil(item)
		end)

		it("Refresh item triggers selectBestDevice for both types", function()
			local calls = {}
			AudioPilot.selectBestDevice = function(_self, deviceType) table.insert(calls, deviceType) end
			local item = findMenuItem(AudioPilot._menu._menuItems, "Refresh")
			assert.is_not_nil(item)
			item.fn()
			local hasOutput, hasInput = false, false
			for _, v in ipairs(calls) do
				if v == "output" then hasOutput = true end
				if v == "input" then hasInput = true end
			end
			assert.is_true(hasOutput)
			assert.is_true(hasInput)
		end)

		it("Edit Config File item calls hs.open with configPath", function()
			local openedPath = nil
			mock_hs.open = function(p) openedPath = p end
			local item = findMenuItem(AudioPilot._menu._menuItems, "Edit Config File")
			assert.is_not_nil(item)
			item.fn()
			assert.are.equal(AudioPilot.configPath, openedPath)
		end)

		it("Edit Priorities item calls openEditor", function()
			local editorOpened = false
			AudioPilot.openEditor = function(_self) editorOpened = true end
			local item = findMenuItem(AudioPilot._menu._menuItems, "Edit Priorities")
			assert.is_not_nil(item)
			item.fn()
			assert.is_true(editorOpened)
		end)

		it("does nothing when menu is nil", function()
			AudioPilot._menu = nil
			assert.has_no.errors(function() AudioPilot:updateMenu() end)
		end)
	end)

	describe("_buildEditorHTML", function()
		before_each(function()
			AudioPilot:loadConfig()
			AudioPilot._config.outputPriority = { "uidSpk" }
			AudioPilot._config.inputPriority = { "uidMic" }
			AudioPilot._config.knownDevices.output = {
				{ uid = "uidSpk", name = "Speakers" },
				{ uid = "uidHp", name = "Headphones" },
			}
			AudioPilot._config.knownDevices.input = {
				{ uid = "uidMic", name = "Microphone" },
				{ uid = "uidExtra", name = "ExtraMic" },
			}
		end)

		it("returns a string", function()
			local html = AudioPilot:_buildEditorHTML()
			assert.is.string(html)
		end)

		it("contains output priority device name", function()
			local html = AudioPilot:_buildEditorHTML()
			assert.truthy(html:find("Speakers", 1, true))
		end)

		it("contains input priority device name", function()
			local html = AudioPilot:_buildEditorHTML()
			assert.truthy(html:find("Microphone", 1, true))
		end)

		it("contains unranked known output device", function()
			local html = AudioPilot:_buildEditorHTML()
			assert.truthy(html:find("Headphones", 1, true))
		end)

		it("carries the device uid", function()
			local html = AudioPilot:_buildEditorHTML()
			assert.truthy(html:find("uidSpk", 1, true))
		end)

		it("does not include ranked device in unranked output list", function()
			local html = AudioPilot:_buildEditorHTML()
			local count = 0
			local pos = 1
			while true do
				local s, e = html:find('"uidSpk"', pos, true)
				if not s then break end
				count = count + 1
				pos = e + 1
			end
			assert.are.equal(1, count)
		end)
	end)

	describe("openEditor", function()
		before_each(function()
			AudioPilot:loadConfig()
			AudioPilot._menu = mock_hs.menubar.new()
		end)

		it("creates a webview on first call", function()
			AudioPilot:openEditor()
			assert.is_not_nil(AudioPilot._editor)
		end)

		it("shows the webview", function()
			AudioPilot:openEditor()
			assert.is_true(mock_hs.webview._lastWebview._visible)
		end)

		it("does not create a second webview when already open", function()
			AudioPilot:openEditor()
			local first = AudioPilot._editor
			AudioPilot:openEditor()
			assert.are.equal(first, AudioPilot._editor)
		end)

		it("window closing callback sets _editor to nil", function()
			AudioPilot:openEditor()
			local wv = mock_hs.webview._lastWebview
			wv._windowCb("closing")
			assert.is_nil(AudioPilot._editor)
		end)

		it("save callback updates outputPriority", function()
			AudioPilot:openEditor()
			local ctrl = mock_hs.webview._lastController
			ctrl._callback({ body = { action = "save", outputPriority = { "NewOut" }, inputPriority = {} } })
			assert.are.equal("NewOut", AudioPilot._config.outputPriority[1])
		end)

		it("save callback updates inputPriority", function()
			AudioPilot:openEditor()
			local ctrl = mock_hs.webview._lastController
			ctrl._callback({ body = { action = "save", outputPriority = {}, inputPriority = { "NewMic" } } })
			assert.are.equal("NewMic", AudioPilot._config.inputPriority[1])
		end)

		it("save callback calls saveConfig", function()
			AudioPilot:openEditor()
			local writeCount = 0
			local origWrite = mock_hs.json.write
			mock_hs.json.write = function(data, path, pretty)
				writeCount = writeCount + 1
				return origWrite(data, path, pretty)
			end
			local ctrl = mock_hs.webview._lastController
			ctrl._callback({ body = { action = "save", outputPriority = {}, inputPriority = {} } })
			assert.truthy(writeCount > 0)
		end)

		it("save callback calls selectBestDevice for output", function()
			local calls = {}
			AudioPilot:openEditor()
			AudioPilot.selectBestDevice = function(_self, dt) table.insert(calls, dt) end
			local ctrl = mock_hs.webview._lastController
			ctrl._callback({ body = { action = "save", outputPriority = {}, inputPriority = {} } })
			local found = false
			for _, v in ipairs(calls) do
				if v == "output" then found = true end
			end
			assert.is_true(found)
		end)

		it("save callback calls selectBestDevice for input", function()
			local calls = {}
			AudioPilot:openEditor()
			AudioPilot.selectBestDevice = function(_self, dt) table.insert(calls, dt) end
			local ctrl = mock_hs.webview._lastController
			ctrl._callback({ body = { action = "save", outputPriority = {}, inputPriority = {} } })
			local found = false
			for _, v in ipairs(calls) do
				if v == "input" then found = true end
			end
			assert.is_true(found)
		end)

		it("save callback deletes webview and sets _editor to nil", function()
			AudioPilot:openEditor()
			local ctrl = mock_hs.webview._lastController
			ctrl._callback({ body = { action = "save", outputPriority = {}, inputPriority = {} } })
			assert.is_nil(AudioPilot._editor)
		end)

		it("save callback forgets known devices and keeps the rest", function()
			AudioPilot._config.knownDevices.output = {
				{ uid = "uidGone", name = "Old Device" },
				{ uid = "uidKeep", name = "Keep Device" },
			}
			AudioPilot:openEditor()
			local ctrl = mock_hs.webview._lastController
			ctrl._callback({
				body = { action = "save", outputPriority = {}, inputPriority = {}, forgetOutput = { "uidGone" } },
			})
			assert.is_nil(findKnown(AudioPilot._config.knownDevices.output, "uidGone"))
			assert.is_not_nil(findKnown(AudioPilot._config.knownDevices.output, "uidKeep"))
		end)

		it("save callback forgets known input devices", function()
			AudioPilot._config.knownDevices.input = { { uid = "uidMicGone", name = "Old Mic" } }
			AudioPilot:openEditor()
			local ctrl = mock_hs.webview._lastController
			ctrl._callback({
				body = { action = "save", outputPriority = {}, inputPriority = {}, forgetInput = { "uidMicGone" } },
			})
			assert.is_nil(findKnown(AudioPilot._config.knownDevices.input, "uidMicGone"))
		end)

		it("save callback without forget lists leaves knownDevices intact", function()
			AudioPilot._config.knownDevices.output = { { uid = "uidKeep", name = "Keep" } }
			AudioPilot:openEditor()
			local ctrl = mock_hs.webview._lastController
			ctrl._callback({ body = { action = "save", outputPriority = {}, inputPriority = {} } })
			assert.is_not_nil(findKnown(AudioPilot._config.knownDevices.output, "uidKeep"))
		end)

		it("cancel callback does not modify config", function()
			AudioPilot._config.outputPriority = { "Original" }
			AudioPilot:openEditor()
			local ctrl = mock_hs.webview._lastController
			ctrl._callback({ body = { action = "cancel" } })
			assert.are.equal("Original", AudioPilot._config.outputPriority[1])
		end)

		it("cancel callback deletes webview and sets _editor to nil", function()
			AudioPilot:openEditor()
			local ctrl = mock_hs.webview._lastController
			ctrl._callback({ body = { action = "cancel" } })
			assert.is_nil(AudioPilot._editor)
		end)
	end)

	describe("start and stop", function()
		it("creates menu on start", function()
			AudioPilot:start()
			assert.is_not_nil(AudioPilot._menu)
		end)

		it("sets menu title to sound icon on start", function()
			AudioPilot:start()
			assert.are.equal("🔊", AudioPilot._menu._title)
		end)

		it("sets audio watcher callback on start", function()
			AudioPilot:start()
			assert.is_not_nil(mock_hs.audiodevice.watcher._callback)
		end)

		it("calls selectBestDevice for output on start", function()
			local outputCalled = false
			AudioPilot.selectBestDevice = function(_self, deviceType)
				if deviceType == "output" then outputCalled = true end
			end
			AudioPilot:start()
			assert.is_true(outputCalled)
		end)

		it("calls selectBestDevice for input on start", function()
			local inputCalled = false
			AudioPilot.selectBestDevice = function(_self, deviceType)
				if deviceType == "input" then inputCalled = true end
			end
			AudioPilot:start()
			assert.is_true(inputCalled)
		end)

		it("stops watcher on stop", function()
			AudioPilot:start()
			AudioPilot:stop()
			assert.is_nil(mock_hs.audiodevice.watcher._callback)
		end)

		it("deletes menu on stop", function()
			AudioPilot:start()
			local menu = AudioPilot._menu
			AudioPilot:stop()
			assert.is_true(menu._deleted)
		end)

		it("sets menu to nil on stop", function()
			AudioPilot:start()
			AudioPilot:stop()
			assert.is_nil(AudioPilot._menu)
		end)

		it("scans for Bluetooth devices on start", function()
			AudioPilot:start()
			assert.is_not_nil(mock_hs.task._lastTask)
			assert.is_true(mock_hs.task._lastTask._started)
		end)

		it("closes an open editor webview on stop", function()
			AudioPilot:start()
			AudioPilot:openEditor()
			local wv = AudioPilot._editor
			AudioPilot:stop()
			assert.is_true(wv._deleted)
			assert.is_nil(AudioPilot._editor)
		end)

		it("does not error on stop when no editor is open", function()
			AudioPilot:start()
			assert.has_no.errors(function() AudioPilot:stop() end)
		end)
	end)

	describe("uid-based matching", function()
		before_each(function() AudioPilot:loadConfig() end)

		it("switches by uid even when the device name changed", function()
			makeMockDevice("New Name", true, "stableUid")
			AudioPilot._config.outputPriority = { "stableUid" }
			AudioPilot:selectBestDevice("output")
			assert.are.equal("stableUid", mock_hs.audiodevice._defaultOutput:uid())
		end)

		it("distinguishes two devices that share a name", function()
			makeMockDevice("USB Audio", true, "uidA")
			local devB = makeMockDevice("USB Audio", true, "uidB")
			AudioPilot._config.outputPriority = { "uidB" }
			AudioPilot:selectBestDevice("output")
			assert.are.equal(devB, mock_hs.audiodevice._defaultOutput)
		end)

		it("does not switch when the priority uid is not connected", function()
			makeMockDevice("USB Audio", true, "uidA")
			AudioPilot._config.outputPriority = { "uidB" } -- different uid, same name
			AudioPilot:selectBestDevice("output")
			assert.is_nil(mock_hs.audiodevice._defaultOutput)
		end)

		it("refreshes a stored name when the device is renamed", function()
			makeMockDevice("Old Name", true, "uidR")
			AudioPilot:getAvailableDevices()
			mock_hs.audiodevice._outputDevices[1]._name = "New Name"
			AudioPilot:getAvailableDevices()
			local entry = findKnown(AudioPilot._config.knownDevices.output, "uidR")
			assert.is_not_nil(entry)
			assert.are.equal("New Name", entry.name)
		end)
	end)

	describe("mergeBluetoothDevices", function()
		before_each(function()
			AudioPilot:loadConfig()
			mock_hs.json.decode = function(_s)
				return {
					SPBluetoothDataType = {
						{
							device_connected = {
								{ ["Phone"] = { device_address = "74:42:18:CC:B2:D5" } },
							},
							device_not_connected = {
								{
									["Bose QC"] = { device_minorType = "Headset", device_address = "E4:58:BC:D4:81:B5" },
								},
								{
									["AirPods"] = {
										device_minorType = "Headphones",
										device_address = "5C:52:30:DB:6E:80",
									},
								},
								{
									["Keyboard"] = {
										device_minorType = "Keyboard",
										device_address = "AA:BB:CC:DD:EE:FF",
									},
								},
								{ ["No Addr"] = { device_minorType = "Speaker" } },
							},
						},
					},
				}
			end
		end)

		it("adds a headset under both output and input by MAC-derived uid", function()
			AudioPilot:mergeBluetoothDevices("ignored")
			assert.is_not_nil(findKnown(AudioPilot._config.knownDevices.output, "E4-58-BC-D4-81-B5:output"))
			assert.is_not_nil(findKnown(AudioPilot._config.knownDevices.input, "E4-58-BC-D4-81-B5:input"))
		end)

		it("stores the Bluetooth name for display", function()
			AudioPilot:mergeBluetoothDevices("ignored")
			local entry = findKnown(AudioPilot._config.knownDevices.output, "E4-58-BC-D4-81-B5:output")
			assert.are.equal("Bose QC", entry.name)
		end)

		it("skips non-audio Bluetooth devices", function()
			AudioPilot:mergeBluetoothDevices("ignored")
			for _, v in ipairs(AudioPilot._config.knownDevices.output) do
				assert.is_falsy(v.uid:find("AA-BB", 1, true))
			end
		end)

		it("skips audio devices without an address", function()
			AudioPilot:mergeBluetoothDevices("ignored")
			for _, v in ipairs(AudioPilot._config.knownDevices.output) do
				assert.are_not.equal("No Addr", v.name)
			end
		end)

		it("does not duplicate entries on rescan", function()
			AudioPilot:mergeBluetoothDevices("ignored")
			local n = #AudioPilot._config.knownDevices.output
			AudioPilot:mergeBluetoothDevices("ignored")
			assert.are.equal(n, #AudioPilot._config.knownDevices.output)
		end)

		it("ignores unparsable data without error", function()
			mock_hs.json.decode = function(_s) error("bad json") end
			assert.has_no.errors(function() AudioPilot:mergeBluetoothDevices("garbage") end)
		end)
	end)

	describe("menu (Bluetooth)", function()
		it("contains a Rescan Bluetooth Devices item that triggers a scan", function()
			AudioPilot:loadConfig()
			AudioPilot._menu = mock_hs.menubar.new()
			AudioPilot:updateMenu()
			local item = findMenuItem(AudioPilot._menu._menuItems, "Rescan Bluetooth")
			assert.is_not_nil(item)
			item.fn()
			assert.is_not_nil(mock_hs.task._lastTask)
		end)
	end)

	describe("scanBluetoothDevices", function()
		it("logs a warning when hs.task.new fails to create a task", function()
			mock_hs.task.new = function(_path, _cb, _args) return nil end
			AudioPilot:scanBluetoothDevices()
			assert.truthy(#AudioPilot.log._warnings > 0)
		end)

		it("logs a warning when the task fails to start", function()
			mock_hs.task.new = function(_path, cb, _args)
				local t = { _cb = cb }
				function t.start(_self) return false end
				mock_hs.task._lastTask = t
				return t
			end
			AudioPilot:scanBluetoothDevices()
			assert.truthy(#AudioPilot.log._warnings > 0)
		end)

		it("does not log a warning when the task starts successfully", function()
			AudioPilot:scanBluetoothDevices()
			assert.are.equal(0, #AudioPilot.log._warnings)
		end)
	end)

	describe("forgetDevices", function()
		before_each(function() AudioPilot:loadConfig() end)

		it("removes the matching uid from knownDevices", function()
			AudioPilot._config.knownDevices.output = {
				{ uid = "a", name = "A" },
				{ uid = "b", name = "B" },
			}
			AudioPilot:forgetDevices("output", { "a" })
			assert.is_nil(findKnown(AudioPilot._config.knownDevices.output, "a"))
			assert.is_not_nil(findKnown(AudioPilot._config.knownDevices.output, "b"))
		end)

		it("removes multiple uids", function()
			AudioPilot._config.knownDevices.output = {
				{ uid = "a", name = "A" },
				{ uid = "b", name = "B" },
				{ uid = "c", name = "C" },
			}
			AudioPilot:forgetDevices("output", { "a", "c" })
			assert.are.equal(1, #AudioPilot._config.knownDevices.output)
			assert.are.equal("b", AudioPilot._config.knownDevices.output[1].uid)
		end)

		it("is a no-op when uids is nil", function()
			AudioPilot._config.knownDevices.output = { { uid = "a", name = "A" } }
			assert.has_no.errors(function() AudioPilot:forgetDevices("output", nil) end)
			assert.are.equal(1, #AudioPilot._config.knownDevices.output)
		end)
	end)
end)
