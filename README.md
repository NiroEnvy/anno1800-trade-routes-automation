# Anno 1800 mod that automates goods management between islands

Inspired by https://www.reddit.com/r/anno/comments/hp5uac/automatic_trade_routes_anno_1800/,
but implemented in game's Lua.

The mod manages a set of ships to transfer goods between islands inside a region, based on islands' goods stock and
requests.

The main goals is to eliminate the manual management of trade routes. It is tedious and boring.

Check [Before/after mod when no in-region trade routes exist (except oil and mail)](#beforeafter-mod-when-no-in-region-trade-routes-exist-except-oil-and-mail)
for an example.

Notes:
1. The mod currently handles trades INSIDE a single region. Cross-region trades are not handled. It does handle Old and New World regions separately.
2. Mod works only in single player. Mod may misbehave on non-Normal difficulties (it relies a bit on game prices, I never tested on other difficulties).

## Installation

1. Install mod (https://github.com/kr3v/anno1800-trade-routes-automation/releases).
2. Set game speed to "Fast" during region and island scans.
   - "Fastest" breaks the scanning process.
3. Execute "Trade Route Automation: rescan current region" hotkey. Default: Shift+Alt+O.
4. For each _your_ island:
   1. Switch camera to middle of island. Move mouse cursor to middle of your screen.
   2. Execute "Trade Route Automation: rescan current island" hotkey. Default: Shift+Alt+P.
   3. Switch to next island and repeat.
5. Create a fake trade route named `TRA_${REGION_NAME}` (e.g., `TRA_OW` for Old World, `TRA_NW` for New World).
   - beware: other regions are not enabled atm.
6. Assign ships to that trade route. Please rename ships to short names (1-2 letters). See [Ship assignment](#ship-assignment).

Notes:
1. If you capture a new island (or a new player island appears), you need to rescan that island manually.
   The mod does not automatically detect new islands.
2. You can assign new ships to the trade route at any time.
3. You don't need to rescan islands or region when you reload the game after scanning.

BEWARE: mod expects to be installed at `C:/users/<user>/Documents/Anno 1800/mods/TradeRoutesAutomation_DEV`.
mod.io does not work for me. I am not sure how it installs mods.

Mod logs are at `C:/users/<user>/Documents/Anno 1800/mods/TradeRoutesAutomation_DEV/logs/TrRAt_*`.
E.g.:
```azure
$ ls C:/users/DBAYNAK/Documents/Anno\ 1800/mods/TradeRoutesAutomation_DEV/logs/
Anno1800_LOGFILE_...-PC_2025-12-05-20-09-41.log
mod-loader.log
TrRAt_Cache_Frances_Farthorp__FuncAnnoAreaIDToItsOIDargs_OW_.json
TrRAt_Cache_Frances_Farthorp__FuncAnnoAreasToProductionGuidsargs_OW_.json
TrRAt_Cache_Frances_Farthorp__FuncAnnoAreasToResidenceGuidsargs_OW_.json
TrRAt_Cache_Frances_Farthorp__FuncAnnoBuildingsWithSocketsargs_OW_.json
TrRAt_Cache_Frances_Farthorp__FuncAnnoShipsGetAllargs_OW_.json
TrRAt_Cache_Frances_Farthorp__FuncareaScannerdfsargs_OW870620_.json
TrRAt_Cache_Frances_Farthorp__FuncareaScannerdfsargs_OW915420_.json
TrRAt_Cache_Frances_Farthorp__FuncareaScannerdfsargs_OW960220_.json
TrRAt_Cache_Frances_Farthorp__FuncareaScannerdfsargs_OWSassenberg20_.json
TrRAt_Cache_Frances_Farthorp__FuncareaScannerdfsargs_OWSiphington20_.json
TrRAt_Cache_Frances_Farthorp__FuncareaScannerdfsargs_OWStockfisk20_.json
TrRAt_Cache_Frances_Farthorp__FuncmapscannerSessionP11args_OW_.json
TrRAt_Frances_Farthorp_area_scan_Sassenberg.tsv
TrRAt_Frances_Farthorp_area_scan_Siphington.tsv
TrRAt_Frances_Farthorp_area_scan_Stockfisk.tsv
TrRAt_Frances_Farthorp_base.log
TrRAt_Frances_Farthorp_force-unload-ships.log
TrRAt_Frances_Farthorp_OW_remaining-deficit.json
TrRAt_Frances_Farthorp_OW_remaining-surplus.json
TrRAt_Frances_Farthorp_trade-execute-iteration.log
TrRAt_Frances_Farthorp_trade-execute-iteration.log.hub
TrRAt_Frances_Farthorp_trade-executor-history.json
TrRAt_Frances_Farthorp_trades.log
```

If you have problems, please check the logs and open an issue if needed (with attached logs).

NOTE: if scanning misbehaves, consider checking if that island was properly scanned.
Check [readme.md](docs/images/area-visualzer/readme.md).

### Ship assignment

The mod uses ships that are assigned to a fake `TRA_${REGION_NAME}` trade route.

| Trade Route Name | Region Name        |
|------------------|--------------------|
| `TRA_OW`         | Old World          |
| `TRA_NW`         | New World          |
| `TRA_AR`         | Arctic (*)         |
| `TRA_EN`         | Enbesa (*)         |
| `TRA_CT`         | Cape Trelawney (*) |

Which regions the mod drives is decided by one table,
[`trade_route_automation/_regions.lua`](trade_route_automation/_regions.lua) — including regions
added by other mods. See [docs/regions.md](docs/regions.md).

The trade route must be created manually, the ships should also be assigned to it manually.
The ships MUST be in the relevant region, mod DOES NOT move ships between regions.

TODO - better handle when ships are added to the trade route after the mod starts.
At the moment, the ship can only be added to the trade route IF:

- the ship name is at most 2 letters; otherwise, the mod might fail to use the ship (the mod will misbehave when using
  the ship).
- the ship _cargo_ must be empty; otherwise the mod will not use the ship.

However, the mod automatically handles the above when it is restarted.

NOTE: the mod stores ship assignments in the ship names. A name like 'k-7n-gd-2lA' is not a bug, but an encoded 4-tuple
of ship short name, ship destination X and Y coordinates, and the destination area ID.

(*) - off by default: the region needs its map bounds measured once, by hand, because the game
exposes no way to read them. Fill them into `_regions.lua` and the region turns on. The procedure is
in [docs/regions.md](docs/regions.md).

### Hub cities

If the mod has 'idle' ships (ships assigned to automation, but not currently executing any trade), it will try to
send goods to hub cities. Mark one by putting a suffix at the end of the island's name:

- `(h)` — collect **every** good
- `(hc)` — collect **construction goods only** (wood, timber, bricks, steel beams, windows,
  reinforced concrete, elevators, steam motors, aluminium profiles) — useful for a city you are
  actively building up

A hub requests goods from the other islands until it holds 90% of its capacity. This runs as a
second pass, *after* the normal trade loop and using only the ships that loop did not need, so
filling a hub never delays an island that is genuinely short of something.

Goods leave a hub through the normal trade loop, like any other island — so a hub in the middle of
a region also works as a redistribution point.

See [docs/hubs.md](docs/hubs.md) for the details and the measurements.

## Before/after mod when no in-region trade routes exist (except oil and mail)

![trade-routes.png](docs/images/before-after/trade-routes.png)
^^ trade routes example.

Routes groups like "A-O", "O-E", "N-O" are cross-region trade routes. I don't have any in-region routes except oil and
mail.

That alpaca wool trade route is to Isabel trader to sell surplus wool from my NW island to keep generating
dung/fertilizer.

| Without mod                                                                                  | With mod                                                                                                                  |
|----------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------|
| old world city supply![c4-before.png](docs/images/before-after/c4-before.png)                | no hot sauce in the region<br/>![c4-after.png](docs/images/before-after/c4-after.png)                                     |
| new world city supply![n3-before.png](docs/images/before-after/n3-before.png)                | no Enbesa Teff available in region<br/>![n3-after.png](docs/images/before-after/n3-after.png)                             |
| new world population![nw-before.png](docs/images/before-after/nw-before.png)                 | <br/>![nw-after.png](docs/images/before-after/nw-after.png)                                                               |
| old world population![ow-before.png](docs/images/before-after/ow-before.png)                 | <br/>![ow-after.png](docs/images/before-after/ow-after.png)                                                               |
| old world 'deficit'![ow-deficits-before.png](docs/images/before-after/ow-deficit-before.png) | most solved, others require players' attention<br/>![ow-deficit-after.png](docs/images/before-after/ow-deficit-after.png) |

# Implementation details

## Tests

Two suites, described in [docs/testing-index.md](docs/testing-index.md):

- `make test` — the planning and execution logic under plain `lua5.4` against a fake Anno 1800, no
  game needed.
- `make test/game` — the same assertions the fake rests on, re-checked against a **running game**,
  so you find out when the fake drifts from reality.

`make check` runs syntax, lint, typecheck and the unit suite together.

For ad-hoc poking at real game APIs there is a file-drop hot-reload loop: `make run` and
[docs/in-game-testing.md](docs/in-game-testing.md).

## List of "low-level" features

- scanning
    - scan current region to detect all islands,
    - scan all detected islands to detect players' islands with approximate coast locations,
    - scan all players' ships and detect ships assigned to this mod (through a specific trade route name),
- trading
    - given a ship, a source and destination island, and one or more goods, the mod can:
        - move the ship to the source island's pier,
        - load the goods from the source island to the ship,
        - move the ship to the destination island's pier,
        - unload the whole hold at the destination island
    - ships are packed: a voyage carries as many goods as will fit, provided they are all going
      from the same island to the same island. A six-slot ship no longer sails with two slots used
      because a single request only needed 100 units. Goods are only added to a hull if the
      destination is genuinely short of them, so packing does not cause goods to be shipped back
      and forth.
        - the budget is cargo *slots*, not units: two different goods never share a slot, so 30
          units of one good costs a whole slot just as 50 units would.
    - detect all islands' goods stock, requests, and total capacity,
        - requests are also automated, the mod checks island's buildings/residences and their consumptions (**),
        - new inputs from trade unions are detected, both old and new input goods are requested though,

(**) - factories consumption info is hardcoded per building type. If a mod changes that, this mod will not be aware of it.
   But, the detection is automated. So it is a matter of changing the existing code a bit, not a big effort.
