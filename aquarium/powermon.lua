-- powermon.lua — an ambient power & resource monitor that lives in a Rex tab.
--
--   rex do powermon.lua                     (from inside a Rex terminal)
--   rex do -s <session> powermon.lua        (from anywhere)
--
-- Creates a window whose pane renders a live dashboard: battery, battery
-- health, memory, CPU, disk. It is battery-friendly on purpose:
--   * one shell fork per tick (all data collected in a single exec)
--   * polling slows down when the session is idle (no layout changes,
--     no keystrokes) and speeds back up the moment you do anything
--   * the tab label only updates when its text actually changes, so a
--     quiet machine produces zero layout churn
--
-- When the battery drops below the threshold (default 20%) while on
-- battery power, it emits an OSC 7501 "blocked" record, so Rex's own
-- indicators (tab icons, session picker) flag it, and posts one macOS
-- notification. Recovering clears the record. Close the tab and the
-- monitor shuts itself down.
--
-- Flags:  interval=5   seconds between updates while the session is active
--         idle=25      seconds between updates while idle
--         low=20       battery % that counts as "low"
--         test=true    print one reading as JSON and exit (no window)

local TERMINAL = "com.superlogical.terminal"

local interval = tonumber(rex.args.interval) or 5
local idleInterval = tonumber(rex.args.idle) or 25
local lowAt = tonumber(rex.args.low) or 20

------------------------------------------------------------------ helpers --

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local floor = math.floor

-- Base64 without padding (OSC 7501 says padding is optional).
local function b64(s)
  local out = {}
  local i = 1
  while i <= #s do
    local a, b, c = s:byte(i, i + 2)
    local n = a * 65536 + (b or 0) * 256 + (c or 0)
    local chars = {
      B64:sub(floor(n / 262144) % 64 + 1, floor(n / 262144) % 64 + 1),
      B64:sub(floor(n / 4096) % 64 + 1, floor(n / 4096) % 64 + 1),
      B64:sub(floor(n / 64) % 64 + 1, floor(n / 64) % 64 + 1),
      B64:sub(n % 64 + 1, n % 64 + 1),
    }
    local rem = #s - i + 1
    out[#out + 1] = table.concat(chars, "", 1, rem == 1 and 2 or rem == 2 and 3 or 4)
    i = i + 3
  end
  return table.concat(out)
end

local function C(code) return "\27[" .. code .. "m" end
local GREEN, YELLOW, RED = C("32"), C("33"), C("31")
local DIM, BOLD, RESET = C("2"), C("1"), C("0")

local function sev(pct, good, ok)
  if pct <= good then return GREEN end
  if pct <= ok then return YELLOW end
  return RED
end

local function bar(pct, width, color)
  local fill = floor(pct / 100 * width + 0.5)
  if fill < 0 then fill = 0 end
  if fill > width then fill = width end
  return color .. string.rep("█", fill) .. DIM .. string.rep("░", width - fill) .. RESET
end

------------------------------------------------------------------- collect --

local COLLECT = table.concat({
  "echo @PM@; pmset -g batt",
  "echo @SYS@; sysctl -n hw.ncpu hw.memsize",
  "echo @VM@; vm_stat",
  "echo @DF@; df -k /",
  "echo @PS@; ps -Aro pcpu=,comm=",
}, "; ")

local function sections(text)
  local marks, found = {}, {}
  local i = 1
  while true do
    local s, e = text:find("@%u+@", i)
    if not s then break end
    marks[#marks + 1] = { name = text:sub(s + 1, e - 1), body = e + 1 }
    i = e + 1
  end
  for idx, m in ipairs(marks) do
    local last = idx < #marks and marks[idx + 1].body - 5 or #text + 1
    found[m.name] = text:sub(m.body, last)
  end
  return found
end

local function batteryHealth()
  local r = rex.exec({ "ioreg", "-rn", "AppleSmartBattery" })
  if not r or not r.ok then return nil end
  local out = r.stdout
  return {
    cycles = tonumber(out:match('"CycleCount"%s*=%s*(%d+)')),
    max = tonumber(out:match('"AppleRawMaxCapacity"%s*=%s*(%d+)')),
    design = tonumber(out:match('"DesignCapacity"%s*=%s*(%d+)')),
  }
end

local function collect()
  local r = rex.exec({ "sh", "-c", COLLECT }, { timeout = 10 })
  if not r or not r.ok then return nil end
  local s = sections(r.stdout)
  local d = {}

  -- battery:  " -InternalBattery-0 (id=...)  39%; discharging; 1:46 remaining"
  local pm = s.PM or ""
  d.source = pm:match("drawing from '([%w%s]+)'")
  local pct, state = pm:match("(%d+)%%;%s*([%a%s]+);")
  if pct then
    d.bat = {
      pct = tonumber(pct),
      state = (state:gsub("%s+", " ")):gsub("^%s", ""):gsub("%s$", ""),
      time = pm:match("%%;%s*[%a%s]+;%s*(%d+:%d+)"),
    }
  end

  -- cores & ram total
  local nums = {}
  for n in (s.SYS or ""):gmatch("%d+") do nums[#nums + 1] = tonumber(n) end
  d.cores = nums[1]
  local total = nums[2]

  -- memory: used = active + wired + compressor (Apple's "Memory Used" recipe)
  local vm = s.VM or ""
  local page = tonumber(vm:match("page size of (%d+)"))
  local function pages(label) return tonumber(vm:match(label .. ":%s+(%d+)")) or 0 end
  if page and total then
    local used = (pages("Pages active") + pages("Pages wired down")
      + pages("Pages occupied by compressor")) * page
    d.mem = { used = used, total = total, pct = used / total * 100 }
  end

  -- disk: capacity % from the last df line
  local cap
  for line in (s.DF or ""):gmatch("[^\n]+") do
    cap = line:match("(%d+)%%")
  end
  d.disk = cap and tonumber(cap) or nil

  -- cpu: sum of ps %cpu across processes (100 = one core), plus top process
  local ps = s.PS or ""
  local sum, first = 0, true
  for line in ps:gmatch("[^\n]+") do
    local c = line:match("^%s*([%d%.]+)")
    if c then
      sum = sum + tonumber(c)
      if first then
        first = false
        local name = line:match("^%s*[%d%.]+%s+(.+)$")
        d.top = { cpu = tonumber(c), name = name and name:match("[^/]+$") or "?" }
      end
    end
  end
  if d.cores then d.cpu = math.min(sum / d.cores, 100) end

  return d
end

------------------------------------------------------------------ display --

local display -- the block that shows the dashboard
local writeKey

local function termWrite(data)
  local r, err = rex.block.call(TERMINAL, "write", { block_id = display, [writeKey] = data })
  if err then error(err, 0) end
end

local health -- battery health, read once at startup

local function render(d)
  local W = 16
  local L = {}

  local function row(label, body) L[#L + 1] = BOLD .. label .. RESET .. "  " .. body end

  if d.bat then
    local onAC = d.source and d.source:find("AC") ~= nil
    local charging = onAC and d.bat.state ~= "charged"
    local color = onAC and GREEN or sev(d.bat.pct, 40, lowAt)
    local time = (not onAC and d.bat.time) and (" · " .. d.bat.time .. " left") or ""
    local stateTxt = charging and "charging" or (onAC and "on AC" or d.bat.state)
    row("BATTERY", color .. string.format("%3d%% ", d.bat.pct) .. bar(d.bat.pct, W, color)
      .. RESET .. "  " .. DIM .. stateTxt .. time .. RESET)
    if health and health.max and health.design then
      local h = floor(health.max / health.design * 100 + 0.5)
      row("HEALTH", DIM .. h .. "% capacity · " .. (health.cycles or "?") .. " cycles" .. RESET)
    end
  else
    row("BATTERY", DIM .. "not found" .. RESET)
  end

  if d.mem then
    local gb = 1024 * 1024 * 1024
    local color = sev(d.mem.pct, 60, 85)
    row("MEMORY", color .. string.format("%3d%% ", d.mem.pct) .. bar(d.mem.pct, W, color)
      .. RESET .. "  " .. DIM .. string.format("%.1f / %.1f GB", d.mem.used / gb, d.mem.total / gb) .. RESET)
  end

  if d.cpu then
    local color = sev(d.cpu, 50, 85)
    row("CPU", color .. string.format("%3d%% ", d.cpu) .. bar(d.cpu, W, color)
      .. RESET .. "  " .. DIM .. string.format("%d cores · top %s %d%%",
        d.cores or 0, d.top and d.top.name or "?", d.top and d.top.cpu or 0) .. RESET)
  end

  if d.disk then
    local color = sev(d.disk, 75, 90)
    row("DISK", color .. string.format("%3d%% ", d.disk) .. bar(d.disk, W, color) .. RESET)
  end

  return "\27[?25l\27[H\27[2J" .. table.concat(L, "\n") .. "\n"
end

local lastLabel
local function updateLabel(d)
  local text
  if d.bat then
    local onAC = d.source and d.source:find("AC") ~= nil
    local low = not onAC and d.bat.pct <= lowAt
    text = (low and "LOW " or "BAT ") .. d.bat.pct .. "%"
      .. (not onAC and d.bat.time and (" " .. d.bat.time) or (onAC and " AC" or ""))
  else
    text = "BAT ?"
  end
  if text ~= lastLabel then
    lastLabel = text
    rex.session.set_block_label{ block_id = display, label = text }
  end
end

------------------------------------------------------------------- status --

local lowActive = false
local function updateStatus(d)
  if not d.bat then return end
  local onAC = d.source and d.source:find("AC") ~= nil
  local should = not onAC and d.bat.pct <= lowAt
  if should == lowActive then return end
  lowActive = should
  if should then
    local msg = b64("Battery low: " .. d.bat.pct .. "% — plug in")
    termWrite("\27]7501;state=blocked:kind=auth:app=powermon:msg=" .. msg .. "\27\\")
    rex.exec({ "osascript", "-e",
      'display notification "Battery at ' .. d.bat.pct .. '% — plug in" with title "powermon"' })
  else
    termWrite("\27]7501;state=clear\27\\")
    rex.exec({ "osascript", "-e", 'display notification "Battery recovered" with title "powermon"' })
  end
end

--------------------------------------------------------------------- main --

if rex.args.test then
  local d = collect()
  health = batteryHealth()
  local frame = d and render(d) or ""
  return {
    data = d,
    health = health,
    frame = (frame:gsub("\27%[[%d;]*m", "")),
  }
end

-- create the window that hosts the dashboard
local win, err = rex.session.new_window{
  window_label = "powermon",
  focus = false,
  layout = rex.layout.block{
    flavor  = TERMINAL .. ".shell",
    options = {
      command = { "sh", "-c", "stty -echo; exec cat" },
      shell   = "none",
      exit    = { on_completion = false },
    },
  },
}
if err ~= nil then error(err, 0) end
display = win.block_ids and win.block_ids[1]
if not display then error("could not create the display pane", 0) end

rex.block.call(TERMINAL, "reset", { block_id = display })

-- discover which argument name terminal.write accepts (defensive)
for _, key in ipairs({ "data", "bytes", "text" }) do
  local ok = rex.block.call(TERMINAL, "write", { block_id = display, [key] = " " })
  if ok then writeKey = key break end
end
if not writeKey then error("terminal.write rejected all known argument names", 0) end

health = batteryHealth()

-- activity tracking: any layout change or keystroke marks the session active
local lastActivity = os.time()
rex.on("session_view_changed", function() lastActivity = os.time() end)
rex.on("block_event", function() lastActivity = os.time() end)
rex.on("block_closed", function(_, ev)
  if ev.block_id == display then rex.stop(0) end
end)

local function tick()
  local d = collect()
  if d then
    termWrite(render(d))
    updateLabel(d)
    updateStatus(d)
  end
  local idle = os.time() - lastActivity >= idleInterval
  rex.after(idle and idleInterval or interval, tick)
end

print("powermon: watching in a new window; close the tab to stop")
tick()
