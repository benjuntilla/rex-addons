# Aquarium notes

## What was built

Two scripts in `aquarium/`, both tested live in Rex:

1. **`powermon.lua`** — plain dashboard (battery/health/CPU/RAM/disk in a tab, label updates, low-battery alerts). Kept as the non-whimsical fallback.
2. **`aquarium.lua`** — pixel-art aquarium (tab label `🐠 <pct> <time>`). ~600 lines, zero dependencies.

### Aquarium mechanics

- Half-block rendering: each terminal cell = 2 vertical pixels, 24-bit color (`▀` fg=top / bg=bottom). One `write` per frame, no per-frame forks.
- Water level = memory usage; fish speed = CPU; water flushes warm red above 70% CPU (capped at 50% tint); seaweed height = disk usage; buddy pufferfish mood = battery (happy on AC / worried <35% with sweat drop / panic ≤ low threshold: swims to surface + OSC 7501 `blocked:kind=auth` + macOS notification + `state=clear` on recovery); sun (AC) or moon + twinkling stars (battery); sand + pebbles; idle (45s) → buddy sleeps, animation slows 5×.
- Data: single `sh -c` per sample (pmset/sysctl/vm_stat/df/ps), one fork per 2.5s.
- Flags: `anim=`, `data=`, `idle=`, `low=`, `fish=`, `debug=true`, `shot=/path` (dumps one ANSI frame — used with `/tmp/ansi2png.py` to render PNG previews for visual iteration).

## Hard-won gotchas (these cost debugging time)

1. **`com.superlogical.terminal.write` takes `data`** (not `bytes`/`text`).
2. **Display pane trick**: create block with `command = { "sh", "-c", "stty -echo -icanon; exec cat" }`, `shell = "none"`. `-echo` stops every frame rendering twice (pty echo + cat echo). `-icanon` is just as essential: in line mode macOS drops any line longer than MAX_CANON (1024 bytes). Water rows change color every column, so at widths above ~80 they exceeded that and vanished. Only the sky drew and the tank looked "drained".
3. **`registry overflow` Lua crash**: caused by thousands of unique escape strings per frame (per-pixel water gradients). Fix = give every color an integer `id`, quantize gradients to 24 steps, memoize escape strings by `kind + id`.
4. **`terminal.format` defaults to plain text and strips colors** — pass `{"format":"vt"}` to verify truecolor SGR reached the screen.
5. **Rex Lua has no `math.fmod` issues but has no `//`; `local floor = math.floor` must be defined before use** (debugView crashed on nil `floor`).
7. **Sign error lesson**: waterline `wl` is *above* sand, so depth = `(H - SAND_H) - wl`, not the reverse (seaweed never grew at first).
8. **`terminal.size` returns top-level `columns`/`rows`** — NOT `sz.cells.*` (an earlier guess read `sz.cells`, which is nil, so the canvas silently stuck at 80x20 no matter the pane size; fixed in `paneSize()`). Verify with `rex api call -s <session> com.superlogical.terminal.size '{"block_id":"<id>"}'`. A fresh window opens at 80x24; the canvas follows the pane on resize within one data tick.

## Ideas not yet done

- Network throughput row (netstat -ib deltas)
- Swap pressure visualization
- Keybinding/palette action to summon the aquarium as a floating layer popup (see `rex.action` docs; phinze's `init.lua` in the Discord thread is the reference)
- Kitty graphics protocol version (Rex supports it per community feedback — real PNG sprites, bigger lift)
- Post to the Rex Discord when it's polished; aquarium/tamagotchi is unclaimed territory there
ANSI frame -> PNG converter, for visual iteration: python3 ansi2png.py frame.ans frame.png

## Changelog — 2026-10-21 (Claude takeover)

**Art** (verified with `ansi2png.py` across night/day, idle/active, and low/high-battery states; before/after PNGs are `/tmp/before.png`, `/tmp/after.png`, `/tmp/after_day_hot.png`)
- Fish now share one shape with a dorsal fin, stripe, belly shade, eye highlight, mouth, and a 2-frame tail wiggle. The four species (clownfish, teal, pink, yellow tang) are palettes. Bubbles now come from the mouth.
- The buddy's face changes with mood: happy/ok/worried/panic/sleep. New `puffed` mood: when CPU >= 70% it inflates with spikes. It eases toward its target height instead of snapping.
- A crab walks the sand, pauses now and then, and carries the top CPU process name and % as real text. The encoder now supports a `labels` text overlay.
- A jellyfish drifts in when memory >= 80% and leaves below 75% (hysteresis).
- Sky gradients for day and night, a bigger sun with twinkling rays, and thicker 2-tone seaweed with leaves (3 clumps). Stars no longer land on the gauge or moon, and bubbles pop at the surface instead of floating into the sky.

**Bugs fixed**
- Memory leak: `lerpC` minted a new color id every frame, so `escapeMemo` grew without bound (~100 entries/sec). Colors are now interned by RGB.
- HUD showed low battery in green (severity was inverted for battery).
- Activity from our own display block no longer counts as user activity.

**Robustness**
- Double-launch guard: refuses to start if a window labeled `aquarium` already exists in the session.
- Terminal resize: pane size is re-read on every data tick, and the canvas rebuilds when it changes.
- Instant wake: activity during idle starts a fast frame right away. A generation counter drops the pending slow timer.

**Performance**
- The ripple `math.sin` is computed per column, not per pixel (~2400 to 80 calls/frame), and the background fill writes `pix` directly.
- `ps` summation moved into `awk` (still one `sh` fork per sample).
- Idle: frames every `anim*10` (3.5s), and data sampled every 8th tick (20s). `rex.exec` costs rex CPU for the child's whole runtime, so fewer samples is the main lever.

**Tooling**
- New debug flags: `cpu= mem= bat= ac= ticks=` fake readings to preview any mood. Example: `rex do aquarium.lua debug=true shot=/tmp/f.ans ac=true cpu=85 mem=85`.
- `ansi2png.py` now renders text cells (the crab label) instead of dropping them and shifting columns.

**Not done / ideas**: food pellets; pausing frames entirely when the tab is not visible (needs a visibility signal); active CPU is still ~3%, mostly the per-frame write RPC. **Resize has now been exercised live** (2026-10-21): the 80x20-canvas bug was the `terminal.size` field-name issue above; `paneSize()` re-reads the real columns/rows on every data tick.

## Redesign — 2026-10-21 (late, Claude Code)

- **Draws from inside its own pane.** `rex do aquarium.lua` is now a launcher: it opens the `aquarium` tab running `rex do <script> pane=true` and exits. The pane process writes frames to stdout. No `cat` relay, no `terminal.write`, no `stty` line-mode trap (gotcha 2 no longer applies). stderr (rex's banner, errors) goes to `/tmp/aquarium.log`; if the script crashes, the tab shows the log's tail. Closing the tab ends the process.
- **Pauses when its tab is not the active window** (`session.view().active_window_id`). Hidden cost: ~0.07% CPU. The label and low-battery alarm still update (data sampled 8x less often). Limit: this is the session's active tab, so a minimized Rex app or another session still counts as "visible".
- **Diff rendering**: only changed cells are sent, using cursor moves, wrapped in synchronized output (`?2026`). At 154x49: 25KB → 4KB per frame, 13 → 9 ms per frame. `encode()` with no argument still makes full newline frames for `shot=` / ansi2png.py.
- **Time-based motion**: `sceneTick(k)` scales every step by elapsed time, so `anim=` changes smoothness, not speed. Default `anim=0.15`.
- **Gotcha 9: `registry overflow` also comes from one huge `table.concat`** (one entry per cell, about 15k entries). Join each row first, then join the rows. Memoize cursor-move strings too.

## Art + meaning pass — 2026-10-21 (late)

- **New meanings.** CPU = thermometer on the glass, plus air-stone bubbles. RAM = water level. Disk = sand depth. Battery = time of day: the sun sinks, the sky goes golden, then sunset, then night under 15%, and the water dims too. Sun rays = charging. The status line icons (🌡️ 💧 ⏳ ☀️/🌙) match. Kelp is now just decoration. The CPU "warm water" tint is gone (it duplicated the thermometer and looked muddy).
- **New sprites**: outlined 16x9 fish with shading (stripes are per-species palette slots x/X/z), a 13x10 pufferfish with 5 faces plus a spiky puffed form, a 13x9 crab, a sun disc with charging rays, a moon, and the air stone. `palette{}` turns `{char = {r,g,b}}` into interned colors.
- **Preview any state at any size**: `rex do aquarium.lua debug=true cols=154 rows=49 bat=24 ac=false cpu=90 mem=85 shot=/tmp/x.ans && python3 ansi2png.py /tmp/x.ans /tmp/x.png`

## Simplify pass — 2026-10-21 (late)

- CPU = **bubble column** from the air stone (the thermometer read as temperature). Its width and density scale with load, and the `CPU n%` label rides beside it. Fish no longer blow CPU bubbles.
- Legend labels sit inline next to their elements (`addLabel(x, y, text)` in pixels; ink auto-picks dark/light from the background): `BAT` beside the sun/moon, `~ RAM ~` just above the waterline, `~ DISK ~` just above the sand. The bottom status line is gone, and the canvas uses the full pane.
- **Removed the crab and the pufferfish**: neither carried data once labels existed. The low-battery OSC flag + notification still fire (`updateStatus`). The default is now 6 fish, from 6 species (added blue tang and royal purple).

## Native integration — 2026-10-21 (late)

- `~/.config/rex/init.lua` defines a **"Toggle Aquarium"** action (in the command palette; also `rex do aquarium`) bound to **Ctrl+Cmd+A**. It opens the tank as a floating layer in the bottom-right of the active tab (`session.new_layer`, bounds `{0.52, 0.5, 0.46, 0.46}`). Pressing it again closes that layer, which ends the process. The layer is found by kind `floating` + block label `aquarium` / `🐠…`.
- Config can't hold long-lived scripts (no `rex.on` / `rex.every` there), so the action just launches `aquarium.lua pane=true` in the float. After editing init.lua, run `rex config reload`.
- In pane mode the script finds its window by searching every layer's blocks, not by `focused_block_id`, so pause-when-hidden works for floats too.
- The fish count defaults to `clamp(W*H/2600, 3, 6)` and is recomputed on resize. `fish=N` overrides it.
- **Gotcha 10: never call session APIs inside a key-bound init.lua action.** The app waits on `client.action` while the server waits on the app, so it deadlocks: a 50s freeze, then the app reconnects. `rex do <action>` from the CLI does NOT reproduce it; `rex -C <app client> do <action>` does. So the action only does `rex.exec` of `sh -c '<rex> do -s <session> aquarium.lua float=true &'` and returns at once. The toggle logic lives in `aquarium.lua float=true`.
- **Floating layers don't show in the Mac app beta (1347).** The server creates them, and `session.view` lists `kind: "floating"`, but nothing is drawn, and the app has no float actions. So `float=true` now toggles a **bottom drawer split** across the whole active tab (`session.new_split`, anchor = the tiled layer's root, vertical, `ratio = 0.62`). It closes with `rex.block.close`. Revisit floats when the app supports them.
- In Rex Lua, `rex.block` only has `call` (block methods). For other API methods, such as `block.close`, use `rex.call("<method>", {...})` and pass `session_id` explicitly.
- **Ctrl+Cmd+A now toggles a full "aquarium" tab** (`aquarium.lua toggle=true`), replacing the drawer. It opens the tab and focuses it. Pressed on that tab, it closes it and focuses the previous tab (saved in `/tmp/aquarium-prev-<session>`). If the tab is open elsewhere, it jumps to it.
- The server's `focus_window` / `new_window{focus=true}` do NOT move the Mac app's visible tab. The toggle asks every app client (`client.list` where `info.kind == "app"`) to run `client.perform` → `session.select {session_id, window_id}`. `ctx.client_id` in an action can be a short-lived CLI connection, so it isn't used.
- **Floats DO work; the bug is placement.** App bug: when bounds `x > w`, the floating layer is invisible but still focused (all our corner floats, like `{0.52,0.5,0.46,0.46}`). Centered bounds like `{0.15,0.15,0.7,0.6}` show fine. Floats also have transparent unpainted cells, so the program must paint its own background.
- **Ctrl+Cmd+A now floats the tank** (centered bounds `{0.12,0.12,0.88,0.88}`). Rex app bug: float `w`/`h` size the terminal as width/height but are drawn as right/bottom edges, so only `x..w` × `y..h` shows. Floats therefore have to be centered (`w <= 1-x`), and the tank renders into the visible fraction via `cropx`/`cropy` args (`(w-x)/w`). The tab version is gone; `rex do aquarium.lua` still opens a full tab.
- **Gotcha 11: large whole-number table keys are slow in Rex Lua (gopher-lua).** `colorCache[r*65536+g*256+b]` grew the table to millions of array slots: about 0.9 s at startup, plus memory. The key now has `+ 0.5` so it goes in the hash part. Key press to first frame went from about 2.0 s to 0.44 s.
- **Perf pass:** CPU scales about 0.9% per fps plus about 2% fixed. (1) The static background (sky/water/sand) is cached in `bgPix` and rebuilt only when its key (size, waterline, sand, sky/water colors) changes; each frame copies it and adds the ripple line. (2) `encode(diff)` has a fast path for rows without labels. (3) Stats are sampled every other data tick (5 s); size is still checked every tick. (4) The float runs with `GOGC=400`. Frame time went from 4.0 to 1.9 ms, and the visible float at 10 fps from about 13% to about 8% CPU (memory about 36 → 52 MB from GOGC).

## Perf pass 2: only redraw what changes

- The cost wasn't drawing time. A frame took ~1.9 ms, yet the process used ~7% CPU. Rex's Lua runs on Go and allocates on most number operations, so the real cost is Go's garbage collector on other threads, and it scales with how many pixels are touched. Baselines: an empty timer script uses 0.2%, and writing a 2 KB frame at 7.7 fps uses 0.25%.
- `px` records each drawn pixel in `dlist`, with its color from before the draw in `dmark`. After drawing, last frame's pixels that weren't redrawn get the background back (`erased`). `encode` then only visits cells whose pixel color actually changed, plus label cells (this frame's and last frame's), sorted. So still scenery (kelp, sun, stone) costs nothing to encode. It falls back to a full repaint when the background key changes.
- Sprites compile once into pixel lists per (sprite, palette, flip).
- Frame time went from 1.9 to 1.0 ms. CPU went from ~7% to ~5% visible, and to ~0.9% at the idle frame rate.
- Labels are white on a band that's a darker shade (50%) of whatever is behind them, with no tildes. They're padded by one cell and handle any Unicode character, one character per cell. CPU points at the air stone (`◂`), RAM sits mid-water, and DISK mid-sand.
- Fish start in shuffled width slices and jittered depth lanes, and each bobs at its own rate, so they don't line up.
- Fish are 11x6 (`FISH_W`, `FISH_H`), down from 16x9. The default count is `clamp(W*H/1800, 3, 7)`. The drawn y is clamped between `waterline + 2` and `H - SAND_H - FISH_H`, and `baseY` is clamped to the current lanes, so bobbing or a dropping waterline can't put fish in the sky. A stress test swinging RAM 10-90% over 2,000 frames found zero fish at or above the surface.
- Debug previews: `disk=` and `left=` fake disk use and battery time left. `clean=true` keeps simulating until no fish overlaps another fish, the jellyfish or a label (for README shots).
