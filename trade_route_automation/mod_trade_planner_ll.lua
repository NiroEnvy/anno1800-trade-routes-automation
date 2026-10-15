--[[
    Trade Planner - Low Level Planning Logic

    DOCUMENTATION: See docs/CLAUDE_architecture-trade-automation.md
    - Overview: "mod_trade_planner_ll.lua (Low-Level Planning Logic)"
    - Key sections:
      * Supply/Request Tables - core data structure
      * In-Flight Tracking - prevents double-shipping
      * Stock Thresholds - o2, o6, o8 explained
      * Command Structure - full type definitions

    This module contains the CORE PLANNING LOGIC. It:
    1. Analyzes stock across all areas
    2. Builds supply/request tables (accounts for in-flight goods)
    3. Converts requests into concrete orders
    4. Matches ships to orders (distance-optimized)
    5. Spawns execution tasks

    Key functions:
    - SupplyRequest_Build: Analyzes areas -> supply/request table (lines 227-356)
    - SupplyRequest_ToOrders: supply/request -> Orders (lines 412-459)
    - SupplyRequestOrders_ToShipCommands: Orders -> Commands (lines 467-534)
    - SupplyRequestShipCommands_Execute: Commands -> async tasks (lines 542-642)
]]

local Anno = require("trade_route_automation/anno_interface");
local AreasRequest = require("trade_route_automation/mod_area_requests");
local AnnoInfo = require("trade_route_automation/generator/products");
local TradeExecutor = require("trade_route_automation/mod_trade_executor");
local inspector = require("trade_route_automation/anno_object_inspector");

local TradePlannerLL = {
    __Internal = {
        ProductGUID_Unknown = {},
    }
};

---@generic K1, K2, V
---@param k123 table<K1, table<K2, V>>
---@return table<K2, table<K1, V>>
local function dict123to213(k123)
    local ret = {}
    for k1, k23 in pairs(k123) do
        for k2, v3 in pairs(k23) do
            if ret[k2] == nil then
                ret[k2] = {}
            end
            ret[k2][k1] = v3
        end
    end
    return ret;
end

---@param coord1 Coordinate
---@param coord2 Coordinate
---@return number
local function CalculateDistanceBetweenCoordinates(coord1, coord2)
    local dx = coord1.x - coord2.x;
    local dy = coord1.y - coord2.y;
    return math.sqrt(dx * dx + dy * dy);
end

---@param areas table<AreaID, AreaData>
---@param areaID1 AreaID
---@param areaID2 AreaID
---@return Distance
local function CalculateDistanceBetweenAreas(L, areas, areaID1, areaID2)
    local area1 = areas[areaID1];
    local area2 = areas[areaID2];

    if area1 == nil or area1.water_points == nil then
        L.logf("Area %d has no water points", areaID1);
        return { dist = math.huge };
    end
    if area2 == nil or area2.water_points == nil then
        L.logf("Area %d has no water points", areaID2);
        return { dist = math.huge };
    end

    local options = {};
    for _, point1 in ipairs(areas[areaID1].water_points) do
        for _, point2 in ipairs(areas[areaID2].water_points) do
            local dist = CalculateDistanceBetweenCoordinates(point1, point2);
            table.insert(options, { src = point1, dst = point2, dist = dist });
        end
    end
    table.sort(options, function(a, b)
        return a.dist < b.dist
    end);

    if #options == 0 then
        L.logf("No water route found between area %d and area %d", areaID1, areaID2);
        return { dist = math.huge };
    end

    return options[1];
end

---

local TradeDirection_In = "In";
local TradeDirection_Out = "Out";

--- Accumulates `amount` into `t[areaID][guid][direction]`, creating the nesting as needed.
---@param t TradePlanner.AreaGoodsInFlight
---@param direction TradeDirection
local function inFlight_Add(t, areaID, guid, direction, amount)
    if t[areaID] == nil then
        t[areaID] = {};
    end
    if t[areaID][guid] == nil then
        t[areaID][guid] = { In = 0, Out = 0 };
    end
    t[areaID][guid][direction] = t[areaID][guid][direction] + amount;
end

---@param L Logger
---@param region RegionID
---@param trades ActiveTrades
---@return TradePlanner.AreaGoodsInFlight
function TradePlannerLL.Ships_StockInFlight(
    L, region, trades
)
    local _inFlight = {}; -- table<areaID, table<productID, amount>>
    -- 3.2. In flight
    for _, trade in ipairs(trades) do
        local shipOID = trade.command.Key.ShipID;

        -- What the voyage was ordered to carry. Used only while the hold is still empty; once
        -- the ship has actually loaded, what is aboard wins.
        local tCargo = {};
        for _, g in ipairs(trade.command.Key.Order.Goods or {}) do
            table.insert(tCargo, {
                Guid = g.GoodID,
                Amount = g.Amount,
            });
        end

        local info = TradeExecutor.Ship_Name_FetchCmdInfo(shipOID);
        if info.area_id == nil then
            goto continue;
        end

        local sCargo = {};
        local cargo = Anno.Ship_Cargo_Get(shipOID);
        for _, cargo_item in pairs(cargo) do
            if cargo_item.Value == 0 then
                goto continue_j;
            end
            table.insert(sCargo, {
                Guid = cargo_item.Guid,
                Amount = cargo_item.Value,
            });

            :: continue_j ::
        end

        if #sCargo == 0 then
            -- Still sailing to the pickup island: the goods are BOTH still sitting at the source
            -- and already spoken for by the destination, so both ends have to see them.
            --
            -- Counting only the source is what let four consecutive cycles dispatch against one
            -- request on 2026-08-23: a cycle runs every ~10s, sailing to the pickup takes longer,
            -- and every cycle in between saw an unreserved request and sent more ships. n5 asked
            -- for 360 Bricks and 950 arrived at an island with room for 520.
            local area_from = trade.command.Key.Order.AreaID_from;
            local area_to = trade.command.Key.Order.AreaID_to;
            if area_from == nil then
                -- A force-unload has no source. If its hold is empty the goods are already
                -- ashore, so counting them as incoming would double them.
                L.logf("[warn]: Ship %d has no area_id_from set in trade command; skipping", shipOID);
                goto continue;
            end

            for _, cargo_item in pairs(tCargo) do
                inFlight_Add(_inFlight, area_from, cargo_item.Guid, TradeDirection_Out, cargo_item.Amount);
                if area_to ~= nil then
                    inFlight_Add(_inFlight, area_to, cargo_item.Guid, TradeDirection_In, cargo_item.Amount);
                end
            end
        else
            -- Loaded: the source's real stock has already dropped, so only the destination is
            -- still waiting on these.
            local area_id = trade.command.Key.Order.AreaID_to;
            for _, cargo_item in pairs(sCargo) do
                inFlight_Add(_inFlight, area_id, cargo_item.Guid, TradeDirection_In, cargo_item.Amount);
            end
        end

        :: continue ::
    end

    return _inFlight;
end

---

--- Units per cargo slot. Measured in-game and pinned by tests/game/contract_cargo.lua.
local AMOUNT_PER_SLOT = 50;

--- Below this a delivery is not worth a slot.
local MIN_TRANSFER = 25;

--[[
    The four stock levels every supply/request decision is made against, for an island whose
    total capacity for one good is `areaCap`.

    An island fills up to o6 and is drained down to o2, so `o6 - o2` IS the amplitude it will
    oscillate through. The `+ 300` terms exist to cap that amplitude on large islands: below
    capacity ~750 the band is 0.4 * capacity, above it the band is pinned at 300.

        cap    o2   o4   o6   o8   band(o6-o2)  o8-o6
         75    15   30   45   60        30        15
        250    50  100  150  200       100        50
        650   130  225  390  520       260       130
       1000   200  225  500  525       300        25   <-- o8 is 25 above o6

    The column that matters for stability is not `o8 - o6` but the distance from the level an
    island STOPS at to the level where it starts asking again -- `o8 - o2` for a consumer,
    `o4 - o2` for a producer:

        cap    consumer (o8-o2)   producer (o4-o2)
         75          45                 15
        250         150                 50
        650         390                 95
       1000         325                 25

    The producer column is the thin one, because `o2` clamps at 200 but `o4` at 225: a large
    island that has exported down to o4 is one minimum transfer from asking. It is self-limiting
    -- a producer refills itself, and one inbound delivery flips it to a consumer with the roomy
    o8 floor -- but it is the remaining edge in this ladder. Raising `o4_cap` would close it,
    at the cost of every number below.

    Exposed as a function so a tuning run can substitute a different set.
]]
--[[
    The level an island refills TO, once it has dropped below o2. Always o6.

    The caller asks for `o6 - stock`, not for o6, so an island lands ON o6 rather than overshooting
    it by whatever it was still holding. That is what keeps it below o8 and stops it turning round
    and exporting its own delivery -- see issue #14.

    A two-tier version of this ("o2 for an island that has just exported, o6 otherwise") was tried
    as an anti-oscillation rule and rejected: measured against tests/test_scenarios.lua it settles
    the region at o2, which is the level at which asking STARTS, so islands rest one consumption
    tick from a fresh request. The deficit is what removes the oscillation; the two-tier ask just
    moves less.

    Exposed as a function so a tuning run can substitute a different level.
]]
---@param isRequester boolean whether this island's last movement of the good was inbound
---@param stock Amount
---@return Amount
function TradePlannerLL.RequestLevel(isRequester, stock, o2, o6)
    return o6;
end

--- How full a hub holds itself: 90% of capacity.
---
--- Deliberately NOT a level on the o2/o4/o6/o8 ladder. That ladder describes an island that lives
--- off the good -- o6 is "topped up", o8 is "more than I need". A hub does not consume what it
--- collects, so its target is a warehouse fill level and diverges from the ladder completely: at
--- capacity 3000 the ladder clamps o8 to 525 while a hub holds 2700.
local HUB_FILL_NUM, HUB_FILL_DEN = 9, 10;

---@param areaCap Amount
---@return Amount
function TradePlannerLL.HubTarget(areaCap)
    return math.ceil(areaCap * HUB_FILL_NUM / HUB_FILL_DEN);
end


---@param areaCap Amount
---@return Amount o2, Amount o4, Amount o6, Amount o8
function TradePlannerLL.Thresholds(areaCap)
    local o2_cap = 200;
    local o4_cap = 225;

    local o2 = math.min(o2_cap, math.floor(areaCap * 2 / 10));
    local o6 = math.min(o2 + 300, math.min(o2_cap + 300, math.floor(areaCap * 6 / 10)));
    local o4 = math.min(o4_cap, math.floor(areaCap * 4 / 10));
    local o8 = math.min(o4 + 300, math.min(o4_cap + 300, math.floor(areaCap * 8 / 10)));

    return o2, o4, o6, o8;
end

---@alias TradePlanner.AreaGoodAmount table<AreaID, table<ProductGUID, Amount>>
---@alias TradePlanner.GoodAreaAmount table<ProductGUID, table<AreaID, Amount>>
---@alias Distance { src: Coordinate, dst: Coordinate, dist: number }


---@alias InOut { In: Amount, Out: Amount }
---@alias TradePlanner.AreaGoodsInFlight table<AreaID, table<ProductGUID, InOut>>

---@class TradePlanner.SupplyRequestTable
---@field Supply TradePlanner.AreaGoodAmount
---@field Request TradePlanner.AreaGoodAmount

---@class TradePlanner.OrderKey
---@field AreaID_from AreaID
---@field AreaID_to AreaID
---@field GoodID ProductGUID
---@field RequestAmount Amount
---@field SupplyAmount Amount

---@param t TradePlanner.OrderKey
---@return TradePlanner.OrderKey
local function OrderKey(t)
    return t;
end

---@param t TradePlanner.OrderValue
---@return TradePlanner.OrderValue
local function OrderValue(t)
    return t;
end

---@param t TradePlanner.Order
---@return TradePlanner.Order
local function Order(t)
    return t;
end

---@class TradePlanner.OrderValue
---@field OrderDistance Distance

---@class TradePlanner.Order
---@field Key TradePlanner.OrderKey
---@field Value TradePlanner.OrderValue

---@alias TradePlanner.Orders TradePlanner.Order[]

--- One good aboard one voyage.
---@class TradePlanner.CommandGood
---@field GoodID ProductGUID
---@field Amount Amount

--- A voyage: one source, one destination, and everything carried between them.
---
--- An Order is one good; a Command may carry several, provided they share the same island pair.
--- That restriction is what keeps the whole thing inside the game's cargo semantics: the hold is
--- filled at one island and emptied at one island, so no partial unload is ever needed.
---@class TradePlanner.CommandOrder
---@field AreaID_from AreaID|nil
---@field AreaID_to AreaID
---@field Goods TradePlanner.CommandGood[]

---@class TradePlanner.CommandKey
---@field ShipID ShipID
---@field Order TradePlanner.CommandOrder

---@class TradePlanner.CommandValue
---@field Order TradePlanner.OrderValue
---@field ShipDistance number
---@field ShipSlots number

---@class TradePlanner.Command
---@field Key TradePlanner.CommandKey
---@field Value TradePlanner.CommandValue

---@alias TradePlanner.Commands TradePlanner.Command[]

---@param L Logger
---@param region RegionID
---@param areaToGoodsInFlight TradePlanner.AreaGoodsInFlight
---@param areas table<AreaID, AreaData>
---@param state tradeExecutor_iteration_state
---@param hubMode TradePlanner.HubMode|nil  nil for the main pass; see SupplyRequest_BuildHubs
---@return TradePlanner.SupplyRequestTable
function TradePlannerLL.supplyRequest_Build(
    L, region, areaToGoodsInFlight, areas, state,
    hubMode
)
    --- Does `areaID` collect `productID` in this pass?
    local function hubWants(areaID, productID)
        if hubMode == nil then
            return false;
        end
        local t = hubMode.targets[areaID];
        return t ~= nil and (t == true or t[productID] == true);
    end

    local function isHub(areaID)
        return hubMode ~= nil and hubMode.targets[areaID] ~= nil;
    end
    local areaToProductRequest = AreasRequest.All(L, region);

    local function formatReasons(reasons)
        local formatted = {};
        for _, reason in ipairs(reasons) do
            local rS = reason.type;
            if reason.name ~= nil then
                rS = rS .. "/" .. reason.name;
            end
            table.insert(formatted, rS);
        end

        return formatted
    end

    local allProducts = {};
    for areaID, products in pairs(areaToProductRequest) do
        for productID, _ in pairs(products) do
            allProducts[productID] = true;
        end
    end
    for productID in pairs(allProducts) do
        local product = AnnoInfo.Product(productID);
        if product == nil then
            if not TradePlannerLL.__Internal.ProductGUID_Unknown[productID] then
                L.logf("Warning: Product ID %d not found in AnnoInfo", productID);
                TradePlannerLL.__Internal.ProductGUID_Unknown[productID] = true;
            end
        end
    end

    local supply = {};
    local request = {};
    for areaID, areaData in pairs(areas) do
        local _minTransfer = MIN_TRANSFER;

        local inFlightStock_area = areaToGoodsInFlight[areaID] or {};
        local _areaCap = areaData.capacity or 75;

        if supply[areaID] == nil then
            supply[areaID] = {}
        end
        if request[areaID] == nil then
            request[areaID] = {}
        end

        for productID in pairs(allProducts) do
            local product = AnnoInfo.Product(productID);
            if product == nil then
                goto continue;
            end
            local productName = product.Name;

            local inFlightStock_t = inFlightStock_area[productID] or { In = 0, Out = 0 };
            local stock_incoming = inFlightStock_t.In;
            local stock_outgoing = inFlightStock_t.Out;

            local _stock = Anno.Area_GetGood(region, areaID, productID);

            local _lastTrade_direction = state:areaTradeDirection_Last(L, areaID, productID);

            local o2, o4, o6, o8 = TradePlannerLL.Thresholds(_areaCap);

            local doesAreaRequestProduct = areaToProductRequest[areaID] and areaToProductRequest[areaID][productID];

            local _request_reasons = nil;
            if doesAreaRequestProduct then
                local _rr = areaToProductRequest[areaID][productID];
                local _rr_fmt = formatReasons(_rr);
                _request_reasons = '[' .. table.concat(_rr_fmt, ",") .. ']';
            end

            -- Skip if area doesn't request this product and has no stock -- unless it is a hub
            -- collecting it, which is exactly the case of an empty warehouse.
            if not doesAreaRequestProduct and _stock == 0 and not hubWants(areaID, productID) then
                goto continue;
            end

            local isRequester = _lastTrade_direction == TradeDirection_In;

            local _stock_held = _stock;
            -- Stock already promised to a waiting ship is not ours to offer again.
            _stock = _stock - stock_outgoing;

            -- What this island wants DELIVERED: enough to reach o6, less whatever is already
            -- sailing towards it. An amount, not a level -- SupplyRequestOrders_ToShipCommands
            -- and the packing loop both spend it as one.
            --
            -- A hub asks on the same terms -- a shortfall, never a level -- but against
            -- HubTarget and with no `< o2` gate. It is not short, it is collecting, so it tops
            -- up whenever it is under target.
            local _request_ask = 0;
            if hubMode ~= nil then
                if hubWants(areaID, productID) then
                    _request_ask = TradePlannerLL.HubTarget(_areaCap) - _stock - stock_incoming;
                end
            elseif doesAreaRequestProduct and _stock < o2 then
                _request_ask = TradePlannerLL.RequestLevel(isRequester, _stock, o2, o6)
                    - _stock - stock_incoming;
            end

            L.logf("Area %s (id=%d) %s stock=%s (+%s) (-%s) request=%s (reasons=%s)", areaData.city_name, areaID,
                productName, _stock_held,
                stock_incoming, stock_outgoing, _request_ask, _request_reasons or '[]');

            -- A hub is a SINK for the length of the hub pass: it never offers, however fat it
            -- gets. Redistributing what it has collected is the MAIN pass's job, on the main
            -- pass's floors -- that is what makes a central hub a reseller rather than a black
            -- hole, and it is why a hub is not excluded from Supply generally, only here.
            if isHub(areaID) then
                if _request_ask >= _minTransfer then
                    request[areaID][productID] = _request_ask;
                end
                goto continue;
            end

            if not doesAreaRequestProduct then
                if _stock >= _minTransfer then
                    supply[areaID][productID] = _stock;
                end
                goto continue;
            end


            -- The floor an island exports down to is the level that qualified it to export: o8 for
            -- a consumer, o4 for a producer. Both sit above o2, so having exported, an island is
            -- not one consumption tick away from asking for it all back. No separate high-water
            -- gate is needed -- `_surplus >= _minTransfer` already implies `_stock > _floor`.
            --
            -- The hub pass uses these SAME floors. A higher hub-pass floor was tried and dropped;
            -- see docs/hubs.md for what it was measured to be worth (nothing, for the islands it
            -- was aimed at).
            local _floor = isRequester and o8 or o4;
            local _surplus = _stock - _floor;
            if _surplus >= _minTransfer then
                supply[areaID][productID] = _surplus;
            end
            if hubMode == nil and _request_ask >= _minTransfer then
                request[areaID][productID] = _request_ask;
            end

            :: continue ::
        end
    end

    ---@type TradePlanner.SupplyRequestTable
    local ret = {
        Supply = supply,
        Request = request,
    };
    return ret;
end

---@param L Logger
---@param region RegionID
---@param _stockFromInFlight TradePlanner.AreaGoodsInFlight
---@param areas table<AreaID, AreaData>
---@param state tradeExecutor_iteration_state
---@return TradePlanner.SupplyRequestTable
function TradePlannerLL.SupplyRequest_Build(L, region, _stockFromInFlight, areas, state)
    return TradePlannerLL.supplyRequest_Build(L, region, _stockFromInFlight, areas, state, nil);
end

---@class TradePlanner.HubMode
---@field targets table<AreaID, true|table<ProductGUID, boolean>>  true = every good

--- Islands the player has marked as hubs, by a suffix on the city name.
---
---   `(h)`   collect every good in play in the region
---   `(hc)`  collect CONSTRUCTION goods only -- a city actively being built
---
--- Checked longest-first: `(hc)` also ends in `c)`, so testing `(h)` first would never match it.
---@param areas table<AreaID, AreaData>
---@return table<AreaID, true|table<ProductGUID, boolean>>
function TradePlannerLL.Hubs(areas)
    local hubs = {};
    for areaID, areaData in pairs(areas) do
        local name = areaData.city_name;
        if name ~= nil then
            if name:find("%(hc%)$") then
                local goods = {};
                for _, guid in ipairs(AreasRequest.ConstructionGoods) do
                    goods[guid] = true;
                end
                hubs[areaID] = goods;
            elseif name:find("%(h%)$") then
                hubs[areaID] = true;
            end
        end
    end
    return hubs;
end

--- The hub pass: fill marked islands towards HubTarget, from everybody else's surplus.
---
--- Runs AFTER the main loop and only with ships the main loop left idle, so it never competes
--- with a genuine shortage. Three things separate it from the main pass:
---
---   1. only hubs appear in Request, so `SupplyRequest_ToOrders` can only produce voyages that
---      END at a hub -- no other wiring is needed to confine the pass to hub traffic;
---   2. hubs never appear in Supply, so the pass cannot move goods hub-to-hub or back out;
---
--- Donors export down to the SAME floors as the main pass. Deliberately: a hub-pass-only floor
--- was built and measured, and it changed nothing for producers (they refill past the asking line
--- and never re-request) and nothing for pure oversupply (a non-consumer offers everything
--- regardless of any floor). See docs/hubs.md.
---
--- Returns nil when the region has no hub, which the caller treats as "nothing to do".
---@param L Logger
---@param region RegionID
---@param _stockFromInFlight TradePlanner.AreaGoodsInFlight
---@param areas table<AreaID, AreaData>
---@param state tradeExecutor_iteration_state
---@return TradePlanner.SupplyRequestTable|nil
function TradePlannerLL.SupplyRequest_BuildHubs(L, region, _stockFromInFlight, areas, state)
    local hubs = TradePlannerLL.Hubs(areas);
    if next(hubs) == nil then
        L.logf("No hub area found in region %s", region);
        return nil;
    end

    return TradePlannerLL.supplyRequest_Build(L, region, _stockFromInFlight, areas, state, {
        targets = hubs,
    });
end

---@param L Logger
---@param supplyRequest TradePlanner.SupplyRequestTable
---@param areas table<AreaID, AreaData>
---@return TradePlanner.Orders
function TradePlannerLL.SupplyRequest_ToOrders(
    L,
    supplyRequest,
    areas
)
    ---@type TradePlanner.Orders
    local request_orders = {}

    local supply_gta = dict123to213(supplyRequest.Supply)

    for areaID, area_requests in pairs(supplyRequest.Request) do
        for goodID, amount in pairs(area_requests) do
            local supply_areas = supply_gta[goodID]
            if supply_areas ~= nil then
                L.logf("found supply areas for goodID=%d %s", goodID, tostring(supply_areas));
                for supply_areaID, supply_amount in pairs(supply_areas) do
                    local distance = CalculateDistanceBetweenAreas(L, areas, supply_areaID, areaID)

                    if distance.dist == math.huge then
                        L.logf("Skipping order from area %d to area %d for good %d due to no water route",
                            supply_areaID, areaID, goodID);
                        goto continue;
                    end

                    local key = OrderKey {
                        AreaID_from = supply_areaID,
                        AreaID_to = areaID,
                        GoodID = goodID,
                        RequestAmount = amount,
                        SupplyAmount = supply_amount,
                    }
                    local value = OrderValue {
                        OrderDistance = distance,
                    }

                    table.insert(request_orders, Order {
                        Key = key,
                        Value = value,
                    })

                    :: continue ::
                end
            end
        end
    end

    return request_orders
end

---@param L Logger
---@param available_ships table<ShipID, any>
---@param request_orders TradePlanner.Orders
---@param areas table<AreaID, AreaData>
---@param state tradeExecutor_iteration_state
---@return TradePlanner.Commands
function TradePlannerLL.SupplyRequestOrders_ToShipCommands(
    L, areas, available_ships,
    request_orders, state
)
    ---@type TradePlanner.Commands
    local available_commands = {}

    for ship, _ in pairs(available_ships) do
        local slots_cap = Anno.Ship_Cargo_SlotCapacity(ship);
        local cap = slots_cap * AMOUNT_PER_SLOT;

        if cap < AMOUNT_PER_SLOT then
            L.logf("Skipping ship %d due to insufficient cargo capacity: %d slots (%d total)", ship, slots_cap, cap);
            goto continue;
        end

        for _, order in ipairs(request_orders) do
            local order_key, order_value = order.Key, order.Value
            local ship_position = order_value.OrderDistance.src

            local info = TradeExecutor.Ship_Name_FetchCmdInfo(ship)
            if info.x ~= nil and info.y ~= nil then
                ship_position = { x = info.x, y = info.y }
            end

            local distance_to_pickup = CalculateDistanceBetweenCoordinates(
                ship_position,
                order_value.OrderDistance.src
            )

            local total_distance = distance_to_pickup + order_value.OrderDistance.dist

            -- Calculate transfer amount: limited by ship capacity, supply available, AND request needed
            local amount = math.min(cap, order_key.SupplyAmount, order_key.RequestAmount)

            ---@type TradePlanner.CommandKey
            local command_key = {
                ShipID = ship,
                Order = {
                    AreaID_from = order_key.AreaID_from,
                    AreaID_to = order_key.AreaID_to,
                    Goods = { { GoodID = order_key.GoodID, Amount = amount } },
                },
            }
            ---@type TradePlanner.CommandValue
            local command_value = {
                Order = order_value,
                ShipDistance = total_distance,
                ShipSlots = slots_cap,
            }

            table.insert(available_commands, {
                Key = command_key,
                Value = command_value,
            })
        end

        :: continue ::
    end

    -- Distance decides, but ties must break the same way every run: `pairs(available_ships)` has
    -- no defined order, so without this the same game state dispatches different ships run to run
    -- and nothing downstream is reproducible.
    table.sort(available_commands, function(a, b)
        if a.Value.ShipDistance ~= b.Value.ShipDistance then
            return a.Value.ShipDistance < b.Value.ShipDistance
        end
        if a.Key.ShipID ~= b.Key.ShipID then
            return a.Key.ShipID < b.Key.ShipID
        end
        local ao, bo = a.Key.Order, b.Key.Order
        if ao.AreaID_from ~= bo.AreaID_from then
            return (ao.AreaID_from or 0) < (bo.AreaID_from or 0)
        end
        if ao.AreaID_to ~= bo.AreaID_to then
            return ao.AreaID_to < bo.AreaID_to
        end
        return ao.Goods[1].GoodID < bo.Goods[1].GoodID
    end);

    return available_commands;
end

---@param L Logger
---@param region RegionID
---@param supplyRequestTable TradePlanner.SupplyRequestTable
---@param commands TradePlanner.Commands
---@param ships table<ShipID, any>
---@return ActiveTrades
function TradePlannerLL.SupplyRequestShipCommands_Execute(
    L,
    region,
    supplyRequestTable,
    commands,
    ships
)
    local spawned_tasks = {}

    -- Every good this ship could carry between this same pair of islands, so a voyage that would
    -- otherwise sail a third full can be topped up. Keyed ship|from|to; the lists keep the
    -- distance order the commands arrived in.
    local byShipAndPair = {};
    for _, kv in ipairs(commands) do
        local o = kv.Key.Order;
        local pair_key = string.format("%d|%s|%s", kv.Key.ShipID, tostring(o.AreaID_from), tostring(o.AreaID_to));
        if byShipAndPair[pair_key] == nil then
            byShipAndPair[pair_key] = {};
        end
        table.insert(byShipAndPair[pair_key], kv);
    end

    for _, kv in ipairs(commands) do
        local command_key = kv.Key
        local command_value = kv.Value

        local ship = command_key.ShipID
        local order = command_key.Order
        local order_value = command_value.Order

        if ships[ship] == nil then
            -- ship already used
            goto continue;
        end

        local slots_available = command_value.ShipSlots;
        local slots_used = 0;
        local accepted = {};
        local taken = {};

        --- Puts as much of `g` aboard as supply, demand and the free slots allow.
        ---
        --- Every figure is read as it stands right now: earlier voyages in this same loop have
        --- already drawn the tables down. Where the old code skipped a good whose supply had
        --- shrunk below the order, this carries what is actually there.
        local function take(g)
            if taken[g.GoodID] then
                return; -- a good travels once per voyage
            end

            local available_supply = supplyRequestTable.Supply[order.AreaID_from][g.GoodID] or 0
            local available_request = supplyRequestTable.Request[order.AreaID_to][g.GoodID] or 0
            local slots_free = slots_available - slots_used;

            local amount = math.min(
                g.Amount,
                available_supply,
                available_request,
                slots_free * AMOUNT_PER_SLOT
            );

            if amount < MIN_TRANSFER then
                L.logf("Dropping good %d from voyage: only %d could be carried (supply=%d request=%d slots_free=%d)",
                    g.GoodID, amount, available_supply, available_request, slots_free);
                return;
            end

            -- A good never shares a slot with another good, so a part-full stack still costs a
            -- whole slot. The budget is slots, not units.
            slots_used = slots_used + math.ceil(amount / AMOUNT_PER_SLOT);
            taken[g.GoodID] = true;
            table.insert(accepted, { GoodID = g.GoodID, Amount = amount });
        end

        -- The good this voyage was picked for goes aboard first: it won on distance.
        for _, g in ipairs(order.Goods) do
            take(g);
        end

        -- Then fill the rest of the hold from the other goods waiting on the same run, largest
        -- first so the slots that are left move as much as they can.
        local pair_key = string.format("%d|%s|%s", ship, tostring(order.AreaID_from), tostring(order.AreaID_to));
        local siblings = {};
        for _, other in ipairs(byShipAndPair[pair_key] or {}) do
            if other ~= kv then
                for _, g in ipairs(other.Key.Order.Goods) do
                    table.insert(siblings, g);
                end
            end
        end
        table.sort(siblings, function(a, b)
            if a.Amount ~= b.Amount then
                return a.Amount > b.Amount
            end
            return a.GoodID < b.GoodID
        end);

        for _, g in ipairs(siblings) do
            if slots_used >= slots_available then
                break;
            end
            take(g);
        end

        if #accepted == 0 then
            goto continue;
        end

        for _, g in ipairs(accepted) do
            supplyRequestTable.Supply[order.AreaID_from][g.GoodID] =
                supplyRequestTable.Supply[order.AreaID_from][g.GoodID] - g.Amount
            supplyRequestTable.Request[order.AreaID_to][g.GoodID] =
                supplyRequestTable.Request[order.AreaID_to][g.GoodID] - g.Amount
        end

        -- The command travels on into ActiveTrades, where in-flight accounting reads it. It has
        -- to describe what actually sails, not what was proposed.
        order.Goods = accepted;
        ships[ship] = nil;

        -- Spawn async task

        ---@type TradeExecutor.Command
        local cmd = {
            Ship_ID = ship,
            AreaID_from = order.AreaID_from,
            AreaID_to = order.AreaID_to,
            Goods = accepted,
            OrderDistance = {
                src = order_value.OrderDistance.src,
                dst = order_value.OrderDistance.dst,
                dist = order_value.OrderDistance.dist,
            },
            ShipDistance = command_value.ShipDistance,
            Ship_AmountPerSlot = AMOUNT_PER_SLOT,
        }

        local shipName = TradeExecutor.Ship_Name_FetchCmdInfo(ship).name;

        local goodsDesc, totalAmount = {}, 0;
        for _, g in ipairs(accepted) do
            table.insert(goodsDesc, string.format("%d (%s) x%d", g.GoodID, AnnoInfo.Product(g.GoodID).Name, g.Amount));
            totalAmount = totalAmount + g.Amount;
        end

        local tags = {
            ship = tostring(ship) .. " (" .. shipName .. ")",
            aSrc = order.AreaID_from .. " (" .. Anno.Area_CityName(region, order.AreaID_from) .. ")",
            aDst = order.AreaID_to .. " (" .. Anno.Area_CityName(region, order.AreaID_to) .. ")",
            good = table.concat(goodsDesc, ", "),
            amount = tostring(totalAmount),
        }
        local Lt = L;
        for k, v in pairs(tags) do
            Lt = Lt.with(k, v);
        end
        Lt.logf("Spawning trade order");

        local task_id = TradeExecutor.SpawnTradeOrder(Lt, region, cmd)
        if task_id == nil then
            for _, g in ipairs(accepted) do
                supplyRequestTable.Supply[order.AreaID_from][g.GoodID] =
                    supplyRequestTable.Supply[order.AreaID_from][g.GoodID] + g.Amount;
                supplyRequestTable.Request[order.AreaID_to][g.GoodID] =
                    supplyRequestTable.Request[order.AreaID_to][g.GoodID] + g.Amount;
            end
            goto continue;
        end
        table.insert(spawned_tasks, {
            coroutineID = task_id,
            command = kv,
        })

        :: continue ::
    end
    return spawned_tasks;
end

---

---@param L Logger
---@param region RegionID
---@param areas table<AreaID, AreaData>
---@param toUnload table<ShipID, any>
---@param activeTrades? ActiveTrades
---@return ActiveTrades
function TradePlannerLL.Ships_ForceUnloadStoppedShips(
    L,
    region,
    areas,
    toUnload,
    activeTrades
)
    local trades = {};

    -- Space promised to earlier ships in this same pass, so two stuck ships are not both sent to
    -- the one island with room for exactly one of them. areaID -> goodID -> amount.
    local reserved = {};
    for areaID, goods in pairs(TradePlannerLL.Ships_StockInFlight(L, region, activeTrades or {})) do
        reserved[areaID] = {};
        for guid, amounts in pairs(goods) do
            reserved[areaID][guid] = amounts.In;
        end
    end

    for ship, _ in pairs(toUnload) do
        if TradeExecutor.Ship_IsBusy(ship) then
            goto continue;
        end
        L.logf("Ship %d has cargo, waiting for it to unload before starting automation.", ship);

        -- Total up the hold per good. A packed ship carries several, and the unload puts the
        -- whole hold ashore in one go -- so the destination has to have room for all of it.
        local byGood = {};
        local goods = {};
        local totalCargo = 0;

        local cargo = Anno.Ship_Cargo_Get(ship);
        for _, cargo_item in pairs(cargo) do
            local guid, value = cargo_item.Guid, cargo_item.Value;
            if value > 0 then
                if byGood[guid] == nil then
                    byGood[guid] = 0;
                    table.insert(goods, guid);
                end
                byGood[guid] = byGood[guid] + value;
                totalCargo = totalCargo + value;
            end
        end

        if #goods == 0 then
            L.logf("Ship %d has no cargo, cannot proceed with automation.", ship);
            goto continue;
        end

        table.sort(goods);

        local candidates = {};
        for areaID, areaData in pairs(areas) do
            if areaData.water_points == nil or areaData.water_points[1] == nil then
                goto continueA;
            end

            local headroom = math.huge;

            for _, guid in ipairs(goods) do
                local capacity = Anno.Area_GetGoodCapacity(region, areaID, guid);
                if type(capacity) ~= "number" or capacity < 0 then
                    goto continueA;
                end
                local taken = Anno.Area_GetGood(region, areaID, guid) + ((reserved[areaID] or {})[guid] or 0);
                local availableCap = capacity - taken;
                if availableCap < byGood[guid] then
                    goto continueA;
                end
                headroom = math.min(headroom, availableCap);
            end

            table.insert(candidates, {
                AreaID = areaID,
                -- The tightest good decides: an island with plenty of room for one good and
                -- barely any for another is a poor place to put a mixed hold.
                Available = headroom,
            });

            :: continueA ::
        end

        -- Roomiest first, area id breaking ties so the choice does not depend on pairs() order.
        table.sort(candidates, function(a, b)
            if a.Available ~= b.Available then
                return a.Available > b.Available
            end
            return a.AreaID < b.AreaID
        end);

        if #candidates == 0 then
            L.logf("Ship %d: no island has room for its whole hold (%d units across %d good(s)).",
                ship, totalCargo, #goods);
            goto continue;
        end

        do
            local areaID = candidates[1].AreaID;

            if reserved[areaID] == nil then
                reserved[areaID] = {};
            end
            for _, guid in ipairs(goods) do
                reserved[areaID][guid] = (reserved[areaID][guid] or 0) + byGood[guid];
            end

            local cargoList = {};
            for _, guid in ipairs(goods) do
                table.insert(cargoList, { GoodID = guid, Amount = byGood[guid] });
            end

            table.insert(trades, {
                ship_oid = ship,
                goods = cargoList,
                total_cargo = totalCargo,
                areaID_dst = areaID,
                area_dst_coords = areas[areaID].water_points[1],
            });
        end

        :: continue ::
    end

    ---@type ActiveTrades
    local spawned_tasks = {};

    for _, trade in ipairs(trades) do
        local goodsDesc = {};
        for _, g in ipairs(trade.goods) do
            table.insert(goodsDesc, string.format("%d (%s) x%d", g.GoodID, AnnoInfo.Product(g.GoodID).Name, g.Amount));
        end

        local shipName = Anno.Ship_Name_Get(trade.ship_oid);
        local Lt = L.with("ship", tostring(trade.ship_oid) .. " (" .. shipName .. ")")
            .with("aDst", trade.areaID_dst .. " (" .. Anno.Area_CityName(region, trade.areaID_dst) .. ")")
            .with("good", table.concat(goodsDesc, ", "))
            .with("amount", tostring(trade.total_cargo));
        Lt.logf("Forcing ship %d to unload %d units across %d good(s) to area %d",
            trade.ship_oid,
            trade.total_cargo,
            #trade.goods,
            trade.areaID_dst
        );
        local task_id = TradeExecutor._ExecuteUnloadWithShip(
            Lt,
            region,
            trade.ship_oid,
            trade.areaID_dst,
            trade.area_dst_coords
        );
        if task_id == nil then
            goto continueTrade;
        end

        table.insert(spawned_tasks, {
            coroutineID = task_id,
            command = {
                Key = {
                    ShipID = trade.ship_oid,
                    Order = {
                        AreaID_from = nil,
                        AreaID_to = trade.areaID_dst,
                        Goods = trade.goods,
                    }
                },
                Value = {
                    Order = {
                        OrderDistance = {
                            src = trade.area_dst_coords,
                            dst = nil,
                            dist = nil,
                        },
                    },
                    ShipDistance = nil,
                }
            }
        })
        :: continueTrade ::
    end

    return spawned_tasks;
end

return TradePlannerLL;
