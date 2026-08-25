# Unit test infrastructure — how the fake game works

Enough to *extend* the harness. To write a test you only need
[testing-unit.md](testing-unit.md).

## The idea

Anno 1800 has no public modding interface. The mod reaches the game by building text-source command
strings and handing them to `serpLight.DoForSessionGameObjectRaw`, plus a few `session.*` / `ts.*`
globals. None of that exists outside the game.

But it all funnels through **one module**: `anno_interface.lua`. Every game read and every game
write goes through some `Anno.*` function. That is the seam.

So the tests do not mock anything. They stand up a small **imitation of the game** — islands that
hold goods up to a capacity, ships that carry cargo in slots and take time to sail — and put it
behind `Anno.*`. Arrange a world, let the mod run against it, then look at what the world became.
No expectations to record, no call assertions: if the bricks ended up on the right island, it
worked.

```
      real mod code                          test doubles
 ┌──────────────────────────┐
 │ mod_trade_planner_ll     │
 │ mod_trade_executor       │──── Anno.* ───▶ ┌────────────────────┐
 │ mod_ship_cmd             │                 │ tests/lib/world.lua│
 │ utils_async, utils_table │                 │  areas / ships     │
 └──────────────────────────┘                 │  stock / capacity  │
                                              │  cargo slots       │
                                              │  movement per tick │
                                              └────────────────────┘
```

The fake is a set of **claims** about Anno. [testing-integration.md](testing-integration.md) is how
those claims get checked.

## Module substitution

`tests/lib/harness.lua` exploits the fact that every mod file is loaded as
`require("trade_route_automation/...")`. Before requiring the module under test it:

1. clears every `package.loaded` key starting with `trade_route_automation`,
2. writes fakes into `package.loaded` under the names the mod will ask for,
3. requires the modules under test, which pick up the fakes transparently.

No production code knows it is being tested. No dependency-injection scaffolding, no
`if TESTING then`, nothing to strip before release.

Step 1 matters as much as step 2: `utils_async` keeps its task table at module level and
`TradeExecutor.Records` accumulates, so without a fresh copy per harness tests leak into each
other.

### What is faked and what is real

| Module | | Why |
|---|---|---|
| `anno_interface` | **fake** | the seam; backed by `world.lua` |
| `generator/products` | **fake** | the real one loads JSON through the disk cache and scans game objects; the fake serves names from the same `product_info.json` |
| `mod_area_requests` | **hybrid** | see below |
| `utils_logger` | **fake** | the real one appends to a file per line |
| `anno_object_accessor`, `anno_object_inspector` | **stub** | required by the modules under test but unused on these paths |
| `mod_trade_planner_ll` | real | under test |
| `mod_trade_executor` | real | under test |
| `mod_ship_cmd` | real | thin, and exercised by every voyage |
| `utils_async` | real | the scheduler's interleaving is part of what is being tested |
| `utils_table` | real | pure |

### `mod_area_requests` is a hybrid, on purpose

The real module derives requested goods from four sources: residences, factories, construction, and
trade-union input replacements. Three need deep game state — population levels, factory consumption
tables, socketed items — so the fake lets a test declare that half directly, as `area.requests`.

The **construction** half is different: a flat list of 9 goods every island always requests, living
in production code (`AreaRequests.ConstructionGoods`, `mod_area_requests.lua:76-86`). So the
harness loads the real `mod_area_requests` first — it needs nothing from the game beyond
`Anno.Region_AreaID_To_OID`, which the fake world provides — captures it, then shadows the module
with a fake whose `All()` unions the declared requests with the **real** `Construction()`.

The fake also **passes `ConstructionGoods` straight through**, because `TradePlannerLL.Hubs` reads
it to resolve the `(hc)` marker. It did not, originally, and `(hc)` crashed under test while
working in the game — a fake that omits part of the real module's surface lets production code
tell the two apart, which is the one thing a fake here must never allow.

This is not a detail. Without it you can build an island holding 600 Bricks that requests none, a
shape the game cannot produce, and draw conclusions from it. That happened during development and
invalidated six scenarios.

## The world

`tests/lib/world.lua`. Plain data plus a `tick()`.

### Islands

`stock[guid]`, a `capacity`, and `water_points` the planner measures distances between.

`addGood` clamps to `[0, capacity]` as the game does — and **counts what it had to invent or
destroy** to do so, in `world.created[guid]` / `world.destroyed[guid]`. That counter is the point:
a mod bug that silently overfills an island shows up as a number rather than as nothing.

Islands can also `produce` and `consume` per tick, which is how you make one fill up while a ship
is sailing toward it.

### Ships

`ship.cargo` is keyed by **real slot**, 0-based, one entry per occupied slot, with gaps where slots
are empty.

`Anno.Ship_Cargo_Get` does **not** return that table. It converts to the game's cargo *vector*,
which is dense — occupied stacks only, keyed `0..count-1`, re-indexing on removal. Keeping the two
representations distinct in the fake is deliberate: conflating them is exactly the bug the real
code can have, and a fake that conflates them cannot catch it. See the cargo comment in
`trade_route_automation/anno_interface.lua`.

`World:load` imitates `CheatItemInSlot`: tops up a partial stack of the same good first, then takes
the lowest free slot, returning how much fit. It picks the slot itself because the real command
does — `Anno.Ship_Cargo_Set(oid, slot, cargo)` accepts a `slot` and never sends it.

Movement is a target and a speed: `Ship_MoveTo` sets both, each tick advances the ship along the
straight line, arrival stops it. Positions are floored, because game coordinates are integers and
the mod base62-encodes them into ship names.

## Driving time

Voyages are coroutines. `utils_async` resumes them, `mod_ship_cmd` parks them on
`async.await(function() return not Anno.Ship_IsMoving(oid) end)`, and `mod_trade_executor` also
yields bare `coroutine.yield()` to let the game settle.

`Harness:step()` is one tick of the whole thing:

```lua
local stats = self.async.tick();   -- resume coroutines, evaluate wait conditions
self.world:tick();                 -- ships sail, islands produce and consume
```

Order matters. The scheduler runs first so a task can issue `Ship_MoveTo` and mark the ship moving;
the world then advances it; next tick the task's wait condition sees the new position.

`Harness:run(maxTicks, onStep)` loops until `stats.running == 0 and stats.waiting == 0` and returns
the tick count. The 2000 default is far more than a voyage needs, so a test that hits it has hung —
`T.truthy(ticks < 2000)` catches that.

**Errors inside tasks are swallowed by the scheduler** (`Async.tick` catches them into
`task.state = "error"`). `Harness:taskErrors()` surfaces them. A test that does not check it will
pass happily while every voyage crashed.

## The `tradeExecutor_iteration_state` stand-in

`mod_trade_planner_ll` calls exactly one method on the iteration state:
`state:areaTradeDirection_Last(L, areaID, productGUID)` — "which way did this island last move this
good", used to decide whether an island is currently a requester or a supplier.

The real class lives in `mod_trade_planner_hl`, which drags in the map scanners, the disk cache,
`rxi/json` and `ui_cmds`. So `Harness.State` is a ~20-line stand-in holding a
`directions[areaID][guid]` table.

This is the one place a double re-implements production behaviour, deliberately: the method is a
lookup with no logic worth sharing. **If the state class ever grows logic the planner depends on,
extract it from `mod_trade_planner_hl` into its own module and use the real one** rather than
growing the stand-in.

## Known fidelity gaps

Places where a green unit test does not mean a working mod.

**Frame delay is not modelled.** In the game a read in the same frame as a write sees the old
state; the fake applies changes instantly. So the fake is *more forgiving* than reality, and a
missing `coroutine.yield()` in production code will not show up here. The contract suite covers
this one directly.

**Unit halving.** `Area_AddGood` and `Ship_Cargo_Set` divide by 2 on the way in, and special-case
`amount == 1 -> 2`. The fake works in displayed units throughout, so odd-amount rounding (issue #8)
is invisible.

**`mod_trade_planner_hl` is not covered.** The orchestrator loop, ship renaming, region caching and
rescan events are untested. Issues #2 and #11 were both found and fixed here without a test to
hold them, and #11b — the same nil-ship-list hole in `Ships_RenameAll` — is still open.

This gap grew when the **hub pass** was wired in: `tradeExecutor_iteration` now runs two passes,
and the rules that make that safe (the hub pass gets only the ships the main pass left, and
in-flight is recomputed between passes) live *here*, not in the planner. `tests/test_hubs.lua`
covers the planner half through `tests/lib/sim.lua`, which reimplements the two-pass loop rather
than calling it. See below.

**Requests are declared, not derived.** Residences, factories and trade-union replacements collapse
into `area.requests`. `AnnoInfo.Residence` and `AnnoInfo.Factory` return nil in the fake, so
`AreaRequests.Population` and `AreaRequests.Production` are never exercised.

**Capacity is one number per island.** The real `Area_GetGoodCapacity` is queried per good (and the
mod only ever asks about Wood, then applies the answer to everything). The fake stores one
`capacity`, so it cannot show issue #6, where a bad read returns a diagnostic table.

**No AI, traders, pirates or other players.** Only the player's islands and ships.

**Distances are straight lines** — as in the real planner, so this matches; neither knows about
land in the way.

## Extending

### Add an `Anno.*` function

Add it to `fake_anno` in `harness.lua`, backed by world state. Keep the signature identical to
`anno_interface.lua`, **including arguments the real one ignores** — production code must not be
able to tell the difference.

### Add world state

Add the field to the `World.new` spec with a sensible default, a reader, and — if it changes over
time — a line in `World:tick`. Add it to `World:describe` if it would help when reading a failure.

### Cover `mod_trade_planner_hl`

Needs four more doubles: `mod_map_scanner_hl` (`Areas` returning the table `Harness:areas()`
already builds), `mod_map_scanner`, `utils_cache` (in-memory `Get`/`Set`/`Exists`/`WriteTo`), and
`ui_cmds` (event tables). `rxi/json` and `iskolbin/base64` are pure Lua and load as they are.

That unlocks testing whole iterations rather than single dispatches, and would settle issues #2 and
#11. It is the largest remaining gap.

### Prove a suspected bug

The pattern that has worked: write the test asserting the **wrong** behaviour, `TODAY` in the name,
a comment pointing at the line. It passes, which proves the bug is real and reproducible. When the
fix lands the test fails loudly and you change it deliberately.

If the scenario needed to trigger it cannot occur in the real game, that is itself the finding —
say so in `possible_issues_*.md` and do not write the test.
