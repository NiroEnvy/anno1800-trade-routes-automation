# Regions

Every region the mod knows about is one row in
[`trade_route_automation/_regions.lua`](../trade_route_automation/_regions.lua). Nothing else needs
editing to add or enable one — `Anno.Region_*`, the map scanner's camera sweep and the per-region
planner threads in `_main.lua` all read from that table.

A region is **enabled** once its row has `bounds`. Only enabled regions get a planner thread, so a
row without bounds costs nothing at runtime.

| Region | Session GUID | Code | Shipped state |
|---|---|---|---|
| Old World | `180023` | `OW` | enabled |
| New World | `180025` | `NW` | enabled |
| Enbesa | `112132` | `EN` | needs bounds |
| The Arctic | `180045` | `AR` | needs bounds |
| Cape Trelawney | `110934` | `CT` | needs bounds |

## Why bounds are hand-measured

Nothing in the game's Lua surface reports a session's extents. `ts.Area` exposes only `GetArea`,
`GetAreaFromID`, `GetAreaFromContext` and `GetCurrentSelectedArea` (see
`docs/lua-inspector/ts.yaml`) — there is no way to enumerate islands and no map-size property
anywhere in the dump. Session size also depends on how the save was generated, so a constant that is
right for one playthrough need not be right for the next.

Hence the sweep in `mod_map_scanner.lua`: park the camera on a grid of world positions and read
`ts.Area.Current.ID` at each one. That is the only island-discovery mechanism there is, and it needs
to be told where to look.

## What the numbers mean

`bounds` are world coordinates — the same ones `ts.SessionCamera.ToWorldPos(x, y)` takes.
`x0,y0` is where the sweep starts, `x1,y1` where it stops.

The step between samples is **not** part of `bounds`. It lives in `mod_map_scanner.lua` as
`presets.P11.DeltaX = 90` / `DeltaY = 50`, because it is a property of camera preset 11's zoom and
angle rather than of the map. The two differ because the camera looks at the map tilted, so equal
steps on screen are unequal distances in world x and y. Don't raise them: the step is the sampling
resolution, and an island narrower than a step can fall between samples and never be found.

The cost of the sweep is roughly `((x1-x0)/90) * ((y1-y0)/50)` camera moves at ~1 frame each — about
1200 for the Old World's box. Guessing **too large** only costs sweep time. Guessing **too small**
silently drops the islands outside the box, which is the failure worth avoiding.

`x0 = y0 = 250` in both shipped rows. That is a margin off the map origin, carried over from when
the numbers were first measured; leaving it at 250 for a new region is the safe default.

## Enabling a region

1. **Confirm the session GUID.** In the region, with the console open:

   ```lua
   print(session.getSessionGUID())
   ```

   If it matches a row in `_regions.lua`, good. If it does not — a modded session — add a row, or
   call `Regions.Register{ guid = "...", code = "XX", name = "...", bounds = {...} }` from
   `_init.lua`. Codes must be unique; `Register` raises if one is already taken, because the code is
   what the player's `TRA_<code>` route and every cache file are keyed by.

2. **Measure the bounds.** Move the camera and watch where the map stops responding:

   ```lua
   ts.SessionCamera.ToWorldPos(2000, 2000); print(ts.Area.Current.ID)
   ```

   Work outwards from a known island until you have a box that comfortably contains every island you
   can see on the minimap, then add a margin. Over-estimating is the cheap mistake.

3. **Fill in the row** in `_regions.lua`, then `make install` and restart the mod
   (`Shift+Alt+R`, or `trade_route_automation_restart()`).

4. **Scan.** In the region:

   ```lua
   console.toggleVisibility(); require("trade_route_automation/ui_cmds").RegionRescan.Do(20)
   ```

   Before the bounds are set this fails with `region EN has no bounds` rather than a confusing
   `'for' limit must be a number`.

5. **Check the sweep found everything.** The scan lands in a cache file under
   `<Documents>/Anno 1800/log/` whose name contains `map_scanner.Session(P11)` and the region code.
   Each island gets a `min_x/min_y/max_x/max_y` rectangle. If any island's rectangle runs right up
   against `x1` or `y1`, the box is probably clipping it — widen and rescan. The area visualizer
   (`docs/images/area-visualzer/readme.md`) is the easier way to eyeball this.

6. **Create the trade route.** A route named `TRA_<code>` — `TRA_EN` for Enbesa — with the ships you
   want the mod to use assigned to it, cargo empty, names at most 2 letters. See the ship assignment
   section of the [README](../README.md).

7. **Restart** once more and check the log for `Driving N region(s): OW, NW, EN`.

## Known limitation: the Arctic

Gas and heat are a per-building supply in the Arctic, not island stock, so the planner's
deficit/surplus model cannot see them. Ordinary goods will trade normally once `AR` is enabled;
heating will simply be ignored.
