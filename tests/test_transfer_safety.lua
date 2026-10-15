-- Cargo transfers must conserve goods when stock, capacity, or ship ownership changes in flight.

local T = require("tests/lib/t");
local World = require("tests/lib/world");
local Harness = require("tests/lib/harness");
local G = require("tests/lib/goods");

local function harness()
    return Harness.new(World.new {
        region = "OW",
        areas = {
            { id = 10, capacity = 1000, at = { x = 100, y = 100 },
              stock = { [G.Bricks] = 500, [G.Windows] = 500 } },
            { id = 20, capacity = 75, at = { x = 900, y = 100 } },
        },
        ships = {
            { oid = 900, name = "a", slots = 6, speed = 100, at = { x = 100, y = 100 } },
        },
    });
end

local function command(goods)
    return {
        Ship_ID = 900,
        AreaID_from = 10,
        AreaID_to = 20,
        Goods = goods or { { GoodID = G.Bricks, Amount = 50 } },
        OrderDistance = {
            src = { x = 100, y = 100 },
            dst = { x = 900, y = 100 },
            dist = 800,
        },
        ShipDistance = 800,
        Ship_AmountPerSlot = 50,
    };
end

local function no_destination_credit(h)
    for _, entry in ipairs(h.world.goods_log) do
        T.falsy(entry.area == 20 and entry.amount > 0, "no good is credited before the whole hold fits");
    end
end

T.test("transfer safety: a destination filled during sailing retains the entire load", function()
    local h = harness();
    local before = h.world:total(G.Bricks);
    local changed = false;

    h.TradeExecutor.SpawnTradeOrder(h.L, "OW", command());
    h:run(2000, function()
        if not changed and h.world:cargo(900)[G.Bricks] == 50 and h.world:ship(900).moving then
            h.world:setStock(20, G.Bricks, 70);
            changed = true;
        end
    end);

    T.truthy(changed, "destination changed while the ship was sailing");
    T.deep_eq(h:taskErrors(), {}, "no task error");
    T.eq(h.world:stock(20, G.Bricks), 70, "75-capacity destination receives none of the 50 aboard");
    T.deep_eq(h.world:cargo(900), { [G.Bricks] = 50 }, "whole load remains aboard");
    T.eq(h.world:total(G.Bricks), before + 70, "only the external stock change affects the total");
    T.deep_eq(h.world.destroyed, {}, "no overflow destruction");
    T.len(h.TradeExecutor.Records, 1, "attempt is recorded");
    T.eq(h.TradeExecutor.Records[1].good_unloaded, 0, "record reports zero unloaded");
    no_destination_credit(h);
end);

T.test("transfer safety: one full good prevents every good in a mixed hold from unloading", function()
    local h = harness();
    local beforeBricks = h.world:total(G.Bricks);
    local beforeWindows = h.world:total(G.Windows);
    local changed = false;

    h.TradeExecutor.SpawnTradeOrder(h.L, "OW", command {
        { GoodID = G.Bricks, Amount = 50 },
        { GoodID = G.Windows, Amount = 50 },
    });
    h:run(2000, function()
        if not changed and h.world:cargo(900)[G.Windows] == 50 and h.world:ship(900).moving then
            h.world:setStock(20, G.Windows, 70);
            changed = true;
        end
    end);

    T.truthy(changed, "one destination good filled in flight");
    T.deep_eq(h:taskErrors(), {}, "no task error");
    T.eq(h.world:stock(20, G.Bricks), 0, "bricks also stay aboard despite their free space");
    T.eq(h.world:stock(20, G.Windows), 70, "windows do not overflow");
    T.deep_eq(h.world:cargo(900), { [G.Bricks] = 50, [G.Windows] = 50 }, "mixed hold is retained");
    T.eq(h.world:total(G.Bricks), beforeBricks, "bricks conserved");
    T.eq(h.world:total(G.Windows), beforeWindows + 70, "windows conserved after external addition");
    T.deep_eq(h.world.destroyed, {}, "nothing destroyed");
    for _, record in ipairs(h.TradeExecutor.Records) do
        T.eq(record.good_unloaded, 0, "every good records zero unloaded");
    end
    no_destination_credit(h);
end);

T.test("transfer safety: source depletion during approach limits cargo and the trade record", function()
    local h = harness();
    h.world:ship(900).at = { x = 500, y = 100 };
    local changed = false;

    h.TradeExecutor.SpawnTradeOrder(h.L, "OW", command());
    h:run(2000, function()
        local ship = h.world:ship(900);
        if not changed and ship.moving and ship.target.x == 100 then
            h.world:setStock(10, G.Bricks, 20);
            changed = true;
        end
    end);

    T.truthy(changed, "source depleted before arrival");
    T.deep_eq(h:taskErrors(), {}, "no task error");
    T.eq(h.world:stock(10, G.Bricks), 0, "only the remaining source stock left");
    T.eq(h.world:stock(20, G.Bricks), 20, "only actual stock arrived");
    T.eq(h.world:total(G.Bricks), 20, "no cargo was invented");
    T.deep_eq(h.world.created, {}, "no source underflow");
    T.len(h.TradeExecutor.Records, 1, "one good recorded");
    local record = h.TradeExecutor.Records[1];
    T.eq(record.good_amount, 50, "original request remains visible");
    T.eq(record.good_loaded, 20, "record reports actual amount loaded");
    T.eq(record.good_unloaded, 20, "record reports actual amount delivered");
end);

T.test("transfer safety: recovery unloads all physical slots of a gapped mixed hold", function()
    local h = harness();
    h.world:load(900, G.Beer, 50);
    h.world:load(900, G.Bricks, 50);
    h.world:load(900, G.Windows, 50);
    h.world:clearSlot(900, 0);
    local beforeBricks = h.world:total(G.Bricks);
    local beforeWindows = h.world:total(G.Windows);

    h.TradeExecutor._ExecuteUnloadWithShip(h.L, "OW", 900, 20, { x = 900, y = 100 });
    h:run();

    T.deep_eq(h:taskErrors(), {}, "no task error");
    T.deep_eq(h.world:cargo(900), {}, "all occupied physical slots cleared");
    T.eq(h.world:stock(20, G.Bricks), 50, "bricks recovered");
    T.eq(h.world:stock(20, G.Windows), 50, "windows recovered");
    T.eq(h.world:total(G.Bricks), beforeBricks, "bricks conserved");
    T.eq(h.world:total(G.Windows), beforeWindows, "windows conserved");
end);

T.test("transfer safety: recovery owns its ship before execution and through its final wait", function()
    local h = harness();
    local TE = h.TradeExecutor;
    h.world:load(900, G.Bricks, 50);
    local task = TE._ExecuteUnloadWithShip(h.L, "OW", 900, 20, { x = 900, y = 100 });

    T.truthy(task, "first recovery accepted");
    T.eq(TE.Ship_IsBusy(900), true, "ship claimed before the scheduler starts");
    T.nil_(TE._ExecuteUnloadWithShip(h.L, "OW", 900, 20, { x = 900, y = 100 }), "duplicate recovery refused");
    T.nil_(TE.SpawnTradeOrder(h.L, "OW", command()), "normal order cannot take a recovery ship");

    local sawFinalWait = false;
    h:run(2000, function()
        if h.world:slotsUsed(900) == 0 and h.async.get_task(task).state ~= "completed" then
            sawFinalWait = true;
            T.eq(TE.Ship_IsBusy(900), true, "ownership remains after cargo clears until task completion");
            T.nil_(TE.SpawnTradeOrder(h.L, "OW", command()), "final-wait normal order refused");
        end
    end);

    T.truthy(sawFinalWait, "observed the post-unload wait");
    T.deep_eq(h:taskErrors(), {}, "no task error");
    T.eq(TE.Ship_IsBusy(900), false, "completed recovery releases ownership");
end);

T.test("transfer safety: a normal voyage excludes duplicate orders and recovery until completion", function()
    local h = harness();
    local TE = h.TradeExecutor;
    local task = TE.SpawnTradeOrder(h.L, "OW", command());

    T.truthy(task, "first order accepted");
    T.eq(TE.Ship_IsBusy(900), true, "normal ship claimed before the scheduler starts");
    T.nil_(TE.SpawnTradeOrder(h.L, "OW", command()), "duplicate normal order refused");
    T.nil_(TE._ExecuteUnloadWithShip(h.L, "OW", 900, 20, { x = 900, y = 100 }), "recovery cannot take a normal ship");

    local sawFinalWait = false;
    h:run(2000, function()
        if h.world:stock(20, G.Bricks) == 50 and h.async.get_task(task).state ~= "completed" then
            sawFinalWait = true;
            T.eq(TE.Ship_IsBusy(900), true, "ship stays owned through final yields");
            T.nil_(TE._ExecuteUnloadWithShip(h.L, "OW", 900, 10, { x = 100, y = 100 }), "final-wait recovery refused");
        end
    end);

    T.truthy(sawFinalWait, "observed the normal voyage's final wait");
    T.deep_eq(h:taskErrors(), {}, "no task error");
    T.eq(TE.Ship_IsBusy(900), false, "completed normal order releases ownership");
    T.eq(h.world:stock(10, G.Bricks), 450, "only one order removed stock");
    T.len(TE.Records, 1, "only one trade recorded");
end);

T.test("transfer safety: a rejected oversized voyage releases ship ownership", function()
    local h = harness();
    local TE = h.TradeExecutor;

    TE.SpawnTradeOrder(h.L, "OW", command { { GoodID = G.Bricks, Amount = 350 } });
    h:run();

    T.eq(TE.Ship_IsBusy(900), false, "failed order releases ownership");
    T.truthy(#h:logsMatching("needs 7 slots") > 0, "oversized order was refused");
    T.truthy(TE.SpawnTradeOrder(h.L, "OW", command()), "a later valid order can claim the ship");
    h:run();
    T.deep_eq(h:taskErrors(), {}, "no scheduler error");
    T.eq(h.world:stock(20, G.Bricks), 50, "later order succeeds");
end);

T.test("transfer safety: recovery chooses using live per-good capacity instead of cached area capacity", function()
    local h = harness();
    h.world:load(900, G.Bricks, 50);
    h.world:load(900, G.Windows, 50);
    local areas = h:areas();
    areas[20].capacity = 2000;
    local capacity = h.Anno.Area_GetGoodCapacity;
    h.Anno.Area_GetGoodCapacity = function(region, areaID, guid)
        if areaID == 20 and guid == G.Windows then
            return 40;
        end
        return capacity(region, areaID, guid);
    end;

    local trades = h.TradePlannerLL.Ships_ForceUnloadStoppedShips(h.L, "OW", areas, { [900] = {} });

    T.len(trades, 1, "one recovery destination fits");
    T.eq(trades[1].command.Key.Order.AreaID_to, 10, "live windows capacity excludes the apparently roomiest island");
    h:run();
    T.deep_eq(h:taskErrors(), {}, "no task error");
    T.eq(h.world:stock(10, G.Bricks), 550, "bricks recovered at the safe island");
    T.eq(h.world:stock(10, G.Windows), 550, "windows recovered at the same island");
    T.deep_eq(h.world:cargo(900), {}, "hold emptied safely");
end);

T.test("transfer safety: recovery reserves incoming capacity across planner cycles", function()
    local h = harness();
    h.world:setStock(10, G.Bricks, 980);
    h.world.ships[901] = {
        oid = 901, name = "b", route = "TRA_OW", slots = 6, speed = 100,
        at = { x = 100, y = 100 }, cargo = {}, moving = false, target = nil,
    };
    table.insert(h.world.ship_order, 901);
    h.world:load(900, G.Bricks, 50);
    h.world:load(901, G.Bricks, 50);
    local before = h.world:total(G.Bricks);

    local first = h.TradePlannerLL.Ships_ForceUnloadStoppedShips(h.L, "OW", h:areas(), { [900] = {} });
    T.len(first, 1, "first ship claims the only destination with room");
    T.eq(first[1].command.Key.Order.AreaID_to, 20, "75 units free at destination");
    h:step();
    T.eq(h.world:stock(20, G.Bricks), 0, "first ship has not arrived yet");

    local second = h.TradePlannerLL.Ships_ForceUnloadStoppedShips(
        h.L, "OW", h:areas(), { [901] = {} }, first);

    T.len(second, 0, "second cycle sees the 50 units already promised to the destination");
    h:run();
    T.deep_eq(h:taskErrors(), {}, "no task error");
    T.eq(h.world:stock(20, G.Bricks), 50, "only the first ship delivers");
    T.deep_eq(h.world:cargo(901), { [G.Bricks] = 50 }, "second ship keeps its cargo");
    T.eq(h.world:total(G.Bricks), before, "both holds conserved");
end);

T.test("transfer safety: a busy ship restores planner supply and requests when dispatch is refused", function()
    -- The same producer/city fixture as test_planner.lua: consumer goods have no construction
    -- demand at the source, so all three offers and requests are produced by the real planner.
    local goods = { G.Beer, G.Sausages, G.Bread };
    local h = Harness.new(World.new {
        areas = {
            { id = 10, capacity = 1000, at = { x = 100, y = 100 },
              stock = { [G.Beer] = 100, [G.Sausages] = 100, [G.Bread] = 100 } },
            { id = 20, capacity = 1000, at = { x = 900, y = 100 }, requests = goods,
              stock = { [G.Beer] = 50, [G.Sausages] = 50, [G.Bread] = 50 } },
        },
        ships = { { oid = 900, name = "a", slots = 6, at = { x = 100, y = 100 } } },
    });
    local planner = h.TradePlannerLL;
    local srt = planner.SupplyRequest_Build(h.L, "OW", {}, h:areas(), h:state());
    local orders = planner.SupplyRequest_ToOrders(h.L, srt, h:areas());
    local ships = h:availableShips();
    local commands = planner.SupplyRequestOrders_ToShipCommands(h.L, h:areas(), ships, orders, h:state());
    T.len(commands, 3, "three offers were planned before the ship became busy");
    T.truthy(h.TradeExecutor.SpawnTradeOrder(h.L, "OW", command { { GoodID = G.Beer, Amount = 50 } }),
        "another order claims the ship before these commands dispatch");

    local trades = planner.SupplyRequestShipCommands_Execute(h.L, "OW", srt, commands, ships);

    T.len(trades, 0, "busy ship accepts none of the planned commands");
    for _, guid in ipairs(goods) do
        T.eq(srt.Supply[10][guid], 100, "source offer restored for good " .. guid);
        T.eq(srt.Request[20][guid], 450, "destination request restored for good " .. guid);
    end
    h:run();
    T.deep_eq(h:taskErrors(), {}, "no task error");
    T.len(h.TradeExecutor.Records, 1, "only the previously accepted order executes");
end);

T.test("transfer safety: the final source unit is neither debited nor rounded into extra cargo", function()
    local h = harness();
    h.world:setStock(10, G.Bricks, 1);
    local cargoSet = h.Anno.Ship_Cargo_Set;
    h.Anno.Ship_Cargo_Set = function(oid, slot, cargo)
        -- The real one-unit cargo cheat rounds to two; the ordinary world fake does not.
        return cargoSet(oid, slot, { Guid = cargo.Guid, Value = cargo.Value == 1 and 2 or cargo.Value });
    end;

    h.TradeExecutor.SpawnTradeOrder(h.L, "OW", command());
    h:run();

    T.deep_eq(h:taskErrors(), {}, "no task error");
    T.eq(h.world:stock(10, G.Bricks), 1, "untransferable last unit remains at the source");
    T.eq(h.world:stock(20, G.Bricks), 0, "destination receives none");
    T.deep_eq(h.world:cargo(900), {}, "no rounded cargo aboard");
    T.eq(h.world:total(G.Bricks), 1, "exactly the original unit still exists");
    T.deep_eq(h.world.goods_log, {}, "no warehouse debit or credit");
    T.len(h.TradeExecutor.Records, 0, "no completed trade for an empty voyage");
end);

T.test("transfer safety: invalid per-good destination capacity preserves the entire recovery hold", function()
    for _, invalid in ipairs({ { label = "unreadable" }, { label = "negative", capacity = -1 } }) do
        local h = harness();
        h.world:load(900, G.Bricks, 50);
        h.world:load(900, G.Windows, 50);
        local capacity = h.Anno.Area_GetGoodCapacity;
        h.Anno.Area_GetGoodCapacity = function(region, areaID, guid)
            if areaID == 20 and guid == G.Windows then
                return invalid.capacity;
            end
            return capacity(region, areaID, guid);
        end;

        h.TradeExecutor._ExecuteUnloadWithShip(h.L, "OW", 900, 20, { x = 900, y = 100 });
        h:run();

        T.deep_eq(h:taskErrors(), {}, invalid.label .. ": failure handled by the executor");
        T.deep_eq(h.world:cargo(900), { [G.Bricks] = 50, [G.Windows] = 50 }, invalid.label .. ": whole hold retained");
        T.eq(h.world:stock(20, G.Bricks), 0, invalid.label .. ": no bricks credited");
        T.eq(h.world:stock(20, G.Windows), 0, invalid.label .. ": no windows credited");
        T.eq(h.TradeExecutor.Ship_IsBusy(900), false, invalid.label .. ": ownership released after refusal");
        no_destination_credit(h);
    end
end);

T.test("transfer safety: the high-level loop recovers a loaded fleet when capacity becomes available", function()
    local h = harness();
    h.world:setStock(10, G.Bricks, 980);
    h.world:setStock(20, G.Bricks, 70);
    h.world:load(900, G.Bricks, 50);
    local before = h.world:total(G.Bricks);

    -- Keep the real high-level loop, ship classification, low-level planner and scheduler.
    -- Substitute only its map/cache/UI boundaries that the ordinary executor harness omits.
    local prefix = "trade_route_automation/";
    package.loaded[prefix .. "anno_object_accessor"].GameObject = function(oid)
        return { Nameable = { Name = h.world:ship(oid).name } };
    end;
    package.loaded[prefix .. "utils_cache"] = { WriteTo = function() end };
    package.loaded[prefix .. "mod_map_scanner"] = {};
    package.loaded[prefix .. "mod_map_scanner_hl"] = {
        Region_AllAreas_Get = function() return h:areas(); end,
        Areas = function() return h:areas(); end,
    };
    package.loaded[prefix .. "ui_cmds"] = { AreaRescan = { Events = {} }, RegionRescan = { Events = {} } };
    local highLevel = require(prefix .. "mod_trade_planner_hl");
    local stop, opened = false, false;
    h.async.spawn(function()
        highLevel.Loop(h.L, "OW", function() return stop; end);
    end);

    local ticks = h:run(2000, function()
        if not opened and #h:logsMatching("No available ships for trade routes automation") > 0 then
            -- Startup could not unload anywhere. Only later regular iterations can recover this
            -- ship, and every ship is loaded, so the free-ship set is still empty.
            h.world:setStock(20, G.Bricks, 0);
            opened = true;
        end
        if opened and h.world:slotsUsed(900) == 0 then
            stop = true;
        end
    end);

    T.truthy(opened, "capacity opened after an iteration with no free ships");
    T.truthy(ticks < 2000, "loop recovered the fleet and stopped");
    T.deep_eq(h:taskErrors(), {}, "real loop and recovery completed without error");
    T.eq(#h:logsMatching("[Error]"), 0, "no swallowed high-level iteration error");
    T.eq(h.world:stock(20, G.Bricks), 50, "cargo recovered on a later iteration");
    T.deep_eq(h.world:cargo(900), {}, "fleet is usable again");
    T.eq(h.world:total(G.Bricks), before - 70, "only the explicit capacity-opening removal changed the total");
end);
