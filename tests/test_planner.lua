--[[
    Characterization tests for mod_trade_planner_ll.lua.

    The scenario throughout is the one the ship-packing work is about: a producer island with a
    modest surplus of several goods, a city that wants all of them, and one big ship.

    The goods are Beer, Sausages and Bread rather than Bricks and Windows on purpose: every island
    carries a standing request for the 9 *construction* goods, so no island can ever be a pure
    supplier of those. Consumer goods are where a producer/consumer split actually exists.

    With capacity 1000 the planner's thresholds come out as:
        o2 = min(200, 1000 * 0.2) = 200     -- request when stock is below this
        o4 = min(225, 1000 * 0.4) = 225     -- a producer exports down to this
        o6 = min(o2 + 300, 500, 600) = 500  -- and refills TO this: it asks for `o6 - stock`
        o8 = min(o4 + 300, 525, 800) = 525  -- a consumer exports down to this
]]

local T = require("tests/lib/t");
local World = require("tests/lib/world");
local Harness = require("tests/lib/harness");
local G = require("tests/lib/goods");

local SASSENBERG, SIPHINGTON = 10, 20;

--- Producer has 100 spare of each of three goods; the city is low on all three; one 6-slot ship.
local function world(opts)
    opts = opts or {};
    return World.new {
        region = "OW",
        areas = {
            { id = SASSENBERG, name = "Sassenberg", capacity = 1000, at = { x = 100, y = 100 },
              stock = { [G.Beer] = 100, [G.Sausages] = 100, [G.Bread] = 100 } },
            { id = SIPHINGTON, name = "Siphington", capacity = 1000, at = { x = 900, y = 100 },
              requests = { G.Beer, G.Sausages, G.Bread },
              stock = { [G.Beer] = 50, [G.Sausages] = 50, [G.Bread] = 50 } },
        },
        ships = {
            { oid = 900, name = "a", slots = opts.slots or 6, speed = 400, at = { x = 100, y = 100 } },
        },
    };
end

---@param h Harness
local function buildSupplyRequest(h)
    return h.TradePlannerLL.SupplyRequest_Build(h.L, "OW", {}, h:areas(), h:state());
end

--- goodID -> amount, for one area, so assertions read in terms of goods rather than nesting.
local function forArea(tbl, areaID)
    local ret = {};
    for goodID, amount in pairs(tbl[areaID] or {}) do
        ret[goodID] = amount;
    end
    return ret;
end

---

T.test("planner: a producer offers its whole stock as surplus", function()
    local h = Harness.new(world());
    local srt = buildSupplyRequest(h);

    T.deep_eq(forArea(srt.Supply, SASSENBERG), {
        [G.Beer] = 100,
        [G.Sausages] = 100,
        [G.Bread] = 100,
    }, "producer supply");

    -- it still requests the 9 construction goods, as every island does
    T.nil_(forArea(srt.Request, SASSENBERG)[G.Beer], "but not the goods it produces");
end);

T.test("planner: a city below o2 asks for the shortfall against o6, not for o6", function()
    -- The ask is an amount, not a level: holding 50 against o6 = 500 it wants 450 delivered, so
    -- it lands ON o6 rather than overshooting to 550. Issue #14.
    local h = Harness.new(world());
    local srt = buildSupplyRequest(h);

    local requests = forArea(srt.Request, SIPHINGTON);
    T.eq(requests[G.Beer], 450, "Beer: 500 - the 50 it holds");
    T.eq(requests[G.Sausages], 450, "Sausages");
    T.eq(requests[G.Bread], 450, "Bread");

    T.deep_eq(forArea(srt.Supply, SIPHINGTON), {}, "and offers nothing while it is short");
end);

T.test("planner: a city above o2 stops asking", function()
    local h = Harness.new(world());
    h.world:setStock(SIPHINGTON, G.Beer, 250); -- o2 is 200

    local srt = buildSupplyRequest(h);
    local requests = forArea(srt.Request, SIPHINGTON);

    T.nil_(requests[G.Beer], "no longer requested");
    T.eq(requests[G.Sausages], 450, "the goods it is still short of are unaffected");
    T.eq(forArea(srt.Supply, SIPHINGTON)[G.Beer], 25,
        "and it exports down to its producer floor o4 = 225, not to o2");
end);

T.test("planner: goods nobody consumes are invisible to the planner", function()
    local h = Harness.new(world());
    h.world:setStock(SASSENBERG, G.Coffee, 900);

    local srt = buildSupplyRequest(h);

    T.nil_(forArea(srt.Supply, SASSENBERG)[G.Coffee],
        "no island requests Coffee, so it is never even considered for export");
end);

T.test("planner: an island with no water route gets no orders", function()
    local h = Harness.new(world());
    local areas = h:areas();
    areas[SASSENBERG].water_points = nil;

    local orders = h.TradePlannerLL.SupplyRequest_ToOrders(h.L, buildSupplyRequest(h), areas);

    T.len(orders, 0, "nothing routable");
end);

---

T.test("planner: one order per (source, destination, good)", function()
    local h = Harness.new(world());
    local orders = h.TradePlannerLL.SupplyRequest_ToOrders(h.L, buildSupplyRequest(h), h:areas());

    T.len(orders, 3, "three goods, one supplier, one requester");

    for _, o in ipairs(orders) do
        T.eq(o.Key.AreaID_from, SASSENBERG, "from the producer");
        T.eq(o.Key.AreaID_to, SIPHINGTON, "to the city");
        T.eq(o.Key.SupplyAmount, 100, "what the producer can spare");
        T.eq(o.Key.RequestAmount, 450, "what the city asked for");
        T.eq(o.Value.OrderDistance.dist, 800, "distance between the two piers");
    end
end);

T.test("planner: each ship is offered every order", function()
    local h = Harness.new(world());
    local orders = h.TradePlannerLL.SupplyRequest_ToOrders(h.L, buildSupplyRequest(h), h:areas());

    local commands = h.TradePlannerLL.SupplyRequestOrders_ToShipCommands(
        h.L, h:areas(), h:availableShips(), orders, h:state());

    T.len(commands, 3, "one ship x three orders");

    for _, c in ipairs(commands) do
        T.eq(c.Key.ShipID, 900, "the only ship");
        T.eq(c.Value.ShipSlots, 6, "six slots");
        T.len(c.Key.Order.Goods, 1, "one good per command at this stage");
        T.eq(c.Key.Order.Goods[1].Amount, 100, "min(ship capacity 300, supply 100, request 500)");
    end
end);

T.test("planner: a ship too small to hold one slot is skipped", function()
    local h = Harness.new(world { slots = 0 });
    local orders = h.TradePlannerLL.SupplyRequest_ToOrders(h.L, buildSupplyRequest(h), h:areas());

    local commands = h.TradePlannerLL.SupplyRequestOrders_ToShipCommands(
        h.L, h:areas(), h:availableShips(), orders, h:state());

    T.len(commands, 0, "no commands for a ship with no hold");
end);

---

--- Runs the whole low-level pipeline the way mod_trade_planner_hl does.
---@param h Harness
local function dispatch(h)
    local srt = buildSupplyRequest(h);
    local orders = h.TradePlannerLL.SupplyRequest_ToOrders(h.L, srt, h:areas());
    local ships = h:availableShips();
    local commands = h.TradePlannerLL.SupplyRequestOrders_ToShipCommands(
        h.L, h:areas(), ships, orders, h:state());

    local trades = h.TradePlannerLL.SupplyRequestShipCommands_Execute(
        h.L, "OW", srt, commands, ships);

    return trades, srt;
end

T.test("planner: one ship carries every good the same run has waiting", function()
    -- The producer has 300 units spare across three goods and the city wants all three. The ship
    -- holds 300, so one voyage clears the lot. Before packing it left with 100 of a single good,
    -- filling 2 of its 6 slots, and the other two goods stayed on the quay.
    local h = Harness.new(world());

    local trades = dispatch(h);
    T.len(trades, 1, "one voyage");
    T.len(trades[1].command.Key.Order.Goods, 3, "carrying all three goods");

    local peakSlots = 0;
    h:run(2000, function()
        peakSlots = math.max(peakSlots, h.world:slotsUsed(900));
    end);
    T.deep_eq(h:taskErrors(), {}, "no errors");

    T.eq(peakSlots, 6, "6 of 6 slots used -- the ship sailed full");

    local moved = 0;
    local goodsMoved = 0;
    for _, guid in ipairs({ G.Beer, G.Sausages, G.Bread }) do
        local delivered = h.world:stock(SIPHINGTON, guid) - 50;
        if delivered > 0 then
            goodsMoved = goodsMoved + 1;
            moved = moved + delivered;
        end
    end

    T.eq(goodsMoved, 3, "all three goods travelled");
    T.eq(moved, 300, "and all 300 units that were waiting");
end);

T.test("planner: dispatching draws down the supply and request tables", function()
    local h = Harness.new(world());
    local _, srt = dispatch(h);

    local supplyLeft = 0;
    for _, amount in pairs(forArea(srt.Supply, SASSENBERG)) do
        supplyLeft = supplyLeft + amount;
    end

    T.eq(supplyLeft, 0, "300 offered, all 300 committed to the one voyage");
end);

T.test("planner: a second ship is only sent for what the first could not fit", function()
    -- 150 of each good waiting, 450 in all, and a hull takes 300. The first ship packs two goods
    -- and fills up; the second carries the one that was left. Before packing, each ship took a
    -- single good, so the two of them moved 300 between them and 150 stayed on the quay.
    local h = Harness.new(world());
    for _, guid in ipairs({ G.Beer, G.Sausages, G.Bread }) do
        h.world:setStock(SASSENBERG, guid, 150);
    end

    h.world.ships[901] = {
        oid = 901, name = "b", route = "TRA_OW", slots = 6, speed = 400,
        at = { x = 100, y = 100 }, cargo = {}, moving = false, target = nil,
    };
    table.insert(h.world.ship_order, 901);

    local trades = dispatch(h);
    T.len(trades, 2, "two ships, two voyages");
    T.len(trades[1].command.Key.Order.Goods, 2, "the first ship packed two goods");
    T.len(trades[2].command.Key.Order.Goods, 1, "the second took what was left over");

    h:run();
    T.deep_eq(h:taskErrors(), {}, "no errors");

    local delivered = 0;
    for _, guid in ipairs({ G.Beer, G.Sausages, G.Bread }) do
        delivered = delivered + (h.world:stock(SIPHINGTON, guid) - 50);
    end
    T.eq(delivered, 450, "everything moved, not the 300 two unpacked hulls would have managed");
end);

T.test("planner: a part-full stack still costs a whole slot", function()
    -- 30 units of each good is 90 units in total -- under two slots' worth -- but three goods
    -- cannot share a slot, so they occupy three. A packer budgeting in units would think this
    -- hull had room for another 210 and overfill it.
    local h = Harness.new(world { slots = 3 });
    for _, guid in ipairs({ G.Beer, G.Sausages, G.Bread }) do
        h.world:setStock(SASSENBERG, guid, 30);
    end

    local trades = dispatch(h);
    T.len(trades, 1, "one voyage");
    T.len(trades[1].command.Key.Order.Goods, 3, "all three goods, one slot each");

    local peakSlots = 0;
    h:run(2000, function()
        peakSlots = math.max(peakSlots, h.world:slotsUsed(900));
    end);

    T.deep_eq(h:taskErrors(), {}, "no errors");
    T.eq(peakSlots, 3, "three part-full slots");
end);

T.test("planner: a ship is not packed with goods the destination has stopped wanting", function()
    -- Only goods that crossed the request threshold on their own merit are eligible. Topping a
    -- hull up with something the city is already stocked on would fight the direction memory and
    -- get shipped straight back next cycle.
    local h = Harness.new(world());
    h.world:setStock(SIPHINGTON, G.Beer, 250); -- above o2 = 200, so no longer requested

    local trades = dispatch(h);
    T.len(trades, 1, "one voyage");

    for _, g in ipairs(trades[1].command.Key.Order.Goods) do
        T.truthy(g.GoodID ~= G.Beer, "Beer stayed behind");
    end
    T.len(trades[1].command.Key.Order.Goods, 2, "only the two goods still wanted");
end);

T.test("planner: goods are conserved through a full dispatch", function()
    local h = Harness.new(world());
    local before = {};
    for _, guid in ipairs({ G.Beer, G.Sausages, G.Bread }) do
        before[guid] = h.world:total(guid);
    end

    dispatch(h);
    h:run();

    for _, guid in ipairs({ G.Beer, G.Sausages, G.Bread }) do
        T.eq(h.world:total(guid), before[guid], "conserved: " .. G.name[guid]);
    end
    T.deep_eq(h.world.created, {}, "nothing invented");
    T.deep_eq(h.world.destroyed, {}, "nothing destroyed");
end);
