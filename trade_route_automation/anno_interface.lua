local serpLight = require("trade_route_automation/serp/lighttools");
local objectAccessor = require("trade_route_automation/anno_object_accessor");
local cache = require("trade_route_automation/utils_cache");
local Regions = require("trade_route_automation/_regions");

local Anno = {
    Internal = {},
};

---

---@class SessionObject
---@field GUID number
---@field userdata userdata
---@field OID number
---@field ParticipantID number
---@field SessionGuid number

---@class TsVectorType
---@field Guid number
---@field Icon string
---@field Text string
---@field Value string

---@alias Coordinate { x: number, y: number }
---@alias CoordinateString string
---@alias AreaID number
---@alias AreaID_str string
---@alias ShipID number
---@alias ProductGUID number
---@alias Amount number

---@class AreaData
---@field city_name string
---@field scan table<CoordinateString, string>
---@field water_points Coordinate[]
---@field capacity number

---

function Anno.Camera_MoveTo_Object(oid)
    ts.MetaObjects.CheatLookAtObject(oid);
end

function Anno.Object_Properties(oid)
    local props = {};
    for i, v in pairs(serpLight.PropertiesStringToID) do
        xpcall(function()
            local t = session.getObjectByID(oid):getProperty(v);
            table.insert(props, { name = i, id = v });
        end, debug.traceback);
    end
    return props;
end

-- Objects[OID] = { GUID = GUID, userdata = userdata, OID = OID, ParticipantID = ParticipantID, SessionGuid = SessionGuid }

---@return table<number, SessionObject>
function Anno.Objects_GetAll_ByProperty(property)
    return serpLight.GetCurrentSessionObjectsFromLocaleByProperty(property);
end

---
Anno.TsVectorType = {
    Guid = "number",
    Icon = "string",
    Text = "string",
    Value = "string",
}

---@return TsVectorType[]
function Anno.Object_ItemContainer_GetSockets(oid)
    return serpLight.GetVectorGuidsFromSessionObject(
        '[MetaObjects SessionGameObject(' .. tostring(oid) .. ') ItemContainer Sockets Count]', Anno.TsVectorType);
end

---@return GUID[]
function Anno.SocketItemGuidsToInputReplacements(socketItemGUID)
    local res = {};
    local i = 0;
    while true do
        local r = serpLight.DoForSessionGameObjectRaw(
            ('[AssetData([ItemAssetData(%s) ReplaceInputNewInput(%s)]) Guid]'):
            format(tostring(socketItemGUID), tostring(i)));
        local rN = tonumber(r);
        if rN == nil or rN <= 0 then
            break;
        end
        table.insert(res, r);

        i = i + 1;
        if i > 100 then
            --error("wtf? infinite loop detected in Anno.SocketItemGuidsToInputReplacements for socketItemGUID " .. tostring(socketItemGUID));
            break;
        end
    end
    return res;
end

function Anno.Object_Name(guid)
    local NO_RESULT = ts.Participants.GetParticipant(120).Profile.CompanyName;
    local ret = serpLight.DoForSessionGameObjectRaw('[AssetData(' .. tostring(guid) .. ') Text]');
    if ret == NO_RESULT then
        return nil;
    end
    return ret;
end

function Anno.Object_Icon(guid)
    return serpLight.DoForSessionGameObjectRaw('[AssetData(' .. tostring(guid) .. ') Icon]');
end

---

function Anno.Area_AddGood(region, areaID, guid, amount)
    if amount == 1 then
        amount = 2;
    end

    local mapping = Anno.Region_AreaID_To_OID(region);
    local oid = mapping[tostring(areaID)];
    local cmd = '[MetaObjects SessionGameObject(' ..
        tostring(oid) .. ') Area Economy AddAmount(' .. tostring(guid) .. ',' .. tostring(amount / 2) .. ')]';
    return serpLight.DoForSessionGameObjectRaw(cmd);
end

function Anno.Area_GetGood(region, areaID, guid)
    local mapping = Anno.Region_AreaID_To_OID(region);
    local oid = mapping[tostring(areaID)];
    local cmd = '[MetaObjects SessionGameObject(' ..
        tostring(oid) .. ') Area Economy AvailableAmount(' .. tostring(guid) .. ')]';
    local ret = serpLight.DoForSessionGameObjectRaw(cmd);
    return tonumber(ret);
end

function Anno.Area_GetGoodCapacity(region, areaID, guid)
    local mapping = Anno.Region_AreaID_To_OID(region);
    local oid = mapping[tostring(areaID)];
    local cmd = '[MetaObjects SessionGameObject(' ..
        tostring(oid) .. ') Area Economy StorageCapacity(' .. tostring(guid) .. ')]';
    local ret = serpLight.DoForSessionGameObjectRaw(cmd);
    local cap = tonumber(ret);
    if cap >= 2147483647 or cap < 0 or cap == nil then
        return { got = cap, orig = ret, args = { region = region, areaID = areaID, guid = guid } };
    end
    return cap;
end

---

function Anno.Area_Owner(region, areaID)
    local mapping = Anno.Region_AreaID_To_OID(region);
    local oid = mapping[tostring(areaID)];
    local cmd = '[MetaObjects SessionGameObject(' .. tostring(oid) .. ') Area Owner]';
    local ret = serpLight.DoForSessionGameObjectRaw(cmd);
    return tonumber(ret);
end

function Anno.Area_CityName(region, areaID)
    local mapping = Anno.Region_AreaID_To_OID(region);
    local oid = mapping[tostring(areaID)];
    if not oid then
        return nil;
    end
    local cmd = '[MetaObjects SessionGameObject(' .. tostring(oid) .. ') Area CityName]';
    local ret = serpLight.DoForSessionGameObjectRaw(cmd);
    return ret;
end

---

--[[
    SHIP CARGO -- how the game actually behaves
    ===========================================

    Measured against a running game on 2026-08-22 (ship "O1", 6 slots). Not inferred, not assumed.
    Every claim below is re-checkable with `make test/game`, which runs
    tests/game/contract_cargo.lua against the live game and fails if any of it stops being true.

    Read this before touching anything that loads or unloads a ship. Two of these cost half a day
    each to find.

    1. A CARGO VECTOR KEY IS NOT A SLOT NUMBER.

       `Cargo Count` returns the number of STACKS ABOARD, not the number of slots -- 3 for three
       goods on a six-slot ship. The vector is keyed 0..count-1 and RE-INDEXES when a stack is
       removed, so the keys are positions in a dense list.

       `ClearSlot(i)`, in contrast, addresses a REAL SLOT.

       They agree only while the hold has no gaps. The run that settled it:

           real slots [0]=Bricks [1]=Windows [2]=Beer   vector [0]=Bricks [1]=Windows [2]=Beer
           ClearSlot(0)                              -> vector [0]=Windows [1]=Beer
           ClearSlot(1)   -- vector[1] is Beer, real slot 1 is Windows
                                                     -> vector [0]=Beer      ... Windows went

       So this is WRONG, however natural it looks:

           for i, item in pairs(Anno.Ship_Cargo_Get(oid)) do
               Anno.Ship_Cargo_Clear(oid, i)          -- i is a position, not a slot
           end

       and this is right, because it never maps one onto the other:

           for i = 0, Anno.Ship_Cargo_SlotCapacity(oid) + 1 do
               Anno.Ship_Cargo_Clear(oid, i)
           end

       Practical consequence: unload a WHOLE hold, never part of one. Delivering some goods at one
       island and the rest at another needs slot-level addressing, and slot-level addressing needs
       a slot->position map nobody currently maintains.

    2. A READ IN THE SAME FRAME AS A WRITE SEES THE OLD STATE.

       Cheat commands land a frame or two later. mod_trade_executor.lua's `coroutine.yield()`s
       after loading are load-bearing, not decoration -- drop them and the mod silently reads an
       empty hold. (An experiment that omitted them concluded "loading does nothing at all".)

    3. `CheatItemInSlot` PICKS THE SLOT ITSELF -- the `slot` argument below is ignored.

       It fills the lowest free slot, and tops up an existing partial stack of the same good before
       opening a new one: 30 + 30 of one good gives two stacks, 50 and 10, not two of 30.

    4. UNITS ARE SYMMETRIC ACROSS THIS BOUNDARY.

       `Ship_Cargo_Set` takes displayed units and halves them on the way in; `Ship_Cargo_Get`
       returns displayed units. Write 50, read 50. Same for `Area_AddGood`. So callers can think
       purely in displayed units -- which is what the planner and tests/lib/world.lua both do.

    5. TWO DIFFERENT GOODS NEVER SHARE A SLOT.

       Measured 2026-08-23, same ship. Loading 30 of one good and then 30 of another gives two
       stacks of 30 -- not one slot holding 60:

           Ship_Cargo_Set(Bricks, 30); Ship_Cargo_Set(Windows, 30)
                                                     -> [0]=Bricks 30  [1]=Windows 30

       and the sequence the executor actually runs for a packed voyage behaves the same way:

           Bricks 50, Bricks 50, Windows 30          -> [0]=Bricks 50  [1]=Bricks 50  [2]=Windows 30

       So a good's cost is `ceil(amount / 50)` SLOTS regardless of how full the last one is, and a
       hold's budget is slots rather than units. mod_trade_planner_ll.lua packs on exactly this
       basis: budget in units instead and a 6-slot ship carrying six 30-unit goods looks like it
       still has room for another 120.

       Pinned by the `packing:` tests in tests/game/contract_cargo.lua.

    6. THE UNBALANCED PAREN IN Ship_Cargo_Clear IS TOLERATED.

       It emits `ClearSlot(1))]`, one paren too many, and the parser accepts it. Left as-is
       deliberately: it is the form that has been running in production, and "fixing" it is a
       change with no upside and a real chance of a behaviour difference nobody would notice.
       tests/game/contract_cargo.lua pins the current form as working.
]]

local type_Cargo = {
    Guid = "number",
    Value = "number"
}

--- Returns a DENSE vector of the stacks aboard, keyed 0..count-1. A key is a position, not a
--- slot -- see note 1 above before passing one to Ship_Cargo_Clear.
function Anno.Ship_Cargo_Get(oid)
    return serpLight.GetVectorGuidsFromSessionObject(
        '[MetaObjects SessionGameObject(' .. tostring(oid) .. ') ItemContainer Cargo Count]', type_Cargo);
end

--- `slot` is ignored: CheatItemInSlot picks the lowest free slot itself (note 3).
--- `cargo.Value` is in displayed units (note 4).
function Anno.Ship_Cargo_Set(oid, slot, cargo)
    if cargo.Value == 1 then
        cargo.Value = 2;
    end
    return serpLight.DoForSessionGameObjectRaw('[MetaObjects SessionGameObject(' ..
        tostring(oid) ..
        ') ItemContainer CheatItemInSlot(' .. tostring(cargo.Guid) .. ',' .. tostring(cargo.Value / 2) .. ')]');
end

--- Empties REAL SLOT `slot` -- not a cargo-vector position (note 1).
--- The extra `)` is deliberate; it works, and it is what production has always sent (note 6).
function Anno.Ship_Cargo_Clear(oid, slot)
    return serpLight.DoForSessionGameObjectRaw('[MetaObjects SessionGameObject(' ..
        tostring(oid) .. ') ItemContainer ClearSlot(' .. tostring(slot) .. '))]');
end

function Anno.Load(L, base)
    local cache_path_shipCargoSlotCap = base .. "ship_cargo_slot_capacity.json";
    local cache_path_shipCargoStackLimit = base .. "ship_cargo_stack_limit.json";
    Anno.__Cache_Ship_Cargo_SlotCapacity = cache.NewMapCache(L, cache_path_shipCargoSlotCap);
    Anno.__Cache_Ship_Cargo_StackLimit = cache.NewMapCache(L, cache_path_shipCargoStackLimit);
end

function Anno.__Ship_Cargo_SlotCapacity(oid)
    local slotAmount = serpLight.DoForSessionGameObjectRaw(
        '[ToolOneHelper SlotAmount([MetaObjects SessionGameObject(' .. tostring(oid) .. ') Static Guid])]');
    return tonumber(slotAmount) or -1;
end

function Anno.__Ship_Cargo_StackLimit(oid)
    local stackLimit = serpLight.DoForSessionGameObjectRaw(
        '[MetaObjects SessionGameObject(' .. tostring(oid) .. ') ItemContainer StackLimit]');
    return tonumber(stackLimit) or -1;
end


function Anno.Ship_Cargo_SlotCapacity(oid)
    local cache = Anno.__Cache_Ship_Cargo_SlotCapacity;
    local ret = cache:Get(tostring(oid));
    if ret == nil then
        ret = Anno.__Ship_Cargo_SlotCapacity(oid);
        cache:Set(tostring(oid), ret);
    end
    return ret;
end

function Anno.Ship_Cargo_StackLimit(oid)
    local cache = Anno.__Cache_Ship_Cargo_StackLimit;
    local ret = cache:Get(tostring(oid));
    if ret == nil then
        ret = Anno.__Ship_Cargo_StackLimit(oid);
        cache:Set(tostring(oid), ret);
    end
    return ret;
end

---

function Anno.Ship_Name_Get(oid)
    return serpLight.DoForSessionGameObjectRaw("[MetaObjects SessionGameObject(" .. tostring(oid) .. ") Nameable Name]");
end

function Anno.Ship_Name_Set(oid, name)
    return serpLight.DoForSessionGameObjectRaw("[MetaObjects SessionGameObject(" ..
        tostring(oid) .. ") Nameable Name(" .. tostring(name) .. ")]");
end

---

function Anno.Ship_IsMoving(oid)
    local ret = serpLight.DoForSessionGameObjectRaw("[MetaObjects SessionGameObject(" ..
        tostring(oid) .. ") Walking IsMoving(true)]");
    return ret == "true";
end

function Anno.Ship_MoveTo(oid, x, y)
    return serpLight.DoForSessionGameObjectRaw("[MetaObjects SessionGameObject(" ..
        tostring(oid) .. ") Walking DebugGoto(" .. tostring(x) .. "," .. tostring(y) .. ")]");
end

---

function Anno.Ship_TradeRoute_GetName(oid)
    return serpLight.DoForSessionGameObjectRaw("[MetaObjects SessionGameObject(" ..
        tostring(oid) .. ") TradeRouteVehicle RouteName]");
end

---

---@alias RegionID string

-- `_regions.lua` owns which regions exist, their session GUIDs and their map bounds. These
-- constants remain because call sites read better with a name than with "OW", but they are aliases
-- into the registry now, not a second list to keep in sync.

---@type RegionID
Anno.Region_OldWorld = Regions.OldWorld;
---@type RegionID
Anno.Region_NewWorld = Regions.NewWorld;
---@type RegionID
Anno.Region_Enbesa = Regions.Enbesa;
---@type RegionID
Anno.Region_Arctic = Regions.Arctic;
---@type RegionID
Anno.Region_CapeTrelawney = Regions.CapeTrelawney;

---@return RegionID|nil  nil in a session the registry does not describe
function Anno.Region_Current()
    local region = Regions.Current();
    if region == nil then
        return nil;
    end
    return region.code;
end

--- The regions the mod will actually drive -- those whose bounds have been measured. `_main.lua`
--- spawns one planner thread per entry, so a region left without bounds costs nothing at runtime.
---@return RegionID[]
function Anno.Region_Enabled()
    local ret = {};
    for _, region in ipairs(Regions.Enabled()) do
        table.insert(ret, region.code);
    end
    return ret;
end

---

----- high level region functions -----

---@return ShipID[]
local function _Ships_GetAll()
    local objs = serpLight.GetCurrentSessionObjectsFromLocaleByProperty("Walking");
    local ret = {};
    for oid, _ in pairs(objs) do
        table.insert(ret, oid);
    end
    return ret;
end

local function _AreaID_To_ItsOID_Build()
    local ret = {};
    local os = session.getObjectGroupByProperty(serpLight.PropertiesStringToID.LoadingPier);
    for _, v in pairs(os) do
        local oid = serpLight.get_OID(v);
        local o = objectAccessor.GameObject(oid);
        local areaID = serpLight.AreatableToAreaID(o.Area.ID);
        ret[tostring(areaID)] = oid;
    end
    return ret;
end

local function _AreasToResidenceGuids()
    local _residenceGuids = {};
    local os = session.getObjectGroupByProperty(serpLight.PropertiesStringToID.Residence7);
    for _, v in pairs(os) do
        local oid = serpLight.get_OID(v);
        local o = objectAccessor.GameObject(oid);
        local areaID = serpLight.AreatableToAreaID(o.Area.ID);
        local guid = o.Static.Guid;

        if _residenceGuids[areaID] == nil then
            _residenceGuids[areaID] = {};
        end
        _residenceGuids[areaID][guid] = true;
    end

    local ret = {};
    for areaID, guidSet in pairs(_residenceGuids) do
        local areaIdStr = tostring(areaID);
        ret[areaIdStr] = {};
        for guid, _ in pairs(guidSet) do
            table.insert(ret[areaIdStr], guid);
        end
    end
    return ret;
end

---@alias GUID number
---@alias OID number
---@alias OID_str string

---@return table<AreaID_str, table<OID_str, GUID[]>>
local function _BuildingsWithSockets()
    local ret = {};
    local os = Anno.Objects_GetAll_ByProperty(serpLight.PropertiesStringToID.Distribution);
    for oid, _ in pairs(os) do
        local areaId = serpLight.AreatableToAreaID(objectAccessor.GameObject(oid).Area.ID);
        local areaIdStr = tostring(areaId);
        local oidStr = tostring(oid);

        local sockets = Anno.Object_ItemContainer_GetSockets(oid);
        if #sockets > 0 then
            local socketItemsGuids = {};
            for _, v in ipairs(sockets) do
                table.insert(socketItemsGuids, v.Guid);
            end

            if ret[areaIdStr] == nil then
                ret[areaIdStr] = {};
            end
            ret[areaIdStr][oidStr] = socketItemsGuids;
        end
    end
    return ret;
end

---

function Anno.Internal._AreasToProductionGuids()
    local os = {};
    local factories = session.getObjectGroupByProperty(serpLight.PropertiesStringToID.Factory7);
    for _, v in pairs(factories) do
        table.insert(os, serpLight.get_OID(v));
    end
    local recipeBuildings = session.getObjectGroupByProperty(serpLight.PropertiesStringToID.RecipeBuilding);
    for _, v in pairs(recipeBuildings) do
        table.insert(os, serpLight.get_OID(v));
    end
    local buffFactories = session.getObjectGroupByProperty(serpLight.PropertiesStringToID.BuffFactory);
    for _, v in pairs(buffFactories) do
        table.insert(os, serpLight.get_OID(v));
    end

    local guids = {};
    for _, v in ipairs(os) do
        local oid = (v);
        local o = objectAccessor.GameObject(oid);
        local areaID = serpLight.AreatableToAreaID(o.Area.ID);
        local guid = o.Static.Guid;

        if guids[areaID] == nil then
            guids[areaID] = {};
        end
        guids[areaID][guid] = true;
    end

    local ret = {};
    for areaID, guidSet in pairs(guids) do
        local areaIdStr = tostring(areaID);
        ret[areaIdStr] = {};
        for guid, _ in pairs(guidSet) do
            table.insert(ret[areaIdStr], guid);
        end
    end
    return ret;
end

---

function Anno.Region_AreaID_To_OID(region)
    local currentRegion = Anno.Region_Current();
    if currentRegion ~= region then
        return cache.Get("Anno.AreaID_To_ItsOID", region);
    end
    return cache.GetOrSet("Anno.AreaID_To_ItsOID", _AreaID_To_ItsOID_Build, region);
end

---@param region RegionID
---@return ShipID[]|nil
function Anno.Region_Ships_GetAll(region)
    local currentRegion = Anno.Region_Current();
    if currentRegion ~= region then
        return cache.Get("Anno.Ships_GetAll", region);
    end
    return cache.GetOrSet("Anno.Ships_GetAll", _Ships_GetAll, region);
end

function Anno.Region_ResidenceGUIDs(region)
    local currentRegion = Anno.Region_Current();
    if currentRegion ~= region then
        return cache.Get("Anno.AreasToResidenceGuids", region);
    end
    return cache.GetOrSet("Anno.AreasToResidenceGuids", _AreasToResidenceGuids, region);
end

function Anno.Region_ProductionGUIDs(region)
    local currentRegion = Anno.Region_Current();
    if currentRegion ~= region then
        return cache.Get("Anno.AreasToProductionGuids", region);
    end
    return cache.GetOrSet("Anno.AreasToProductionGuids", Anno.Internal._AreasToProductionGuids, region);
end

function Anno.Region_BuildingsWithSockets(region)
    local currentRegion = Anno.Region_Current();
    if currentRegion ~= region then
        return cache.Get("Anno.BuildingsWithSockets", region);
    end
    return cache.GetOrSet("Anno.BuildingsWithSockets", _BuildingsWithSockets, region);
end

---

function Anno.Region_IsCached(region)
    return cache.Exists("Anno.AreaID_To_ItsOID", region)
        and cache.Exists("Anno.Ships_GetAll", region)
        and cache.Exists("Anno.AreasToResidenceGuids", region)
        and cache.Exists("Anno.AreasToProductionGuids", region)
        and cache.Exists("Anno.BuildingsWithSockets", region);
end

function Anno.Region_CanCache(region)
    local currentRegion = Anno.Region_Current();
    return currentRegion == region;
end

-- no camera jumps
function Anno.Region_RefreshCache()
    local currentRegion = Anno.Region_Current();
    cache.Set("Anno.AreaID_To_ItsOID", _AreaID_To_ItsOID_Build, currentRegion);
    cache.Set("Anno.Ships_GetAll", _Ships_GetAll, currentRegion);
    cache.Set("Anno.AreasToResidenceGuids", _AreasToResidenceGuids, currentRegion);
    cache.Set("Anno.AreasToProductionGuids", Anno.Internal._AreasToProductionGuids, currentRegion);
    cache.Set("Anno.BuildingsWithSockets", _BuildingsWithSockets, currentRegion);
end

---

return Anno
