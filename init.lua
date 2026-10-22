-- rex-addons: palette actions and shortcuts for the scripts in this repo.
-- Load it from ~/.config/rex/init.lua:
--
--   REX_ADDONS = "/path/to/rex-addons"
--   dofile(REX_ADDONS .. "/init.lua")
--
-- then run `rex config reload`.

local ROOT = REX_ADDONS or error("set REX_ADDONS before loading rex-addons/init.lua")
local HOME = ROOT:match("^(/Users/[^/]+)") or ROOT:match("^(/home/[^/]+)")
local REX = HOME .. "/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"

-- Actions run their script in the background and return at once. Creating or
-- closing panes from inside a key-bound action deadlocks the app: it waits
-- for the action while the server waits for the app (a ~50s freeze).
local function spawn(ctx, script, args)
  local cmd = '"$0" do ' .. (ctx.session_id and '-s "$1" ' or '') .. '"$2" ' .. args .. ' >/tmp/rex-addons.log 2>&1 &'
  rex.exec({ "sh", "-c", cmd, REX, ctx.session_id or "", ROOT .. "/" .. script, ctx.block_id or "" })
end

-- Aquarium: a floating fish tank. Bubbles = CPU, water = RAM, sand = disk,
-- time of day = battery.
rex.action{
  name        = "aquarium",
  title       = "Toggle Aquarium",
  description = "Float a fish tank that shows CPU, RAM, disk and battery",
  keywords    = "fish tank monitor battery cpu ram",
  run = function(ctx) spawn(ctx, "aquarium/aquarium.lua", "toggle=true") end,
}
rex.bind("ctrl+cmd+a", "aquarium")

-- Grab: pick any URL, path, host:port, IP or git hash visible on any pane in
-- any session, and type it into the pane you're in (Option+Enter copies).
rex.action{
  name        = "grab",
  title       = "Grab From Any Screen…",
  description = "Pick a URL, path, port or hash from any pane and type it here",
  keywords    = "copy paste url link path file hash commit port ip pick insert",
  run = function(ctx) spawn(ctx, "grab/grab.lua", ctx.block_id and 'origin="$3"' or "") end,
}
rex.bind("ctrl+cmd+g", "grab")

-- Unread: tabs whose panes printed new lines since you last looked get a "● "
-- prefix (needs the watcher running: `rex do unread/unread.lua`). What's New
-- lists them with just the new lines; Enter jumps to the tab.
rex.action{
  name        = "whats_new",
  title       = "What's New…",
  description = "Tabs with output you haven't seen, and just the new lines",
  keywords    = "unread new output since activity changed",
  run = function(ctx) spawn(ctx, "unread/unread.lua", "show=true") end,
}
rex.bind("ctrl+cmd+u", "whats_new")
