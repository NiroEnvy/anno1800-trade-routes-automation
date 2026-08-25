# Supply and request — how the mod decides what should move

`supplyRequest_Build` in `trade_route_automation/mod_trade_planner_ll.lua`.

This is the core of the mod. Everything downstream is logistics: orders are (supplier, requester,
good) triples drawn from this table, commands assign ships to orders, and the executor sails them.
If this function is wrong, the rest is efficiently wrong.

It runs once per cycle and produces two tables:

```
Supply[areaID][goodID] = amount this island can spare
Request[areaID][goodID] = amount this island wants
```

Nothing else in the mod decides what should move.

The same function also builds the **hub pass**'s tables, under a `hubMode` argument: same
machinery, a different target and gate for the ask, and hubs held out of `Supply` so the pass can
only move goods *towards* them. See [hubs.md](hubs.md); everything below describes the main pass.

## The four levels

Every decision is made against four stock levels, derived from one number: the island's total
capacity for a single good. `TradePlannerLL.Thresholds(areaCap)`.

| level | what it means |
|---|---|
| **o2** | below this, an island asks. Also the minimum ask for a good it consumes |
| **o4** | a **producer** exports what it holds above o4 — its own working buffer |
| **o6** | a **consumer** refills up to o6 |
| **o8** | a **consumer** exports what it holds above o8 |

Capacity is not a free parameter. The smallest city holds 75, raising it is not an early-game
priority, and it climbs in steps of 50/75/150 — so every row below is a size a real island has.

```
   cap     o2     o4     o6     o8 | band(o6-o2)  o8-o6
    75     15     30     45     60 |       30       15
   125     25     50     75    100 |       50       25
   150     30     60     90    120 |       60       30
   250     50    100    150    200 |      100       50
   400     80    160    240    320 |      160       80
   650    130    225    390    520 |      260      130
  1000    200    225    500    525 |      300       25
  2000    200    225    500    525 |      300       25
```

Pinned by `thresholds: the ladder, so any tuning shows up as a diff here`.

Two things worth reading off that table:

- **`o6 - o2` is the amplitude an island swings through** — it fills to o6 and is drained to o2.
  Below capacity ~750 that band is `0.4 × cap`; above it, it is pinned at 300. That is what the
  `+ 300` terms in the formula are for: capping the swing on large islands, not setting a supply
  level.
- **`o8 - o6` collapsing to 25 on large islands does not matter.** It looks alarming, and an
  earlier draft of issue #14 blamed it, but a consumer never sits at `o6` *and asks* — it sits
  there and waits. The column that governs stability is the distance from where an island **stops**
  to where it **starts asking**:

| cap | consumer (`o8 - o2`) | producer (`o4 - o2`) |
|---|---|---|
| 75 | 45 | 15 |
| 250 | 150 | 50 |
| 650 | 390 | 95 |
| 1000 | 325 | **25** |

The producer column is the thin one, and it is the only edge left in this ladder: `o2` clamps at
200 but `o4` at 225, so a capacity-1000 producer stops one minimum transfer above the asking line.
It is self-limiting — a producer refills itself, and one inbound delivery flips it to a consumer
with the roomy `o8` floor — but it is what a future tuning of `o4_cap` would target. Pinned by
`roles: PROPERTY -- how much headroom that gap actually leaves`.

`_minTransfer = 25` is a separate floor: nothing under 25 units is worth a cargo slot. On the
supply side it does real work — an island 20 units above its floor advertises nothing rather than
sailing for 20. On the request side it almost never bites, because the smallest ask an island can
raise is its own band (`o6 - o2`), 30 units even on the smallest island. What it still catches is
in-flight subtraction: an island that is short but already has a ship inbound computes a small
remainder and stays quiet.

## Producer or consumer

The planner never observes production. It sees three things:

1. **does the island request the good** — `AreaRequests.All`, from buildings and residences.
   Every island carries a standing request for the nine construction goods, so Wood, Bricks,
   Timber and friends are requested *everywhere*.
2. **how much it holds** — `Area_GetGood`, less anything already promised away.
3. **which way the good last moved** — the direction memory in
   `mod_trade_planner_hl.lua`'s `tradeExecutor_iteration_state`.

That third one is how production is inferred:

```lua
local isRequester = _lastTrade_direction == TradeDirection_In;
```

**producer = not requester.** An island that last *sent* this good is treated as producing it; one
that last *received* it is treated as consuming it. It is a single bit, rewritten by every voyage,
and it is the only thing separating the two roles — see
`roles: the direction memory is the only thing separating a supplier from a consumer`, where the
same island with the same 400 units holds all of it or gives away 175 depending purely on that
bit.

An island that requests nothing and holds stock is a pure producer: it offers **everything**, with
no threshold applied, because it never uses any itself.

## The decision, as intended

```
island does not request the good   ->  Supply = all of it
island requests it, last move In   ->  Supply = stock - o8       (if that clears _minTransfer)
                                       Request = o6 - stock      (if stock < o2)
island requests it, last move Out  ->  Supply = stock - o4       (if that clears _minTransfer)
                                       Request = o6 - stock      (if stock < o2)
```

Two properties hold this together.

**The floor an island exports down to is the level that qualified it to export.** Having exported,
it is nowhere near asking again — that is the headroom table above.

**The request is an amount, not a level.** An island asks for the shortfall against `o6`, so a
delivery lands it *on* `o6` rather than overshooting to `o6 + whatever it was already holding`.
That matters because overshooting past `o8` re-qualifies it to export what it has just received.
It is also what `Request` has always meant to its three readers — `SupplyRequest_ToOrders` spends
it via `math.min(cap, SupplyAmount, RequestAmount)`, and the packing loop clamps against it and
decrements it.

Since both floors sit strictly above `o2`, an island can never both supply and request the same
good in one cycle, and no separate high-water gate is needed: `surplus >= _minTransfer` already
implies `stock > floor`.

## What this used to do, and what fixing it was worth

Until 2026-08-23 the implementation departed from the above in two ways, and the two compounded.

**1. Everything exported down to `o2`.** `_surplus` was computed once, above the branch, as
`_stock - o2`, so `o4` was never referenced at all and a consumer cleared by the `o8` gate still
drained to `o2`. Since `o2` is *also* the level at which asking starts, every export finished one
consumption tick from a fresh request. Fill to o6, drain to o2, repeat.

**2. Everyone asked for `o6` as a level.** The request written to the table was a flat `o6`
regardless of what the island already held, and every reader spends it as a quantity — so an
island holding 199 of a capacity-1000 good was sent 500 and landed on 699, which is above
`o8 = 525`, which re-qualified it to ship 174 straight back.

Measured: Wood was 92 of 239 voyages in a live save with every island both sending and receiving
it. In the *static* four-island test region, where nothing is produced or consumed and only 770
units are genuinely short, the planner moved **1000** units and used one island as a staging post
(handed 500, shipped 435 back out).

Fixing only the floor — the candidate fix originally proposed in issue #14 — still moved all 1000
units; the staging post just handed back 125 instead of 435. Both halves were needed. With both,
the same region moves **770** units, settles a cycle earlier, and no island both sends and
receives. Issue [#14](possible_issues_2026-08-22.md).

A two-tier ask (`o2` for an island that has just exported, `o6` otherwise) was tried as a third
ingredient and rejected: it moves less only because it stops filling islands, settling the region
at `o2` — the level at which asking starts. The deficit is what removes the oscillation.

The `- 15` deadband that used to sit in the consumer branch is gone. It was one minimum island's
`o2` (75 × 0.2), and `_minTransfer` already withholds more.

## In-flight

Both tables are adjusted for goods already on the water, so consecutive cycles do not dispatch
against the same shortage. A voyage still sailing *to its pickup* counts at **both** ends — removed
from the source that promised it away, added to the destination already expecting it. Once loaded
it counts only at the destination, because the source's real stock has already dropped.

Counting only the source is what let four cycles in a row dispatch against one request: 950 Bricks
arrived at an island that asked for 360 and had room for 520. Fixed 2026-08-23,
[#15](possible_issues_2026-08-22.md).

## Reading the logs

The per-area line is emitted for every (island, good) considered:

```
Area C6 (id=8962) Wood stock=946 (+0) (-0) request=200 (reasons=[Production/Sawmill,Construction])
```

`(+n)` is inbound in flight, `(-n)` outbound. `reasons` is why the island wants it at all.

`request=` is the real ask — the shortfall against `o6`, less anything already inbound. It printed
a discarded variable until 2026-08-23, which is how issues #14 and #15 came to be found in the
first place. Issue #16.

## Tests

- `tests/test_thresholds.lua` — the ladder, the headroom properties, and the role × stock-band
  matrix
- `tests/test_scenarios.lua` — whole regions over many cycles; see
  [testing-scenarios.md](testing-scenarios.md)
- `tests/test_in_flight.lua` — the in-flight adjustments
