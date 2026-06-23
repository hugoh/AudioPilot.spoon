local mock_hs
local AudioPilot

local function makeLogger()
	return { i = function() end, w = function() end, d = function() end, v = function() end }
end

local function makeMockDevice(name, isOutput)
	local d = { _name = name }
	function d:name() return self._name end
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
		open = function(_p) end,
		notify = {
			_sent = {},
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
				start = function(cb) mock_hs.audiodevice.watcher._callback = cb end,
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
		function wv:html(h) self._html = h end
		function wv:show() self._visible = true end
		function wv:delete() self._deleted = true end
		function wv.windowStyle(_self, _m) end
		function wv:windowCallback(fn) self._windowCb = fn end
		mock_hs.webview._lastWebview = wv
		mock_hs.webview._lastController = controller
		return wv
	end

	mock_hs._setConfig = function(path, cfg) config_store[path] = cfg end

	package.loaded.hs = nil
	_G.hs = mock_hs

	AudioPilot = dofile("init.lua")
end)

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
			makeMockDevice("NewSpeakers", true)
			AudioPilot:getAvailableDevices()
			local found = false
			for _, v in ipairs(AudioPilot._config.knownDevices.output) do
				if v == "NewSpeakers" then found = true end
			end
			assert.is_true(found)
		end)

		it("updates knownDevices with newly seen input devices", function()
			makeMockDevice("NewMic", false)
			AudioPilot:getAvailableDevices()
			local found = false
			for _, v in ipairs(AudioPilot._config.knownDevices.input) do
				if v == "NewMic" then found = true end
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
			makeMockDevice("KnownDevice", true)
			-- Pre-populate knownDevices
			AudioPilot._config.knownDevices.output = { "KnownDevice" }
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
		before_each(function() AudioPilot:loadConfig() end)

		it("sends notification when switching output device", function()
			makeMockDevice("DevA", true)
			AudioPilot._config.outputPriority = { "DevA" }
			AudioPilot:selectBestDevice("output")
			assert.are.equal(1, #mock_hs.notify._sent)
			assert.are.equal("AudioPilot", mock_hs.notify._sent[1].title)
			assert.truthy(mock_hs.notify._sent[1].informativeText:find("DevA"))
		end)

		it("sends notification when switching input device", function()
			makeMockDevice("MicA", false)
			AudioPilot._config.inputPriority = { "MicA" }
			AudioPilot:selectBestDevice("input")
			assert.are.equal(1, #mock_hs.notify._sent)
			assert.truthy(mock_hs.notify._sent[1].informativeText:find("MicA"))
		end)

		it("does not notify when device is already current", function()
			local dev = makeMockDevice("DevA", true)
			mock_hs.audiodevice._defaultOutput = dev
			AudioPilot._config.outputPriority = { "DevA" }
			AudioPilot:selectBestDevice("output")
			assert.are.equal(0, #mock_hs.notify._sent)
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
			AudioPilot._config.outputPriority = { "Speakers" }
			AudioPilot._config.inputPriority = { "Microphone" }
			AudioPilot._config.knownDevices.output = { "Speakers", "Headphones" }
			AudioPilot._config.knownDevices.input = { "Microphone", "ExtraMic" }
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

		it("does not include ranked device in unranked output list", function()
			local html = AudioPilot:_buildEditorHTML()
			local count = 0
			local pos = 1
			while true do
				local s, e = html:find('"Speakers"', pos, true)
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
	end)
end)
