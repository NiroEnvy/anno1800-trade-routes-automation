# Scenario tests — does the system behave, not is the arithmetic right

`tests/test_scenarios.lua`, driven by `tests/lib/sim.lua`.

Every other test in the suite checks one step: this stock produces that request, this hold holds
those slots. Scenarios check the thing those steps add up to. Put a region into a state, let the
automation run for many cycles, and look at what it did.

They exist because the Wood oscillation shipped past a suite of 65 passing tests. Nothing in it
ran long enough to see goods going round in circles.

## What they measure

Three properties, which are the three things the mod is for:

| goal | measured as |
|---|---|
| 1. islands have enough to live | final stock against `o2` |
| 2. minimise ship movements | units and voyages spent, against the least that had to move |
| 3. exporters export as soon as they may | the cycle the first voyage left on |

## Static worlds

Most scenarios have **no production and no consumption**. That is deliberate: the only thing that
can change any island's stock is a trade the mod chose to make, so the region *must* reach a fixed
point — a cycle that dispatches nothing. "It never settled" is then proof, not suspicion, and no
argument about consumption rates can muddy it.

Dynamic worlds are supported (`production` / `consumption` per tick on an area) but a fixed point
is no longer guaranteed, so assert on flows rather than on settling.

## Writing a case

Cases are data. Declare a world and what should be true afterwards:

```lua
{
    name = "one producer fills three empty consumers, then stops",
    areas = { area(SUP, "sup", 2000, 100, 1500, false),
              area(BIG, "big", 1000, 700,    0, true) },
    ships = { ship(901, "a", 100) },

    settles       = true,
    firstVoyageAt = 1,
    stockAtLeast  = { [BIG] = 200 },
    noOscillation = true,
    maxUnits      = 1300,
}
```

| field | asserts |
|---|---|
| `settles` | a cycle passed with nothing dispatched |
| `firstVoyageAt` | which cycle the first voyage left on |
| `stock` | exact final stock, per island |
| `stockAtLeast` | lower bounds, per island |
| `noOscillation` | no island both received and sent the good |
| `units` / `maxUnits` | total units moved — exact (a pinned baseline) or a budget |
| `check(r)` | anything else; gets the full result |

`cycles` defaults to 25. `mode` is `"sequential"` (default) or `"overlapped"`.

Two more spec fields, both for hub runs:

| field | does |
|---|---|
| `hubs = true` | run the hub pass each cycle, on whatever ships the main pass left idle |
| `runAllCycles = true` | do not stop at the first quiet cycle |

`runAllCycles` matters whenever an island produces or consumes. `settled` only means something in
a static world; once stock moves on its own, a quiet cycle is just a lull, and stopping there
freezes the clock so nothing ever gets hungry. An early hub experiment concluded "no problem here"
purely because it stopped too soon.

## The result object

`check = function(r)` receives everything the run recorded. The useful primitive is the
per-island view:

```lua
r:flow(areaID, good)   -- { {direction="In"|"Out", good, iteration, amount}, ... }
```

every movement in or out of one island for one good, in cycle order. Built on it:

| | |
|---|---|
| `r:totals(area, good)` | units in, units out |
| `r:reversals(area, good)` | times the island changed its mind about which way the good travels |
| `r:oscillations()` | every (island, good) that both received and sent — the detector |
| `r:roundTrips(good?)` | the same good going A → B and later B → A |
| `r:unitsIn(phase)` | units moved by one pass, `"main"` or `"hub"` |
| `r:units()`, `r:voyages()` | scheduling cost |
| `r:stock(area, good)` | final stock |
| `r.settled`, `r.settledAt`, `r.firstVoyageAt`, `r.perCycle` | convergence |
| `r:summary()` | one line, for assertion messages |
| `r:fingerprint()` | stable description of what was dispatched, for comparing runs |

### Which detector to use

`oscillations()` is the right test for a hub-free region: in a static world an island that both
received and sent the same good did wasted work.

**It is the wrong test once a hub is involved**, because a hub receives and sends by design — it
collects on idle ships and resells from the middle. Use `roundTrips()` there: the same good going
back where it came from. A relay (`producer → hub → consumer`) shows up as an oscillation and as
zero round trips, and that gap is the whole point.

Every trade also carries `t.phase` (`"main"` or `"hub"`), so a check can assert which pass moved
something — for instance that every delivery *into* a hub rode the idle-ship pass.

## Sequential vs overlapped

**sequential** — each cycle's voyages finish before the next is planned. Deterministic, and
isolates the planner's decisions from ship timing. Use it for anything about *what* should move.

**overlapped** — voyages stay in the water across cycles, so `Ships_StockInFlight` decides whether
the planner dispatches against a shortage it has already addressed. This is how the mod really
runs, and it is where the n5 oversupply lived. Use it for anything about *when*.

## Determinism

`scenario: the same starting state dispatches the same voyages every run` runs an identical world
four times and compares fingerprints. Areas and goods are walked with `pairs`, whose order is
undefined, so without this nothing else measured here would mean much.

It passes: the command sort carries a full tie-breaker chain — distance, ship, source,
destination, good — so nothing downstream depends on table order.

## Current state

Seven cases, all passing. One is named `PROPERTY VIOLATED` and pins a defect rather than desired
behaviour: in a static region of four equal islands, one is handed 500 units and ships 435 straight
back out, moving 1000 units to place 770. It is a *staging post* rather than a true oscillation —
the planner drains the nearest source to `o2`, which makes that island short, so the next cycle
refills it from further away.

Pinned as exact numbers so the fix in [supply-request.md](supply-request.md) shows up as a
measurement rather than an opinion.
