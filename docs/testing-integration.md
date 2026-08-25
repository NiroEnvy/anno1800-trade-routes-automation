# Contract tests — running and writing

These run **inside the running game**, against the real Anno APIs.

Every assertion here is a claim that `tests/lib/world.lua` makes about the game. If one fails, the
fake is lying and the unit suite is testing fiction. That is the entire point of them — the unit
suite is fast and thorough and completely unable to notice when its own premises stop being true.

Shared conventions are in [testing-shared.md](testing-shared.md); the delivery machinery is in
[testing-infra-contract.md](testing-infra-contract.md).

## What you need

1. **The game running**, in a session, with the mod loaded.
2. **A trade route named exactly `TRA_TEST`**, with **one ship of at least 3 slots** assigned.
   - The name matters: the automation loop matches `^TRA_<region>` (`TRA_OW`, `TRA_NW`, …), so
     `TRA_TEST` is invisible to it and cannot race the tests for that ship.
   - Three slots is the minimum that can distinguish "cleared the slot I asked for" from "cleared
     the first occupied one" — with two goods those look identical.
3. **The executor thread running** — see [in-game-testing.md](in-game-testing.md). After
   `make install` it starts on the next `Shift+Alt+R`.

## Run

```sh
make test/game
```

That copies the suite next to the game and drops the runner where the executor picks it up, within
a frame. Results:

```
<Documents>/Anno 1800/log/TrRAt_<profile>_game-tests.log
```

Output is the same format as the unit suite:

```
running 10 contract tests against the live game
  ok   cargo: a cheated stack shows up after a frame
  ok   cargo: ClearSlot addresses a real slot, not a vector position
  ...
10 passed, 0 failed
the fake in tests/lib/world.lua matches the game on every checked point.
```

## Add a test

```
tests/game/
  run.lua              entry point; becomes execute.lua
  game_env.lua         finding the ship, settling frames, cleanup
  contract_cargo.lua   the assertions
```

Append to an existing `contract_*.lua`, or add a file and register it in **three** places:

1. the `package.loaded` reset list in `tests/game/run.lua`
2. the `require` list just below it
3. a `cp` line in the `test/game` Makefile target

## Rules

**Settle after every mutation.** A read in the same frame as a write sees the old state. `G.settle()`
yields three frames. Forgetting this is not a subtle failure — an early version of this suite
concluded "loading cargo does nothing at all" for exactly this reason.

```lua
Anno.Ship_Cargo_Set(ship, 0, { Guid = BRICKS, Value = 50 });
G.settle();
local cargo = Anno.Ship_Cargo_Get(ship);
```

**Start from a known hold.** Call `G.emptyHold(ship)` at the top of every test rather than trusting
what the last one left. It raises if it cannot empty the ship, which is a better failure than a
mystery three tests later.

**Only ever touch the `TRA_TEST` ship.** `G.ship()` is the only sanctioned way to get an oid.

**Never touch island stock.** Cargo is cheated into the hold and cleared out again; nothing here
should change a save in a way the player would notice.

**Test the contract, not the logic.** Belongs here: indexing, units, ordering, what a command
actually does, what an API returns for a missing thing. Does not: planner behaviour, which the unit
suite covers far faster and without a running game.

**Write down what you measure.** A contract test that discovers something belongs in the comment
next to the code it governs — the cargo semantics live at the top of the cargo section in
`trade_route_automation/anno_interface.lua` — and, if it changes a conclusion, in
[possible_issues_2026-08-22.md](possible_issues_2026-08-22.md).

## `game_env` API

```lua
local G = require("game_env")
```

| | |
|---|---|
| `G.ship()` | the `TRA_TEST` ship's oid; raises with a useful message if there is none |
| `G.settle()` | yield three frames so a cheat command lands |
| `G.emptyHold(oid)` | clear every slot index, then verify; raises if anything remains |
| `G.load(oid, {guid, …})` | one full stack of each, in order, settling between |
| `G.raw(suffix, oid)` | a raw text-source command against that ship |
| `G.note(fmt, …)` | write a line into the results log |

## When a contract test fails

It means one of three things, in rough order of likelihood:

1. **the test ship is wrong** — fewer than 3 slots, or the route is misnamed, or another mod is
   moving it;
2. **the fake is wrong** — fix `tests/lib/world.lua` or `tests/lib/harness.lua`, then re-run
   `make test` and see which unit tests were relying on the false premise;
3. **the game changed** — a patch or another mod. Update the comment in `anno_interface.lua`, then
   (2).

A failure is a real finding either way. Do not adjust the assertion to make it pass without working
out which of the three it was.
