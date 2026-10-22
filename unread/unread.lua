-- unread.lua: "unread" output for terminals. A tab whose panes printed new
-- lines since you last looked gets a "● " prefix on its label, and
-- What's New… (Ctrl+Cmd+U) lists those tabs with just the new lines.
--
--   rex do unread.lua              the watcher (keep it running)
--   rex do unread.lua show=true    the What's New picker (Ctrl+Cmd+U)
--   rex do unread.lua clear=true   remove every ● mark and exit
--
-- "Seen" = the pane is in its session's active tab. Only the visible screen
-- is compared (no scrollback), and digits and spinner glyphs are ignored so
-- clocks and "Thinking… 3s" lines don't count as new output.

local TERMINAL = "com.superlogical.terminal"
local DIR = "/tmp/rex-unread"
local MARK = "● "

local function sessions()
  return (rex.call("session.attach_all", { event_scope = "session" }) or {}).sessions or {}
end

local function unmark(label) return label:sub(1, #MARK) == MARK and label:sub(#MARK + 1) or label end

local function setLabel(sid, wid, label)
  rex.call("session.set_window_label", { session_id = sid, window_id = wid, label = label })
end

-- clear=true: strip every mark and exit
if rex.args.clear == true then
  for _, s in ipairs(sessions()) do
    local v = rex.call("session.view", { session_id = s.session_id }) or {}
    for _, w in ipairs(v.windows or {}) do
      if w.label and unmark(w.label) ~= w.label then setLabel(s.session_id, w.window_id, unmark(w.label)) end
    end
  end
  print("unread: cleared")
  return
end

-- show=true: the What's New picker, as a centered float (see grab/grab.lua
-- for why it's centered and why fzf gets margins)
if rex.args.show == true then
  local v = rex.session.view() or {}
  for _, w in ipairs(v.windows or {}) do -- pressed again while open: close it
    if w.window_id == v.active_window_id then
      for _, l in ipairs(w.layers or {}) do
        for _, b in ipairs(l.blocks or {}) do
          if l.kind == "floating" and b.label == "whats-new" then
            rex.session.close_layer{ layer_id = l.layer_id }
            return
          end
        end
      end
    end
  end
  local B = { 0.12, 0.1, 0.88, 0.9 }
  local mR = math.ceil((1 - (B[3] - B[1]) / B[3]) * 100)
  local mB = math.ceil((1 - (B[4] - B[2]) / B[4]) * 100)
  local picker = [[
if [ ! -s "$1/index.tsv" ]; then printf '\033[2J\033[H  nothing new anywhere\n'; sleep 1.2; exit 0; fi
sel=$(fzf --prompt='new ❯ ' --delimiter='\t' --with-nth=3,5 --layout=reverse --border=rounded \
  --margin="0,$2%,$3%,0" --header='Enter: go to that tab · Esc or ⌃⌘U: close' \
  --preview="cat $1/{4}.txt" --preview-window=down,65%,wrap \
  --color='bg:#ffffff,bg+:#e6eefb,fg:#24292f,fg+:#0b3d91,hl:#cf222e,hl+:#cf222e,header:#57606a,info:#57606a,border:#8c959f,prompt:#0969da,pointer:#0969da,preview-bg:#f6f8fa' \
  < "$1/index.tsv")
[ -z "$sel" ] && exit 0
s=$(printf '%s' "$sel" | cut -f1); w=$(printf '%s' "$sel" | cut -f2)
rex api call -s "$s" session.focus_window "{\"window_id\":\"$w\"}" >/dev/null
for c in $(rex client ls | awk '/ app /{print $NF}'); do rex -C "$c" do session.select session_id="$s" window_id="$w" >/dev/null 2>&1; done
exit 0
]]
  local _, err = rex.session.new_layer{
    bounds = B,
    focus  = true,
    layout = rex.layout.block{
      flavor  = TERMINAL .. ".shell",
      label   = "whats-new",
      options = { command = { "sh", "-c", picker, "sh", DIR, tostring(mR), tostring(mB) } },
    },
  }
  if err ~= nil then error(err, 0) end
  return
end

-- the watcher --------------------------------------------------------------

rex.exec({ "mkdir", "-p", DIR })

local function norm(line)
  line = line:gsub("%s+$", "")
  line = line:gsub("%d", "#")
  line = line:gsub("[\226][\160-\163][\128-\191]", "") -- braille spinners (U+2800-28FF)
  line = line:gsub("[|/\\%-]%s*$", "")                  -- ascii spinner at line end
  return line
end

local function screenLines(sid, block)
  local r = rex.block.call(TERMINAL, "format",
    { session_id = sid, block_id = block, args = { format = "text", trim = true, unwrap = true } })
  local text = type(r) == "table" and r.content or ""
  local lines, i = {}, 1
  while i <= #text do -- split by hand: gmatch on "" matches crashes Rex's Lua
    local j = text:find("\n", i, true) or (#text + 1)
    lines[#lines + 1] = text:sub(i, j - 1)
    i = j + 1
  end
  return lines
end

-- lines on screen now that weren't there when last seen (multiset, in order)
local function newLines(seen, now)
  local have = {}
  for _, l in ipairs(seen) do local n = norm(l); have[n] = (have[n] or 0) + 1 end
  local out = {}
  for _, l in ipairs(now) do
    local n = norm(l)
    if (have[n] or 0) > 0 then have[n] = have[n] - 1
    elseif n:find("%S") then out[#out + 1] = l end
  end
  return out
end

local function write(path, text)
  local f = io.open(path, "w")
  if f then f:write(text); f:close() end
end

local seen = {} -- block id -> screen lines when last seen

local function tick()
  local index = {}
  for _, s in ipairs(sessions()) do
    local v = rex.call("session.view", { session_id = s.session_id }) or {}
    for _, w in ipairs(v.windows or {}) do
      local active = w.window_id == v.active_window_id
      local count, report = 0, {}
      for _, l in ipairs(w.layers or {}) do
        if l.kind ~= "floating" then
          for _, b in ipairs(l.blocks or {}) do
            if b.creator_name == TERMINAL then
              local now = screenLines(s.session_id, b.block_id)
              if active or not seen[b.block_id] then
                seen[b.block_id] = now
              else
                local new = newLines(seen[b.block_id], now)
                if #new > 0 then
                  count = count + #new
                  report[#report + 1] = "── " .. (b.label or "pane") .. " ──\n" .. table.concat(new, "\n")
                end
              end
            end
          end
        end
      end
      local base = unmark(w.label or "")
      local want = count > 0 and (MARK .. base) or base
      if want ~= (w.label or "") then setLabel(s.session_id, w.window_id, want) end
      if count > 0 then
        local id = w.window_id:gsub("%W", "_")
        write(DIR .. "/" .. id .. ".txt", table.concat(report, "\n\n") .. "\n")
        index[#index + 1] = table.concat({ s.session_id, w.window_id, (s.label or "?") .. " › " .. base, id, count .. " new" }, "\t")
      end
    end
  end
  write(DIR .. "/index.tsv", #index > 0 and (table.concat(index, "\n") .. "\n") or "")
end

print("unread: watching every pane. Ctrl-C to stop (then `rex do unread.lua clear=true`).")
tick()
rex.every(2, tick)
