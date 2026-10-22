-- mood.lua: mood lighting for Rex panes. Each terminal's background tints
-- with its state, so you can read every pane at a glance:
--   * red, fading over ~45s   the last command failed (needs rex-mood.fish)
--   * slowly darker           nothing on screen has changed for a while
--
--   rex do mood.lua                 run it (Ctrl-C to stop)
--   rex do mood.lua reset=true      clear every tint and exit
--
-- Flags:  base=ffffff   your theme's background (tints are mixed into it)
--         fade=45       seconds for a failure tint to fade out
--         idle=120      seconds without screen changes before dimming starts

local TERMINAL = "com.superlogical.terminal"
local base = tostring(rex.args.base or "ffffff"):gsub("^#", "")
local fadeSecs = tonumber(rex.args.fade) or 45
local idleAfter = tonumber(rex.args.idle) or 120
local IDLE_FULL = 600   -- seconds after idleAfter to reach full dimness
local RED = { 255, 70, 70 }
local FAIL_MIX, IDLE_MIX = 0.22, 0.12

local BASE = { tonumber(base:sub(1, 2), 16), tonumber(base:sub(3, 4), 16), tonumber(base:sub(5, 6), 16) }

local function terminals()
  local out = {}
  local v = rex.session.view() or {}
  for _, w in ipairs(v.windows or {}) do
    for _, l in ipairs(w.layers or {}) do
      for _, b in ipairs(l.blocks or {}) do
        if b.creator_name == TERMINAL then out[#out + 1] = b.block_id end
      end
    end
  end
  return out
end

local function setBg(block, hex)
  rex.block.call(TERMINAL, "set_theme", { block_id = block, background = hex })
end

if rex.args.reset == true then
  for _, b in ipairs(terminals()) do setBg(b, "") end
  print("mood: cleared")
  return
end

local function mix(a, b, t)
  return { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t }
end

-- the last command's exit code and time, written by rex-mood.fish
local function lastCommand(block)
  local f = io.open("/tmp/rex-mood/" .. block:gsub(":", "_"))
  if not f then return nil end
  local code, at = (f:read("*l") or ""):match("^(%d+) (%d+)")
  f:close()
  return tonumber(code), tonumber(at)
end

local screens, changedAt, applied = {}, {}, {}

local function tick()
  local now = os.time()
  for _, b in ipairs(terminals()) do
    -- idle = how long since the screen last changed (Rex has no output event)
    local text = rex.block.call(TERMINAL, "format", { block_id = b, args = { format = "text", trim = true } })
    text = type(text) == "table" and text.content or tostring(text)
    if text ~= screens[b] then screens[b], changedAt[b] = text, now end

    local code, at = lastCommand(b)
    local fail = (code and code ~= 0 and at) and math.max(0, 1 - (now - at) / fadeSecs) or 0
    local idle = math.min(math.max((now - changedAt[b] - idleAfter) / IDLE_FULL, 0), 1)

    local hex = "" -- neutral: Rex's own background
    if fail > 0 or idle > 0 then
      local c = mix(BASE, RED, FAIL_MIX * fail)
      c = mix(c, { 0, 0, 0 }, IDLE_MIX * idle)
      hex = string.format("%02x%02x%02x", math.floor(c[1] + 0.5), math.floor(c[2] + 0.5), math.floor(c[3] + 0.5))
    end
    if hex ~= applied[b] then
      setBg(b, hex)
      applied[b] = hex
    end
  end
end

print("mood: watching panes in this session. Ctrl-C to stop (then `rex do mood.lua reset=true`).")
tick()
rex.every(2, tick)
