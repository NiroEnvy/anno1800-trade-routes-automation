# Cargo transfer safety

The executor checks live stock and warehouse space again after sailing. A plan is a reservation,
not proof that the source still has the goods or that the destination still has room.

## Loading

A normal order refuses a ship that already carries goods. It leaves those goods aboard for
ordinary recovery rather than clearing them to make room for the new order.

Each loaded stack is limited by the source's current stock. The history records what was loaded,
not just what the planner requested. A one-unit remainder is left at the source because the
existing one-unit cargo command rounds up to two.

## Unloading and recovery

Before crediting any goods, the executor totals the whole hold by product and checks the live
per-good destination capacity. If any product does not fit, it credits nothing and clears nothing.
For example, a ship carrying 50 bricks keeps all 50 when it arrives at a warehouse holding 70/75.
Mixed holds use the same rule: room for one product does not justify deleting another.

The entire physical hold is cleared only after the capacity check and warehouse credit commands.
Keys returned by `Ship_Cargo_Get` are compact vector positions, not physical slot numbers. The
existing whole-hold clear avoids translating between them and works when physical slots have gaps.
Partial unloading would need a separately verified slot/quantity API; this change does not invent one.

One task owns a ship from queueing through its final completion. Normal orders and recovery cannot
both control it, including the final waiting ticks when its cargo is already empty. Rejected stale
dispatches return their supply/request reservations to the current planning pass.

Recovery uses live per-good capacities and subtracts incoming reservations from earlier active
voyages. It runs even when there is no empty ship. If no island can accept the complete hold,
the cargo stays aboard until another planning cycle finds room. A refused unload records zero
delivered goods and an incomplete normal order, rather than reporting the planned amount as delivered.

## Validation boundary

The regression suite uses the existing fake game world, including its warehouse capacity clamp.
The warehouse clamp and accepted-quantity reporting are still listed as unverified live contracts
in [the contract testing guide](testing-infra-contract.md#extending).

The game's cargo and warehouse cheat commands are separate, asynchronous operations with no
accepted-quantity receipt in the currently verified interface. A capacity check cannot prove
conservation if production, consumption, manual actions or another command change the inventories
between that check and command application. A stock change in the requested direction is not proof
that the whole command succeeded; restoring an old warehouse snapshot would overwrite real gameplay.

This patch closes the tested stale-plan overflow and task-overlap cases. It does not claim atomic
transactions, silent-command-failure recovery, multiplayer support or live-game validation. It adds
no legacy HOLD migration or save-specific ship exception.

## Regression tests

From the repository root:

```sh
lua5.4 tests/run.lua "transfer safety"
lua5.4 tests/run.lua
```

The tests exercise destination fill during sailing, mixed cargo, source depletion, physical-slot
gaps, duplicate tasks, reservation reuse and ownership through final completion.
