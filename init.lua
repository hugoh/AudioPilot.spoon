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

local function tableContains(t, value)
	for _, v in ipairs(t) do
		if v == value then return true end
	end
	return false
end

function obj:loadConfig()
	local config = hs.json.read(self.configPath)
	if not config then
		self._config = {
			outputPriority = {},
			inputPriority = {},
			knownDevices = { output = {}, input = {} },
		}
		self:saveConfig()
	else
		self._config = config
	end
	self.log.i("Config loaded from " .. self.configPath)
end

function obj:saveConfig()
	local dir = string.match(self.configPath, "^(.*)/[^/]+$")
	if dir then hs.fs.mkdir(dir) end
	hs.json.write(self._config, self.configPath, true)
	self.log.i("Config saved to " .. self.configPath)
end

function obj:getAvailableDevices()
	local outputSet = {}
	local inputSet = {}
	local changed = false

	for _, dev in ipairs(hs.audiodevice.allOutputDevices()) do
		local name = dev:name()
		outputSet[name] = true
		if not tableContains(self._config.knownDevices.output, name) then
			table.insert(self._config.knownDevices.output, name)
			changed = true
		end
	end

	for _, dev in ipairs(hs.audiodevice.allInputDevices()) do
		local name = dev:name()
		inputSet[name] = true
		if not tableContains(self._config.knownDevices.input, name) then
			table.insert(self._config.knownDevices.input, name)
			changed = true
		end
	end

	if changed then self:saveConfig() end

	return { output = outputSet, input = inputSet }
end

function obj:selectBestDevice(deviceType)
	local available = self:getAvailableDevices()
	local priorities = self._config[deviceType .. "Priority"] or {}
	local availableSet = available[deviceType]

	for _, name in ipairs(priorities) do
		if availableSet[name] then
			local current
			if deviceType == "output" then
				current = hs.audiodevice.defaultOutputDevice()
			else
				current = hs.audiodevice.defaultInputDevice()
			end

			if current and current:name() == name then
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
				if dev:name() == name then
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

	local items = {}

	table.insert(items, { title = "Output: " .. currentOutputName, disabled = true })
	table.insert(items, { title = "Input:  " .. currentInputName, disabled = true })
	table.insert(items, { title = "-" })

	table.insert(items, { title = "Output Priority:", disabled = true })
	for _, name in ipairs(self._config.outputPriority) do
		local prefix = (name == currentOutputName) and "* " or "  "
		local suffix = available.output[name] and "" or " (disconnected)"
		table.insert(items, { title = prefix .. name .. suffix, disabled = true })
	end
	table.insert(items, { title = "-" })

	table.insert(items, { title = "Input Priority:", disabled = true })
	for _, name in ipairs(self._config.inputPriority) do
		local prefix = (name == currentInputName) and "* " or "  "
		local suffix = available.input[name] and "" or " (disconnected)"
		table.insert(items, { title = prefix .. name .. suffix, disabled = true })
	end
	table.insert(items, { title = "-" })

	local self_ref = self
	table.insert(items, {
		title = "Refresh",
		fn = function()
			self_ref:selectBestDevice("output")
			self_ref:selectBestDevice("input")
		end,
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
	local prioritySet = {}
	for _, v in ipairs(self._config.outputPriority) do
		prioritySet[v] = true
	end
	local outputUnranked = {}
	for _, v in ipairs(self._config.knownDevices.output) do
		if not prioritySet[v] then table.insert(outputUnranked, v) end
	end

	prioritySet = {}
	for _, v in ipairs(self._config.inputPriority) do
		prioritySet[v] = true
	end
	local inputUnranked = {}
	for _, v in ipairs(self._config.knownDevices.input) do
		if not prioritySet[v] then table.insert(inputUnranked, v) end
	end

	local initScript = "<script>window.__initialState="
		.. hs.json.encode({
			output = { priority = self._config.outputPriority, unranked = outputUnranked },
			input = { priority = self._config.inputPriority, unranked = inputUnranked },
		})
		.. ";</script>"

	local f = io.open(_spoonPath .. "editor.html")
	if not f then
		self.log.e("editor.html not found at " .. _spoonPath)
		return ""
	end
	local html = f:read("*all")
	f:close()
	return (html:gsub("</head>", initScript .. "</head>", 1))
end

function obj:openEditor()
	if self._editor then
		self._editor:show()
		return
	end

	local controller = hs.webview.usercontent.new("AudioPilotEditor")
	local sf = hs.screen.mainScreen():frame()
	local w, h = 480, 620
	local frame = { x = sf.x + (sf.w - w) / 2, y = sf.y + (sf.h - h) / 2, w = w, h = h }

	self._editor = hs.webview.new(frame, {}, controller)
	self._editor:windowStyle(hs.webview.windowMasks.titled + hs.webview.windowMasks.closable)

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

	self._editor:html(self:_buildEditorHTML(), "file://" .. _spoonPath)
	self._editor:show()
end

function obj:openConfig() hs.open(self.configPath) end

function obj:start()
	self:loadConfig()
	self._menu = hs.menubar.new()
	self._menu:setTitle("🔊")
	self:selectBestDevice("output")
	self:selectBestDevice("input")
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
