# Testing — shared conventions

Everything both suites use. See [testing-index.md](testing-index.md) for the split.

## Make targets

| | |
|---|---|
| `make check` | syntax + lint + typecheck + unit tests — run before committing |
| `make test` | unit tests only |
| `make test T=packing` | unit tests whose name contains `packing` |
| `make test/game` | contract tests, inside the running game |
| `make syntax` | `luac5.4 -p` over every file; no dependencies |
| `make lint` | `luacheck`; config in `.luacheckrc` |
| `make typecheck` | `lua-language-server --check`; config in `.luarc.json` |

`check` runs all four steps even when an earlier one fails, then reports which failed, so a lint
warning never hides a broken test. `lint` and `typecheck` skip themselves with an install hint when
their tool is missing.

**`typecheck` is what catches broken annotations** — a `---@return FakeWorld` where `FakeWorld` was
never declared with `---@class` is an error there and nowhere else. Run it after adding
annotations.

## The framework

`tests/lib/t.lua`. Around 200 lines, because there is no busted or luarocks here and pulling one in
for a handful of assertions is not worth it.

```lua
T.test("name", function()
    T.eq(actual, expected, "what this means")
end)
```

Assertions: `T.eq` `T.ne` `T.truthy` `T.falsy` `T.nil_` `T.approx(a, b, tol)` `T.deep_eq`
`T.len(t, n)` `T.fail(msg)`.

All take a trailing context string. **Use it** — it is what you read when the test fails six months
from now, and it should say what the number *means*, not restate it:

```lua
T.eq(peakSlots, 2, "2 of 6 slots used -- the ship sailed a third full");
```

`T.out` is where results go — `io.write` offline, the mod's logger in-game. `T.reset()` clears
registered tests, which the in-game runner needs because it is `dofile`d repeatedly into one
long-lived Lua state.

## Product GUIDs

Use `tests/lib/goods.lua`, never a literal:

```lua
local G = require("tests/lib/goods")
G.Bricks              -- 1010205
G["Alpaca Wool"]      -- 120036
G.name[1010205]       -- "Bricks"
```

It loads the real `trade_route_automation/generator/product_info.json` — 184 products, the same
names the mod logs. An unknown name **raises** rather than returning nil, so a typo fails loudly
instead of becoming a nil GUID deep inside the planner.

The in-game suite writes GUIDs inline instead, since it cannot reach the repo's `tests/lib` at
runtime beyond the files `make test/game` copies over.

## Naming

`"<area>: <what is true>"`, lowercase, stating the behaviour rather than the function name:

```
planner: a city below o2 asks for o6 of each good
cargo: ClearSlot addresses a real slot, not a vector position
```

Prefix with **`TODAY`** when pinning behaviour you believe is *wrong*, so that changing it is a
deliberate, visible act:

```
in-flight: TODAY a supplier island subtracts outgoing goods twice
```

and say why in a comment, with a file:line pointer. When the fix lands, the test fails loudly and
you change it on purpose.

## Recording what you find

A test that pins a bug is half the job; the other half is
[possible_issues_2026-08-22.md](possible_issues_2026-08-22.md), where each finding is marked:

- **proven** — a passing test demonstrates the wrong behaviour
- **read-only** — spotted by reading, not reproduced; a lead, not a fact
- **answered** — settled by measurement, with the run that settled it

Keep those labels honest. "I read the code and it looks wrong" and "here is a test that fails" are
very different claims, and mixing them up wastes the next person's time.

Facts about how *the game* behaves do not go in these docs at all — they go next to the code they
govern, as the cargo slot semantics do at the top of the cargo section in
`trade_route_automation/anno_interface.lua`.
