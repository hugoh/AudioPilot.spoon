local mock_hs
local AutoAudioSwitcher

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

	AutoAudioSwitcher = dofile("init.lua")
end)

after_each(function()
	if AutoAudioSwitcher._menu then AutoAudioSwitcher:stop() end
end)

describe("AutoAudioSwitcher", function()
	describe("module structure", function()
		it("returns a table", function() assert.is.table(AutoAudioSwitcher) end)

		it("has name", function() assert.are.equal("AutoAudioSwitcher", AutoAudioSwitcher.name) end)

		it("has version string", function() assert.is.string(AutoAudioSwitcher.version) end)

		it("has configPath ending in config.json", function()
			assert.is.string(AutoAudioSwitcher.configPath)
			assert.truthy(AutoAudioSwitcher.configPath:find("config.json$"))
		end)

		it("has required methods", function()
			assert.are.equal("function", type(AutoAudioSwitcher.loadConfig))
			assert.are.equal("function", type(AutoAudioSwitcher.saveConfig))
			assert.are.equal("function", type(AutoAudioSwitcher.getAvailableDevices))
			assert.are.equal("function", type(AutoAudioSwitcher.selectBestDevice))
			assert.are.equal("function", type(AutoAudioSwitcher.onDeviceChange))
			assert.are.equal("function", type(AutoAudioSwitcher.updateMenu))
			assert.are.equal("function", type(AutoAudioSwitcher.start))
			assert.are.equal("function", type(AutoAudioSwitcher.stop))
			assert.are.equal("function", type(AutoAudioSwitcher.openConfig))
			assert.are.equal("function", type(AutoAudioSwitcher.openEditor))
			assert.are.equal("function", type(AutoAudioSwitcher._buildEditorHTML))
		end)

		it("initializes with nil menu", function() assert.is_nil(AutoAudioSwitcher._menu) end)

		it("initializes with nil config", function() assert.is_nil(AutoAudioSwitcher._config) end)

		it("initializes with nil editor", function() assert.is_nil(AutoAudioSwitcher._editor) end)

		it("has logger instance", function() assert.is.table(AutoAudioSwitcher.log) end)
	end)

	describe("loadConfig", function()
		it("creates default config when file missing", function()
			AutoAudioSwitcher:loadConfig()
			assert.is.table(AutoAudioSwitcher._config)
			assert.is.table(AutoAudioSwitcher._config.outputPriority)
			assert.is.table(AutoAudioSwitcher._config.inputPriority)
			assert.is.table(AutoAudioSwitcher._config.knownDevices)
			assert.is.table(AutoAudioSwitcher._config.knownDevices.output)
			assert.is.table(AutoAudioSwitcher._config.knownDevices.input)
			assert.are.equal(0, #AutoAudioSwitcher._config.outputPriority)
			assert.are.equal(0, #AutoAudioSwitcher._config.inputPriority)
		end)

		it("saves config when creating default", function()
			local writeCount = 0
			local orig = mock_hs.json.write
			mock_hs.json.write = function(data, path, pretty)
				writeCount = writeCount + 1
				return orig(data, path, pretty)
			end
			AutoAudioSwitcher:loadConfig()
			assert.truthy(writeCount > 0)
		end)

		it("reads existing config from disk", function()
			mock_hs._setConfig(AutoAudioSwitcher.configPath, {
				outputPriority = { "DevA", "DevB" },
				inputPriority = { "MicA" },
				knownDevices = { output = {}, input = {} },
			})
			AutoAudioSwitcher:loadConfig()
			assert.are.equal(2, #AutoAudioSwitcher._config.outputPriority)
			assert.are.equal("DevA", AutoAudioSwitcher._config.outputPriority[1])
			assert.are.equal("DevB", AutoAudioSwitcher._config.outputPriority[2])
		end)

		it("calls hs.fs.mkdir with config directory", function()
			local mkdirPath = nil
			mock_hs.fs.mkdir = function(p) mkdirPath = p end
			AutoAudioSwitcher:loadConfig()
			assert.is_not_nil(mkdirPath)
			assert.truthy(mkdirPath:find("AutoAudioSwitcher"))
		end)
	end)

	describe("saveConfig", function()
		it("calls hs.json.write with configPath", function()
			AutoAudioSwitcher:loadConfig()
			local writtenPath
			mock_hs.json.write = function(_data, path, _pretty) writtenPath = path end
			AutoAudioSwitcher:saveConfig()
			assert.are.equal(AutoAudioSwitcher.configPath, writtenPath)
		end)

		it("calls hs.fs.mkdir before writing", function()
			local callOrder = {}
			mock_hs.fs.mkdir = function(_p) table.insert(callOrder, "mkdir") end
			mock_hs.json.write = function(_d, _p, _pp) table.insert(callOrder, "write") end
			AutoAudioSwitcher._config =
				{ outputPriority = {}, inputPriority = {}, knownDevices = { output = {}, input = {} } }
			AutoAudioSwitcher:saveConfig()
			assert.are.equal("mkdir", callOrder[1])
			assert.are.equal("write", callOrder[2])
		end)
	end)

	describe("getAvailableDevices", function()
		before_each(function() AutoAudioSwitcher:loadConfig() end)

		it("returns output and input keys", function()
			local available = AutoAudioSwitcher:getAvailableDevices()
			assert.is.table(available.output)
			assert.is.table(available.input)
		end)

		it("returns connected output device names as truthy keys", function()
			makeMockDevice("Speakers", true)
			local available = AutoAudioSwitcher:getAvailableDevices()
			assert.truthy(available.output["Speakers"])
		end)

		it("returns connected input device names as truthy keys", function()
			makeMockDevice("Microphone", false)
			local available = AutoAudioSwitcher:getAvailableDevices()
			assert.truthy(available.input["Microphone"])
		end)

		it("updates knownDevices with newly seen output devices", function()
			makeMockDevice("NewSpeakers", true)
			AutoAudioSwitcher:getAvailableDevices()
			local found = false
			for _, v in ipairs(AutoAudioSwitcher._config.knownDevices.output) do
				if v == "NewSpeakers" then found = true end
			end
			assert.is_true(found)
		end)

		it("updates knownDevices with newly seen input devices", function()
			makeMockDevice("NewMic", false)
			AutoAudioSwitcher:getAvailableDevices()
			local found = false
			for _, v in ipairs(AutoAudioSwitcher._config.knownDevices.input) do
				if v == "NewMic" then found = true end
			end
			assert.is_true(found)
		end)

		it("saves config when new device discovered", function()
			local writeCount = 0
			mock_hs.json.write = function(_d, _p, _pp) writeCount = writeCount + 1 end
			makeMockDevice("BrandNewDevice", true)
			AutoAudioSwitcher:getAvailableDevices()
			assert.truthy(writeCount > 0)
		end)

		it("does not save config when no new devices found", function()
			makeMockDevice("KnownDevice", true)
			-- Pre-populate knownDevices
			AutoAudioSwitcher._config.knownDevices.output = { "KnownDevice" }
			local writeCount = 0
			mock_hs.json.write = function(_d, _p, _pp) writeCount = writeCount + 1 end
			AutoAudioSwitcher:getAvailableDevices()
			assert.are.equal(0, writeCount)
		end)
	end)

	describe("selectBestDevice", function()
		before_each(function() AutoAudioSwitcher:loadConfig() end)

		it("selects highest-priority available output device", function()
			makeMockDevice("DevB", true)
			AutoAudioSwitcher._config.outputPriority = { "DevA", "DevB" }
			AutoAudioSwitcher:selectBestDevice("output")
			assert.are.equal("DevB", mock_hs.audiodevice._defaultOutput:name())
		end)

		it("selects first priority device when connected", function()
			makeMockDevice("DevA", true)
			makeMockDevice("DevB", true)
			AutoAudioSwitcher._config.outputPriority = { "DevA", "DevB" }
			AutoAudioSwitcher:selectBestDevice("output")
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
			AutoAudioSwitcher._config.outputPriority = { "DevA" }
			AutoAudioSwitcher:selectBestDevice("output")
			assert.are.equal(0, switchCount)
		end)

		it("does nothing when no priority device is available", function()
			AutoAudioSwitcher._config.outputPriority = { "NonExistentDevice" }
			-- Should not error, no switch
			AutoAudioSwitcher:selectBestDevice("output")
			assert.is_nil(mock_hs.audiodevice._defaultOutput)
		end)

		it("selects highest-priority available input device", function()
			makeMockDevice("MicB", false)
			AutoAudioSwitcher._config.inputPriority = { "MicA", "MicB" }
			AutoAudioSwitcher:selectBestDevice("input")
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
			AutoAudioSwitcher._config.inputPriority = { "MicA" }
			AutoAudioSwitcher:selectBestDevice("input")
			assert.are.equal(0, switchCount)
		end)
	end)

	describe("notifications", function()
		before_each(function() AutoAudioSwitcher:loadConfig() end)

		it("sends notification when switching output device", function()
			makeMockDevice("DevA", true)
			AutoAudioSwitcher._config.outputPriority = { "DevA" }
			AutoAudioSwitcher:selectBestDevice("output")
			assert.are.equal(1, #mock_hs.notify._sent)
			assert.are.equal("AutoAudioSwitcher", mock_hs.notify._sent[1].title)
			assert.truthy(mock_hs.notify._sent[1].informativeText:find("DevA"))
		end)

		it("sends notification when switching input device", function()
			makeMockDevice("MicA", false)
			AutoAudioSwitcher._config.inputPriority = { "MicA" }
			AutoAudioSwitcher:selectBestDevice("input")
			assert.are.equal(1, #mock_hs.notify._sent)
			assert.truthy(mock_hs.notify._sent[1].informativeText:find("MicA"))
		end)

		it("does not notify when device is already current", function()
			local dev = makeMockDevice("DevA", true)
			mock_hs.audiodevice._defaultOutput = dev
			AutoAudioSwitcher._config.outputPriority = { "DevA" }
			AutoAudioSwitcher:selectBestDevice("output")
			assert.are.equal(0, #mock_hs.notify._sent)
		end)
	end)

	describe("onDeviceChange", function()
		before_each(function()
			AutoAudioSwitcher:loadConfig()
			AutoAudioSwitcher._menu = mock_hs.menubar.new()
		end)

		it("calls selectBestDevice for output and input on dev# event", function()
			local calls = {}
			AutoAudioSwitcher.selectBestDevice = function(_self, deviceType) table.insert(calls, deviceType) end
			AutoAudioSwitcher:onDeviceChange("dev#")
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
			AutoAudioSwitcher.updateMenu = function() updateCalled = true end
			AutoAudioSwitcher.selectBestDevice = function() selectCalled = true end
			AutoAudioSwitcher:onDeviceChange("dOut")
			assert.is_true(updateCalled)
			assert.is_false(selectCalled)
		end)

		it("calls updateMenu on dIn event without selectBestDevice", function()
			local updateCalled = false
			local selectCalled = false
			AutoAudioSwitcher.updateMenu = function() updateCalled = true end
			AutoAudioSwitcher.selectBestDevice = function() selectCalled = true end
			AutoAudioSwitcher:onDeviceChange("dIn")
			assert.is_true(updateCalled)
			assert.is_false(selectCalled)
		end)

		it("ignores unknown events without error", function()
			AutoAudioSwitcher.selectBestDevice = function() error("should not be called") end
			AutoAudioSwitcher.updateMenu = function() error("should not be called") end
			assert.has_no.errors(function() AutoAudioSwitcher:onDeviceChange("unknown") end)
		end)
	end)

	describe("updateMenu", function()
		before_each(function()
			AutoAudioSwitcher:loadConfig()
			AutoAudioSwitcher._menu = mock_hs.menubar.new()
			AutoAudioSwitcher._config.outputPriority = { "Speakers", "Headphones" }
			AutoAudioSwitcher._config.inputPriority = { "Microphone" }
			makeMockDevice("Speakers", true)
			makeMockDevice("Headphones", true)
			makeMockDevice("Microphone", false)
			mock_hs.audiodevice._defaultOutput = mock_hs.audiodevice._outputDevices[1] -- Speakers
			mock_hs.audiodevice._defaultInput = mock_hs.audiodevice._inputDevices[1] -- Microphone
			AutoAudioSwitcher:updateMenu()
		end)

		it("sets menu title to sound icon", function() assert.are.equal("🔊", AutoAudioSwitcher._menu._title) end)

		it("menu contains current output device name", function()
			local item = findMenuItem(AutoAudioSwitcher._menu._menuItems, "Output:")
			assert.is_not_nil(item)
			assert.truthy(item.title:find("Speakers"))
		end)

		it("menu contains current input device name", function()
			local item = findMenuItem(AutoAudioSwitcher._menu._menuItems, "Input:")
			assert.is_not_nil(item)
			assert.truthy(item.title:find("Microphone"))
		end)

		it("marks current output device with asterisk", function()
			local item = findMenuItem(AutoAudioSwitcher._menu._menuItems, "* Speakers")
			assert.is_not_nil(item)
		end)

		it("marks non-current connected device without asterisk", function()
			local item = findMenuItem(AutoAudioSwitcher._menu._menuItems, "  Headphones")
			assert.is_not_nil(item)
		end)

		it("marks disconnected priority device", function()
			AutoAudioSwitcher._config.outputPriority = { "Speakers", "DisconnectedDevice" }
			AutoAudioSwitcher:updateMenu()
			local item = findMenuItem(AutoAudioSwitcher._menu._menuItems, "DisconnectedDevice")
			assert.is_not_nil(item)
			assert.truthy(item.title:find("disconnected"))
		end)

		it("menu contains Refresh item", function()
			local item = findMenuItem(AutoAudioSwitcher._menu._menuItems, "Refresh")
			assert.is_not_nil(item)
		end)

		it("menu contains Edit Priorities item", function()
			local item = findMenuItem(AutoAudioSwitcher._menu._menuItems, "Edit Priorities")
			assert.is_not_nil(item)
		end)

		it("menu contains Edit Config File item", function()
			local item = findMenuItem(AutoAudioSwitcher._menu._menuItems, "Edit Config File")
			assert.is_not_nil(item)
		end)

		it("Refresh item triggers selectBestDevice for both types", function()
			local calls = {}
			AutoAudioSwitcher.selectBestDevice = function(_self, deviceType) table.insert(calls, deviceType) end
			local item = findMenuItem(AutoAudioSwitcher._menu._menuItems, "Refresh")
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
			local item = findMenuItem(AutoAudioSwitcher._menu._menuItems, "Edit Config File")
			assert.is_not_nil(item)
			item.fn()
			assert.are.equal(AutoAudioSwitcher.configPath, openedPath)
		end)

		it("Edit Priorities item calls openEditor", function()
			local editorOpened = false
			AutoAudioSwitcher.openEditor = function(_self) editorOpened = true end
			local item = findMenuItem(AutoAudioSwitcher._menu._menuItems, "Edit Priorities")
			assert.is_not_nil(item)
			item.fn()
			assert.is_true(editorOpened)
		end)

		it("does nothing when menu is nil", function()
			AutoAudioSwitcher._menu = nil
			assert.has_no.errors(function() AutoAudioSwitcher:updateMenu() end)
		end)
	end)

	describe("_buildEditorHTML", function()
		before_each(function()
			AutoAudioSwitcher:loadConfig()
			AutoAudioSwitcher._config.outputPriority = { "Speakers" }
			AutoAudioSwitcher._config.inputPriority = { "Microphone" }
			AutoAudioSwitcher._config.knownDevices.output = { "Speakers", "Headphones" }
			AutoAudioSwitcher._config.knownDevices.input = { "Microphone", "ExtraMic" }
		end)

		it("returns a string", function()
			local html = AutoAudioSwitcher:_buildEditorHTML()
			assert.is.string(html)
		end)

		it("contains output priority device name", function()
			local html = AutoAudioSwitcher:_buildEditorHTML()
			assert.truthy(html:find("Speakers", 1, true))
		end)

		it("contains input priority device name", function()
			local html = AutoAudioSwitcher:_buildEditorHTML()
			assert.truthy(html:find("Microphone", 1, true))
		end)

		it("contains unranked known output device", function()
			local html = AutoAudioSwitcher:_buildEditorHTML()
			assert.truthy(html:find("Headphones", 1, true))
		end)

		it("does not include ranked device in unranked output list", function()
			local html = AutoAudioSwitcher:_buildEditorHTML()
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
			AutoAudioSwitcher:loadConfig()
			AutoAudioSwitcher._menu = mock_hs.menubar.new()
		end)

		it("creates a webview on first call", function()
			AutoAudioSwitcher:openEditor()
			assert.is_not_nil(AutoAudioSwitcher._editor)
		end)

		it("shows the webview", function()
			AutoAudioSwitcher:openEditor()
			assert.is_true(mock_hs.webview._lastWebview._visible)
		end)

		it("does not create a second webview when already open", function()
			AutoAudioSwitcher:openEditor()
			local first = AutoAudioSwitcher._editor
			AutoAudioSwitcher:openEditor()
			assert.are.equal(first, AutoAudioSwitcher._editor)
		end)

		it("window closing callback sets _editor to nil", function()
			AutoAudioSwitcher:openEditor()
			local wv = mock_hs.webview._lastWebview
			wv._windowCb("closing")
			assert.is_nil(AutoAudioSwitcher._editor)
		end)

		it("save callback updates outputPriority", function()
			AutoAudioSwitcher:openEditor()
			local ctrl = mock_hs.webview._lastController
			ctrl._callback({ body = { action = "save", outputPriority = { "NewOut" }, inputPriority = {} } })
			assert.are.equal("NewOut", AutoAudioSwitcher._config.outputPriority[1])
		end)

		it("save callback updates inputPriority", function()
			AutoAudioSwitcher:openEditor()
			local ctrl = mock_hs.webview._lastController
			ctrl._callback({ body = { action = "save", outputPriority = {}, inputPriority = { "NewMic" } } })
			assert.are.equal("NewMic", AutoAudioSwitcher._config.inputPriority[1])
		end)

		it("save callback calls saveConfig", function()
			AutoAudioSwitcher:openEditor()
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
			AutoAudioSwitcher:openEditor()
			AutoAudioSwitcher.selectBestDevice = function(_self, dt) table.insert(calls, dt) end
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
			AutoAudioSwitcher:openEditor()
			AutoAudioSwitcher.selectBestDevice = function(_self, dt) table.insert(calls, dt) end
			local ctrl = mock_hs.webview._lastController
			ctrl._callback({ body = { action = "save", outputPriority = {}, inputPriority = {} } })
			local found = false
			for _, v in ipairs(calls) do
				if v == "input" then found = true end
			end
			assert.is_true(found)
		end)

		it("save callback deletes webview and sets _editor to nil", function()
			AutoAudioSwitcher:openEditor()
			local ctrl = mock_hs.webview._lastController
			ctrl._callback({ body = { action = "save", outputPriority = {}, inputPriority = {} } })
			assert.is_nil(AutoAudioSwitcher._editor)
		end)

		it("cancel callback does not modify config", function()
			AutoAudioSwitcher._config.outputPriority = { "Original" }
			AutoAudioSwitcher:openEditor()
			local ctrl = mock_hs.webview._lastController
			ctrl._callback({ body = { action = "cancel" } })
			assert.are.equal("Original", AutoAudioSwitcher._config.outputPriority[1])
		end)

		it("cancel callback deletes webview and sets _editor to nil", function()
			AutoAudioSwitcher:openEditor()
			local ctrl = mock_hs.webview._lastController
			ctrl._callback({ body = { action = "cancel" } })
			assert.is_nil(AutoAudioSwitcher._editor)
		end)
	end)

	describe("start and stop", function()
		it("creates menu on start", function()
			AutoAudioSwitcher:start()
			assert.is_not_nil(AutoAudioSwitcher._menu)
		end)

		it("sets menu title to sound icon on start", function()
			AutoAudioSwitcher:start()
			assert.are.equal("🔊", AutoAudioSwitcher._menu._title)
		end)

		it("sets audio watcher callback on start", function()
			AutoAudioSwitcher:start()
			assert.is_not_nil(mock_hs.audiodevice.watcher._callback)
		end)

		it("calls selectBestDevice for output on start", function()
			local outputCalled = false
			AutoAudioSwitcher.selectBestDevice = function(_self, deviceType)
				if deviceType == "output" then outputCalled = true end
			end
			AutoAudioSwitcher:start()
			assert.is_true(outputCalled)
		end)

		it("calls selectBestDevice for input on start", function()
			local inputCalled = false
			AutoAudioSwitcher.selectBestDevice = function(_self, deviceType)
				if deviceType == "input" then inputCalled = true end
			end
			AutoAudioSwitcher:start()
			assert.is_true(inputCalled)
		end)

		it("stops watcher on stop", function()
			AutoAudioSwitcher:start()
			AutoAudioSwitcher:stop()
			assert.is_nil(mock_hs.audiodevice.watcher._callback)
		end)

		it("deletes menu on stop", function()
			AutoAudioSwitcher:start()
			local menu = AutoAudioSwitcher._menu
			AutoAudioSwitcher:stop()
			assert.is_true(menu._deleted)
		end)

		it("sets menu to nil on stop", function()
			AutoAudioSwitcher:start()
			AutoAudioSwitcher:stop()
			assert.is_nil(AutoAudioSwitcher._menu)
		end)
	end)
end)
