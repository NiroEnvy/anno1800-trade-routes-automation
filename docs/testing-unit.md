# Unit tests — running and writing

The mod's planning and execution logic under plain `lua5.4`, against a fake Anno 1800. No game.

Shared conventions (assertions, GUIDs, naming) are in [testing-shared.md](testing-shared.md). How
the fake is built is [testing-infra-unit.md](testing-infra-unit.md) — you do not need it to write
a test.

## Run

```sh
make test              # everything
make test T=packing    # only tests whose name contains "packing"
lua5.4 tests/run.lua   # same thing without make
```

**Run from the repo root.** `tests/lib/goods.lua` opens `trade_route_automation/generator/…` by
relative path. Exit code is non-zero on failure.

## Layout

```
tests/
  run.lua                 registers every test file, applies the name filter
  lib/t.lua               framework, shared with the contract suite
  lib/world.lua           the fake game world
  lib/harness.lua         swaps fakes in, hands back the real modules
  lib/goods.lua           real product GUIDs and names
  test_world.lua          the fake itself
  test_executor.lua       mod_trade_executor
  test_planner.lua        mod_trade_planner_ll
  test_in_flight.lua      Ships_StockInFlight
  test_force_unload.lua   Ships_ForceUnloadStoppedShips
```

## Add a test

Append to whichever file matches the module. Build a world, wrap it in a harness, act, then look at
what the world became:

```lua
T.test("planner: a city above o2 stops asking", function()
    local h = Harness.new(world());
    h.world:setStock(SIPHINGTON, G.Beer, 250);        -- arrange

    local srt = h.TradePlannerLL.SupplyRequest_Build(  -- act
        h.L, "OW", {}, h:areas(), h:state());

    T.nil_(srt.Request[SIPHINGTON][G.Beer], "no longer requested");  -- assert
end);
```

Most files define a local `world()` helper returning a fresh `World.new{...}` — reuse it rather
than inventing a new island layout per test.

**New file:** create `tests/test_<thing>.lua` and add `"tests/test_<thing>"` to the `files` list in
`tests/run.lua`.

## Rules

**Every island requests the 9 construction goods.** `AreaRequests.Construction` gives Wood, Timber,
Bricks, Steel Beams, Windows, Reinforced Concrete, Elevator, Steam Motors and Aluminium Profiles to
every island, always, and the fake models this. So there is no such thing as a pure supplier of a
construction good. For a producer/consumer split use a consumer good (Beer, Sausages, Bread, Soap,
Work Clothes) or something nobody on the map consumes (Alpaca Wool).

`construction = false` turns it off, but say in a comment why — you are then testing a game that
does not exist.

**Do not build states the game cannot produce.** Automation ships are never touched by the player
and every trade today is one good between two islands, so cargo cannot appear in a hold mid-voyage.
A test that injects some proves a mechanism while looking like it proved a bug.

**Assert on the world, not on calls.** There are no call recorders and no expectations to verify.
Set up, run, then read stock levels, cargo, ship positions. If you want to assert "and then it
called X", assert on what X *did*.

**Check `h:taskErrors()` after running.** The async scheduler swallows errors raised inside tasks —
a voyage that crashed looks like a quiet no-op unless you ask.

**A cargo vector key is not a slot number.** `ship.cargo` in the world is keyed by real slot;
`Anno.Ship_Cargo_Get` returns the game's dense vector. See the cargo comment in
`trade_route_automation/anno_interface.lua`.

## Harness API

`Harness.new(world)` gives fresh copies of every mod module, so `utils_async` task state and
`TradeExecutor.Records` never leak between tests.

| | |
|---|---|
| `h.world` | the `World` you passed in |
| `h.L` | logger, collecting into memory |
| `h.Anno` / `h.async` | the fake game interface / the real scheduler |
| `h.TradeExecutor` / `h.TradePlannerLL` | the real modules under test |
| `h:areas()` | the `areas` table the planner expects, built from the world |
| `h:availableShips(oids)` | ships as `mod_trade_planner_hl` passes them down; all by default |
| `h:state(directions)` | stand-in for `tradeExecutor_iteration_state`; `directions[areaID][guid] = "In"\|"Out"` |
| `h:step()` | one tick: scheduler, then world |
| `h:run(maxTicks, onStep)` | tick until every task finishes; returns ticks spent |
| `h:taskErrors()` | errors the scheduler swallowed |
| `h:logsMatching(s)` / `h:dumpLogs()` | log lines |

`onStep(tick, stats)` runs after each tick — for watching something mid-voyage:

```lua
local peakSlots = 0;
h:run(2000, function()
    peakSlots = math.max(peakSlots, h.world:slotsUsed(900));
end);
```

## World API

```lua
World.new {
    region = "OW",
    construction = true,           -- default; every island requests construction goods
    areas = {
        { id = 10, name = "Sassenberg", capacity = 1000, at = { x = 100, y = 100 },
          stock = { [G.Beer] = 100 },
          requests = { G.Bread },          -- goods this island consumes
          production = { [G.Beer] = 5 },   -- units per tick
          consumption = { [G.Bread] = 4 } },
    },
    ships = {
        { oid = 900, name = "a", slots = 6, speed = 400, at = { x = 100, y = 100 } },
    },
}
```

Reads: `w:stock(areaID, guid)`, `w:cargo(oid)` (guid → amount), `w:slotsUsed(oid)`,
`w:total(guid)` (islands + holds), `w:describe()` (printable board).

Writes: `w:setStock`, `w:addGood`, `w:load(oid, guid, amount)`, `w:clearSlot(oid, realSlot)`,
`w:moveTo`, `w:tick`.

`w.created[guid]` / `w.destroyed[guid]` count units the world had to invent or destroy to stay
inside `[0, capacity]` — how you catch goods vanishing on an overfull unload:

```lua
T.eq(h.world:total(G.Beer), before, "conserved");
T.deep_eq(h.world.destroyed, {}, "nothing destroyed");
```

## Planner thresholds

Most planner tests use `capacity = 1000`, making the thresholds:

```
o2 = min(200, cap * 0.2)           = 200   -- an island requests below this
o6 = min(o2 + 300, 500, cap * 0.6) = 500   -- and asks for this much
o4 = min(225, cap * 0.4)           = 225
o8 = min(o4 + 300, 525, cap * 0.8) = 525   -- a consumer exports above this
```

Minimum transfer is 25 units; anything smaller is dropped rather than shipped.
