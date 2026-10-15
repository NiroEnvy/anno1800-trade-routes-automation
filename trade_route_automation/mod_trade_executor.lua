--[[
    Trade Executor Module

    DOCUMENTATION: See docs/CLAUDE_architecture-trade-automation.md
    - Overview: "mod_trade_executor.lua (Ship Command Execution)"
    - Key sections:
      * Ship Name Encoding (Base62 Trick) - explains the encoding system
      * Trade Execution - flow of individual trade orders
      * Trade Records - what gets logged

    This module handles asynchronous execution of individual trade orders.
    It moves ships, loads/unloads cargo, and records all completed trades.

    Key functions:
    - Ship_Name_StoreCmdInfo/FetchCmdInfo: Encode destination in ship name
    - _ExecuteTradeOrderWithShip: Main async executor (lines 218-317)
    - SpawnTradeOrder: Wrapper that spawns async task

    Requires: lua/utils_async.lua, lua/mod_ship_cmd.lua
]]

local TradeExecutor = {}

local Anno = require("trade_route_automation/anno_interface");
local async = require("trade_route_automation/utils_async");
local shipCmd = require("trade_route_automation/mod_ship_cmd");
local objectAccessor = require("trade_route_automation/anno_object_accessor");
local AnnoInfo = require("trade_route_automation/generator/products");

---


local alphabet = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
local SEPARATOR = "-";

-- A task owns its ship even while queued, loading, or finishing with an empty
-- hold. Movement/cargo alone cannot distinguish those states from idle.
local busyShips = {};

---@param ship_oid ShipID
---@return boolean
function TradeExecutor.Ship_IsBusy(ship_oid)
    return busyShips[ship_oid] == true;
end

local function SpawnShipTask(L, ship_oid, execute)
    if TradeExecutor.Ship_IsBusy(ship_oid) then
        return nil;
    end
    busyShips[ship_oid] = true;
    return async.spawn(function()
        local success, result = xpcall(execute, debug.traceback);
        busyShips[ship_oid] = nil;
        if not success then
            L.logf("[Error] executing cargo task for ship %d: %s", ship_oid, tostring(result));
        end
        return result;
    end);
end

function TradeExecutor.numberToBase62(num)
    if num == 0 then
        return "0"
    end

    local result = ""

    while num > 0 do
        local remainder = num % #alphabet
        result = alphabet:sub(remainder + 1, remainder + 1) .. result
        num = math.floor(num / #alphabet)
    end

    return result
end

function TradeExecutor.base62ToNumber(str)
    local num = 0

    for i = 1, #str do
        local char = str:sub(i, i)
        local index = string.find(alphabet, char) - 1
        num = num * #alphabet + index
    end

    return num
end

function TradeExecutor.Ship_Name_StoreCmdInfo(oid, dst)
    local x = dst.x;
    local y = dst.y;
    local areaID = dst.area_id;
    local name = dst.name;

    if dst.x == nil or dst.y == nil or dst.area_id == nil
        or dst.x <= 0 or dst.y <= 0 or dst.area_id <= 0 then
        error(string.format("Invalid dst info to store in ship name: x=%s, y=%s, area_id=%s",
            tostring(dst.x), tostring(dst.y), tostring(dst.area_id)));
    end

    if not name then
        local name1 = Anno.Ship_Name_Get(oid);
        local sep = string.find(name1, SEPARATOR);
        if sep then
            name = string.sub(name1, 1, sep - 1);
        else
            name = name1:sub(1, 2);
        end
    end

    local info = name .. SEPARATOR ..
        TradeExecutor.numberToBase62(x) .. SEPARATOR ..
        TradeExecutor.numberToBase62(y) .. SEPARATOR ..
        TradeExecutor.numberToBase62(areaID);
    Anno.Ship_Name_Set(oid, info);
end

---@class ShipInfo
---@field name string
---@field x number|nil
---@field y number|nil
---@field area_id number|nil

---@return ShipInfo
function TradeExecutor.Ship_Name_FetchCmdInfo(oid)
    local name = Anno.Ship_Name_Get(oid);
    -- if name characters are outside the alphabet, then no info is packed
    for c in string.gmatch(name, ".") do
        if not string.find(alphabet, c, 1, true) and c ~= SEPARATOR then
            return { name = name };
        end
    end

    local parts = {};
    for part in string.gmatch(name, "([^" .. SEPARATOR .. "]+)") do
        table.insert(parts, part);
    end

    if #parts < 4 then
        return { name = name }; -- No info packed
    end

    local info = {
        name = parts[1],
        x = TradeExecutor.base62ToNumber(parts[2]),
        y = TradeExecutor.base62ToNumber(parts[3]),
        area_id = TradeExecutor.base62ToNumber(parts[4])
    };

    if info.x == nil or info.y == nil or info.area_id == nil
        or info.x <= 0 or info.y <= 0 or info.area_id <= 0 then
        return { name = name }; -- Invalid info
    end

    return info;
end

---

local function dst_moveTo(
    ship_oid,
    dst_coords,
    areaID_dst
)
    TradeExecutor.Ship_Name_StoreCmdInfo(ship_oid, {
        x = dst_coords.x,
        y = dst_coords.y,
        area_id = areaID_dst
    })
    shipCmd.MoveShipToAsync(
        ship_oid,
        dst_coords.x,
        dst_coords.y
    )
end

--- Puts the WHOLE hold ashore at `areaID_dst` and empties it.
---
--- Every good aboard is credited, not just the one the voyage was ordered for. The old version
--- credited a single good and then cleared every slot, which deleted anything else in the hold --
--- harmless while a hull only ever carried one good, fatal the moment it carries several.
---
--- Whole-hold is also the only unload this can do: `Ship_Cargo_Clear` takes a real slot while the
--- cargo vector is keyed by position, so leaving part of a load aboard would need a slot->position
--- map nobody maintains (see the SHIP CARGO note in anno_interface.lua). Clearing every slot index
--- never maps one onto the other, which is why it is safe.
---
---@return table<ProductGUID, Amount> unloaded per good
local function dst_unload(
    L,
    region,
    ship_oid,
    areaID_dst
)
    local cargo = Anno.Ship_Cargo_Get(ship_oid)

    local unloaded = {}
    for _, cargo_item in pairs(cargo) do
        if cargo_item.Value > 0 then
            unloaded[cargo_item.Guid] = (unloaded[cargo_item.Guid] or 0) + cargo_item.Value
        end
    end

    -- Check the complete hold against current per-good headroom BEFORE any
    -- credit. Partial unloading cannot map dense cargo positions back to real
    -- slots, and the destination may have filled during the voyage.
    for guid, amount in pairs(unloaded) do
        local capacity = Anno.Area_GetGoodCapacity(region, areaID_dst, guid);
        assert(type(capacity) == "number" and capacity >= 0, "Cannot read destination capacity");
        local available = capacity - Anno.Area_GetGood(region, areaID_dst, guid);
        if available < amount then
            L.logf("Unload deferred: area %d has room for %d of %d units of good %d; keeping the whole hold",
                areaID_dst, available, amount, guid);
            return {};
        end
    end

    for guid, amount in pairs(unloaded) do
        Anno.Area_AddGood(region, areaID_dst, guid, amount);
    end

    for i = 0, Anno.Ship_Cargo_SlotCapacity(ship_oid) + 1 do
        Anno.Ship_Cargo_Clear(ship_oid, i)
    end

    return unloaded
end

TradeExecutor.Records = {};

--[[
    Executes a trade order with a ship asynchronously.
    Must be called from within an async task.

    See TradeExecutor.Command below for the command structure.

    @param cmd table - Command structure
]]

--- One good on one voyage.
---@class TradeExecutor.CommandGood
---@field GoodID number
---@field Amount number

--- One voyage: a ship, one source, one destination, and everything it carries between them.
---@class TradeExecutor.Command
---@field AreaID_from number
---@field AreaID_to number
---@field Goods TradeExecutor.CommandGood[]
---@field Ship_ID number
---@field Ship_AmountPerSlot number
---@field OrderDistance Distance
---@field ShipDistance number

--- How many slots `goods` occupies. A good never shares a slot with another good, so a 30-unit
--- leg costs a whole slot -- which is why the packing budget is slots and not units.
---@param goods TradeExecutor.CommandGood[]
---@param amount_per_slot number
---@return number
function TradeExecutor.SlotsNeeded(goods, amount_per_slot)
    local slots = 0
    for _, g in ipairs(goods) do
        slots = slots + math.ceil(g.Amount / amount_per_slot)
    end
    return slots
end

---@param L Logger
---@param region RegionID
---@param cmd TradeExecutor.Command
function TradeExecutor._ExecuteTradeOrderWithShip(L, region, cmd)
    local start_at = os.date("%Y-%m-%dT%H:%M:%SZ");

    local ship_oid = cmd.Ship_ID
    local amount_per_slot = cmd.Ship_AmountPerSlot
    local order_distance = cmd.OrderDistance
    local aSrc, aDst = cmd.AreaID_from, cmd.AreaID_to
    local goods = cmd.Goods

    L = L.with("loc", "TradeExecutor._ExecuteTradeOrderWithShip");

    L.logf("start");

    local slots_needed = TradeExecutor.SlotsNeeded(goods, amount_per_slot)
    local slots_available = Anno.Ship_Cargo_SlotCapacity(ship_oid)
    if slots_needed > slots_available then
        -- The planner is meant to have fitted this. Refuse rather than load a hull past its
        -- capacity, where the surplus would vanish silently at the load step.
        error(string.format("Command needs %d slots but ship %d has %d", slots_needed, ship_oid, slots_available))
    end

    local srcBefore, dstBefore = {}, {}
    for _, g in ipairs(goods) do
        srcBefore[g.GoodID] = Anno.Area_GetGood(region, aSrc, g.GoodID)
        dstBefore[g.GoodID] = Anno.Area_GetGood(region, aDst, g.GoodID)
        L.logf("before: good=%d source = %d, destination = %d", g.GoodID, srcBefore[g.GoodID], dstBefore[g.GoodID])
    end

    -- A stale assignment or a manually loaded ship must not discard real cargo.
    -- Leave it for the ordinary whole-hold recovery path.
    for _, item in pairs(Anno.Ship_Cargo_Get(ship_oid)) do
        if item.Value > 0 then
            L.logf("Trade order refused: ship %d already has cargo", ship_oid);
            return { success = false, loaded = 0, unloaded = 0 };
        end
    end

    -- Step 2: Move ship to source area
    L.logf("Moving ship %d to source area %d (x=%d, y=%d)", ship_oid, aSrc,
        order_distance.src.x, order_distance.src.y)
    TradeExecutor.Ship_Name_StoreCmdInfo(ship_oid, {
        x = order_distance.src.x,
        y = order_distance.src.y,
        area_id = aSrc
    })
    shipCmd.MoveShipToAsync(
        ship_oid,
        order_distance.src.x,
        order_distance.src.y
    )
    L.logf("Ship %d arrived at source area", ship_oid)

    -- Step 3: Load cargo at source, one good at a time.
    -- CheatItemInSlot picks the slot itself: it tops up a partial stack of the SAME good before
    -- opening a new one, so a good loaded in one run of slots stays contiguous and never merges
    -- with a different good.
    local loaded = {}
    local total_loaded = 0
    for _, g in ipairs(goods) do
        local good_loaded = 0
        local good_slots = math.ceil(g.Amount / amount_per_slot)
        for i = 1, good_slots do
            local amount_to_load = math.min(amount_per_slot, g.Amount - good_loaded,
                Anno.Area_GetGood(region, aSrc, g.GoodID))
            -- The one-unit cargo cheat rounds up to two. Never invent that
            -- extra unit when only one remains at the source.
            if amount_to_load < 2 then
                break;
            end
            Anno.Ship_Cargo_Set(ship_oid, i, { Guid = g.GoodID, Value = amount_to_load })
            Anno.Area_AddGood(region, aSrc, g.GoodID, -amount_to_load)
            good_loaded = good_loaded + amount_to_load
        end
        loaded[g.GoodID] = (loaded[g.GoodID] or 0) + good_loaded
        total_loaded = total_loaded + good_loaded
    end

    if total_loaded == 0 then
        return { success = false, loaded = 0, unloaded = 0 };
    end

    coroutine.yield();
    coroutine.yield();

    local srcAfter = {}
    for _, g in ipairs(goods) do
        srcAfter[g.GoodID] = Anno.Area_GetGood(region, aSrc, g.GoodID);
    end

    L.logf("Loaded %d total units across %d good(s) in %d/%d slots; moving to dst area (x=%d y=%d)",
        total_loaded, #goods, slots_needed, slots_available, order_distance.dst.x, order_distance.dst.y)

    -- Step 4: Move ship to destination area
    dst_moveTo(ship_oid, order_distance.dst, aDst)
    L.logf("Ship arrived at destination area")

    -- Step 5: Unload the whole hold at destination
    local unloaded = dst_unload(L, region, ship_oid, aDst)

    coroutine.yield();
    coroutine.yield();

    local total_unloaded = 0
    for _, amount in pairs(unloaded) do
        total_unloaded = total_unloaded + amount
    end

    local area_src_n = Anno.Area_CityName(region, aSrc);
    local area_dst_n = Anno.Area_CityName(region, aDst);
    local ship_name = Anno.Ship_Name_Get(ship_oid);
    local end_at = os.date("%Y-%m-%dT%H:%M:%SZ");

    -- One record per good, so a packed voyage stays as readable in the log as a single-good one.
    for _, g in ipairs(goods) do
        local dstAfter = Anno.Area_GetGood(region, aDst, g.GoodID)
        L.logf("Trade order %s: good=%d unloaded=%d; src=(%d -> %d); dst=(%d -> %d)",
            (unloaded[g.GoodID] or 0) == loaded[g.GoodID] and "completed" or "incomplete",
            g.GoodID, unloaded[g.GoodID] or 0, srcBefore[g.GoodID], srcAfter[g.GoodID],
            dstBefore[g.GoodID], dstAfter)

        table.insert(TradeExecutor.Records, {
            _start = start_at,
            _end = end_at,
            ship_oid = ship_oid,
            ship_name = ship_name,
            area_src = aSrc,
            area_dst = aDst,
            area_src_name = area_src_n,
            area_dst_name = area_dst_n,
            good_id = g.GoodID,
            good_name = AnnoInfo.Product(g.GoodID).Name,
            good_amount = g.Amount,
            good_loaded = loaded[g.GoodID] or 0,
            good_unloaded = unloaded[g.GoodID] or 0,
            good_src_before = srcBefore[g.GoodID],
            good_src_after = srcAfter[g.GoodID],
            good_dst_before = dstBefore[g.GoodID],
            good_dst_after = dstAfter
        })
    end

    return {
        success = total_loaded == total_unloaded,
        loaded = total_loaded,
        unloaded = total_unloaded
    }
end

-- Helper: Clears all cargo from a ship
function TradeExecutor._ClearAllShipCargo(ship_oid)
    for i = 0, Anno.Ship_Cargo_SlotCapacity(ship_oid) + 1 do
        Anno.Ship_Cargo_Clear(ship_oid, i)
    end
end

---

--- Sails a ship to `areaID_dst` and puts its whole hold ashore, whatever is in it.
---@param L Logger
---@param region RegionID
---@param ship_oid number
---@param areaID_dst number
---@param area_dst_coords Coordinate
---@return number|nil async task id, or nil while another task owns the ship
function TradeExecutor._ExecuteUnloadWithShip(L, region, ship_oid, areaID_dst, area_dst_coords)
    return SpawnShipTask(L, ship_oid, function()
        L.logf("Moving ship %d to unload at area %d (x=%d, y=%d)", ship_oid, areaID_dst, area_dst_coords.x,
            area_dst_coords.y)
        dst_moveTo(ship_oid, area_dst_coords, areaID_dst)
        L.logf("Ship %d arrived at unload area %d, unloading its hold", ship_oid, areaID_dst)

        local before = {}
        for _, item in pairs(Anno.Ship_Cargo_Get(ship_oid)) do
            before[item.Guid] = Anno.Area_GetGood(region, areaID_dst, item.Guid)
        end

        async.sleep(1)
        local unloaded = dst_unload(L, region, ship_oid, areaID_dst);
        async.sleep(1)

        for guid, amount in pairs(unloaded) do
            L.logf("Unloaded %d units of good %d at area %d; area good before: %d, after: %d",
                amount, guid, areaID_dst, before[guid] or 0, Anno.Area_GetGood(region, areaID_dst, guid))
        end
    end)
end

---

---@param L Logger
---@param region RegionID
---@param cmd TradeExecutor.Command
---@return number|nil async task id, or nil while another task owns the ship
function TradeExecutor.SpawnTradeOrder(L, region, cmd)
    return SpawnShipTask(L, cmd.Ship_ID, function()
        return TradeExecutor._ExecuteTradeOrderWithShip(L, region, cmd);
    end);
end

function TradeExecutor.ExecuteMultipleOrders(L, region, orders)
    local task_ids = {}

    for _, order in ipairs(orders) do
        local task_id = TradeExecutor.SpawnTradeOrder(L, region, order.cmd)
        table.insert(task_ids, task_id)
    end
    L.logf("Spawned %d trade order tasks", #task_ids)

    return task_ids
end

return TradeExecutor
