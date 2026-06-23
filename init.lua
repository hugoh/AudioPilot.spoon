local obj = {}
obj.__index = obj

obj.name = "AutoAudioSwitcher"
obj.version = "1.0.0"
obj.author = "Hugo Haas"
obj.license = "MIT"
obj.homepage = "https://github.com/hugoh/AutoAudioSwitcher.spoon"

obj.configPath = os.getenv("HOME") .. "/.config/AutoAudioSwitcher/config.json"

obj._menu = nil
obj._config = nil
obj.log = hs.logger.new("AutoAudioSwitcher", "info")

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
					hs.notify
						.new({ title = "AutoAudioSwitcher", informativeText = deviceType .. " → " .. name })
						:send()
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
		title = "Edit Config...",
		fn = function() self_ref:openConfig() end,
	})

	self._menu:setTitle("🔊")
	self._menu:setMenu(items)
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
	self.log.i("AutoAudioSwitcher started")
end

function obj:stop()
	hs.audiodevice.watcher.stop()
	if self._menu then
		self._menu:delete()
		self._menu = nil
	end
	self.log.i("AutoAudioSwitcher stopped")
end

return obj
