--[[
    Characterization tests for mod_trade_executor.lua.

    These describe what the code does today, not what it ought to do. Where current behaviour is
    wrong, the test name says so and the assertion pins the wrong behaviour down anyway -- so that
    changing it is a visible, deliberate act rather than a silent one.
]]

local T = require("tests/lib/t");
local World = require("tests/lib/world");
local Harness = require("tests/lib/harness");
local G = require("tests/lib/goods");

local function world()
    return World.new {
        region = "OW",
        areas = {
            { id = 10, name = "Sassenberg", capacity = 1000, at = { x = 100, y = 100 },
              stock = { [G.Bricks] = 600, [G.Windows] = 600, [G.Beer] = 600 } },
            { id = 20, name = "Siphington", capacity = 1000, at = { x = 900, y = 100 },
              requests = { G.Bricks, G.Windows, G.Beer }, stock = { [G.Bricks] = 50 } },
        },
        ships = {
            { oid = 900, name = "a", slots = 6, speed = 200, at = { x = 100, y = 100 } },
        },
    };
end

--- A voyage carrying one good, written as `command(G.Bricks, 150)`, or several, written as
--- `command({ { GoodID = G.Bricks, Amount = 150 }, ... })`.
---@param goodID number|table
---@param amount number|nil
local function command(goodID, amount)
    local goods = goodID;
    if type(goodID) == "number" then
        goods = { { GoodID = goodID, Amount = amount } };
    end

    return {
        Ship_ID = 900,
        AreaID_from = 10,
        AreaID_to = 20,
        Goods = goods,
        OrderDistance = {
            src = { x = 100, y = 100 },
            dst = { x = 900, y = 100 },
            dist = 800,
        },
        ShipDistance = 800,
        Ship_AmountPerSlot = 50,
    };
end

---

T.test("executor: base62 round trips", function()
    local h = Harness.new(world());
    local TE = h.TradeExecutor;

    for _, n in ipairs({ 0, 1, 61, 62, 63, 999, 123456 }) do
        T.eq(TE.base62ToNumber(TE.numberToBase62(n)), n, "round trip " .. n);
    end
end);

T.test("executor: destination round trips through the ship name", function()
    local h = Harness.new(world());
    local TE = h.TradeExecutor;

    TE.Ship_Name_StoreCmdInfo(900, { x = 123, y = 456, area_id = 20, name = "a" });
    T.eq(h.world:ship(900).name, "a-1Z-7m-k", "encoded name");

    local info = TE.Ship_Name_FetchCmdInfo(900);
    T.eq(info.name, "a", "name");
    T.eq(info.x, 123, "x");
    T.eq(info.y, 456, "y");
    T.eq(info.area_id, 20, "area");
end);

T.test("executor: a plain name carries no destination", function()
    local h = Harness.new(world());

    h.world:ship(900).name = "a";
    local info = h.TradeExecutor.Ship_Name_FetchCmdInfo(900);

    T.eq(info.name, "a", "name survives");
    T.nil_(info.x, "no x packed");
    T.nil_(info.area_id, "no area packed");
end);

---

T.test("executor: a trade order sails, loads, sails on and unloads", function()
    local h = Harness.new(world());

    h.TradeExecutor.SpawnTradeOrder(h.L, "OW", command(G.Bricks, 150));
    local ticks = h:run();

    T.deep_eq(h:taskErrors(), {}, "no errors raised inside the task");
    T.truthy(ticks < 2000, "finished rather than timed out");

    T.eq(h.world:ship(900).at.x, 900, "ship ended up at the destination island");
    T.eq(h.world:stock(10, G.Bricks), 450, "600 - 150 left the source");
    T.eq(h.world:stock(20, G.Bricks), 200, "50 + 150 arrived at the destination");
    T.deep_eq(h.world:cargo(900), {}, "hold is empty afterwards");
end);

T.test("executor: goods are conserved across a trade order", function()
    local h = Harness.new(world());
    local before = h.world:total(G.Bricks);

    h.TradeExecutor.SpawnTradeOrder(h.L, "OW", command(G.Bricks, 150));
    h:run();

    T.eq(h.world:total(G.Bricks), before, "same number of bricks in the world");
    T.nil_(h.world.created[G.Bricks], "none invented");
    T.nil_(h.world.destroyed[G.Bricks], "none destroyed");
end);

T.test("executor: cargo travels as whole slots of 50", function()
    local h = Harness.new(world());
    local slotsSeen = 0;

    h.TradeExecutor.SpawnTradeOrder(h.L, "OW", command(G.Bricks, 150));
    h:run(2000, function()
        slotsSeen = math.max(slotsSeen, h.world:slotsUsed(900));
    end);

    T.eq(slotsSeen, 3, "150 units travelled as three slots");
end);

T.test("executor: one trade order records one trade", function()
    local h = Harness.new(world());

    h.TradeExecutor.SpawnTradeOrder(h.L, "OW", command(G.Bricks, 150));
    h:run();

    T.len(h.TradeExecutor.Records, 1, "one record");

    local r = h.TradeExecutor.Records[1];
    T.eq(r.ship_oid, 900, "ship");
    T.eq(r.area_src, 10, "source");
    T.eq(r.area_dst, 20, "destination");
    T.eq(r.area_src_name, "Sassenberg", "source name");
    T.eq(r.good_id, G.Bricks, "good");
    T.eq(r.good_name, "Bricks", "good name");
    T.eq(r.good_amount, 150, "amount ordered");
    T.eq(r.good_loaded, 150, "amount loaded");
    T.eq(r.good_unloaded, 150, "amount unloaded");
    T.eq(r.good_src_before, 600, "source before");
    T.eq(r.good_dst_after, 200, "destination after");
end);

T.test("executor: the ship name tracks where the ship is headed", function()
    local h = Harness.new(world());

    h.TradeExecutor.SpawnTradeOrder(h.L, "OW", command(G.Bricks, 150));
    h:run();

    local info = h.TradeExecutor.Ship_Name_FetchCmdInfo(900);
    T.eq(info.name, "a", "short name preserved");
    T.eq(info.area_id, 20, "name points at the destination island once done");
    T.eq(info.x, 900, "and at its coordinates");
end);

T.test("executor: a normal order preserves cargo already aboard", function()
    local h = Harness.new(world());

    h.world:load(900, G.Windows, 100);
    local before = h.world:total(G.Windows);

    h.TradeExecutor.SpawnTradeOrder(h.L, "OW", command(G.Bricks, 150));
    h:run();

    T.eq(h.world:total(G.Windows), before, "existing windows are conserved");
    T.deep_eq(h.world:cargo(900), { [G.Windows] = 100 }, "existing hold remains aboard");
    T.eq(h.world:stock(10, G.Bricks), 600, "nothing loaded at the source");
    T.len(h.TradeExecutor.Records, 0, "no completed trade");
end);

---

--- Packed voyages: several goods between one pair of islands. Nothing plans these yet -- the
--- planner still emits one good per command -- but the executor has to carry them before it can.

T.test("executor: one voyage carries several goods and lands them all", function()
    local h = Harness.new(world());

    h.TradeExecutor.SpawnTradeOrder(h.L, "OW", command {
        { GoodID = G.Bricks, Amount = 150 },
        { GoodID = G.Windows, Amount = 100 },
        { GoodID = G.Beer, Amount = 50 },
    });
    h:run();

    T.deep_eq(h:taskErrors(), {}, "no errors");
    T.eq(h.world:stock(20, G.Bricks), 200, "50 + 150 bricks");
    T.eq(h.world:stock(20, G.Windows), 100, "100 windows -- not deleted by the bricks unload");
    T.eq(h.world:stock(20, G.Beer), 50, "50 beer");
    T.deep_eq(h.world:cargo(900), {}, "hold emptied");
end);

T.test("executor: a packed voyage conserves every good aboard", function()
    local h = Harness.new(world());
    local before = {
        [G.Bricks] = h.world:total(G.Bricks),
        [G.Windows] = h.world:total(G.Windows),
        [G.Beer] = h.world:total(G.Beer),
    };

    h.TradeExecutor.SpawnTradeOrder(h.L, "OW", command {
        { GoodID = G.Bricks, Amount = 150 },
        { GoodID = G.Windows, Amount = 100 },
        { GoodID = G.Beer, Amount = 50 },
    });
    h:run();

    for guid, was in pairs(before) do
        T.eq(h.world:total(guid), was, "conserved: " .. guid);
    end
    T.deep_eq(h.world.created, {}, "none invented");
    T.deep_eq(h.world.destroyed, {}, "none destroyed");
end);

T.test("executor: a good never shares a slot, so a part-slot load still costs a whole slot", function()
    -- 30 + 30 + 30 is 90 units -- under two slots' worth -- but three goods cannot be stacked
    -- together, so it occupies three. This is why the packing budget has to be counted in slots.
    local h = Harness.new(world());
    local slotsSeen = 0;

    T.eq(h.TradeExecutor.SlotsNeeded({
        { GoodID = G.Bricks, Amount = 30 },
        { GoodID = G.Windows, Amount = 30 },
        { GoodID = G.Beer, Amount = 30 },
    }, 50), 3, "three part-full slots, not two");

    h.TradeExecutor.SpawnTradeOrder(h.L, "OW", command {
        { GoodID = G.Bricks, Amount = 30 },
        { GoodID = G.Windows, Amount = 30 },
        { GoodID = G.Beer, Amount = 30 },
    });
    h:run(2000, function()
        slotsSeen = math.max(slotsSeen, h.world:slotsUsed(900));
    end);

    T.eq(slotsSeen, 3, "and the hold agrees");
end);

T.test("executor: a voyage that would not fit the hold is refused, not silently trimmed", function()
    -- The planner is meant to have fitted this. If it ever gets the sum wrong, the surplus would
    -- otherwise vanish at the load step with nothing in the log to say so.
    local h = Harness.new(world());

    h.TradeExecutor.SpawnTradeOrder(h.L, "OW", command {
        { GoodID = G.Bricks, Amount = 300 },  -- 6 slots
        { GoodID = G.Windows, Amount = 50 },  -- one more than the ship has
    });
    h:run();

    T.truthy(#h:logsMatching("needs 7 slots") > 0, "refused, and says why");
    T.eq(h.world:stock(10, G.Bricks), 600, "nothing left the source island");
    T.deep_eq(h.world:cargo(900), {}, "and nothing is stuck aboard");
end);

---

T.test("executor: the cargo vector is dense, so its keys are not slot numbers", function()
    -- Measured in-game: `Cargo Count` is the number of STACKS aboard, and the vector re-indexes
    -- when one is removed. So a key from Ship_Cargo_Get is a position, and handing it to
    -- Ship_Cargo_Clear -- which takes a real slot -- hits the wrong slot the moment there is a
    -- gap. Pinned by tests/game/contract_cargo.lua against the live game.
    local h = Harness.new(world());

    h.world:load(900, G.Bricks, 50);   -- real slot 0
    h.world:load(900, G.Windows, 50);  -- real slot 1
    h.world:load(900, G.Beer, 50);     -- real slot 2
    h.world:clearSlot(900, 0);         -- punch a hole at real slot 0

    local cargo = h.Anno.Ship_Cargo_Get(900);
    T.len(cargo, 2, "two stacks left");
    T.eq(cargo[0].Guid, G.Windows, "the vector starts at 0 again, not at the real slot number");
    T.eq(cargo[1].Guid, G.Beer, "Beer is at position 1 while sitting in real slot 2");
end);

T.test("executor: a normal order preserves an occupied hold with a gap", function()
    local h = Harness.new(world());

    h.world:load(900, G.Windows, 50);
    h.world:load(900, G.Beer, 50);
    h.world:clearSlot(900, 0);   -- Beer now sits alone in real slot 1
    local before = h.world:total(G.Beer);

    h.TradeExecutor.SpawnTradeOrder(h.L, "OW", command(G.Bricks, 150));
    h:run();

    T.deep_eq(h:taskErrors(), {}, "no errors");
    T.deep_eq(h.world:cargo(900), { [G.Beer] = 50 }, "gapped cargo is retained");
    T.eq(h.world:total(G.Beer), before, "beer is conserved");
    T.eq(h.world:stock(10, G.Bricks), 600, "source is untouched");
    T.eq(h.world:stock(20, G.Bricks), 50, "destination is untouched");
end);
