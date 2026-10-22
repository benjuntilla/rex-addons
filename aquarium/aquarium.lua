-- aquarium.lua — a whimsical pixel-art resource monitor for Rex.
--
--   rex do aquarium.lua                      (from inside a Rex terminal)
--   rex do -s <session> aquarium.lua         (from anywhere)
--
-- A little tank that reflects your MacBook's insides:
--   * bubble column = CPU load. The air stone trickles when idle and roars
--                    in a wide column when the CPU is busy
--   * water level  = memory usage (the tank literally fills up)
--   * sand depth   = disk usage (storage piles up on the tank floor)
--   * time of day  = battery. Full is bright day; it turns golden, then
--                    sunset, then night as it drains. Sun rays = charging.
--   * low battery  = OSC 7501 flag + macOS notification at the low threshold
--   * a jellyfish  = drifts in while memory is above 80%
--
-- Rendered with half-block pixels: each character cell is two vertical
-- pixels with 24-bit color. One shell fork per data sample; animation
-- ticks never fork.
--
-- Flags:  anim=0.13   seconds between animation frames (active), about 7.7 fps
--         data=2.5    seconds between data samples
--         idle=45     idle seconds before the animation slows
--         low=20      battery % that counts as low
--         fish=N      how many fish (default: 3-7, scaled to the tank)
--         toggle=true float the tank over the active tab, or close it (Ctrl+Cmd+A)
--         debug=true  print the scene as plain text and exit
--         shot=/path  (debug) also dump one ANSI frame; see ansi2png.py
--         cpu= mem= bat= ac= disk= left= ticks=   (debug) fake readings to preview states

local TERMINAL = "com.superlogical.terminal"

local animInterval = tonumber(rex.args.anim) or 0.13
local BASE_STEP = 0.35 -- motion constants below were tuned for one step per 0.35s
local dataInterval = tonumber(rex.args.data) or 2.5
local idleAfter = tonumber(rex.args.idle) or 45
local lowAt = tonumber(rex.args.low) or 20
local fishArg = tonumber(rex.args.fish) -- default: scales with the tank (3 to 6)
local fishCount

local floor = math.floor
local display -- our terminal block

------------------------------------------------------------------ palette --

local PAL = {
  o = {255, 145, 60},  -- fish orange
  d = {200, 95, 30},   -- dark orange (tail, shade)
  t = {80, 200, 200},  -- teal fish
  T = {45, 145, 145},  -- dark teal
  p = {250, 120, 165}, -- pink fish
  y = {255, 205, 80},  -- sun / stars / yellow fish
  g = {70, 185, 95},   -- seaweed
  G = {40, 130, 60},   -- dark seaweed
  b = {35, 25, 25},    -- eye / outline
  w = {240, 245, 255}, -- white (bubbles, zzz)
  r = {255, 90, 90},   -- alarm red
  s = {225, 185, 120}, -- sand
  S = {180, 140, 80},  -- pebbles
  j = {225, 140, 235}, -- jellyfish bell
  J = {255, 215, 255}, -- jellyfish spots
  q = {190, 150, 230}, -- jellyfish tentacles
}

-- every color gets a unique id so the encoder can compare cheaply
-- interned by rgb, so per-frame gradients reuse ids and escapeMemo stays bounded
local colorSeq, colorCache = 0, {}
local function mkColor(r, g, b)
  -- +0.5: Rex's (Go) Lua turns a big whole-number key into array slots,
  -- growing the table to millions of entries (~1s and lots of memory)
  local key = r * 65536 + g * 256 + b + 0.5
  local c = colorCache[key]
  if not c then
    colorSeq = colorSeq + 1
    c = { r, g, b, id = colorSeq }
    colorCache[key] = c
  end
  return c
end

for _, c in pairs(PAL) do
  colorSeq = colorSeq + 1
  c.id = colorSeq
end

local function palette(t)
  local p = {}
  for ch, c in pairs(t) do p[ch] = mkColor(c[1], c[2], c[3]) end
  return p
end
local function dk(c, k) return { floor(c[1] * k), floor(c[2] * k), floor(c[3] * k) } end
local function lt(c, k)
  return { floor(c[1] + (255 - c[1]) * k), floor(c[2] + (255 - c[2]) * k), floor(c[3] + (255 - c[3]) * k) }
end

-- one fish shape (facing right), two tail frames; species are palettes.
-- O outline, h/o/d highlight/body/belly, x/X/z stripe on those rows,
-- f/F fins, e eye, b pupil + mouth
local FISH = {
  { "....OOOO...", "O..OhxhhhO.", "OfOhhxhhebO", "OfOooXooobO", "O..OdzddOO.", "....OFO...." },
  { "....OOOO...", "...OhxhhhO.", "OOOhhxhhebO", "OfOooXooobO", "OOOOdzddOO.", ".....OFO..." },
}
local FISH_W, FISH_H = 11, 6

local function species(o, stripe, fin)
  fin = fin or o
  local p = { O = dk(o, .35), o = o, h = lt(o, .35), d = dk(o, .8), f = fin, F = dk(fin, .7),
    e = { 250, 250, 255 }, b = { 20, 20, 30 } }
  if stripe then p.x, p.X, p.z = stripe, stripe, dk(stripe, .85)
  else p.x, p.X, p.z = p.h, p.o, p.d end
  return palette(p)
end

local SPECIES = {
  species({ 255, 130, 40 }, { 250, 250, 250 }),        -- clownfish
  species({ 70, 195, 200 }, { 255, 210, 80 }),         -- teal
  species({ 245, 120, 165 }),                          -- pink
  species({ 255, 205, 60 }, nil, { 90, 140, 250 }),    -- yellow tang
  species({ 70, 110, 235 }, { 255, 215, 70 }, { 30, 40, 90 }), -- blue tang
  species({ 150, 95, 220 }, { 255, 160, 70 }),         -- royal purple
}

local SUN_DISC = { "..YYY..", ".YWWYY.", "YWWYYYY", "YWYYYYY", "YYYYYYO", ".YYYYO.", "..YOO.." }
local SUN_PAL = palette{ Y = { 255, 220, 90 }, W = { 255, 250, 215 }, O = { 245, 165, 50 }, y = { 255, 200, 70 } }
local SUN_DUSK = palette{ Y = { 255, 150, 70 }, W = { 255, 215, 160 }, O = { 225, 95, 50 } }
local SUN_RAYS = { -- drawn around the disc while charging
  { ".....y.....", ".....y.....", "...........", "...........", "...........", "yy.......yy",
    "...........", "...........", "...........", ".....y.....", ".....y....." },
  { "y.........y", ".y.......y.", "...........", "...........", "...........", "...........",
    "...........", "...........", "...........", ".y.......y.", "y.........y" },
}
local MOON = { "...MMMM..", ".MMWW....", "MMWW.....", "MMW......", "MMW......", "MMW......",
  "MMWW.....", ".MMWW....", "...MMMM.." }
local MOON_PAL = palette{ M = { 215, 215, 235 }, W = { 250, 250, 255 } }
local STONE = { ".OOO.", "OoooO" }
local STONE_PAL = palette{ O = { 85, 90, 105 }, o = { 150, 155, 170 } }

local JELLY = {
  { "..jjj..", ".jJjjj.", "jjjjJjj", "jjjjjjj", "q.q.q.q", ".q.q.q.", "q.q.q.q" },
  { "..jjj..", ".jJjjj.", "jjjjJjj", "jjjjjjj", ".q.q.q.", "q.q.q.q", ".q...q." },
}

------------------------------------------------------------------ canvas --

local SAND_H = 4 -- grows with disk usage (set in sceneTick)

local W, H -- canvas size in pixels (W cells wide, H = 2 * cell rows tall)

local pix -- flat array, pix[(y-1)*W + x] = {r,g,b} or nil
local sandTex -- precomputed pebble pattern for the sea floor

local prev -- what is on screen now; nil forces a full redraw
local moveMemo = {} -- cell index -> cursor-move escape

local function canvasResize(cols, rows)
  W, H = cols, rows * 2
  prev, moveMemo = nil, {}
  dlist, dmark, lastList, erased, fullFrame = {}, {}, {}, {}, true
  pix = {}
  sandTex = {}
  for i = 1, W * H do
    if math.random() < 0.06 then sandTex[i] = true end
  end
end

-- Only what changes gets re-encoded. Every pixel drawn this frame is listed
-- in dlist, with its color from before the draw in dmark. Last frame's pixels
-- that weren't drawn again get the background back (erased). Only pixels
-- whose color actually changed are re-encoded, so still scenery (kelp, sun,
-- stone) costs nothing. Rex's Lua runs on Go and allocates on most number
-- ops, so touching fewer pixels is what saves CPU.
local dlist, dmark, lastList, erased, lastLabelCells = {}, {}, {}, {}, {}
local fullFrame = true -- repaint and re-encode everything this frame
local function touch(i)
  if dmark[i] == nil then dmark[i] = pix[i] or false; dlist[#dlist + 1] = i end
end

local clipY -- while set, pixels at or below this row are skipped (sun setting)
local function px(x, y, c)
  if x >= 1 and x <= W and y >= 1 and y <= H and not (clipY and y >= clipY) then
    local i = (y - 1) * W + x
    touch(i)
    pix[i] = c
  end
end

-- sprites are turned into pixel lists once per (sprite, palette, flip), so
-- drawing one doesn't re-read its strings every frame
local compiled = {}
local function compile(spr, pal, flip)
  local byPal = compiled[spr]
  if not byPal then byPal = {}; compiled[spr] = byPal end
  local byFlip = byPal[pal]
  if not byFlip then byFlip = {}; byPal[pal] = byFlip end
  local k = flip and 2 or 1
  local list = byFlip[k]
  if not list then
    list = { xs = {}, ys = {}, cs = {} }
    for row = 1, #spr do
      local line = spr[row]
      for i = 1, #line do
        local c = pal[line:sub(i, i)]
        if c then
          local n = #list.xs + 1
          list.xs[n], list.ys[n], list.cs[n] = flip and (#line - i) or (i - 1), row - 1, c
        end
      end
    end
    byFlip[k] = list
  end
  return list
end

local function blit(spr, pal, x0, y0, flip)
  local l = compile(spr, pal, flip)
  local xs, ys, cs = l.xs, l.ys, l.cs
  for n = 1, #xs do px(x0 + xs[n], y0 + ys[n], cs[n]) end
end

local function lerp(a, b, t)
  return floor(a + (b - a) * t + 0.5)
end

-- quantized to 24 steps so gradients reuse a small set of colors
local function lerpC(c1, c2, t)
  t = floor(t * 24 + 0.5) / 24
  if t < 0 then t = 0 elseif t > 1 then t = 1 end
  return mkColor(lerp(c1[1], c2[1], t), lerp(c1[2], c2[2], t), lerp(c1[3], c2[3], t))
end

local FOAM = mkColor(190, 220, 255)

local labels -- text drawn over the canvas: labels[cellRow] = { {col, text}, ... }
local function addLabel(x, y, text) -- x, y in pixels; y picks the cell row
  local row = floor((y + 1) / 2)
  if row < 1 or row > H / 2 then return end
  text = " " .. text .. " " -- a cell of padding: the backing reads as a band
  x = x - 1
  local len = select(2, text:gsub("[^\128-\191]", "")) -- characters, not bytes
  x = math.max(1, math.min(x, W - len + 1))
  labels[row] = labels[row] or {}
  table.insert(labels[row], { x, text })
end
-- labels: white text on a band that's a darker shade of what's behind it
local INK = mkColor(245, 248, 255)
local plateMemo = {}
local function plate(bg)
  local p = plateMemo[bg.id]
  if not p then
    p = mkColor(floor(bg[1] * 0.5), floor(bg[2] * 0.5), floor(bg[3] * 0.5))
    plateMemo[bg.id] = p
  end
  return p
end

-- half-block encoder: one cell = two vertical pixels
local escapeMemo = {}
local function escape(kind, c)
  local key = kind .. c.id
  local s = escapeMemo[key]
  if not s then
    s = "\27[" .. kind .. "2;" .. c[1] .. ";" .. c[2] .. ";" .. c[3] .. "m"
    escapeMemo[key] = s
  end
  return s
end

-- diff=true: emit only cells that changed since the last frame, using cursor
-- moves (most of the tank is static, so this sends a fraction of the bytes).
-- diff=nil: a full newline-separated frame (debug shots, ansi2png.py).
local function encode(diff)
  local out = {}
  if diff and not prev then prev = {}; out[1] = "\27[0m\27[2J" end
  local fg, bg = 0, 0 -- 0 = terminal default
  if diff and prev and not fullFrame then
    -- sparse: only the cells holding a pixel that changed, plus label cells
    local cells, seen, chsRow = {}, {}, {}
    local function add(p)
      local y = floor((p - 1) / W) + 1
      local c = floor((y - 1) / 2) * W + (p - (y - 1) * W)
      if not seen[c] then seen[c] = true; cells[#cells + 1] = c end
    end
    for _, p in ipairs(dlist) do if pix[p] ~= dmark[p] then add(p) end end -- drawn in a new color
    for _, p in ipairs(erased) do add(p) end                                -- uncovered
    table.sort(cells) -- left to right, top to bottom: fewer cursor moves
    local labelCells = {}
    for row, ls in pairs(labels or {}) do
      local chs = {}
      for _, l in ipairs(ls) do
        local j = 0
        for ch in l[2]:gmatch("[\1-\127\194-\244][\128-\191]*") do
          chs[l[1] + j] = ch
          labelCells[#labelCells + 1] = (row - 1) * W + l[1] + j
          j = j + 1
        end
      end
      chsRow[row] = chs
    end
    -- this frame's label cells, and last frame's (a label that moved or got
    -- shorter must give its old cells back)
    for _, list in ipairs({ labelCells, lastLabelCells }) do
      for _, c in ipairs(list) do
        if not seen[c] then seen[c] = true; cells[#cells + 1] = c end
      end
    end
    lastLabelCells = labelCells
    local line, cur = {}, nil
    for n, c in ipairs(cells) do
      local row = floor((c - 1) / W) + 1
      local cx = c - (row - 1) * W
      local top, bot = pix[(2 * row - 2) * W + cx], pix[(2 * row - 1) * W + cx]
      local ch = chsRow[row] and chsRow[row][cx]
      local key = ch and -((#ch * 256 + ch:byte(-1)) * 1e6 + bot.id) or top.id * 1e6 + bot.id
      if prev[c] ~= key then
        prev[c] = key
        if cur ~= c then
          local mv = moveMemo[c]
          if not mv then mv = "\27[" .. row .. ";" .. cx .. "H"; moveMemo[c] = mv end
          line[#line + 1] = mv
        end
        cur = cx < W and c + 1 or nil -- don't count on wrapping: the tank may be narrower than the pane
        if ch then
          local back = plate(bot)
          if fg ~= INK.id then line[#line + 1] = escape("38;", INK); fg = INK.id end
          if bg ~= back.id then line[#line + 1] = escape("48;", back); bg = back.id end
          line[#line + 1] = ch
        elseif top.id == bot.id then
          if bg ~= top.id then line[#line + 1] = escape("48;", top); bg = top.id end
          line[#line + 1] = " "
        else
          if fg ~= top.id then line[#line + 1] = escape("38;", top); fg = top.id end
          if bg ~= bot.id then line[#line + 1] = escape("48;", bot); bg = bot.id end
          line[#line + 1] = "▀"
        end
      end
      if #line > 400 then out[#out + 1] = table.concat(line); line = {} end -- registry limit
    end
    out[#out + 1] = table.concat(line)
    out[#out + 1] = "\27[0m"
    lastList, dlist, dmark = dlist, {}, {}
    return table.concat(out)
  end
  for cy = 1, H, 2 do
    local row = (cy + 1) / 2
    local chs -- column -> label character on this row
    local c0, c1 = 1, W
    if labels and labels[row] then
      chs = {}
      for _, l in ipairs(labels[row]) do
        local j = 0 -- one UTF-8 character per cell
        for c in l[2]:gmatch("[\1-\127\194-\244][\128-\191]*") do chs[l[1] + j] = c; j = j + 1 end
      end
    end
    local rowBase = (row - 1) * W
    local cur -- cell index the cursor is at; unknown at row start
    local line = {} -- joined per row: one huge table.concat overflows Rex's Lua registry
    if c0 > c1 then
      -- nothing changed on this row
    elseif diff and not chs and prev[rowBase + c0] ~= nil then
      -- fast path: no labels on this row, and the canvas is fully painted
      local topBase, botBase = (cy - 1) * W, cy * W
      for cx = c0, c1 do
        local i = rowBase + cx
        local top, bot = pix[topBase + cx], pix[botBase + cx]
        local tid, bid = top.id, bot.id
        local key = tid * 1e6 + bid
        if prev[i] ~= key then
          prev[i] = key
          if cur ~= i then
            local mv = moveMemo[i]
            if not mv then mv = "\27[" .. row .. ";" .. cx .. "H"; moveMemo[i] = mv end
            line[#line + 1] = mv
          end
          if tid == bid then
            if bg ~= tid then line[#line + 1] = escape("48;", top); bg = tid end
            line[#line + 1] = " "
          else
            if fg ~= tid then line[#line + 1] = escape("38;", top); fg = tid end
            if bg ~= bid then line[#line + 1] = escape("48;", bot); bg = bid end
            line[#line + 1] = "▀"
          end
          cur = i + 1
        end
      end
    else
    for cx = c0, c1 do
      local i = rowBase + cx
      local top = pix[(cy - 1) * W + cx]
      local bot = pix[cy * W + cx]
      local ch = chs and chs[cx]
      if not bot then ch = nil end
      local key = ch and -((#ch * 256 + ch:byte(-1)) * 1e6 + bot.id)
        or (top and top.id or 0) * 1e6 + (bot and bot.id or 0)
      if not diff or prev[i] ~= key then
        if diff then
          prev[i] = key
          if cur ~= i then
            local mv = moveMemo[i] -- memoized: unique strings per frame overflow Rex's registry
            if not mv then mv = "\27[" .. row .. ";" .. cx .. "H"; moveMemo[i] = mv end
            line[#line + 1] = mv
          end
        end
        if ch then
          local back = plate(bot)
          if fg ~= INK.id then line[#line + 1] = escape("38;", INK); fg = INK.id end
          if bg ~= back.id then line[#line + 1] = escape("48;", back); bg = back.id end
          line[#line + 1] = ch
        elseif top and bot and top.id == bot.id then
          if bg ~= top.id then line[#line + 1] = escape("48;", top); bg = top.id end
          line[#line + 1] = " "
        elseif top or bot then
          local c = top or bot
          if fg ~= c.id then line[#line + 1] = escape("38;", c); fg = c.id end
          local b = top and bot
          if (b and b.id or 0) ~= bg then
            line[#line + 1] = b and escape("48;", b) or "\27[49m"; bg = b and b.id or 0
          end
          line[#line + 1] = top and "▀" or "▄"
        else
          if bg ~= 0 then line[#line + 1] = "\27[49m"; bg = 0 end
          line[#line + 1] = " "
        end
        cur = i + 1
      end
    end
    end -- slow path
    if not diff then line[#line + 1] = "\27[0m\n"; fg, bg = 0, 0 end
    out[#out + 1] = table.concat(line)
  end
  if diff then out[#out + 1] = "\27[0m" end
  lastList, dlist, dmark, fullFrame = dlist, {}, {}, false
  return table.concat(out)
end

-- plain-text view of the canvas, for debugging shapes
local function debugView()
  local names, pool, nextChar = {}, "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+*", 1
  local rowsOut = {}
  for y = 1, H do
    local line = {}
    for x = 1, W do
      local c = pix[(y - 1) * W + x]
      if c then
        local ch = names[c.id]
        if not ch then
          ch = pool:sub(nextChar, nextChar)
          nextChar = nextChar + 1
          if nextChar > #pool then nextChar = 1 end
          names[c.id] = ch
        end
        line[#line + 1] = ch
      else
        line[#line + 1] = "."
      end
    end
    rowsOut[#rowsOut + 1] = table.concat(line)
  end
  return table.concat(rowsOut, "\n")
end

------------------------------------------------------------------- scene --

local data -- latest reading (see collect)
local phase = 0
local fish = {}
local bubbles = {}
local stars = {}
local lastActivity = os.time()

local jelly -- only exists while memory pressure is high
local waterline -- last rendered surface row, so bubbles pop there

local function starsInit()
  stars = {}
  for i = 1, 14 do
    stars[i] = { x = 2 + floor(math.random() * (W - 4)), y = 1 + floor(math.random() * 9) }
  end
end

local function fishInit()
  fishCount = fishArg or math.max(3, math.min(7, floor(W * H / 1800)))
  fish = {}
  -- every fish gets its own depth lane (shuffled so colors mix) and column
  local lanes = {}
  for i = 1, fishCount do lanes[i] = (i - 0.5 + (math.random() - 0.5) * 0.6) / fishCount end
  for i = fishCount, 2, -1 do
    local j = math.random(i)
    lanes[i], lanes[j] = lanes[j], lanes[i]
  end
  -- and its own slice of the width (shuffled), at a random spot inside it:
  -- scattered, but never all bunched up
  local cols = {}
  for i = 1, fishCount do cols[i] = i end
  for i = fishCount, 2, -1 do
    local j = math.random(i)
    cols[i], cols[j] = cols[j], cols[i]
  end
  for i = 1, fishCount do
    fish[i] = {
      pal = SPECIES[((i - 1) % #SPECIES) + 1],
      x = 1 + (W - FISH_W) * (cols[i] - 1 + 0.1 + math.random() * 0.8) / fishCount,
      vx = math.random() < 0.5 and 1 or -1,
      speed = 0.6 + math.random() * 0.7, -- so they don't swim in lockstep
      lane = lanes[i],
      seed = math.random() * 6.28,
      bobRate = 0.015 + math.random() * 0.03, -- each fish bobs to its own rhythm
      bobAmp = 1.5 + math.random() * 3,
    }
  end
  starsInit()
end

-- k = elapsed time in base steps, so motion speed is independent of frame rate
local function sceneTick(k)
  k = k or 1
  local cpu = data and data.cpu or 10
  -- sand depth = disk usage: storage piling up on the tank floor
  SAND_H = 3 + floor(H * 0.25 * (data and data.disk or 40) / 100)
  local spd = 0.55 + cpu / 30
  local top = 4
  for i, f in ipairs(fish) do
    f.x = f.x + f.vx * spd * f.speed * k
    if f.x > W - FISH_W then f.x = W - FISH_W; f.vx = -1 end
    if f.x < 1 then f.x = 1; f.vx = 1 end
    if math.random() < 0.004 * k then f.vx = -f.vx end -- change of mind
    -- ease toward its lane in the current water, bobbing gently around it
    local yTop, yBot = (waterline or top) + 2, H - SAND_H - FISH_H - 2
    local target = yTop + math.max(yBot - yTop, 0) * f.lane + math.sin(phase * f.bobRate + f.seed) * f.bobAmp
    f.baseY = f.baseY and f.baseY + (target - f.baseY) * math.min(0.08 * k, 1) or target
    -- never out of the water, even when the water level drops faster than it eases
    f.baseY = math.max(yTop, math.min(f.baseY, math.max(yBot, yTop)))
    -- bubbles from the mouth
    if math.random() < 0.015 * k then
      bubbles[#bubbles + 1] = { x = floor(f.x) + (f.vx > 0 and FISH_W or -1), y = floor(f.baseY) + 2, small = true }
    end
  end
  -- the bubble column = CPU: a trickle when idle, a wide roaring column when busy
  local spread = 1 + floor(cpu / 20)
  local rate = (0.03 + cpu / 55) * k
  while rate > 0 do
    if math.random() < rate then
      bubbles[#bubbles + 1] = { x = floor(W * 0.3) + 1 + floor(math.random() * spread) - floor(spread / 2),
        y = H - SAND_H - 1, small = math.random() * 100 > cpu }
    end
    rate = rate - 1
  end
  for i = #bubbles, 1, -1 do
    local b = bubbles[i]
    b.y = b.y - (1 + math.random()) * k
    if math.random() < 0.15 * k then b.x = b.x + (math.random() < 0.5 and -1 or 1) end
    if b.y <= (waterline or 4) then table.remove(bubbles, i) end -- pop at the surface
  end
  while #bubbles > 90 do table.remove(bubbles, 1) end
  -- a jellyfish drifts in when memory is tight, and leaves when it eases
  local mem = data and data.mem and data.mem.pct or 0
  if mem >= 80 and not jelly then
    jelly = { x = W * 0.7 }
  elseif mem < 75 then
    jelly = nil
  end
  if jelly then jelly.x = jelly.x + math.sin(phase * 0.03) * 0.3 * k end
  phase = phase + k
end

------------------------------------------------------------------ render --

-- battery % -> sky gradient (top, horizon)
local SKY = {
  { 0,   { 8, 10, 28 },    { 35, 35, 75 } },
  { 15,  { 20, 20, 55 },   { 80, 50, 100 } },
  { 30,  { 70, 55, 130 },  { 245, 125, 95 } },
  { 55,  { 90, 130, 210 }, { 250, 205, 150 } },
  { 80,  { 70, 140, 225 }, { 175, 215, 245 } },
  { 101, { 70, 140, 225 }, { 175, 215, 245 } },
}
local function skyFor(p)
  for i = 2, #SKY do
    local a, b = SKY[i - 1], SKY[i]
    if p < b[1] then
      local t = (p - a[1]) / (b[1] - a[1])
      return lerpC(a[2], b[2], t), lerpC(a[3], b[3], t)
    end
  end
  return lerpC(SKY[#SKY][2], SKY[#SKY][2], 0), lerpC(SKY[#SKY][3], SKY[#SKY][3], 0)
end

local SAND_LT, SAND_DK = mkColor(240, 212, 155), mkColor(196, 152, 92)
local KELP_DK, KELP_LT = mkColor(30, 105, 60), mkColor(130, 220, 120)

local bgPix, bgPixKey, duneTop -- cached background (see render)

local function render(diff)
  if not W then return "" end
  labels = {}
  local mem = data and data.mem
  local cpu = data and data.cpu or 0
  local onAC = data and data.source and data.source:find("AC") ~= nil
  local memPct = mem and mem.pct or 40

  -- waterline: tank fills up with memory usage
  local airMin = 6
  local swimH = H - SAND_H - airMin
  local wl = H - SAND_H - floor(swimH * memPct / 100)
  if wl < airMin then wl = airMin end
  waterline = wl

  -- sky = battery: bright day when full, golden, sunset, then night
  local bat = data and data.bat and data.bat.pct or 100
  local skyTop, skyLow = skyFor(bat)
  -- water: deep blue, dimming with the sky as the battery runs down
  local dusk = math.min(math.max((40 - bat) / 40, 0), 1) * 0.6
  local waterTop = lerpC({45, 105, 200}, {12, 25, 60}, dusk)
  local waterBot = lerpC({18, 50, 115}, {6, 12, 35}, dusk)

  -- the static background (sky, water, sand) only changes with the data or
  -- the size, so it's built once into bgPix and copied each frame
  local sandTop = H - SAND_H + 1
  local bgKey = table.concat({ W, H, wl, SAND_H, skyTop.id, skyLow.id, waterTop.id, waterBot.id }, ",")
  local rebuilt = bgKey ~= bgPixKey
  if rebuilt then
    bgPixKey, bgPix, duneTop = bgKey, {}, {}
    local rowCol = {}
    local denom = math.max(H - wl, 1)
    for y = 1, H do
      rowCol[y] = y >= wl and lerpC(waterTop, waterBot, (y - wl) / denom)
        or lerpC(skyTop, skyLow, (y - 1) / math.max(wl - 1, 1))
    end
    for x = 1, W do
      local top = sandTop + floor(math.sin(x * 0.11) * 1.2 + 0.5) -- gentle dunes
      duneTop[x] = top
      for y = 1, top - 1 do bgPix[(y - 1) * W + x] = rowCol[y] end
      for y = top, H do
        local i = (y - 1) * W + x
        bgPix[i] = y == top and SAND_LT or sandTex[i] and PAL.S
          or (y - top > SAND_H * 0.6 and SAND_DK or PAL.s)
      end
    end
  end
  if rebuilt or not diff or not prev then
    for i = 1, W * H do pix[i] = bgPix[i] end
    fullFrame = true
  end
  for x = 1, W do -- the rippling surface line
    local surface = wl + floor(math.sin(phase * 0.35 + x * 0.3) * 1.5 + 0.5)
    if surface < duneTop[x] then px(x, surface, FOAM) end
  end

  local batLabelAt -- right edge + row for the battery label, next to the sun/moon
  -- the sun sinks toward the water as the battery drains; night below 15%.
  -- Rays mean charging.
  if bat >= 15 then
    local sy = 2 + floor((1 - (bat - 15) / 85) * math.max(wl - 6, 0))
    local sx = W - 14
    clipY = wl -- it sets behind the water
    if onAC then blit(SUN_RAYS[floor(phase / 3) % 2 + 1], SUN_PAL, sx - 2, sy - 2) end
    blit(SUN_DISC, bat < 40 and SUN_DUSK or SUN_PAL, sx, sy)
    clipY = nil
    batLabelAt = { sx - 2, math.min(sy + 3, wl - 1) }
  else
    for _, st in ipairs(stars) do
      if st.y < wl - 1 and st.x > 10 and st.x < W - 14 and (phase + st.x) % 9 < 6 then px(st.x, st.y, PAL.y) end
    end
    blit(MOON, MOON_PAL, W - 12, 2)
    batLabelAt = { W - 13, 5 }
  end

  -- the legend, written beside the things it explains
  if data then
    -- CPU: pointing at the air stone the bubble column rises from
    addLabel(floor(W * 0.3) + 5, H - SAND_H - 3, "◂ CPU " .. floor(cpu) .. "%")
    -- RAM and disk sit on what they measure: mid-water and mid-sand
    local ram = "RAM " .. floor(memPct) .. "%"
    addLabel(floor(W / 2 - #ram / 2), floor((wl + H - SAND_H) / 2), ram)
    if data.disk then
      local disk = "DISK " .. data.disk .. "%"
      addLabel(floor(W / 2 - #disk / 2), H - SAND_H + floor((SAND_H + 1) / 2), disk)
    end
    if data.bat and batLabelAt then
      local t = "BAT " .. data.bat.pct .. "%"
        .. (onAC and " charging" or (data.bat.time and " " .. data.bat.time .. " left" or ""))
      addLabel(batLabelAt[1] - #t, batLabelAt[2], t)
    end
  end

  -- kelp (decoration): a dark/light stalk with leaves on alternating sides
  local depth = (H - SAND_H) - wl
  for k, sx in ipairs({ 12, 18, W - 8 }) do
    local h = floor(depth * (k == 2 and 0.35 or 0.55))
    for i = 1, h do
      local sway = floor(math.sin(phase * 0.2 + i * 0.35 + sx) * 1.5 * i / math.max(h, 1) + 0.5)
      local y = H - SAND_H - i + 1
      local x = sx + sway
      px(x, y, KELP_DK); px(x + 1, y, PAL.g)
      if i % 4 == 2 then px(x - 1, y, PAL.g); px(x - 2, y - 1, KELP_LT)
      elseif i % 4 == 0 then px(x + 2, y, PAL.g); px(x + 3, y - 1, KELP_LT) end
    end
  end

  -- the air stone the CPU bubble column comes from
  blit(STONE, STONE_PAL, floor(W * 0.3) - 1, H - SAND_H - 1)

  -- bubbles
  for _, b in ipairs(bubbles) do
    px(b.x, floor(b.y), PAL.w)
    if not b.small then px(b.x + 1, floor(b.y) - 1, FOAM) end
  end

  -- jellyfish
  if jelly then
    blit(JELLY[phase % 8 < 4 and 1 or 2], PAL, floor(jelly.x),
      wl + 4 + floor(math.sin(phase * 0.12) * 3 + 0.5))
  end

  -- fish, with a wiggling tail
  for _, f in ipairs(fish) do
    local wob = floor(math.sin(phase * 0.25 + f.seed) * 2 + 0.5)
    local frame = FISH[(floor(phase / 2) + floor(f.seed)) % 2 + 1]
    -- the drawn fish stays between just under the surface and just over the sand
    local y = math.max(wl + 2, math.min(floor(f.baseY or 20) + wob, H - SAND_H - FISH_H))
    blit(frame, f.pal, floor(f.x), y, f.vx < 0)
  end

  -- last frame's pixels not drawn again this frame get the background back
  erased = {}
  if not fullFrame then
    for _, i in ipairs(lastList) do
      if dmark[i] == nil and pix[i] ~= bgPix[i] then pix[i] = bgPix[i]; erased[#erased + 1] = i end
    end
  end
  return encode(diff)
end

------------------------------------------------------------------ collect --

local COLLECT = table.concat({
  "echo @PM@; pmset -g batt",
  "echo @SYS@; sysctl -n hw.ncpu hw.memsize",
  "echo @VM@; vm_stat",
  "echo @DF@; df -k /",
  -- summed in awk: parsing ~600 ps lines in Lua cost ~25ms per sample
  "echo @PS@; ps -Aro pcpu=,comm= | awk 'NR==1{print} {s+=$1} END{print s}'",
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

local function collect()
  local r = rex.exec({ "sh", "-c", COLLECT }, { timeout = 10 })
  if not r or not r.ok then return nil end
  local s = sections(r.stdout)
  local d = {}
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
  local nums = {}
  for n in (s.SYS or ""):gmatch("%d+") do nums[#nums + 1] = tonumber(n) end
  d.cores = nums[1]
  local total = nums[2]
  local vm = s.VM or ""
  local page = tonumber(vm:match("page size of (%d+)"))
  local function pages(label) return tonumber(vm:match(label .. ":%s+(%d+)")) or 0 end
  if page and total then
    local used = (pages("Pages active") + pages("Pages wired down")
      + pages("Pages occupied by compressor")) * page
    d.mem = { used = used, total = total, pct = used / total * 100 }
  end
  local cap
  for line in (s.DF or ""):gmatch("[^\n]+") do cap = line:match("(%d+)%%") end
  d.disk = cap and tonumber(cap) or nil
  local topLine, sum = (s.PS or ""):match("^%s*([^\n]+)\n%s*([%d%.]+)")
  if topLine then
    local c, name = topLine:match("^([%d%.]+)%s+(.+)$")
    if c then d.top = { cpu = tonumber(c), name = name:match("[^/]+$") or "?" } end
  end
  sum = tonumber(sum) or 0
  if d.cores then d.cpu = math.min(sum / d.cores, 100) end
  return d
end

------------------------------------------------------------------ status --

local lowActive = false
local function b64(s)
  local B = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  local out, i = {}, 1
  local floor_ = math.floor
  while i <= #s do
    local a, b2, c = s:byte(i, i + 2)
    local n = a * 65536 + (b2 or 0) * 256 + (c or 0)
    local chars = {
      B:sub(floor_(n / 262144) % 64 + 1, floor_(n / 262144) % 64 + 1),
      B:sub(floor_(n / 4096) % 64 + 1, floor_(n / 4096) % 64 + 1),
      B:sub(floor_(n / 64) % 64 + 1, floor_(n / 64) % 64 + 1),
      B:sub(n % 64 + 1, n % 64 + 1),
    }
    local rem = #s - i + 1
    out[#out + 1] = table.concat(chars, "", 1, rem == 1 and 2 or rem == 2 and 3 or 4)
    i = i + 3
  end
  return table.concat(out)
end

local function termWrite(dataStr)
  io.write(dataStr)
  io.stdout:flush()
end

local function updateStatus()
  if not data or not data.bat then return end
  local onAC = data.source and data.source:find("AC") ~= nil
  local should = not onAC and data.bat.pct <= lowAt
  if should == lowActive then return end
  lowActive = should
  if should then
    local msg = b64("Battery low: " .. data.bat.pct .. "% — plug in")
    termWrite("\27]7501;state=blocked:kind=auth:app=aquarium:msg=" .. msg .. "\27\\")
    rex.exec({ "osascript", "-e",
      'display notification "Battery at ' .. data.bat.pct .. '% — plug in" with title "aquarium"' })
  else
    termWrite("\27]7501;state=clear\27\\")
  end
end

local lastLabel
local function updateLabel()
  local text
  if data and data.bat then
    local onAC = data.source and data.source:find("AC") ~= nil
    text = "🐠 " .. data.bat.pct .. "%"
      .. (not onAC and data.bat.time and (" " .. data.bat.time) or (onAC and " ⚡" or ""))
  else
    text = "🐠 ..."
  end
  if text ~= lastLabel then
    lastLabel = text
    rex.session.set_block_label{ block_id = display, label = text }
  end
end

-------------------------------------------------------------------- main --

local debugMode = rex.args.debug == true
local myWindow -- our tab; frames only render while it is the active one

if rex.args.toggle == true then
  -- Ctrl+Cmd+A (via init.lua): float the tank over the active tab, or close it.
  -- Rex app bug: a float's bounds w/h size the terminal as width/height but
  -- are DRAWN as right/bottom edges. So the float must be centered (drawn area
  -- is x..w, which needs w <= 1 - x), and the tank only draws in the visible
  -- top-left fraction of its terminal (crop=), or it gets cut off.
  local B = { 0.12, 0.12, 0.88, 0.88 } -- x, y, w, h (drawn 0.12..0.88 each way)
  local v = rex.session.view() or {}
  for _, w in ipairs(v.windows or {}) do
    if w.window_id == v.active_window_id then
      for _, l in ipairs(w.layers or {}) do
        for _, blk in ipairs(l.blocks or {}) do
          if l.kind == "floating" and blk.label and (blk.label == "aquarium" or blk.label:find("^🐠")) then
            rex.session.close_layer{ layer_id = l.layer_id }
            return
          end
        end
      end
    end
  end
  local cropx, cropy = (B[3] - B[1]) / B[3], (B[4] - B[2]) / B[4]
  local self = debug.getinfo(1, "S").source:gsub("^@", "")
  local _, err = rex.session.new_layer{
    bounds = B,
    layout = rex.layout.block{
      flavor  = TERMINAL .. ".shell",
      label   = "aquarium",
      options = {
        -- default shell: the login environment puts rex on PATH
        command = { "sh", "-c", 'stty -echo; GOGC=400 rex do -s "$REX_SESSION" "' .. self .. '" pane=true'
          .. string.format(" cropx=%.4f cropy=%.4f", cropx, cropy) .. ' 2>/tmp/aquarium.log'
          .. ' || { printf "\\033[0m\\033[2J\\033[H"; tail -5 /tmp/aquarium.log; }' },
        exit = { on_completion = false },
      },
    },
  }
  if err ~= nil then error(err, 0) end
  return
end

if not debugMode and rex.args.pane ~= true then
  -- launcher: open a tab that runs this same script inside it, then exit.
  -- Drawing from inside the pane means plain stdout writes: no pty relay.
  for _, w in ipairs((rex.session.view() or {}).windows or {}) do
    if w.label == "aquarium" then
      error("an aquarium is already running in this session (close its tab first)", 0)
    end
  end
  local self = debug.getinfo(1, "S").source:gsub("^@", "")
  local cmd = { "/usr/bin/env", "PATH=" .. (os.getenv("PATH") or ""), "sh", "-c",
    -- stderr (rex's banner, errors) goes to a log; on a crash, show it in the tab
    'stty -echo; "$@" 2>/tmp/aquarium.log || { printf "\\033[0m\\033[2J\\033[H"; tail -5 /tmp/aquarium.log; }',
    "sh", "rex", "do", "-s", rex.session_id, self, "pane=true" }
  for k, v in pairs(rex.args) do cmd[#cmd + 1] = k .. "=" .. tostring(v) end
  local _, err = rex.session.new_window{
    window_label = "aquarium",
    focus = false,
    layout = rex.layout.block{
      flavor  = TERMINAL .. ".shell",
      options = { command = cmd, shell = "none", exit = { on_completion = false } },
    },
  }
  if err ~= nil then error(err, 0) end
  print("aquarium: your MacBook now has fish. close the tab to stop.")
  return
end

if debugMode then
  display = "debug"
else
  display = rex.block_id or os.getenv("REX_BLOCK")
  -- our tab: the window holding our block, tiled or floating (Toggle Aquarium)
  for _, w in ipairs((rex.session.view() or {}).windows or {}) do
    for _, l in ipairs(w.layers or {}) do
      for _, blk in ipairs(l.blocks or {}) do
        if blk.block_id == display then myWindow = w.window_id end
      end
    end
  end
end

-- size the canvas to the pane (re-checked on every data tick)
local function paneSize()
  local cols, rows = 80, 20
  local sz = rex.block.call(TERMINAL, "size", { block_id = display })
  if sz then
    -- the API returns top-level columns/rows. (An earlier guess read
    -- sz.cells.*, which is nil, so the canvas silently stuck at 80x20.)
    local c = sz.columns or (sz.cells and sz.cells.cols)
    local r = sz.rows or (sz.cells and sz.cells.rows)
    -- crop=: only part of a float's terminal is drawn (see toggle=true)
    if c then cols = math.min(floor(c * (tonumber(rex.args.cropx) or 1)), 200) end
    if r then rows = math.max(floor(r * (tonumber(rex.args.cropy) or 1)), 8) end
  end
  return cols, rows
end
if debugMode and rex.args.cols then
  canvasResize(tonumber(rex.args.cols), tonumber(rex.args.rows) or 24)
else
  canvasResize(paneSize())
end
fishInit()

if debugMode then
  data = collect()
  -- preview other states: cpu=90 mem=85 bat=15 ac=true idle=0 ticks=30
  if data then
    data.cpu = tonumber(rex.args.cpu) or data.cpu
    if rex.args.mem and data.mem then data.mem.pct = tonumber(rex.args.mem) end
    if rex.args.bat and data.bat then data.bat.pct = tonumber(rex.args.bat) end
    if rex.args.ac ~= nil then data.source = rex.args.ac == true and "AC Power" or "Battery Power" end
    if rex.args.disk then data.disk = tonumber(rex.args.disk) end
    if rex.args.left and data.bat then data.bat.time = tostring(rex.args.left) end
  end
  for _ = 1, tonumber(rex.args.ticks) or 2 do sceneTick(); render() end
  if rex.args.clean == true then
    -- clean=true: keep swimming until no fish overlaps another fish or a label
    -- (for screenshots)
    local function box(f)
      local wl = waterline or 4
      local y = math.max(wl + 2, math.min(floor(f.baseY or 20) + floor(math.sin(phase * 0.25 + f.seed) * 2 + 0.5), H - SAND_H - FISH_H))
      return floor(f.x) - 1, y - 1, floor(f.x) + FISH_W, y + FISH_H
    end
    local function clear()
      for a = 1, #fish do
        local ax0, ay0, ax1, ay1 = box(fish[a])
        if jelly then
          local jx, jy = floor(jelly.x), (waterline or 4) + 4 + floor(math.sin(phase * 0.12) * 3 + 0.5)
          if ax0 <= jx + 7 and jx - 1 <= ax1 and ay0 <= jy + 7 and jy - 1 <= ay1 then return false end
        end
        for b = a + 1, #fish do
          local bx0, by0, bx1, by1 = box(fish[b])
          if ax0 <= bx1 and bx0 <= ax1 and ay0 <= by1 and by0 <= ay1 then return false end
        end
        for row, ls in pairs(labels or {}) do
          for _, l in ipairs(ls) do
            local lx1 = l[1] + select(2, l[2]:gsub("[^\128-\191]", "")) - 1
            if ax0 <= lx1 and l[1] <= ax1 and ay0 <= row * 2 and row * 2 - 1 <= ay1 then return false end
          end
        end
      end
      return true
    end
    for _ = 1, 3000 do
      if clear() then break end
      sceneTick(); render()
    end
  end
  if rex.args.shot then
    local f = assert(io.open(tostring(rex.args.shot), "w"))
    f:write("\27[?25l\27[H\27[2J" .. render())
    f:close()
  end
  print(debugView())
  return
end

local visible = true
local function checkVisible()
  local v = rex.session.view()
  visible = not myWindow or not v or v.active_window_id == myWindow
end
checkVisible()

local animGen = 0
local function animTick(gen)
  if gen ~= animGen or not visible then return end -- superseded, or nobody's looking
  local idle = os.time() - lastActivity >= idleAfter
  local interval = animInterval
  -- idle frames are 10x apart but advance one normal step: slow-motion while asleep
  sceneTick(interval / BASE_STEP)
  -- 2026 = synchronized update: the terminal shows the frame all at once
  termWrite("\27[?2026h\27[?25l" .. render(true) .. "\27[?2026l")
  rex.after(idle and interval * 10 or interval, function() animTick(gen) end)
end

-- activity wakes the tank right away instead of after a slow idle frame
local function poke()
  local wasIdle = os.time() - lastActivity >= idleAfter
  lastActivity = os.time()
  if wasIdle then
    animGen = animGen + 1
    animTick(animGen)
  end
end

rex.on("session_view_changed", function()
  local was = visible
  checkVisible()
  if visible and not was then
    lastActivity = os.time()
    animGen = animGen + 1
    animTick(animGen) -- back in view: resume right away
  elseif visible then
    poke()
  end
end)
rex.on("block_event", function(_, ev)
  if not (ev and ev.block_id == display) then poke() end -- our own frames aren't activity
end)
rex.on("block_closed", function(_, ev)
  if ev.block_id == display then rex.stop(0) end
end)

local dataTicks = 0
local function dataTick()
  -- idle: sample 8x less often (exec costs rex CPU for the child's whole runtime)
  dataTicks = dataTicks + 1
  local quiet = not visible or os.time() - lastActivity >= idleAfter
  if quiet and dataTicks % 8 ~= 0 then return end
  -- stats every other tick (the sample's forks cost ~25 ms); size every tick
  local d = (dataTicks % 2 == 1 or not data) and collect()
  if d then
    data = d
    updateLabel()
    updateStatus()
  end
  local cols, rows = paneSize()
  if cols ~= W or rows * 2 ~= H then
    canvasResize(cols, rows)
    fishInit() -- re-spread (and re-count) the fish for the new size
  end
end

dataTick()
animTick(animGen)
rex.every(dataInterval, dataTick)
