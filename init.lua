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
obj._editor = nil
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

	-- luacheck: push ignore 631
	-- stylua: ignore
	return [[<!DOCTYPE html>
<html><head><meta charset="UTF-8"><title>Audio Device Priorities</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;font-size:13px;background:#f5f5f7;color:#1d1d1f;padding:16px;-webkit-user-select:none}
h1{font-size:17px;font-weight:600;margin-bottom:14px}
.lbl{font-size:11px;font-weight:600;text-transform:uppercase;color:#6e6e73;letter-spacing:.05em;margin:10px 0 3px}
.card{background:#fff;border-radius:10px;border:1px solid rgba(0,0,0,.08);overflow:hidden;min-height:34px}
.item{display:flex;align-items:center;padding:7px 12px;border-bottom:1px solid rgba(0,0,0,.06);gap:8px}
.item:last-child{border-bottom:none}
.pi{cursor:grab}.pi:active{cursor:grabbing}
.handle{color:#c0c0c0;font-size:12px;flex-shrink:0}
.name{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.btn{background:none;border:none;cursor:pointer;font-size:15px;line-height:1;padding:0 2px;flex-shrink:0}
.rbtn{color:#ff3b30}.rbtn:hover{color:#c00}
.abtn{color:#007aff}.abtn:hover{color:#005bcc}
.empty{padding:10px 12px;color:#aeaeb2;font-style:italic}
.footer{display:flex;justify-content:flex-end;gap:8px;margin-top:14px;padding-top:12px;border-top:1px solid rgba(0,0,0,.08)}
.bc{padding:5px 16px;border-radius:6px;border:1px solid #d2d2d7;background:#fff;cursor:pointer;font-size:13px}
.bc:hover{background:#f0f0f5}
.bs{padding:5px 16px;border-radius:6px;border:none;background:#007aff;color:#fff;cursor:pointer;font-size:13px;font-weight:500}
.bs:hover{background:#005bcc}
</style>
</head><body>
<h1>Audio Device Priorities</h1>
<div class="lbl">Output Priority</div><div class="card" id="op"></div>
<div class="lbl">Other Known Output Devices</div><div class="card" id="ou"></div>
<div class="lbl" style="margin-top:14px">Input Priority</div><div class="card" id="ip"></div>
<div class="lbl">Other Known Input Devices</div><div class="card" id="iu"></div>
<div class="footer"><button class="bc" id="cc">Cancel</button><button class="bs" id="sc">Save</button></div>
<script>
const state={output:{priority:]] .. hs.json.encode(self._config.outputPriority)
		.. [[,unranked:]] .. hs.json.encode(outputUnranked)
		.. [[},input:{priority:]] .. hs.json.encode(self._config.inputPriority)
		.. [[,unranked:]] .. hs.json.encode(inputUnranked)
		.. [[}};
function esc(s){return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')}
function getOrder(id){return[...document.getElementById(id).querySelectorAll('.pi')].map(e=>e.dataset.name)}
function syncDOM(){state.output.priority=getOrder('op');state.input.priority=getOrder('ip')}
let src=null;
function render(id,items,type,pri){
  const el=document.getElementById(id);el.innerHTML='';
  if(!items.length){el.innerHTML='<div class="empty">'+(pri?'No devices ranked yet':'No other known devices')+'</div>';return}
  items.forEach(n=>{
    const d=document.createElement('div');
    d.className='item'+(pri?' pi':'');d.dataset.name=n;
    if(pri){
      d.draggable=true;
      d.innerHTML='<span class="handle">⠿</span><span class="name">'+esc(n)+'</span><button class="btn rbtn" title="Remove">✕</button>';
      d.addEventListener('dragstart',e=>{src=d;e.dataTransfer.effectAllowed='move';d.style.opacity='.4'});
      d.addEventListener('dragover',e=>{
        e.preventDefault();if(src===d)return;
        const r=d.getBoundingClientRect();
        d.parentNode.insertBefore(src,e.clientY<r.top+r.height/2?d:d.nextSibling);
      });
      d.addEventListener('drop',e=>e.preventDefault());
      d.addEventListener('dragend',()=>{d.style.opacity='';src=null});
      d.querySelector('.rbtn').addEventListener('click',()=>{syncDOM();state[type].priority=state[type].priority.filter(x=>x!==n);state[type].unranked.push(n);renderAll()});
    }else{
      d.innerHTML='<span class="name">'+esc(n)+'</span><button class="btn abtn" title="Add to priority">＋</button>';
      d.querySelector('.abtn').addEventListener('click',()=>{syncDOM();state[type].unranked=state[type].unranked.filter(x=>x!==n);state[type].priority.push(n);renderAll()});
    }
    el.appendChild(d);
  });
  if(pri){
    el.addEventListener('dragover',e=>{if(e.target===el||e.target.classList.contains('empty')){e.preventDefault();if(src)el.appendChild(src)}});
    el.addEventListener('drop',e=>e.preventDefault());
  }
}
function renderAll(){render('op',state.output.priority,'output',true);render('ou',state.output.unranked,'output',false);render('ip',state.input.priority,'input',true);render('iu',state.input.unranked,'input',false)}
document.getElementById('sc').addEventListener('click',()=>{
  webkit.messageHandlers.AutoAudioSwitcherEditor.postMessage({action:'save',outputPriority:getOrder('op'),inputPriority:getOrder('ip')});
});
document.getElementById('cc').addEventListener('click',()=>{
  webkit.messageHandlers.AutoAudioSwitcherEditor.postMessage({action:'cancel'});
});
renderAll();
</script></body></html>]]
	-- luacheck: pop
end

function obj:openEditor()
	if self._editor then
		self._editor:show()
		return
	end

	local controller = hs.webview.usercontent.new("AutoAudioSwitcherEditor")
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

	self._editor:html(self:_buildEditorHTML())
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
