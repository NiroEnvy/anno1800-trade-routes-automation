# Contract test infrastructure — how a test gets into a running game

Enough to *extend* the in-game harness. To write a test you only need
[testing-integration.md](testing-integration.md).

## The problem

There is no way to attach a test runner to Anno. No test hook, no scripting console (that was a
separate mod), no way to call into the process from outside. The only channel is the one the mod
already has: **Lua running inside the game, and the filesystem**.

So a contract test run is a file drop. `make test/game` writes the suite next to the game; a
polling thread already inside the game notices, runs it, and the results come back as a log file
this side reads.

```
    dev machine                        game process
 ┌────────────────┐               ┌──────────────────────────┐
 │ make test/game │──── cp ──────▶│ _executor.lua polls      │
 │                │               │   lua/trade-automation/  │
 │                │               │      execute.lua         │
 │                │               │        │ dofile          │
 │                │               │        ▼                 │
 │                │               │   run.lua → t.lua        │
 │                │               │        │                 │
 │  read log ◀────┼─── log file ──┼── L.logger(game-tests)   │
 └────────────────┘               └──────────────────────────┘
```

## The executor

`trade_route_automation/_executor.lua`, described in full in
[in-game-testing.md](in-game-testing.md). In summary: a thread that every frame checks for
`lua/trade-automation/execute.lua` (relative to the game's working directory, the install root),
renames it to `.running` so a half-copied file is never run twice, `dofile`s it on its own thread,
and deletes it.

Two things about it matter here:

**It is off unless `lua/trade-automation/executor-enabled` exists.** A poller that runs any Lua
dropped at a known path is arbitrary code execution for anything that can write there — fine on a
dev box, not something to ship switched on. `make test/game` and `make install-script` both create
the marker; `make install-script/off` removes it and drops a `stopme`.

**It is required from `_main.lua`, not `_init.lua`.** `Shift+Alt+R` runs
`trade_route_automation_restart()`, a closure from the `_init.lua` chunk already in memory, so its
require list is frozen until `_init.lua` itself re-executes — which per `assets.xml` only happens
on the `SessionEnter` trigger. `_main.lua` *is* re-read from disk by `package_requireAll` on every
restart. Putting the require there is what makes the hotkey sufficient. There is a comment in
`_main.lua` saying so; do not "tidy" it back into `_init.lua`.

## What `make test/game` copies

```
tests/lib/t.lua            -> lua/trade-automation/t.lua
tests/game/game_env.lua    -> lua/trade-automation/game_env.lua
tests/game/contract_*.lua  -> lua/trade-automation/contract_*.lua
tests/game/run.lua         -> lua/trade-automation/execute.lua      <- triggers the run
```

`run.lua` is copied **last**, because the moment it lands the executor may pick it up — the other
files have to be in place first.

Adding a `contract_*.lua` therefore means touching three places: the `cp` line in the Makefile, and
the `package.loaded` reset and `require` lists in `run.lua`.

## `run.lua`

Three things it has to get right:

**Path.** The executor `dofile`s from the game's working directory, so the copied files are not on
`package.path`. It appends `lua/trade-automation/?.lua` before requiring anything.

**Fresh modules.** The game's Lua state outlives many runs, so `package.loaded` is cleared for
`t`, `game_env` and every `contract_*` first. Without that, a second run would use the first run's
copy of an edited assertion — the same trap `package_requireAll` exists to avoid on the mod side.
`T.reset()` likewise clears registered tests, which would otherwise accumulate across runs.

**Output.** `T.out` is repointed from `io.write` to the mod's logger, splitting on newlines because
the logger writes a line at a time. This is why `tests/lib/t.lua` has a `T.out` indirection at all
— it is the single thing the two suites had to negotiate.

## `game_env.lua`

The in-game counterpart to `harness.lua`. Offline, the harness builds a world from nothing; here
the world already exists and belongs to a real save, so this file is mostly about being careful
with it.

| | |
|---|---|
| `G.ship()` | finds and caches the `TRA_TEST` ship; raises with a useful message otherwise |
| `G.settle()` | three `coroutine.yield()`s, so a cheat command lands before a read |
| `G.emptyHold(oid)` | clears every slot index, then verifies; raises if anything remains |
| `G.load(oid, guids)` | one full stack of each, settling between so slot order is deterministic |
| `G.raw(suffix, oid)` | a raw text-source command against that ship |
| `G.note(fmt, …)` | a line into the results log |

`G.settle()` is the one that bites. Cheat commands do not take effect in the frame that issues
them, and an early version of the cargo experiment concluded "loading does nothing at all" purely
because it read too soon. Three frames rather than two: the margin is free, and a flaky contract
suite is worse than a slow one.

`emptyHold` clears **every slot index** rather than walking the cargo vector, because a vector key
is a position and not a slot. It is also the reason it can raise: if the hold is not empty
afterwards, something is wrong that a later test would only report confusingly.

## Constraints this environment puts on tests

**They mutate a real save.** Hence: only the `TRA_TEST` ship, hold emptied before and after,
island stock never touched. `TRA_TEST` does not match `^TRA_<region>` so the automation loop
ignores that ship and cannot race the suite.

**They are not hermetic.** The player's islands, the mod's own threads and any other mod are all
still running. Keep assertions to things that ship and that hold, and do not assume the world is
still as you left it between tests.

**They cannot be run in CI**, or on a machine without the game, or quickly. That is why the split
exists at all: put everything that can live in the unit suite there, and keep this one to claims
only the game can settle.

**Failure reporting is a log file.** No exit code reaches the Makefile — `make test/game` prints
where to look and stops. Automating the read-back would need the game to write a machine-readable
result and this side to poll for it; not worth it while a run needs a human to set up a test ship
anyway.

## Extending

### A new contract area

Copy the shape of `contract_cargo.lua`: `require("t")` and `require("game_env")`, then
`T.test(...)` blocks that each start from `G.emptyHold(G.ship())`. Register in the three places
above.

Good candidates, all currently unverified claims the fake makes:

- **areas** — does `Area_AddGood` really clamp at capacity, and does it report what was lost?
  (Issue #5 rests on assuming it does.)
- **units** — what `Area_GetGoodCapacity` returns for a good an island has never held, and whether
  the odd-amount halving (issue #8) actually loses anything.
- **ship movement** — whether `Ship_IsMoving` is false at the exact tick a ship arrives, which
  `mod_ship_cmd.MoveShipToAsync` depends on.

### Why `tests/game` is excluded from `make typecheck`

Those files `require("t")` and `require("game_env")` — names that only exist once
`make test/game` has copied them into `lua/trade-automation/`. Analysed in the repo they resolve to
`tests/lib/t.lua` under a second name, which produces `different-requires` and `duplicate-set-field`
noise about a layout that is not the one they run in.

They are still covered by `make syntax` and `make lint`, which is the part that would catch a real
mistake. `tests/game` is listed in `workspace.ignoreDir` in `.luarc.json` for this reason.

### Sharing more with the unit suite

`tests/lib/t.lua` is copied verbatim and must keep loading under the game's Lua. Anything added to
it has to avoid `io.*` at load time and anything `luac5.4 -p` accepts but the game's runtime does
not. `tests/lib/goods.lua` is *not* copied — it reads a JSON file by relative path from the repo
root — so in-game tests write GUIDs inline.
