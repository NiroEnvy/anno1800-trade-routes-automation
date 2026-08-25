# Hub cities — the second pass

A **hub** is an island the player marks by a suffix on its city name:

| marker | collects |
|---|---|
| `(h)` | every good in play in the region |
| `(hc)` | construction goods only — a city actively being built |

Hubs solve three things the main loop cannot: absorbing region-wide oversupply, staging goods for
cross-region trade the automation cannot do itself, and feeding a build site.

Wired into `tradeExecutor_iteration` on 2026-08-24. The pass is gated on a hub existing, so a
region without one costs a name scan per cycle and nothing else — no extra game queries.

## Shape

The hub pass runs **after** the main loop, on **only the ships the main loop left idle**. Filling a
warehouse must never compete with a genuine shortage.

Three things separate it from the main pass:

1. **Only hubs appear in `Request`.** `SupplyRequest_ToOrders` walks `Request` and matches against
   `Supply`, so this alone confines the pass to voyages that *end* at a hub. No other wiring.
2. **Hubs never appear in `Supply`** during the pass, so it cannot move goods hub-to-hub or back
   out. Redistribution is the main pass's job — which is what makes a central hub a reseller
   rather than a black hole.
3. **Nothing else.** Donors export down to the same `o8`/`o4` floors the main pass uses.

## The target is not on the ladder

A hub holds to **90% of capacity**. That is deliberately not an `o2/o4/o6/o8` level: the ladder
describes an island that *lives off* the good, and a hub does not consume what it collects.

| capacity | o8 | hub target | gap |
|---|---|---|---|
| 1000 | 525 | 900 | 375 |
| 3000 | 525 | 2700 | **2175** |

The ask is a **shortfall**, never a level — `HubTarget(cap) - stock - incoming`. Writing it as a
level is the mistake that produced the Wood sawtooth; see
[#14](possible_issues_2026-08-22.md) and [supply-request.md](supply-request.md).

## Donors

A donor exports down to the floor that qualified it to export — `o8` if its last movement was
inbound, `o4` if outbound — exactly as in the main pass. There is no hub-specific floor.

**An island that does not consume the good has no floor at all.** It takes the
`not doesAreaRequestProduct` branch and offers every unit it holds. Since that is the whole of the
oversupply case, most hub traffic never touches a floor.

### A higher hub-pass floor was tried and dropped

The argument for one: the main pass drains an island only when somebody is genuinely short,
whereas the hub pass drains it to feed a warehouse, and `o4 = 225` sits just 25 units above the
asking line `o2 = 200` on a big island (issue 14b). So raising the hub-pass floor to at least `o6`
looked like cheap insurance.

Measured, it buys nothing where it was aimed:

- **Producers, the islands `o4` applies to, never re-request anyway.** The request gate is
  `stock < o2`, so an island left on 225 asks for nothing — something has to *eat* through those
  25 units first. A producer refills past the line under its own steam. At break-even it rests on
  225 forever and never crosses.
- **Oversupply donors never reach the floor branch**, so the setting was a no-op there — three
  different floors produced byte-identical runs.
- **Net consumers do pump, and a higher floor only halves it** — 300 units hauled back instead of
  600, still multiple round trips. It treats the symptom.

| donor's net rate | round trips | units hauled back |
|---|---|---|
| **+1/tick** (produces it) | 0 | 0 |
| 0/tick (break-even) | 0 | 0 |
| −1/tick (net consumer) | 3 | 600 |

Pinned by `hubs: PROPERTY -- only a NET CONSUMER pumps`.

The real finding is a **refinement to 14b**, and it is not about hubs. "Producer" in this planner
means *last movement was outbound*, not *produces the good*. So the `o4`/`o2` knife edge only
bites an island that is floored as a producer while being a net consumer. A true producer is
immune — which is likely why 14b has never been seen in the field despite the arithmetic being
plainly there. A net consumer is drained to 225 by the **main** pass too, whenever anyone else is
short; the hub pass only does it more often, on free ships. If that ever needs fixing, the target
is 14b itself, not a hub-pass floor.

## What was measured

`tests/test_hubs.lua`, via `tests/lib/sim.lua` with `hubs = true`.

**Ingesting oversupply.** Two islands sitting on wool neither consumes, one small consumer, a
3000-capacity hub: 1350 units into the hub on idle ships, 150 units of real deficit served by the
main pass, **zero round trips**, both donors emptied.

**`(hc)`.** A 2000-capacity build site wanting 1800, two donors holding 900 each: the site reaches
1350 and both donors rest on `o4 = 225`. Nothing returns, because a static world never gets
hungry — and per the property above, that is what makes it safe, not the floor.

**A relay is not a round trip.** Producer → hub → consumer: the hub both receives and sends, so
`oscillations()` flags it, while `roundTrips()` does not. Every delivery *into* the hub rides the
idle-ship pass, so the collection leg is effectively free and the outbound leg is one the main
pass would have flown anyway.

> `oscillations()` — "an island both received and sent" — is the wrong measure for a hub region,
> because a hub does that by design. Use `roundTrips()`: the same good going A → B and later
> B → A. That is the needless work.

## Known limits

- **A hub cannot collect a good no island in the region requests.** The goods the planner
  considers are the union of the request tables, so a good nobody consumes anywhere is invisible —
  including to a hub whose purpose is to absorb it.
- **Capacity is read for Wood only** and applied to every good ([#6](possible_issues_2026-08-22.md)).
  The main pass hides this because `o2`/`o4` clamp at 200/225; the hub target uses `cap * 0.9` raw,
  so a bad capacity read decides everything.
- **Driving an island to 90% parks it near full**, which is where `dst_unload`'s missing
  free-capacity check destroys the overflow ([#5](possible_issues_2026-08-22.md)).

## Not yet decided

Whether the idea generalises — every island is a hub, with marked ones filled first and the rest
topped up only when a good is genuinely oversupplied region-wide. The leftover in `Supply` after
the hub pass is already that oversupply measure.
