--[[
    Contract tests: cargo.

    These run INSIDE the running game, against the real Anno APIs. Every assertion here is a claim
    that tests/lib/world.lua makes about the game. If one fails, the fake is lying and the offline
    suite is testing fiction.

    The `cargo:` tests were measured on 2026-08-22 (ship O1, 6 slots), not assumed. The experiment
    log is in docs/possible_issues_2026-08-22.md #1.

    The `packing:` tests were added with the ship-packing change and measured on 2026-08-23, all
    passing. Every earlier measurement had a single good aboard; these are the multi-good cases the
    planner's slot budget rests on. The load-bearing one is "a different good opens its own stack
    rather than joining a part-full one": if that ever stops holding, the planner will think a
    packed hull has room it does not have.

    Needs: a trade route named exactly TRA_TEST with one ship of at least 3 slots. TRA_TEST does
    not match `^TRA_<region>`, so the automation loop ignores that ship and cannot race us.

    The ship's hold is emptied before and after every test. Nothing touches island stock.
]]

local T = require("t");
local G = require("game_env");

local Anno = require("trade_route_automation/anno_interface");

local BRICKS, WINDOWS, BEER = 1010205, 1010207, 1010214;

--- Logs a hold in position order, 0 upwards.
---
--- Not `pairs`: the cargo vector is keyed from 0, so key 0 lives in the table's hash part while
--- 1.. live in its array part, and `pairs` yields them out of order. Assertions index directly and
--- are unaffected, but a note printed in `pairs` order reads as though the hold were arranged
--- differently than it is -- which is exactly the wrong thing to be reading when a test fails.
local function noteHold(cargo)
    local n = 0;
    for _ in pairs(cargo) do
        n = n + 1;
    end
    for i = 0, n - 1 do
        local item = cargo[i];
        if item ~= nil then
            G.note("  [%d] guid=%s value=%s", i, tostring(item.Guid), tostring(item.Value));
        end
    end
end

---

T.test("cargo: a cheated stack shows up after a frame", function()
    local ship = G.ship();
    G.emptyHold(ship);

    Anno.Ship_Cargo_Set(ship, 0, { Guid = BRICKS, Value = 50 });
    G.settle();

    local cargo = Anno.Ship_Cargo_Get(ship);
    T.len(cargo, 1, "one stack aboard");
    T.eq(cargo[0].Guid, BRICKS, "it is what we loaded");
    T.eq(cargo[0].Value, 50, "Ship_Cargo_Set takes displayed units and reads back the same");
end);

T.test("cargo: the vector is 0-indexed", function()
    local ship = G.ship();
    G.emptyHold(ship);
    G.load(ship, { BRICKS, WINDOWS });

    local cargo = Anno.Ship_Cargo_Get(ship);
    T.truthy(cargo[0] ~= nil, "there is an entry at key 0");
    T.eq(cargo[0].Guid, BRICKS, "first loaded is first");
    T.eq(cargo[1].Guid, WINDOWS, "second loaded is second");
end);

T.test("cargo: the vector lists occupied stacks only, not every slot", function()
    -- The ship has 6 slots; two goods must give a count of 2, not 6.
    local ship = G.ship();
    G.emptyHold(ship);
    G.load(ship, { BRICKS, WINDOWS });

    local slots = Anno.__Ship_Cargo_SlotCapacity(ship);
    T.truthy(slots >= 3, "test ship needs at least 3 slots, has " .. tostring(slots));

    T.len(Anno.Ship_Cargo_Get(ship), 2, "two stacks, not " .. tostring(slots) .. " slots");
end);

T.test("cargo: the vector compacts when a stack in the middle is removed", function()
    local ship = G.ship();
    G.emptyHold(ship);
    G.load(ship, { BRICKS, WINDOWS, BEER });

    Anno.Ship_Cargo_Clear(ship, 1);   -- real slot 1 == Windows
    G.settle();

    local cargo = Anno.Ship_Cargo_Get(ship);
    T.len(cargo, 2, "two stacks left");
    T.eq(cargo[0].Guid, BRICKS, "Bricks still first");
    T.eq(cargo[1].Guid, BEER, "Beer moved DOWN from key 2 to key 1 -- the vector re-indexes");
end);

T.test("cargo: ClearSlot addresses a real slot, not a vector position", function()
    -- THE load-bearing one. With a hole at slot 0, vector position 1 and real slot 1 name
    -- different stacks, and the two possible behaviours predict different survivors.
    --
    --   real slots: [0]=empty   [1]=Windows [2]=Beer
    --   vector:     [0]=Windows [1]=Beer
    --
    -- Clearing "1" removes Windows if slots are meant, Beer if vector positions are.
    local ship = G.ship();
    G.emptyHold(ship);
    G.load(ship, { BRICKS, WINDOWS, BEER });

    Anno.Ship_Cargo_Clear(ship, 0);   -- punch the hole
    G.settle();
    T.len(Anno.Ship_Cargo_Get(ship), 2, "Bricks gone");

    Anno.Ship_Cargo_Clear(ship, 1);
    G.settle();

    local cargo = Anno.Ship_Cargo_Get(ship);
    T.len(cargo, 1, "one stack left");
    T.eq(cargo[0].Guid, BEER,
        "Windows (real slot 1) went, Beer (vector 1) stayed -- ClearSlot takes a SLOT index");
end);

T.test("cargo: a new stack fills the lowest free slot", function()
    local ship = G.ship();
    G.emptyHold(ship);
    G.load(ship, { BRICKS, WINDOWS, BEER });

    Anno.Ship_Cargo_Clear(ship, 0);   -- free real slot 0, leaving Windows@1 Beer@2
    G.settle();
    Anno.Ship_Cargo_Clear(ship, 1);   -- free real slot 1, leaving Beer@2
    G.settle();
    T.len(Anno.Ship_Cargo_Get(ship), 1, "only Beer left, in real slot 2");

    Anno.Ship_Cargo_Set(ship, 0, { Guid = BRICKS, Value = 50 });
    G.settle();

    local cargo = Anno.Ship_Cargo_Get(ship);
    T.len(cargo, 2, "two stacks");
    T.eq(cargo[0].Guid, BRICKS, "the new stack took slot 0, below Beer, so it sorts first");
end);

T.test("cargo: the mod's unbalanced ClearSlot string is accepted", function()
    -- anno_interface.lua:192 emits `ClearSlot(1))]`, one paren too many. It works; this pins that
    -- down so nobody "fixes" it into a behaviour change without noticing.
    local ship = G.ship();
    G.emptyHold(ship);
    G.load(ship, { BRICKS, WINDOWS });

    G.raw("ItemContainer ClearSlot(0))]", ship);
    G.settle();

    local cargo = Anno.Ship_Cargo_Get(ship);
    T.len(cargo, 1, "the unbalanced form removed a stack");
    T.eq(cargo[0].Guid, WINDOWS, "and it removed slot 0");
end);

T.test("cargo: clearing every slot index empties any hold", function()
    -- The unload loop clears physical slots, never mapping a cargo-vector position
    -- onto a slot number.
    local ship = G.ship();
    G.emptyHold(ship);
    G.load(ship, { BRICKS, WINDOWS, BEER });

    local slots = Anno.__Ship_Cargo_SlotCapacity(ship);
    for i = 0, slots + 1 do
        Anno.Ship_Cargo_Clear(ship, i);
    end
    G.settle();

    T.len(Anno.Ship_Cargo_Get(ship), 0, "hold empty");
end);

T.test("cargo: two part-stacks of one good -- do they merge?", function()
    -- OPEN QUESTION. The mod loads N units as ceil(N/50) separate CheatItemInSlot calls, so
    -- whether 30+30 becomes one slot of 50 plus one of 10, or two slots of 30, decides how many
    -- slots a packed ship actually needs. Whatever this reports is the answer; adjust
    -- tests/lib/world.lua:load to match.
    local ship = G.ship();
    G.emptyHold(ship);

    Anno.Ship_Cargo_Set(ship, 0, { Guid = BRICKS, Value = 30 });
    G.settle();
    Anno.Ship_Cargo_Set(ship, 1, { Guid = BRICKS, Value = 30 });
    G.settle();

    local cargo = Anno.Ship_Cargo_Get(ship);
    local total, stacks = 0, 0;
    for _, item in pairs(cargo) do
        total = total + item.Value;
        stacks = stacks + 1;
        G.note("  stack: guid=%s value=%s", tostring(item.Guid), tostring(item.Value));
    end

    G.note("  30 + 30 of one good -> %d stack(s), %d units total", stacks, total);
    T.eq(total, 60, "all 60 units are aboard however they are arranged");
end);

T.test("cargo: stack limit is 50", function()
    local ship = G.ship();
    T.eq(Anno.__Ship_Cargo_StackLimit(ship), 50,
        "the mod hardcodes 50 units per slot in several places");
end);

---
--- Ship packing. A voyage may now carry several goods between one pair of islands, and the
--- planner budgets in SLOTS on the strength of one claim: two different goods never share a slot,
--- so a 30-unit good costs a whole slot just as a 50-unit one does.
---
--- Everything above was measured with a single good aboard. These are the multi-good cases the
--- packer actually depends on, and until this runs they are assumption, not measurement.
---

T.test("packing: a different good opens its own stack rather than joining a part-full one", function()
    -- The claim the whole slot budget rests on. If Windows merged into the Bricks stack, the
    -- planner would think a packed hull had more room than it does and overfill it.
    local ship = G.ship();
    G.emptyHold(ship);

    Anno.Ship_Cargo_Set(ship, 0, { Guid = BRICKS, Value = 30 });
    G.settle();
    Anno.Ship_Cargo_Set(ship, 1, { Guid = WINDOWS, Value = 30 });
    G.settle();

    local cargo = Anno.Ship_Cargo_Get(ship);
    noteHold(cargo);

    T.len(cargo, 2, "two stacks -- 60 units in two part-full slots, not one slot of 60");
    T.eq(cargo[0].Guid, BRICKS, "Bricks first");
    T.eq(cargo[0].Value, 30, "and still only 30 of it");
    T.eq(cargo[1].Guid, WINDOWS, "Windows took a slot of its own");
    T.eq(cargo[1].Value, 30, "with its own 30");
end);

T.test("packing: three part-full goods occupy three slots", function()
    -- 90 units in total, under two slots' worth, but three slots gone. This is what
    -- TradeExecutor.SlotsNeeded computes and what the offline test of the same name asserts.
    local ship = G.ship();
    G.emptyHold(ship);

    local slots = Anno.__Ship_Cargo_SlotCapacity(ship);
    T.truthy(slots >= 3, "test ship needs at least 3 slots, has " .. tostring(slots));

    for i, guid in ipairs({ BRICKS, WINDOWS, BEER }) do
        Anno.Ship_Cargo_Set(ship, i - 1, { Guid = guid, Value = 30 });
        G.settle();
    end

    local cargo = Anno.Ship_Cargo_Get(ship);
    local total = 0;
    for _, item in pairs(cargo) do
        total = total + item.Value;
    end

    T.len(cargo, 3, "three stacks for 90 units");
    T.eq(total, 90, "and all 90 units are aboard");
end);

T.test("packing: a multi-stack good then a different good, as the executor loads them", function()
    -- The exact sequence _ExecuteTradeOrderWithShip runs for a packed voyage: one good's stacks
    -- consecutively, then the next good. 100 Bricks is two Ship_Cargo_Set calls of 50; Windows
    -- then has to start a new stack rather than land in either of them.
    local ship = G.ship();
    G.emptyHold(ship);

    local slots = Anno.__Ship_Cargo_SlotCapacity(ship);
    T.truthy(slots >= 3, "test ship needs at least 3 slots, has " .. tostring(slots));

    -- The slot argument is ignored (note 3); the game picks. Passed 0,1,2 only for readability.
    Anno.Ship_Cargo_Set(ship, 0, { Guid = BRICKS, Value = 50 });
    G.settle();
    Anno.Ship_Cargo_Set(ship, 1, { Guid = BRICKS, Value = 50 });
    G.settle();
    Anno.Ship_Cargo_Set(ship, 2, { Guid = WINDOWS, Value = 30 });
    G.settle();

    local cargo = Anno.Ship_Cargo_Get(ship);
    noteHold(cargo);

    local bricks, windows = 0, 0;
    for _, item in pairs(cargo) do
        if item.Guid == BRICKS then
            bricks = bricks + item.Value;
        elseif item.Guid == WINDOWS then
            windows = windows + item.Value;
        end
    end

    T.eq(bricks, 100, "all the Bricks arrived");
    T.eq(windows, 30, "and all the Windows");
    T.len(cargo, 3, "in three stacks: 50 + 50 Bricks, 30 Windows");
end);

T.test("packing: a mixed hold reads back whole, which is what the unload walks", function()
    -- dst_unload iterates the cargo vector and credits every stack ashore. It can only do that
    -- if a mixed hold reports every stack with the right guid and value.
    local ship = G.ship();
    G.emptyHold(ship);
    G.load(ship, { BRICKS, WINDOWS, BEER });

    local seen = {};
    local total = 0;
    for _, item in pairs(Anno.Ship_Cargo_Get(ship)) do
        seen[item.Guid] = (seen[item.Guid] or 0) + item.Value;
        total = total + item.Value;
    end

    T.eq(seen[BRICKS], 50, "Bricks readable");
    T.eq(seen[WINDOWS], 50, "Windows readable");
    T.eq(seen[BEER], 50, "Beer readable");
    T.eq(total, 150, "nothing else aboard");
end);

T.test("packing: clearing every slot empties a mixed hold too", function()
    -- The unload loop is already proven for a hold with a gap; this is the
    -- same walk over a hold holding three different goods.
    local ship = G.ship();
    G.emptyHold(ship);
    G.load(ship, { BRICKS, WINDOWS, BEER });
    T.len(Anno.Ship_Cargo_Get(ship), 3, "three goods aboard to start");

    local slots = Anno.__Ship_Cargo_SlotCapacity(ship);
    for i = 0, slots + 1 do
        Anno.Ship_Cargo_Clear(ship, i);
    end
    G.settle();

    T.len(Anno.Ship_Cargo_Get(ship), 0, "hold empty, all three goods gone");
end);
