--[[
    Wires the mod's real modules up to a fake world (tests/lib/world.lua).

    The mod reaches the game only through `anno_interface`, and every module of it is loaded with
    `require("trade_route_automation/...")`. So the whole substitution is: drop a fake into
    `package.loaded` under that name before requiring the module under test. No production code
    knows it is being tested.

    Faked:
      anno_interface        -> the fake world
      generator/products    -> product names, from world.products
      mod_area_requests     -> hybrid: declared area.requests, unioned with the module's own
                               real Construction() list
      utils_logger          -> collects lines in memory
      anno_object_accessor  -> unused by the modules under test, but required by them
      anno_object_inspector -> ditto

    `_regions.lua` is used for real: it is pure data plus pure lookups, and reading the region codes
    from it rather than restating them here keeps the fake honest.

    Real, and therefore actually under test:
      mod_trade_planner_ll, mod_trade_executor, mod_ship_cmd, utils_async, utils_table

    Every harness gets a fresh copy of all of them, because utils_async and
    TradeExecutor.Records hold module-level state that must not leak between tests.
]]

local World = require("tests/lib/world");
local Goods = require("tests/lib/goods");
local Regions = require("trade_route_automation/_regions");

---@class Harness
---@field world FakeWorld
---@field lines string[]                    every log line the mod emitted
---@field L Logger                          in-memory logger, writes into `lines`
---@field Anno table                        the fake anno_interface
---@field async table                       the real utils_async scheduler
---@field TradeExecutor table               the real mod_trade_executor
---@field TradePlannerLL table              the real mod_trade_planner_ll
local Harness = {};
Harness.__index = Harness;

---

local function fake_logger(lines)
    local function new(fields)
        local l = {};
        l.fields = fields or {};
        l.dst = "<memory>";
        l.__base = "<memory>/";

        l.log = function(msg)
            local prefix = "";
            local keys = {};
            for k in pairs(l.fields) do
                table.insert(keys, k);
            end
            table.sort(keys);
            for _, k in ipairs(keys) do
                prefix = prefix .. string.format("%s=%s ", k, tostring(l.fields[k]));
            end
            table.insert(lines, prefix .. tostring(msg));
        end
        l.logf = function(fmt, ...)
            return l.log(string.format(fmt, ...));
        end
        l.with = function(key, value)
            local copy = {};
            for k, v in pairs(l.fields) do
                copy[k] = v;
            end
            copy[key] = value;
            return new(copy);
        end
        l.logger = function()
            return new(l.fields);
        end

        return l;
    end

    return new();
end

---

---@param world FakeWorld
---@return table
local function fake_anno(world)
    -- straight from the real registry, so the codes cannot drift from what the mod actually uses
    local Anno = {
        Region_OldWorld = Regions.OldWorld,
        Region_NewWorld = Regions.NewWorld,
        Region_Enbesa = Regions.Enbesa,
        Region_Arctic = Regions.Arctic,
        Region_CapeTrelawney = Regions.CapeTrelawney,
    };

    function Anno.Region_Enabled()
        local ret = {};
        for _, r in ipairs(Regions.Enabled()) do
            table.insert(ret, r.code);
        end
        return ret;
    end

    function Anno.Load() end

    function Anno.Region_Current()
        return world.region;
    end

    function Anno.Region_IsCached()
        return true;
    end

    function Anno.Region_CanCache()
        return true;
    end

    function Anno.Region_RefreshCache() end

    ---

    function Anno.Area_GetGood(_region, areaID, guid)
        return world:stock(areaID, guid);
    end

    function Anno.Area_AddGood(_region, areaID, guid, amount)
        return world:addGood(areaID, guid, amount);
    end

    function Anno.Area_GetGoodCapacity(_region, areaID, _guid)
        return world:area(areaID).capacity;
    end

    function Anno.Area_CityName(_region, areaID)
        local area = world.areas[areaID];
        return area and area.name or nil;
    end

    function Anno.Area_Owner()
        return 0;
    end

    --- areaID (as a string) -> the OID of that island's loading pier. The real
    --- AreaRequests.Construction walks this to reach every island.
    function Anno.Region_AreaID_To_OID()
        local ret = {};
        for _, areaID in ipairs(world.area_order) do
            ret[tostring(areaID)] = areaID;
        end
        return ret;
    end

    ---

    --[[
        The game's cargo vector is DENSE: it lists occupied stacks only, in ascending slot order,
        keyed 0..count-1. `Cargo Count` is the number of stacks aboard, not the number of slots,
        and the vector re-indexes when a stack is removed.

        So a key here is a POSITION, not a slot number. Feeding one to Ship_Cargo_Clear -- which
        takes a real slot -- addresses the wrong slot as soon as the hold has a gap.

        Measured in-game 2026-08-22; pinned by tests/game/contract_cargo.lua.
    ]]
    function Anno.Ship_Cargo_Get(oid)
        local ret = {};
        local ship = world:ship(oid);
        local pos = 0;
        for slot = 0, ship.slots - 1 do
            local item = ship.cargo[slot];
            if item ~= nil and item.Value > 0 then
                ret[pos] = { Guid = item.Guid, Value = item.Value };
                pos = pos + 1;
            end
        end
        return ret;
    end

    function Anno.Ship_Cargo_Set(oid, _slot, cargo)
        return world:load(oid, cargo.Guid, cargo.Value);
    end

    function Anno.Ship_Cargo_Clear(oid, slot)
        return world:clearSlot(oid, slot);
    end

    function Anno.Ship_Cargo_SlotCapacity(oid)
        return world:ship(oid).slots;
    end

    function Anno.Ship_Cargo_StackLimit()
        return World.SLOT_SIZE;
    end

    ---

    function Anno.Ship_Name_Get(oid)
        return world:ship(oid).name;
    end

    function Anno.Ship_Name_Set(oid, name)
        world:ship(oid).name = name;
    end

    function Anno.Ship_IsMoving(oid)
        return world:ship(oid).moving;
    end

    function Anno.Ship_MoveTo(oid, x, y)
        return world:moveTo(oid, x, y);
    end

    function Anno.Ship_TradeRoute_GetName(oid)
        return world:ship(oid).route;
    end

    function Anno.Region_Ships_GetAll()
        local ret = {};
        for _, oid in ipairs(world.ship_order) do
            table.insert(ret, oid);
        end
        return ret;
    end

    return Anno;
end

---

---@param world FakeWorld
---@return table
local function fake_products(world)
    local AnnoInfo = {};

    function AnnoInfo.Load() end

    --- Real names from generator/product_info.json; the world may override or add.
    function AnnoInfo.Product(guid)
        if guid == nil then
            return nil;
        end
        local n = world.products[guid] or Goods.name[guid];
        if n == nil then
            return nil;
        end
        return { Guid = guid, Name = n };
    end

    function AnnoInfo.Residence()
        return nil;
    end

    function AnnoInfo.Factory()
        return nil;
    end

    return AnnoInfo;
end

--[[
    Which goods each island consumes.

    The real module derives this from residences, factories, construction and trade unions. The
    world declares the residence/factory half directly (`area.requests`) -- but the construction
    half is a flat list of 9 goods that every island always requests, and that list belongs to
    production code, so the *real* AreaRequests.Construction is called for it. It needs nothing
    from the game beyond Region_AreaID_To_OID, which the fake world provides.

    Forgetting construction goods is how you end up designing a test island that holds 600 Bricks
    and requests none -- a shape the game cannot produce.
]]
---@param world FakeWorld
local function fake_area_requests(world, real)
    local AreaRequests = {};

    -- Passed straight through: it is a constant list belonging to production code, and
    -- TradePlannerLL.Hubs reads it to resolve the `(hc)` marker. A fake that omitted it would let
    -- production code tell it apart from the real module, which is the one thing a fake here must
    -- never do.
    AreaRequests.ConstructionGoods = real.ConstructionGoods;

    --- areaID -> productGUID -> list of reasons
    function AreaRequests.All(L, region)
        local ret = {};
        for _, areaID in ipairs(world.area_order) do
            local area = world.areas[areaID];
            ret[areaID] = {};
            for guid in pairs(area.requests) do
                ret[areaID][guid] = { { type = "Consumption" } };
            end
        end

        if world.construction then
            for areaID, goods in pairs(real.Construction(L, region)) do
                if ret[areaID] ~= nil then
                    for guid, reasons in pairs(goods) do
                        if ret[areaID][guid] == nil then
                            ret[areaID][guid] = {};
                        end
                        for _, reason in ipairs(reasons) do
                            table.insert(ret[areaID][guid], reason);
                        end
                    end
                end
            end
        end

        return ret;
    end

    return AreaRequests;
end

---

--- The slice of tradeExecutor_iteration_state that mod_trade_planner_ll actually reads.
--- The real class lives in mod_trade_planner_hl, which drags in the map scanners and the disk
--- cache; the low-level planner only ever asks it "which way did this island last move this good".
---@class FakeState
---@field directions table<AreaID, table<ProductGUID, TradeDirection>>
local FakeState = {};
FakeState.__index = FakeState;

---@param directions? table<AreaID, table<ProductGUID, TradeDirection>>
---@return FakeState
function FakeState.new(directions)
    return setmetatable({ directions = directions or {} }, FakeState);
end

---@param areaID AreaID
---@param productGUID ProductGUID
---@param direction TradeDirection
function FakeState:set(areaID, productGUID, direction)
    if self.directions[areaID] == nil then
        self.directions[areaID] = {};
    end
    self.directions[areaID][productGUID] = direction;
end

---@param areaID AreaID
---@param productGUID ProductGUID
---@return TradeDirection|nil
function FakeState:areaTradeDirection_Last(_L, areaID, productGUID)
    local byArea = self.directions[areaID];
    if byArea == nil then
        return nil;
    end
    return byArea[productGUID];
end

Harness.State = FakeState;

---

local MOD_PREFIX = "trade_route_automation";

---@param world FakeWorld
---@return Harness
function Harness.new(world)
    for name in pairs(package.loaded) do
        if type(name) == "string" and name:find(MOD_PREFIX, 1, true) == 1 then
            package.loaded[name] = nil;
        end
    end

    local h = setmetatable({}, Harness);
    h.world = world;
    h.lines = {};

    h.L = fake_logger(h.lines);
    h.Anno = fake_anno(world);

    package.loaded[MOD_PREFIX .. "/anno_interface"] = h.Anno;
    package.loaded[MOD_PREFIX .. "/generator/products"] = fake_products(world);
    package.loaded[MOD_PREFIX .. "/utils_logger"] = h.L;
    package.loaded[MOD_PREFIX .. "/anno_object_accessor"] = {};
    package.loaded[MOD_PREFIX .. "/anno_object_inspector"] = {};

    -- load the real AreaRequests first (it only needs the fakes above), then shadow it with one
    -- that keeps its real Construction list
    local realAreaRequests = require(MOD_PREFIX .. "/mod_area_requests");
    package.loaded[MOD_PREFIX .. "/mod_area_requests"] = fake_area_requests(world, realAreaRequests);

    h.async = require(MOD_PREFIX .. "/utils_async");
    h.TradeExecutor = require(MOD_PREFIX .. "/mod_trade_executor");
    h.TradePlannerLL = require(MOD_PREFIX .. "/mod_trade_planner_ll");

    return h;
end

--- The `areas` table the planner expects, built from the world.
---@return table<AreaID, AreaData>
function Harness:areas()
    local ret = {};
    for _, areaID in ipairs(self.world.area_order) do
        local area = self.world.areas[areaID];
        ret[areaID] = {
            city_name = area.name,
            capacity = area.capacity,
            water_points = area.water_points,
        };
    end
    return ret;
end

--- Available ships, in the shape mod_trade_planner_hl hands to the low-level planner.
---@param oids? ShipID[] defaults to every ship in the world
---@return table<ShipID, any>
function Harness:availableShips(oids)
    local ret = {};
    for _, oid in ipairs(oids or self.world.ship_order) do
        ret[oid] = { route_name = self.world:ship(oid).route };
    end
    return ret;
end

--- A `tradeExecutor_iteration_state` stand-in. Called as `h:state()` for symmetry with the rest
--- of the harness, though it needs nothing from the instance.
---@param directions? table<AreaID, table<ProductGUID, TradeDirection>>
---@return FakeState
function Harness:state(directions)
    return FakeState.new(directions);
end

--- One tick: the scheduler resumes whatever it can, then the world moves on.
---@return { running: number, waiting: number, completed: number, errors: number }
function Harness:step()
    local stats = self.async.tick();
    self.world:tick();
    return stats;
end

--- Runs until every task is done, or `maxTicks` pass. Returns ticks actually spent.
--- `onStep(tick, stats)` is called after each tick, for tests that need to poke the world
--- mid-voyage.
---@param maxTicks? number defaults to 2000
---@param onStep? fun(tick: number, stats: table)
---@return number ticks spent
function Harness:run(maxTicks, onStep)
    maxTicks = maxTicks or 2000;

    for i = 1, maxTicks do
        local stats = self:step();
        if onStep then
            onStep(i, stats);
        end

        if stats.running == 0 and stats.waiting == 0 then
            return i;
        end
    end

    return maxTicks;
end

--- Errors raised inside async tasks are swallowed by the scheduler; this surfaces them.
---@return string[]
function Harness:taskErrors()
    local ret = {};
    for _, task in ipairs(self.async.get_tasks_by_state("error")) do
        table.insert(ret, task.error);
    end
    return ret;
end

--- All log lines containing `needle`. Useful when a test wants to assert on what the mod decided,
--- not just on what the world ended up looking like.
---@return string[]
function Harness:logsMatching(needle)
    local ret = {};
    for _, line in ipairs(self.lines) do
        if line:find(needle, 1, true) then
            table.insert(ret, line);
        end
    end
    return ret;
end

---@return string
function Harness:dumpLogs()
    return table.concat(self.lines, "\n");
end

return Harness;