-- grab.lua: pick anything visible on any Rex screen (URLs, paths, host:ports,
-- IPs, git hashes) from a floating fzf picker, and type it into the pane you
-- were in.
--
--   rex do grab.lua origin=<block id>    Ctrl+Cmd+G runs this via init.lua
--
-- Items from the pane you're in come first, then newest lines first.

local TERMINAL = "com.superlogical.terminal"
local ITEMS = "/tmp/rex-grab-items.txt"
local origin = rex.args.origin and tostring(rex.args.origin) or nil

-- pressed again while the picker is open in this tab: close it (toggle)
do
  local v = rex.session.view() or {}
  for _, w in ipairs(v.windows or {}) do
    if w.window_id == v.active_window_id then
      for _, l in ipairs(w.layers or {}) do
        for _, b in ipairs(l.blocks or {}) do
          if l.kind == "floating" and b.label == "grab" then
            rex.session.close_layer{ layer_id = l.layer_id }
            return
          end
        end
      end
    end
  end
end

local seen, items = {}, {}
local function add(tok, src)
  tok = tok:gsub("[%.,;:!%?%)%]}>'\"`]+$", "") -- trailing punctuation from prose
  if #tok >= 4 and not seen[tok] then
    seen[tok] = true
    items[#items + 1] = tok .. "\t" .. src
  end
end

-- (Rex's Lua ignores %f frontier patterns, so word edges are checked by hand)
local function edge(line, i) return i < 1 or i > #line or not line:sub(i, i):find("[%w%._%-/~]") end

local function scan(line, src)
  for url in line:gmatch("https?://[%w%-%._~:/%?#%[%]@!%$&%*%+,;=%%]+") do add(url, src) end
  for hp in line:gmatch("localhost:%d+") do add(hp, src) end
  for ip in line:gmatch("%d+%.%d+%.%d+%.%d+[:%d]*") do add(ip, src) end
  local i = 1
  while true do -- paths: something/with/slashes, optionally ~/ ./ or :line
    local s, e = line:find("[~%.]?[%w%._%-]*/[%w%._%-/]+[:%d]*", i)
    if not s then break end
    local p = line:sub(s, e)
    local pathy = p:find("^~/") or p:find("^%.%.?/") or select(2, p:gsub("/", "")) >= 2
      or p:find("%.%a%w*[:%d]*$") -- a/b.ts, src/app.ts:12
    if pathy and not p:find("^//") and edge(line, s - 1) and not line:sub(s, e + 2):find("://") and p:find("%w") then add(p, src) end
    i = e + 1
  end
  i = 1
  while true do -- git hashes: 7-40 hex chars with letters and digits, whole word
    local s, e = line:find("%x+", i)
    if not s then break end
    local h = line:sub(s, e)
    if #h >= 7 and #h <= 40 and h:find("%d") and h:find("%a") and edge(line, s - 1) and edge(line, e + 1) then add(h, src) end
    i = e + 1
  end
end

local function screenText(sessionId, block)
  local r = rex.block.call(TERMINAL, "format",
    { session_id = sessionId, block_id = block, args = { format = "text", trim = true, unwrap = true } })
  return type(r) == "table" and r.content or (type(r) == "string" and r or "")
end

-- every terminal pane in every session, the origin pane first
local panes = {}
local sessions = (rex.call("session.attach_all", { event_scope = "session" }) or {}).sessions or {}
for _, s in ipairs(sessions) do
  local v = rex.call("session.view", { session_id = s.session_id }) or {}
  for _, w in ipairs(v.windows or {}) do
    for _, l in ipairs(w.layers or {}) do
      for _, b in ipairs(l.blocks or {}) do
        if b.creator_name == TERMINAL and b.label ~= "grab" then
          local src = (s.label or "?") .. " › " .. (w.label or "?") .. (b.label and b.label ~= "shell" and (" › " .. b.label) or "")
          local p = { session = s.session_id, block = b.block_id, src = src }
          if b.block_id == origin then table.insert(panes, 1, p) else panes[#panes + 1] = p end
        end
      end
    end
  end
end

for _, p in ipairs(panes) do
  -- split by hand: gmatch with a pattern that can match "" crashes Rex's Lua
  local text, lines, i = screenText(p.session, p.block), {}, 1
  while i <= #text do
    local j = text:find("\n", i, true) or (#text + 1)
    lines[#lines + 1] = text:sub(i, j - 1)
    i = j + 1
  end
  for i = #lines, 1, -1 do scan(lines[i], p.src) end -- newest (bottom) lines first
end

local f = assert(io.open(ITEMS, "w"))
f:write(table.concat(items, "\n"), #items > 0 and "\n" or "")
f:close()
if rex.args.dry == true then -- dry=true: just list what was found
  print(#items .. " items from " .. #panes .. " panes")
  for i = 1, math.min(#items, 40) do print(items[i]) end
  return
end

-- the picker: a centered float. Rex app bug: bounds w/h size the terminal as
-- width/height but are DRAWN as right/bottom edges, so only x..w and y..h show.
-- fzf's margins keep it inside that part. Floats don't paint empty cells, so
-- fzf paints its own background.
local B = { 0.15, 0.12, 0.85, 0.88 } -- drawn: 0.15..0.85 wide, 0.12..0.88 tall
local marginR = math.ceil((1 - (B[3] - B[1]) / B[3]) * 100)
local marginB = math.ceil((1 - (B[4] - B[2]) / B[4]) * 100)
local picker = [[
if [ ! -s "$2" ]; then printf '\033[2J\033[H  nothing to grab on any screen\n'; sleep 1.5; exit 0; fi
out=$(fzf --prompt='grab ❯ ' --delimiter='\t' --tabstop=4 --layout=reverse --border=rounded \
  --margin="0,$3%,$4%,0" --expect=alt-enter --header='Enter: type into your pane · ⌥Enter: copy · Esc or ⌃⌘G: close' \
  --color='bg:#ffffff,bg+:#e6eefb,fg:#24292f,fg+:#0b3d91,hl:#cf222e,hl+:#cf222e,header:#57606a,info:#57606a,border:#8c959f,prompt:#0969da,pointer:#0969da' \
  < "$2")
key=$(printf '%s\n' "$out" | sed -n 1p)
sel=$(printf '%s\n' "$out" | sed -n 2p | cut -f1)
[ -z "$sel" ] && exit 0
if [ "$key" = alt-enter ]; then
  printf '%s' "$sel" | pbcopy
  printf '\033[2J\033[H\n  copied: %s\n' "$sel"; sleep 0.6
elif [ -n "$1" ]; then
  rex send -s "$REX_SESSION" -b "$1" "$sel"
fi
exit 0
]]
local _, err = rex.session.new_layer{
  bounds = B,
  focus  = true,
  layout = rex.layout.block{
    flavor  = TERMINAL .. ".shell",
    label   = "grab",
    options = { command = { "sh", "-c", picker, "sh", origin or "", ITEMS, tostring(marginR), tostring(marginB) } },
  },
}
if err ~= nil then error(err, 0) end
