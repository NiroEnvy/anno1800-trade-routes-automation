--[[
    Characterization tests for TradePlannerLL.Ships_StockInFlight.

    In-flight tracking is what stops the planner from sending five ships to fix the same shortage.
    Its rule:

      - a ship that has NOT loaded yet has its cargo counted at both ends -- removed from the
        source, which has promised it away, and added to the destination, which is already
        expecting it
      - a ship that HAS loaded is counted only at the destination, because the source's real
        stock has already dropped

    The first half of that used to be source-only, which reserved nothing against the
    destination's request. See "an unloaded voyage still reserves the destination's request".
]]

local T = require("tests/lib/t");
local World = require("tests/lib/world");
local Harness = require("tests/lib/harness");
local G = require("tests/lib/goods");

-- Alpaca Wool, not a construction good: an island can hold it without consuming it.
G.AlpacaWool = G["Alpaca Wool"];

local SASSENBERG, SIPHINGTON = 10, 20;

local function world()
    return World.new {
        region = "OW",
        areas = {
            { id = SASSENBERG, name = "Sassenberg", capacity = 1000, at = { x = 100, y = 100 },
              stock = { [G.AlpacaWool] = 600 } },
            { id = SIPHINGTON, name = "Siphington", capacity = 1000, at = { x = 900, y = 100 },
              requests = { G.AlpacaWool }, stock = { [G.AlpacaWool] = 50 } },
        },
        ships = {
            { oid = 900, name = "a", slots = 6, speed = 400, at = { x = 100, y = 100 } },
        },
    };
end

--- A voyage in progress, carrying one good -- `trade(G.AlpacaWool, 150)` -- or several,
--- `trade({ { GoodID = G.AlpacaWool, Amount = 150 }, ... })`.
local function trade(goodID, amount)
    local goods = goodID;
    if type(goodID) == "number" then
        goods = { { GoodID = goodID, Amount = amount } };
    end

    return {
        coroutineID = 1,
        command = {
            Key = {
                ShipID = 900,
                Order = { AreaID_from = SASSENBERG, AreaID_to = SIPHINGTON, Goods = goods },
            },
            Value = {},
        },
    };
end

---

T.test("in-flight: a ship on its way to load is counted at BOTH ends", function()
    -- While the hold is still empty the goods are two things at once: stock the source has
    -- promised away, and stock the destination is already expecting. Counting only the source
    -- was what let four cycles in a row dispatch against a single request -- see the oversupply
    -- test below.
    local h = Harness.new(world());
    h.TradeExecutor.Ship_Name_StoreCmdInfo(900, { x = 100, y = 100, area_id = SASSENBERG, name = "a" });

    local flight = h.TradePlannerLL.Ships_StockInFlight(h.L, "OW", { trade(G.AlpacaWool, 150) });

    T.deep_eq(flight[SASSENBERG][G.AlpacaWool], { In = 0, Out = 150 }, "150 spoken for at the source");
    T.deep_eq(flight[SIPHINGTON][G.AlpacaWool], { In = 150, Out = 0 }, "and already reserved against the destination's request");
end);

T.test("in-flight: a loaded ship counts towards the destination island", function()
    local h = Harness.new(world());
    h.TradeExecutor.Ship_Name_StoreCmdInfo(900, { x = 900, y = 100, area_id = SIPHINGTON, name = "a" });
    h.world:load(900, G.AlpacaWool, 150);

    local flight = h.TradePlannerLL.Ships_StockInFlight(h.L, "OW", { trade(G.AlpacaWool, 150) });

    T.deep_eq(flight[SIPHINGTON][G.AlpacaWool], { In = 150, Out = 0 }, "150 already on the water");
    T.nil_(flight[SASSENBERG], "the source has let go of them");
end);

T.test("in-flight: what is actually aboard wins over what was ordered", function()
    local h = Harness.new(world());
    h.TradeExecutor.Ship_Name_StoreCmdInfo(900, { x = 900, y = 100, area_id = SIPHINGTON, name = "a" });
    h.world:load(900, G.AlpacaWool, 80); -- the island only had 80 to give

    local flight = h.TradePlannerLL.Ships_StockInFlight(h.L, "OW", { trade(G.AlpacaWool, 150) });

    T.eq(flight[SIPHINGTON][G.AlpacaWool].In, 80, "the order said 150, the hold says 80");
end);

T.test("in-flight: a ship whose name carries no destination is ignored", function()
    local h = Harness.new(world());
    h.world:ship(900).name = "a"; -- never dispatched, so nothing is encoded

    local flight = h.TradePlannerLL.Ships_StockInFlight(h.L, "OW", { trade(G.AlpacaWool, 150) });

    T.deep_eq(flight, {}, "no in-flight goods attributed anywhere");
end);

---

T.test("in-flight: incoming goods shrink what a city asks for", function()
    local h = Harness.new(world());

    local none = h.TradePlannerLL.SupplyRequest_Build(h.L, "OW", {}, h:areas(), h:state());
    T.eq(none.Request[SIPHINGTON][G.AlpacaWool], 450,
        "holding 50, it asks for the 450 that would put it on o6");

    local flight = { [SIPHINGTON] = { [G.AlpacaWool] = { In = 300, Out = 0 } } };
    local withFlight = h.TradePlannerLL.SupplyRequest_Build(h.L, "OW", flight, h:areas(), h:state());
    T.eq(withFlight.Request[SIPHINGTON][G.AlpacaWool], 150, "450 - 300 already on the water");
end);

T.test("in-flight: enough already coming means no new request at all", function()
    local h = Harness.new(world());

    local flight = { [SIPHINGTON] = { [G.AlpacaWool] = { In = 440, Out = 0 } } };
    local srt = h.TradePlannerLL.SupplyRequest_Build(h.L, "OW", flight, h:areas(), h:state());

    T.nil_(srt.Request[SIPHINGTON][G.AlpacaWool],
        "440 of the 450 shortfall is already sailing; the remaining 10 is below the 25-unit "
        .. "minimum transfer, so no request is raised");
end);

T.test("in-flight: a supplier island subtracts outgoing goods exactly once", function()
    -- Sassenberg holds 600 Alpaca Wool and does not consume it, so 100 already in flight leaves
    -- 500 on offer. This used to come out as 400: the subtraction happened once for every area
    -- and then a second time for areas that do not consume the good.
    local h = Harness.new(world());

    local flight = { [SASSENBERG] = { [G.AlpacaWool] = { In = 0, Out = 100 } } };
    local srt = h.TradePlannerLL.SupplyRequest_Build(h.L, "OW", flight, h:areas(), h:state());

    T.eq(srt.Supply[SASSENBERG][G.AlpacaWool], 500, "600 - 100");
end);
---

T.test("in-flight: an unloaded voyage still reserves the destination's request", function()
    -- Reproduces the n5 oversupply of 2026-08-23. A cycle runs roughly every ten seconds; sailing
    -- to the pickup island takes longer than that. So the planner gets several goes at the same
    -- shortage while the first ships are still on their way to collect, and unless their cargo is
    -- already reserved against the destination it sends more ships every time.
    --
    -- n5 held 80 Bricks in a 600-unit store and asked for 360. 950 arrived.
    --
    -- Since #14 the ask is the shortfall rather than the level, so the same island asks 280 --
    -- the 360 it wants to reach, less the 80 it already holds.
    local N1, N5 = 30, 40;

    local h = Harness.new(World.new {
        region = "OW",
        areas = {
            { id = N1, name = "n1", capacity = 2000, at = { x = 100, y = 100 },
              stock = { [G.Bricks] = 2000 } },
            { id = N5, name = "n5", capacity = 600, at = { x = 900, y = 100 },
              stock = { [G.Bricks] = 80 } },
        },
        -- Parked far from the pickup and slow, so a cycle elapses with every hold still empty --
        -- which is the whole point.
        ships = {
            { oid = 901, name = "a", slots = 4, speed = 20, at = { x = 100, y = 900 } },
            { oid = 902, name = "b", slots = 4, speed = 20, at = { x = 100, y = 900 } },
            { oid = 903, name = "c", slots = 4, speed = 20, at = { x = 100, y = 900 } },
            { oid = 904, name = "d", slots = 4, speed = 20, at = { x = 100, y = 900 } },
        },
    });

    --- One planning cycle over whichever ships are still idle.
    local function cycle(inFlight, shipOIDs)
        local state = h:state();
        local srt = h.TradePlannerLL.SupplyRequest_Build(h.L, "OW", inFlight, h:areas(), state);
        local orders = h.TradePlannerLL.SupplyRequest_ToOrders(h.L, srt, h:areas());
        local ships = h:availableShips(shipOIDs);
        local commands = h.TradePlannerLL.SupplyRequestOrders_ToShipCommands(
            h.L, h:areas(), ships, orders, state);
        return h.TradePlannerLL.SupplyRequestShipCommands_Execute(h.L, "OW", srt, commands, ships);
    end

    local function bricksTo(trades, areaID)
        local total = 0;
        for _, t in ipairs(trades) do
            if t.command.Key.Order.AreaID_to == areaID then
                for _, g in ipairs(t.command.Key.Order.Goods) do
                    if g.GoodID == G.Bricks then
                        total = total + g.Amount;
                    end
                end
            end
        end
        return total;
    end

    -- Cycle one: two ships are sent, covering the whole 280 the island asked for.
    local first = cycle({}, { 901, 902 });
    local sent1 = bricksTo(first, N5);
    T.eq(sent1, 280, "the first cycle covers the request in full (o6 = 360, less the 80 it holds)");

    -- A few ticks pass. They are slow and far away, so nothing has loaded.
    h:run(3);
    T.eq(h.world:slotsUsed(901), 0, "ship a has not loaded");
    T.eq(h.world:slotsUsed(902), 0, "ship b has not loaded");

    -- Cycle two, as the real loop runs it: in-flight computed from the voyages already out.
    local flight = h.TradePlannerLL.Ships_StockInFlight(h.L, "OW", first);
    local reserved = ((flight[N5] or {})[G.Bricks] or { In = 0 }).In;
    T.eq(reserved, 280, "the 280 already committed is visible at the destination");

    local second = cycle(flight, { 903, 904 });
    T.eq(bricksTo(second, N5), 0, "so the second cycle sends nothing more");

    -- The failure this prevents: without the reservation the island would be swamped.
    local headroom = 600 - 80;
    T.truthy(sent1 <= headroom,
        "and what was sent fits in the store, rather than overflowing and being destroyed");
end);
