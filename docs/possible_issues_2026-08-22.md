# Possible issues — found 2026-08-22

Found while reading the code before the ship-packing change, then re-checked against the test
harness in `tests/`.

**Split into open and fixed on 2026-08-24.** Every entry below was re-read against the code at
`57733a3` on that date; line numbers are as of that commit. Numbers are stable and never reused —
`docs/testing-infra-unit.md` and `docs/supply-request.md` both cite them.

Open entries are marked:

- **proven** — a passing test in `tests/` demonstrates the wrong behaviour. Run `make test`.
- **read-only** — spotted by reading. Not reproduced. Treat as a lead, not a fact.

---

# Open

## 5. Goods can be created or destroyed at the load/unload boundary — *read-only*

`docs/todos.md` item 3.3, restated with locations.

- **Created:** `mod_trade_executor.lua:286` does `Area_AddGood(region, aSrc, g.GoodID, -amount_to_load)`
  with no check that the island still holds it. Planning happens up to a full iteration before
  loading.
- **Destroyed:** `dst_unload` (`mod_trade_executor.lua:164`) adds the whole cargo to the
  destination with no free-capacity check.

On the destroyed side the planner's thresholds make this unlikely *by construction*: a request is
raised only when `stock < o2` and asks for the shortfall up to `o6`, and since `o2 ≤ 0.2·cap` and
`o6 ≤ 0.6·cap`, free space at planning time exceeds the ask. The real exposure is **drift during
transit**: the destination produces the same good itself and fills up while the ship sails.

Ship packing does not change this per-good — same amount per good, just more goods per voyage.

`tests/lib/world.lua` counts every clamped unit in `world.created` / `world.destroyed`, so a
scenario with a nearly-full destination would prove or disprove this quickly.

---

## 6. `Area_GetGoodCapacity` can return a table instead of a number — *read-only*

`anno_interface.lua:135-146`

On a bad read it returns a diagnostic table `{ got=, orig=, args= }`. `mod_trade_planner_hl.lua:532`
stores it straight into `area.capacity`, and `mod_trade_planner_ll.lua:396` does
`areaData.capacity or 75` — a table is truthy, so the `75` fallback never fires and the following
arithmetic in `Thresholds` throws. Same shape at `:530` and `:909`.

The iteration is wrapped in `xpcall` (`mod_trade_planner_hl.lua:537`), so this surfaces as a whole
iteration skipped with an arithmetic error in the log, not as an obvious failure.

**Two further details, found on the 2026-08-24 re-read:**

- The guard is `if cap >= 2147483647 or cap < 0 or cap == nil`. The `nil` test is **last**, so a
  non-numeric read throws "attempt to compare nil with number" on the first clause and the
  diagnostic table is never built. The `cap == nil` branch is dead.
- `capacity` is read for GUID `120008` (Wood) **only**, then used as the capacity for *every* good.

`tests/lib/harness.lua` stores one number per island, so the fake cannot show this — noted in
`docs/testing-infra-unit.md`.

---

## 7. `Anno.Ship_Cargo_Set` takes a `slot` argument it ignores — *read-only, downgraded*

`anno_interface.lua:271-278`

Signature is `Ship_Cargo_Set(oid, slot, cargo)`; the command built is
`CheatItemInSlot(guid, value/2)` — no slot. The game picks the slot.

**No longer a trap, just dead weight.** Since 2026-08-23 note 3 of the SHIP CARGO block in
`anno_interface.lua` states the argument is ignored, the doc comment on the function repeats it,
and `tests/game/contract_cargo.lua` pins the real behaviour (lowest free slot, tops up a partial
stack of the same good first). The remaining issue is that callers still pass a meaningless index
(`mod_trade_executor.lua:285` passes a loop counter) and the fake must keep accepting it.

Deliberately not "fixed": dropping the parameter changes every call site and the harness signature
for no behaviour gain.

---

## 8. Odd amounts lose half a unit — *read-only*

`anno_interface.lua:114-124`, `:271-278`

`Area_AddGood` and `Ship_Cargo_Set` both divide by 2 before sending (game-internal units appear to
be half of displayed units). An odd `amount` produces `x.5`, stringified into the command. Both
special-case `amount == 1 -> 2`, which suggests the halving is lossy for odd values generally.

The fake world does not model the halving at all — it works in displayed units throughout — so no
unit test can see this. `tests/game/contract_cargo.lua` only ever writes even values (30, 50), so
the contract suite does not cover it either. **An odd-value round-trip against the live game is
the one measurement that would settle it.**

---

## 9. `SupplyRequestOrders_ToShipCommands` builds a full cross product — *read-only*

`mod_trade_planner_ll.lua:597`

One command per (ship × order), then sorts the lot. Orders are already
(requesting area × good × supplying area), so worst case is `ships × areas² × goods`, rebuilt every
iteration. Fine at 6 islands; worth watching late-game.

The missing tie-breaker half of this entry is **fixed** — see the fixed section.

---

## 11b. `Ships_RenameAll` still indexes a possibly-nil ship list — *read-only*

`mod_trade_planner_hl.lua:53-59`

#11 fixed `Ships_Available`, which was the caller found by `make typecheck`. The **other** caller
of `Anno.Region_Ships_GetAll` was not touched:

```lua
function TPHL_Internal.Ships_RenameAll(L, region)
    local ships = Anno.Region_Ships_GetAll(region);
    ...
    for _, oid in pairs(ships) do        -- no nil check
```

`Region_Ships_GetAll` (`anno_interface.lua:523-529`) returns `cache.Get(...)` when the region is
not the current one, which is nil when nothing is cached — exactly the case #11 was about.

Worse than #11 was, in one respect: `Ships_RenameAll` is called at `mod_trade_planner_hl.lua:474`,
**outside** the `xpcall` at `:537`, so this throws out of the owner thread rather than being logged
and skipped.

Same fix as #11: return early on nil. Tracked separately from #11 so the fixed entry stays honest.

---

## 12. `AnnoThread` is defined twice, identically — *read-only*

`_init.lua:52-85` and `_thread.lua:1-35`

The same `---@class AnnoThread` and the same `new` / `is_finished` implementation appear in both
files. `_init.lua` requires `_thread.lua` (line 25) and then shadows it with its own copy at
line 59.

This is one root cause producing 24 of `make typecheck`'s warnings
(`duplicate-doc-field` × 18, `duplicate-set-field` × 6). Deleting the copy in `_init.lua` and using
the required module would clear all of them.

---

## 13. `AnnoInfo.Factory` never scans an unknown factory — *read-only*

`generator/products.lua:291-297`

```lua
function AnnoInfo.Factory(L, region, factoryGuid)
    local ret = AnnoInfo.__Factories:Get(tostring(factoryGuid));
    if ret == nil then

    end
    return ret;
end
```

An empty `if` branch sits exactly where the compute-and-cache belongs. Compare `AnnoInfo.Residence`
directly above, which uses `GetOrCompute` with `_Residence.FindAndScan`.

So a factory GUID missing from the generated `factories_info.json` is never scanned — it just
returns nil forever, which is what produces the "Warning: Production GUID %d not found in
AnnoInfo.FactoriesInfo" log in `mod_area_requests.lua:48`. Bears directly on the
"other mods support" item in `docs/todos.md`, since a modded factory would always land here.

---

## 14b. `o2` and `o4` clamp at different ceilings, so big islands have 25 units of headroom — *proven*

`mod_trade_planner_ll.lua:260-270`

The one thing the #14 fix left open, kept because it is the next thing a tuning pass would target.

`o2_cap = 200` but `o4_cap = 225`, so on any island of capacity ≥ 750 the ladder collapses to
`o6 = 500`, `o8 = 525` — the export gate and the refill level end up **one minimum transfer apart**,
and it never gets better however large the island grows.

| capacity | `o8 - o6` |
|---|---|
| 250 | 50 |
| 650 | 130 |
| 1000 | 25 |
| 2000 | 25 |

Under the corrected semantics this is self-limiting rather than a churn source: a producer refills
itself and one inbound delivery flips it to a consumer with the roomy `o8` floor
(`o8 - o2 = 325`). Pinned by two tests that will fail loudly if anyone retunes the constants:
`thresholds: PROPERTY VIOLATED -- the export gate and the ask level converge on big islands` and
`roles: PROPERTY -- how much headroom that gap actually leaves`.

**Narrower than the arithmetic suggests — measured 2026-08-24.** The request gate is
`_stock < o2`, so an island left on 225 asks for *nothing*; something has to consume through those
25 units first. And "producer" here means **last movement was outbound**, not *produces the good*.
So the edge only bites an island that is floored as a producer while being a **net consumer** of
the good. A true producer refills past the line under its own steam, and at break-even an island
rests on 225 forever without ever crossing. That is very likely why this has never been observed
in the field despite the arithmetic being plain. Pinned by
`hubs: PROPERTY -- only a NET CONSUMER pumps; a producer drained to o4 never asks back`, and
written up in [hubs.md](hubs.md).

---

# Fixed

Full detail for the supply/request items lives in **`docs/supply-request.md`**, which is the
canonical description of the design and carries the measured before/after. The entries here are
kept short so the numbers stay resolvable.

## 1. Cargo slots — *ANSWERED in-game 2026-08-22*

Measured against a live game, ship "O1" (6 slots). The finding: **a cargo-vector key is a position,
not a slot.** `Cargo Count` returns stacks aboard, the vector is keyed `0..count-1` and re-indexes
when a stack is removed, while `ClearSlot(i)` addresses a real slot. They agree only while the hold
has no gaps.

The whole answer — that, the same-frame read delay, the ignored `slot` argument, unit symmetry,
"two goods never share a slot", and the tolerated unbalanced paren — is now written up as the
**SHIP CARGO note in `anno_interface.lua:171-255`**, next to the code it governs, and re-checked
against the running game by `tests/game/contract_cargo.lua` via `make test/game`.

Consequence that mattered: `for i in pairs(Ship_Cargo_Get(oid)) do Ship_Cargo_Clear(oid, i)` is
wrong, and that is the shape the multi-good `dst_unload` rewrite was about to take.

## 2. `Ships_RenameAll` renamed session objects 1, 2, 3… instead of ships — *FIXED 2026-08-23*

The rename loop read `for oid, _ in pairs(toBeRenamed)`, binding the array **index** rather than
the ship OID. It never renamed a ship, and it threw out of the owner thread the first time the list
was non-empty, because session object 1 carries no packed destination. Now `ipairs`, with the
reason recorded in a comment at `mod_trade_planner_hl.lua:81-86`.

The nil-ship-list hole in the same function is **still open** — see 11b.

## 3. Supplier islands subtracted in-flight goods twice — *FIXED*

`_stock = _stock - stock_outgoing` ran once for every area and then again for areas that do not
consume the good. Now subtracted exactly once (`mod_trade_planner_ll.lua:440`). Asserted by
`in-flight: a supplier island subtracts outgoing goods exactly once`.

Blast radius was narrow: `AreaRequests.Construction` gives every island a standing request for the
9 construction goods, so only goods an island holds without consuming were affected — and the
direction was conservative, which is why nobody noticed.

## 4. `_request_modifier` was accepted and never called — hub cities were dead — *FIXED 2026-08-24*

`supplyRequest_Build` took `_request_modifier` and never referenced it, so
`SupplyRequest_BuildHubs` — which existed solely to pass a modifier raising the hub's request to
90% of capacity — behaved identically to `SupplyRequest_Build`. The hub path was unreachable
anyway: `tradeExecutor_iteration_hub` was commented out, sat *after* `return TradePlannerHL;` (so
it was not even syntactically restorable), and its calls were missing the `state` argument added
since.

The parameter is gone, replaced by a `hubMode` the builder reads. A callback could never have
worked: a hub also needs a different *gate* (it collects whenever below target, not only when
under `o2`) and a different *target*, and a modifier reaches neither — the likeliest reason it was
never wired up.

**Hubs now run.** `tradeExecutor_iteration` makes a second pass on the ships the main pass left
idle, gated on a hub existing so a hub-less region pays only a name scan. `(h)` collects every
good, `(hc)` construction goods only, the ask is a shortfall against `HubTarget` rather than a
level, and hubs are absent from `Supply` during the pass so it can only move goods *towards* them.
The parked sketch is deleted and `README.md` now describes the real behaviour.

Design and measurements: [hubs.md](hubs.md). Tests: `tests/test_hubs.lua` and the `hubs` option on
`tests/lib/sim.lua`. `mod_trade_planner_hl` still has no doubles, so the wiring itself rests on
the planner-level tests plus `make syntax` / `make typecheck`.

Two pre-existing issues this makes more exposed: a hub **cannot** collect a good no island in the
region requests (the goods considered are the union of the request tables — pinned by a test), and
**#6** matters more because the hub target is `cap * 0.9` raw and unclamped where `o2`/`o4` clamp
at 200/225. Driving an island to 90% also parks it where **#5** would destroy an overflow.

---

## 10. Architecture doc had stale threshold formulas — *MOOT*

`docs/CLAUDE_architecture-trade-automation.md` documented `max` where the code uses `math.min` —
the difference between a floor of 500 and a ceiling of 500 — and its line references were off by
100-200 lines. **The file has since been deleted.** The ladder is now described correctly in
`docs/supply-request.md` and `docs/testing-unit.md:152`, and pinned by
`thresholds: the ladder, so any tuning shows up as a diff here`.

## 11. `Ships_Available` returned nil and its callers indexed it immediately — *FIXED*

It returned `nil, nil, nil` despite `---@return table, table, table` when the region was not
current and nothing was cached. Every caller indexed all three straight away, so the whole
iteration threw inside `xpcall` — once per cycle, silently, with the mod looking alive. It now
returns three empty tables, which is what the callers already assumed. Found by `make typecheck`.

**Not fully closed:** the other caller of `Region_Ships_GetAll` still has the same hole — 11b.

## 14. Export drained to `o2` while the gate was `o8` — the Wood sawtooth — *FIXED 2026-08-23*

Found in a live save: Wood was **92 of 239 voyages** and every island was both sending and
receiving it. Two compounding causes — `_surplus` computed once above the branch as `_stock - o2`
(so `o4` was never referenced and a consumer cleared by `o8` still drained to the level at which
asking starts), and `Request` written as a **level** but spent as a **quantity** (an island holding
199 asked for a flat `o6 = 500`, was sent 500, landed on 699, and re-qualified to export).

Fixed by taking the floor from the role — `local _floor = isRequester and o8 or o4` — and making
the ask a shortfall rather than a level. **Both halves were needed:** the floor alone still moved
all 1000 units in the four-island scenario. Measured there: 1000 units → **770**, the whole
shortfall and nothing else, no island both sending and receiving, settling a cycle earlier. No new
constants and no retuning; the `- 15` deadband and the separate high-water gate both dropped out.

A two-tier ask was tried and rejected — see #16. The residual clamp asymmetry is 14b.

Full write-up, including the ladder and the rejected alternative: `docs/supply-request.md`.
Tests: `tests/test_thresholds.lua`, `tests/test_scenarios.lua`.

## 15. In-flight goods were not reserved against the destination until the ship loaded — *FIXED 2026-08-23*

n5 held 80 Bricks in a 600-unit store and asked for 360; **950 arrived**, and the overflow was
destroyed on unload (see #5). Every individual cycle was correct — the failure was across cycles.
A cycle runs roughly every ten seconds; sailing to the pickup island takes longer, and the
empty-hold branch counted cargo *only* as outgoing from the source, so the planner saw
`stock=80 (+0)` three times running while five ships were already under way.

Now an unloaded voyage counts at **both** ends: removed from the source that promised it away,
added to the destination already expecting it. Once loaded, only the destination counts. A
force-unload has no source and is still skipped.

Tests: `in-flight: a ship on its way to load is counted at BOTH ends` (which previously pinned the
wrong behaviour) and `in-flight: an unloaded voyage still reserves the destination's request`.

## 16. The `request=` value in the log was not what the planner asked for — *FIXED 2026-08-23*

`_request` was computed, logged, and never read again, while the value actually written to the
request table was always `o6 - stock_incoming`. A log line reading `request=120` could mean the
island asked for 360. Harmless to behaviour, actively misleading when reading logs — which is how
#14 and #15 were both found.

**Fixed, but not the way the original entry proposed.** The suggestion was to *wire `_request` up*,
giving a just-exported island a small `o2` top-up instead of a full refill. Measured, that is the
wrong trade: it settles the region at `o2`, the level at which asking starts, so islands rest one
consumption tick from a fresh request. `_request` was deleted instead and the log now prints the
real ask (`mod_trade_planner_ll.lua:445-453`).

## Preconditions for ship packing — *FIXED, ship packing is in*

Both were latent: automation ships were never touched by the player and every trade was one good
between two islands, so mixed cargo could not arise. Packing made them live, and both were fixed
before the planner was allowed to pack anything.

- **`Ships_ForceUnloadStoppedShips` refused mixed cargo** — logged "has mixed cargo, cannot
  proceed" and abandoned the ship, stranding it forever. It now totals the hold per good and looks
  for an island with room for all of it, reserving that room so two stuck ships do not both claim
  it.
- **`dst_unload` cleared every slot after delivering one good** — added only `cmd.GoodID` ashore,
  then cleared all slots, deleting anything else aboard. It now credits every good in the hold.

Also fixed as part of the same change: **#3**, **#11**, and **#9's missing tie-breaker** — the
command sort now falls through to ship, islands and good, so the same game state dispatches the
same way every run.

The rule packing works to: a voyage may carry several goods **only if they share one source and
one destination**. That keeps the hold filled at one island and emptied at one island, so no
partial unload is ever required — which is what note 1 in `anno_interface.lua` says the code
cannot safely do. Multi-stop runs would need slot-level addressing and are deliberately not
attempted.

## Fixed while wiring up `make check`

Two dead-and-broken code paths in `mod_map_scanner.lua`, both of which would have thrown on their
first call:

- `areaScanner_grid` logged through an `L` that was never a parameter and never in scope. The log
  line is commented out with a note; the function is otherwise unchanged.
- `visualizationTsvs` called `cache.getOrSet` (no such function — the real one is `cache.GetOrSetR`,
  and `utils_cache` was not even required by the file) and reached for `map_scanner.X`, which is
  this very module.

Neither function is called from anywhere, so this is untested repair of dead code — but it is now
dead code that would at least run.
