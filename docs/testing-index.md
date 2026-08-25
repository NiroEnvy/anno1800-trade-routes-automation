# Testing — index

Two suites. They share a test framework and a naming style, and almost nothing else.

| | unit | contract |
|---|---|---|
| runs against | a fake Anno in `tests/lib/world.lua` | the **running game** |
| answers | does our logic do the right thing? | does the game still behave the way the fake claims? |
| needs | `lua5.4` | Anno open, a `TRA_TEST` route, the executor thread |
| speed | 82 tests, instant | ~15 tests, a few seconds, manual |
| command | `make test` | `make test/game` |

The unit suite is only as trustworthy as the fake, and the fake is a set of claims about Anno. The
contract suite is what checks those claims. Neither is much use without the other.

## Writing and running

- **[testing-scenarios.md](testing-scenarios.md)** — whole-region runs over many cycles: does the
  system settle, does it oscillate, what did it cost. Start here for planner behaviour
- **[testing-unit.md](testing-unit.md)** — write and run unit tests
- **[testing-integration.md](testing-integration.md)** — write and run contract tests
- **[testing-shared.md](testing-shared.md)** — the bits both use: assertions, product GUIDs,
  naming, make targets

## How the machinery works

Read these when you need to *extend* the harness, not to write a test.

- **[testing-infra-unit.md](testing-infra-unit.md)** — the fake world, module substitution,
  fidelity gaps
- **[testing-infra-contract.md](testing-infra-contract.md)** — how a script gets into a running
  game and reports back

## Nearby

- **[in-game-testing.md](in-game-testing.md)** — the same delivery mechanism used for ad-hoc
  poking rather than tests (`make run` with `sample1.lua`)
- **[possible_issues_2026-08-22.md](possible_issues_2026-08-22.md)** — findings, each marked
  *proven*, *read-only* or *answered*

**[supply-request.md](supply-request.md)** covers the code most of these tests are about: how
`supplyRequest_Build` decides what should move, what o2/o4/o6/o8 each mean, and what the two
departures from that design cost before they were fixed.

**[hubs.md](hubs.md)** covers the second pass built on top of it: `(h)`/`(hc)` islands, the 90%
target, and why donors use the main pass's floors rather than a hub-specific one.

There is no current architecture overview of the rest of the code under test.
`docs/CLAUDE_architecture-trade-automation.md` was deleted before this suite existed (it is still
in git history, and its threshold formulas and line numbers had drifted). The header comments of
`mod_trade_planner_ll.lua`, `mod_trade_planner_hl.lua` and `mod_trade_executor.lua` still point at
it.

Verified facts about the game's own behaviour live next to the code they govern, not in these docs
— the cargo slot/vector semantics are a long comment at the top of the cargo section in
`trade_route_automation/anno_interface.lua`.
