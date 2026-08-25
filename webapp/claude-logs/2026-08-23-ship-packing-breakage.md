# Webapp breakage report: the "ship packing" (multi-good voyage) mod feature

Date: 2026-08-23
Author: investigation agent (diagnosis only — **no webapp application code was changed**)
Status: diagnosed, not fixed

---

## 1. The original assignment

Verbatim intent of the task this file exists to answer, restated so a reader months from now
knows why it is here:

> A feature just landed in the Anno 1800 trade-route-automation mod (working tree, uncommitted at
> the time of writing) and it has probably broken `webapp/`, the browser-based log visualizer.
>
> 1. Explore `webapp/`; base data for it lives in `webapp/claude-logs`.
> 2. Work out **what the webapp does today** and **what the new mod feature broke about it**.
> 3. Write a markdown report under `webapp/` containing: the original assignment, what was found,
>    how it is broken (specifically and concretely, with data shapes and code locations), and a
>    QUESTIONS section.
> 4. **Do not change any webapp application code.** Diagnose and document only. The report file is
>    the only file created or modified. If a fix looks obvious, describe it rather than apply it.

### The feature that landed: ship packing

**Before:** one voyage carried exactly one good — `(ship, source island, destination island, one
good, one amount)`.

**Now:** one voyage may carry several goods, provided they all go from the same source island to
the same destination island. A ship with 6 cargo slots that used to sail with 2 slots filled (a
single request only needed 100 units) now gets its remaining slots packed with other goods the
same island pair wants.

Design constraints that shaped it:

- The game can only unload a **whole hold**, never part of one. So multi-stop runs (A→B→C) are
  **not** implemented: one source, one destination, many goods.
- The packing budget is cargo **slots**, not units. Two different goods never share a slot, so 30
  units of a good costs a whole slot just as 50 units would.

Mod files changed: `trade_route_automation/mod_trade_executor.lua`,
`mod_trade_planner_ll.lua`, `mod_trade_planner_hl.lua`, and a doc comment in `anno_interface.lua`.
Landed in commit `3faccc0` ("save state", 2026-08-23).

---

## 2. What I found: how the webapp ingests and presents mod data

### 2.1 Shape of the app

Vite + TypeScript, no backend, no framework. It reads the Anno log directory through the File
System Access API and does all parsing in the browser. Five tabs
(`webapp/index.html:20-24`):

| Tab | Widget | Data source |
|---|---|---|
| Area Stock (deficits/surpluses) | `src/widgets/stock-table.ts` | `area_stock` lines from `TrRAt_<profile>_base.log` |
| Trade logs | `src/widgets/logs-table.ts` | **all** parsed lines from `TrRAt_<profile>_base.log` |
| Trade aggregated | `src/widgets/trade-table.ts` | `TrRAt_<profile>_trade-executor-history.json` |
| Area Visualizer | `src/widgets/area-visualizer.ts` | `TrRAt_*_area_scan_*.tsv` |
| Ship Usage | `src/widgets/ship-usage-chart.ts` | `ship_count` + `tasks_spawned` lines from base.log |

A single `DataStore` (`src/data-store.ts`) loads and parses **everything up front**, once, and
hands widgets pre-parsed arrays. Widgets never touch the filesystem themselves.
`DataStore.load()` (`src/data-store.ts:70-186`) does, in order: `texts.json` → profile names
(scanned from `TrRAt_<profile>_<REGION>_remaining-{deficit,surplus}.json`,
`src/parsers/deficit-surplus.ts:91-108`) → per profile: trades JSON, deficit/surplus JSON, and
the whole base.log → global ship-usage logs → area scan TSVs.

### 2.2 The two ingestion paths that matter

**Path A — `trade-executor-history.json` (structured).**
`src/parsers/trades.ts` maps each JSON element to a `TradeEntry`
(`trades.ts:98-106`), using exactly six fields: `good_id`, `good_name`, `good_amount`,
`area_src_name`, `area_dst_name`, `_start`, `_end`. It ignores `ship_oid`, `ship_name`,
`area_src`/`area_dst` (numeric ids), `good_loaded`, `good_unloaded`, and all four
`good_*_before`/`good_*_after` fields.

`analyzeTrades()` (`trades.ts:155-217`) folds those into two nested maps —
`received: city → good → {amount, firstTime, lastTime}` and `sent: city → good → …` — plus
`maxAmount` (largest single record's `good_amount`, used for heatmap scaling) and
`tradeCount: trades.length` (`trades.ts:214`).

`TradeTableWidget` renders that as the good×city matrix the user pasted, with the header line
built at `src/widgets/trade-table.ts:127-131`:

```ts
<span>Total trades: ${this.analysis.tradeCount}</span>
```

and cells `↑received/sent↓` formatted at `trade-table.ts:210-240`.

**Path B — `TrRAt_<profile>_base.log` (text).**
`src/parsers/base-log.ts` runs each line through eight parsers in order
(`base-log.ts:629-666`), first match wins, falling back to a `generic` entry that keeps only
`raw`, `timestamp`, `region`, `loc`. The eight types are `area_stock`, `ship_status`,
`ship_count`, `tasks_spawned`, `still_available`, `trade_spawn`, `trade_execution`,
`iteration_start`.

All the tag-carrying parsers use the same trick: harvest every `key=value` / `key="quoted value"`
pair into a flat map (e.g. `base-log.ts:444-453`), then re-parse selected values with
`parseArea()` / `parseIdName()` (`base-log.ts:206-223`), both of which are:

```ts
const match = str.match(/^"?(\d+)\s*\((.+?)\)"?$/);
```

`LogsTableWidget` then derives its own filter dropdowns **from the parsed data itself**
(`extractFilterOptions`, `logs-table.ts:55-113`) and, on first load with no URL state, defaults
the Log Type filter to trade spawns only (`logs-table.ts:395-400`):

```ts
this.config.logTypeFilter = new Set(
  Array.from(this.filterOptions.logTypes).filter((type) => type === 'trade_spawn')
);
```

The Trade-aggregated tab cross-links into this tab: clicking a good, a city header, or a cell
calls `onNavigateToLogs` (`trade-table.ts:153-208` → `src/main.ts:106-134`), which writes
`logGood` / `logAreaSrc` / `logAreaDst` into the URL and re-applies the filters.

---

## 3. How the ship-packing feature breaks it

Ranked by severity. Every claim below was verified by running the webapp's own compiled parser
over the live log (`TrRAt_Ichi_Schnipfi_base.log`, 186 MB) and by loading the live
`trade-executor-history.json`.

### S1 — CRITICAL: every trade line in base.log now fails to parse. The "Trade logs" tab is empty.

The mod's `good=` logger tag gained a per-good count suffix and became a comma-joined list
(`trade_route_automation/mod_trade_planner_ll.lua:776-787`):

```lua
table.insert(goodsDesc, string.format("%d (%s) x%d", g.GoodID, AnnoInfo.Product(g.GoodID).Name, g.Amount));
...
good = table.concat(goodsDesc, ", "),
```

Note the `x%d` is unconditional — **even a single-good voyage** is now logged as
`good="120008 (Wood) x64"`, not `good="120008 (Wood)"`.

`parseIdName()` (`webapp/src/parsers/base-log.ts:216-223`) anchors on `)` followed by end-of-
string, so it returns `null` for both the new single-good and multi-good forms:

```
"120008 (Wood)"                                 -> {"id":120008,"name":"Wood"}
"120008 (Wood) x64"                             -> null
"120008 (Wood) x100, 1010196 (Timber) x200"     -> null
```

Both `parseTradeSpawn` (`base-log.ts:469`) and `parseTradeExecution` (`base-log.ts:521`) bail out
on a null good:

```ts
if (!areaSrc || !areaDst || !ship || !good) return null;
```

so the line falls all the way through to the `generic` fallback (`base-log.ts:663-665`).

**Measured.** I bundled the webapp's real `base-log.ts` with esbuild and ran `parseBaseLog()` over
the last 20 MB (107 158 timestamped lines) of the live log:

```
trade_spawn:      15      generic lines containing "Spawning trade order":            671
trade_execution:  94      generic lines containing "_ExecuteTradeOrderWithShip":     4696
```

The 15 + 94 survivors are all from **before** the new build started. The cutover is exact:

```
last line that still parses:   2026-08-23T01:15:06Z ... good="1010200 (Fish)" ...
first line that no longer does:2026-08-23T01:15:11Z ... good="1010203 (Soap) x42" ...
```

**Downstream consequences, in order of what the user sees:**

1. `extractFilterOptions` (`logs-table.ts:55-113`) never sees a `trade_spawn` or `trade_execution`
   entry, so `filterOptions.logTypes` no longer contains those strings.
2. The default filter at `logs-table.ts:395-400` therefore evaluates to an **empty Set**.
3. `filterLogs` rejects everything on an empty type filter (`logs-table.ts:124-127`):
   `if (config.logTypeFilter.size === 0 || !config.logTypeFilter.has(log.type)) return false;`
4. Result: the Trade logs tab renders `Total logs: 0 / N` and an empty table, with no
   "trade_spawn" checkbox in the Log Type filter to turn back on.
5. The same holds for a bookmarked URL: `decodeFilterSet('trade_spawn', logTypes)`
   (`src/url-state.ts:144-146`) filters against `allOptions` and yields an empty Set.
6. Cross-tab navigation from the aggregated table (`main.ts:106-134`) lands on a tab that can
   show nothing.
7. The Good / Ship / Area Src / Area Dst dropdowns lose all their trade-derived values. Goods and
   ships survive only via `area_stock.goodName` and `ship_status.shipName`; **Area Dst collapses
   entirely**, because `areaDst` is only ever populated by the two trade entry types
   (`logs-table.ts:93-95`).

### S2 — HIGH: two more line-body regexes are stale, so fixing S1 alone is not enough.

Even after `parseIdName` is taught about the new good tag, two stage parsers still silently
degrade (they don't return `null`, they just leave `data` empty, which is worse — the rows appear
but the Other Data column loses its numbers).

**"loaded" stage** — `base-log.ts:550`:

```ts
const loadedMatch = line.match(/Loaded (\d+) total units; area src: (\d+) -> (\d+)/);
```

The mod now emits (`mod_trade_executor.lua:301-302`):

```
Loaded 300 total units across 2 good(s) in 6/6 slots; moving to dst area (x=779 y=585)
```

The `; area src: N -> M` clause is gone entirely — the per-good src before/after is no longer on
this line at all. Verified `null` against a real line. Consequence: `data.unloaded`,
`data.srcBefore`, `data.srcAfter` are all undefined for the `loaded` stage. The new
`across N good(s)` and `in used/total slots` numbers — which are exactly the packing-efficiency
signal this feature exists to produce — are captured nowhere.

**"before" stage** — `base-log.ts:534`:

```ts
const beforeMatch = line.match(/before: source = (\d+), destination = (\d+)/);
```

The mod now emits one line per good with a `good=` prefix inserted
(`mod_trade_executor.lua:253`, diff `-  before: source = %d` → `+  before: good=%d source = %d`):

```
before: good=120008 source = 10, destination = 5
```

Verified `null`. `data.sourceStock` / `data.destinationStock` are dropped.
*(This one was not on the hand-off list of changed formats — it was found by reading the diff.)*

**Still working, for the record:** the completion regex at `base-log.ts:565-567` is unanchored,
so `Trade order completed: good=120008 unloaded=100; src=(1092 -> 856); dst=(4 -> 311)` still
matches and yields the right five numbers. It is only unreachable because of S1.

### S3 — MEDIUM: "Total trades" now counts goods, not voyages.

`TradeExecutor.Records` gets one record **per good per voyage**
(`mod_trade_executor.lua:325-345`, inside `for _, g in ipairs(goods) do`). A packed voyage
carrying 3 goods emits 3 records identical in `_start`, `_end`, `ship_oid`, `ship_name`,
`area_src`, `area_dst`, `area_src_name`, `area_dst_name`, differing only in the `good_*` fields.

`tradeCount` is a raw array length (`trades.ts:214`), so the counter drifted.

**Exact reproduction of the number the user pasted.** Filtering the live
`trade-executor-history.json` to the window shown in the screenshot
(`_start >= 2026-08-23T01:17:32Z`, `_end <= 2026-08-23T01:23:40Z`):

```
records in window:  104     <-- what the webapp printed as "Total trades"
distinct voyages:    97     <-- grouping by (ship_oid, _start)
```

Over the whole current file: **684 records / 657 voyages**; 27 voyages carried 2 goods, 630
carried 1.

**What is NOT broken, and this matters:** the good×city matrix itself is still **numerically
correct**. Because the split is per good and the aggregation in `analyzeTrades` is keyed by
`(city, goodName)` (`trades.ts:174-205`), the `↑received` / `sent↓` sums are exactly what they
would have been under one-record-per-voyage. Nothing double-counts, nothing is dropped. `maxAmount`
likewise still means "largest single-good shipment", so the heatmap thresholds keep their meaning.
Only the label "Total trades" is now a lie — it reads "shipments", not "voyages".

### S4 — MEDIUM: there is no voyage identity, so packing is invisible and unjoinable.

No voyage id ships in the records (one was drafted mod-side and removed before release). The
webapp therefore cannot distinguish "one voyage carrying 3 goods" from "3 separate voyages by the
same ship", which means it can never show ship utilisation, packing efficiency, or a per-voyage
manifest — precisely the things the feature was built to improve.

I measured how good the fallback join `(ship_oid, _start)` actually is on live data, since that is
the only handle available:

```
ship+_start groups with more than one distinct src>dst pair:   0  (of 666 groups)
maximum records sharing a ship+_start:                          2
```

So on this dataset the join is clean. It is nonetheless structurally fragile: `_start` has
one-second resolution (`os.date("%Y-%m-%dT%H:%M:%SZ")`, `mod_trade_executor.lua:227`), and two
voyages by one ship starting inside the same second would silently merge. A voyage takes ~30 s, so
this is unlikely but not impossible — for instance after a force-unload, or if the mod is ever made
to re-dispatch immediately. Adding `(area_src, area_dst)` to the key narrows it further at no cost.

Also unhelped: the joined records give no way to recover slot usage, because slots are a property
of the voyage, not of a good, and no `*_slots` field is written. `FullSlotsNeeded` was removed
from the in-memory command; `Records` never had it.

### S5 — MEDIUM: the test suite is green on stale fixtures and gave no warning.

`npx vitest run` in `webapp/` passes 60/60. `src/parsers/__tests__/base-log.test.ts` asserts the
**old** formats verbatim — e.g. `good="120008 (Wood)"` at line 329, `Loaded 150 total units; area
src: 494 -> 344` at line 388, `Trade order completed: unloaded=150; ...` at line 405. So the one
place that could have caught S1 and S2 automatically instead certifies the broken behaviour as
correct. Any fix should replace/duplicate these fixtures with real post-2026-08-23 lines pulled
from the live log.

### S6 — LOW: new log line types are invisible.

Two genuinely new signals fall to `generic` and appear nowhere except in raw text:

- `Dropping good %d from voyage: only %d could be carried (supply=%d request=%d slots_free=%d)`
  (`mod_trade_planner_ll.lua:699`). Note it carries the good as a bare number **in the message
  body**, with no `good=` tag, so even the Good column/filter cannot pick it up.
- `Forcing ship %d to unload %d units across %d good(s) to area %d`
  (`mod_trade_planner_ll.lua:940`). This one already fell to `generic` before the feature — it has
  no `aSrc` tag, and `parseTradeSpawn`/`parseTradeExecution` both require one (`base-log.ts:456`,
  `:508`) — so it is a pre-existing gap, merely widened.
- `Unloaded %d units of good %d at area %d; area good before: %d, after: %d`
  (`mod_trade_executor.lua:392`) is textually unchanged but is now emitted once per good in the
  hold. It has no parser either way.

### Confirmed NOT broken

- **Area Stock tab.** `Area %s (id=%d) %s stock=%s (+%s) (-%s) request=%s (reasons=%s)`
  (`mod_trade_planner_ll.lua:385`) is untouched; 86 249 `area_stock` entries parsed cleanly from
  the 20 MB tail. `stock-table.ts` reads only `area_stock` (`stock-table.ts:172`).
- **Ship Usage tab.** Depends only on `ship_count` and `tasks_spawned`
  (`src/parsers/ship-logs.ts:40-67`). `Total available trade route automation ships: %d`
  (`mod_trade_planner_hl.lua:147`) and `Spawned %d async tasks for trade route execution.`
  (`:405`) are unchanged. Parsed 776 and 376 respectively.
- **Deficit/surplus.** `<region>_remaining-{deficit,surplus}.json` shape confirmed unchanged
  against the live files; `src/parsers/deficit-surplus.ts` is fine. Profile discovery, which is
  derived from these filenames (`deficit-surplus.ts:95`), is therefore also fine.
- **Area Visualizer.** TSV format untouched.
- **In-memory command structure change** (`Key.Order.GoodID` + `Value.Amount` →
  `Key.Order.Goods: [{GoodID, Amount}]`). I grepped the whole webapp for `GoodID`,
  `AreaID_from`, and `FullSlotsNeeded`: **zero hits**. The webapp never reads a dumped command or
  plan, so this change is a non-event for it.
- **`ship_name` gaining its decoration** (`"L1-le-9l-2gq"` rather than `"L1"`) in the JSON records:
  harmless, `trades.ts` does not read `ship_name` at all. `logs-table.ts` does split on `-` for the
  base.log ship tag (`base-log.ts:472`, `:524`), which still works.

---

## 4. Suggested fixes (described, not applied)

Deliberately not implemented, per the assignment. In rough priority order:

1. **Parse the good tag as a list.** Introduce something like
   `parseGoodsList(str): Array<{id, name, amount}>` handling `"<id> (<name>) x<amount>"` entries
   joined by `", "`, and keep `good` (singular) as the first element for backwards compatibility
   with every existing consumer. Splitting on `", "` is safe here: good names come from
   `AnnoInfo.Product().Name` and the format always terminates each entry with `x<digits>`, so a
   regex like `/(\d+)\s*\(([^)]*)\)\s*x(\d+)/g` is more robust than a naive split. Watch out that
   nested parens do occur in *area* names (`aDst="8706 (R1 (h))"`), though not so far in good
   names — `parseArea` handles that today only because of its `$` anchor, so do not "simplify" it
   into the same helper.
2. **Decide what the Good column shows for a packed voyage.** Options: first good, `"Wood +2"`,
   or one row per good. Also note `amount=` is now the **voyage total**, not the per-good amount,
   so the Amount column silently changed meaning for packed voyages even once parsing is fixed.
3. **Relax the `loaded` and `before` regexes** to the new formats, and capture
   `across N good(s)` and `in used/total slots` — that pair is the natural basis for a
   "packing efficiency" view.
4. **Rename the counter** to `Total shipments` and, if a voyage count is wanted, derive it as
   `new Set(trades.map(t => key(ship_oid, _start, area_src, area_dst))).size` — which requires
   `trades.ts:11-19` to start carrying `ship_oid`, `area_src`, `area_dst`, which it currently
   discards.
5. **Refresh the fixtures** in `base-log.test.ts` from real post-feature log lines before doing any
   of the above, so the fix is test-driven rather than eyeballed.
6. **Mod-side, if it is cheap:** re-adding the voyage id that was drafted and dropped would make
   items 4 and any future per-voyage view exact instead of heuristic. See QUESTIONS.

Unrelated to the webapp and explicitly out of scope: the Wood row in the user's screenshot shows
islands shipping Wood back and forth. That is a real mod-side oscillation bug, already diagnosed
and recorded as issue #14 in `docs/possible_issues_2026-08-22.md`. It is not a visualization
defect.

---

## 5. QUESTIONS

For the mod side — things I cannot determine by reading, only by asking:

1. **Voyage id.** You drafted one and pulled it before shipping. Was that a scope decision or did
   it cause a problem (serialisation size, id stability across saves, threading)? If the webapp
   needs per-voyage grouping to be exact rather than heuristic, is re-adding a `voyage_id` to
   `TradeExecutor.Records` on the table, or should the webapp commit to the
   `(ship_oid, _start, area_src, area_dst)` join permanently?

2. **Slot data in Records.** Nothing in `Records` exposes slots — not `slots_needed`, not
   `slots_available`, not `Ship_AmountPerSlot`. Since the whole point of the feature is slot
   utilisation, is that an intentional omission, or would you accept adding `slots_used` /
   `slots_available` (voyage-level, so repeated across the per-good records)? Without it the
   webapp can only ever show units, never "this 6-slot ship sailed at 2/6".

3. **`_start` resolution and collisions.** `_start` is second-resolution. Can one ship legitimately
   produce two voyages with the same `_start`, `area_src` and `area_dst` — e.g. around a
   force-unload, a re-dispatch, or an iteration that fires twice in one second? I measured zero
   collisions across 666 groups in the current file, but I want to know whether that is a
   guarantee or just luck on this dataset.

4. **Is `good_amount` still the planned amount?** 129 of 693 live records have
   `good_unloaded != good_amount` (always off by 1–2, e.g. amount 73 / unloaded 72). `good_loaded`
   always equals `good_amount`. The webapp aggregates on `good_amount`, i.e. it charts intent, not
   outcome. Is that off-by-one a known rounding artefact of the game's unload, and is
   `good_amount` still the field the trade matrix should be summing — or should it move to
   `good_unloaded` now that a packed hold is unloaded in one go?

5. **Does packing change what `(+n)` / `(-n)` in-flight mean on the `Area … stock=` line?** The
   line format is unchanged and the Area Stock tab reads it verbatim, but if in-flight accounting
   is now per-voyage rather than per-good-request, the numbers could have changed meaning without
   changing shape — which the webapp would render as a silent regression rather than a parse
   failure.

6. **Is the `x<amount>` suffix load-bearing, or would you rather move it?** If the per-good amount
   moved out of the `good=` tag into a separate tag (say `goods="1010205,1010237"` plus
   `amounts="200,150"`, or a single `cargo=` tag), the webapp's flat `key=value` harvester would
   handle it without any bespoke sub-format parser. Not asking you to change it — asking whether
   the current shape is deliberate, since I should write the parser to match whatever is stable.

---

## Appendix: how the evidence was gathered

- Bundled the webapp's own parser without modifying it, and ran it against the live log:
  ```
  webapp/node_modules/.bin/esbuild src/parsers/base-log.ts --bundle --format=cjs \
      --platform=node --outfile=<scratch>/base-log.cjs --alias:@=./src
  ```
  then `parseBaseLog(tail -c 20000000 TrRAt_Ichi_Schnipfi_base.log)` and counted entry types.
- Loaded `TrRAt_Ichi_Schnipfi_trade-executor-history.json` directly for the record/voyage counts
  and the window reproduction.
- `npx vitest run` in `webapp/` for the false-green result.
- Mod-side formats read from `trade_route_automation/mod_trade_executor.lua` and
  `mod_trade_planner_ll.lua`, and cross-checked against `git show 3faccc0` for before/after.
