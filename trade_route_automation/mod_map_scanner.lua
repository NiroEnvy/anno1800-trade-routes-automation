local serpLight = require("trade_route_automation/serp/lighttools");
local objectAccessor = require("trade_route_automation/anno_object_accessor");
local cache = require("trade_route_automation/utils_cache");

local Anno = require("trade_route_automation/anno_interface");
local Regions = require("trade_route_automation/_regions");

local function MoveCameraTo(x, y)
    ts.SessionCamera.ToWorldPos(x, y);
end

local function sleep(frames)
    for i = 1, frames do
        coroutine.yield();
    end
end

local NOT_ACCESSIBLE = "not_accessible";
local SOMETHING_THERE = "something_there";
local LAND = "land";
local WATER = "water";
local WATER_ACCESS_POINT = "water_access_point";

-- The assets we put into build mode to interrogate the ground. There is no map-data API, so the
-- price the game quotes for placing something here is the terrain reading.
local DEMOLISH = 2001044;
local DIRT_ROAD = 1000178;

--[[
    MEASURED 2026-08-25, by holding each of the 25 assets whose text is "Quay" in build mode and
    reading `ts.BuildMode.Costs.MoneyCost`. Three runs: Enbesa water (off Taborime), Arctic water,
    Arctic land. `-` means the game quoted nothing; `x` means `startBuild` refused the asset.

                      EN water    AR water    AR land
        1000178 road      -           -          3        <- the land probe
        101339  quay     20          20          -
        131865  quay     20          20          -
        117729  quay      5           5          -
        1010567 quay      5           5          -
        the other 21      - / x       - / x      - / x

    Three things fall out of this:

    1. A road quotes NOTHING over water in either region -- that is the whole bug. In the Old and
       New World the same road quotes 20, because there a road dragged over water becomes a quay.
    2. Every quay quotes NOTHING over land. They are water-exclusive, so a quay that quotes at all
       is a water reading, and the number is a cross-check rather than the signal.
    3. The four that quote are identical across both regions. `game.startBuild` bypasses the
       construction menu, so what is PLACEABLE does not depend on what the region offers you --
       which is why the Arctic prices a quay it has no button for.

    Picked 101339 at 20: 20 against the road's 3 is a wide, unambiguous gap, and it makes the water
    reading 20 in every region including the two that never needed a second probe.

    Of the two that quote 5, `117729` is unaffordable in the Arctic and affordable in Enbesa, while
    `1010567` is affordable in both -- so 117729 is the one carrying a material cost, presumably
    the Enbesa quay's Wanza Timber (114356). Neither is used here; recorded because it is the only
    hard evidence separating them, and it points the opposite way to their text-GUID neighbours.
]]
local QUAY = 101339;

---@class ScanConfig
--- Threaded down from the caller so the probe can differ per region. nil is allowed everywhere and
--- means "the Old/New World behaviour", which is what every call site did before Enbesa.
---@field region RegionID|nil

---@class ProbeSet
---@field land integer       priced first; the one that can read solid ground
---@field landCost integer   what `land` quotes on buildable land
---@field waterCost integer  the quote that means water
---@field water integer|nil  priced only when `land` came back free. nil = single-probe region

--- Old World, New World, and anything unmeasured. One probe does both jobs here because a road
--- dragged over water silently becomes a quay, and the game charges quay money for it.
local PROBE_DEFAULT = {
    land = DIRT_ROAD,
    landCost = 3,
    water = nil,
    waterCost = 20,
};

--- Enbesa and the Arctic refuse to run a road over water at all -- the quay is a separate building
--- you pick by hand -- so the road probe quotes nothing there and every water tile used to fall
--- through to NOT_ACCESSIBLE. Three cached Enbesa scans bore this out before the fix: 236 sampled
--- points, 104 land, 12 something_there, 120 not_accessible, and not one water. Rescanning two of
--- those islands with the second probe turned up 4 and 8 water points respectively.
---
--- The second probe costs an extra two frames, but only on tiles the road could not price, which
--- is water and blocked ground -- never open land. Slower on coastline, unchanged inland.
---
--- That ordering is also why the table above has no "EN land" column and does not need one: over
--- land the road quotes 3, the answer is LAND, and the quay is never asked.
local PROBE_BY_REGION = {
    [Regions.Enbesa] = {
        land = DIRT_ROAD,
        landCost = 3,
        water = QUAY,
        waterCost = 20,
    },
    [Regions.Arctic] = {
        land = DIRT_ROAD,
        landCost = 3,
        water = QUAY,
        waterCost = 20,
    },
};

---@param config ScanConfig|nil
---@return ProbeSet
local function ProbesFor(config)
    if config == nil or config.region == nil then
        return PROBE_DEFAULT;
    end
    return PROBE_BY_REGION[config.region] or PROBE_DEFAULT;
end

--- Holds `guid` for a frame and reads back what the game would charge to place it here.
--- The cost is only meaningful when the game quoted one at all, so an unquoted probe reports 0
--- rather than whatever `MoneyCost` happened to still be holding.
---@return boolean hasCost, integer cost
local function PriceOf(guid)
    game.startBuild(guid);
    sleep(1);

    local hasCost = not ts.BuildMode.Costs.Empty;
    local cost = 0;
    if hasCost then
        cost = ts.BuildMode.Costs.MoneyCost;
    end
    game.startBuild(0);

    return hasCost, cost;
end

---@param config ScanConfig|nil
local function IdentifyCoordinates(x, y, config)
    local probes = ProbesFor(config);

    MoveCameraTo(x, y);
    game.startMouseMode(DEMOLISH)
    sleep(1);

    -- note: switching to build mode to check the cost and short-circuit function DID NOT WORK for me
    -- i did not debug this, from logs i saw destructible check being unreliable (`NOT_ACCESSIBLE` when there was something)

    local m1 = ts.Target.DestructionPayback.Empty;
    local m2 = ts.Target.DestructionCosts.Empty;
    local canBeDestroyed = not m1 or not m2;
    game.startMouseMode(0);

    local hasCost, cost = PriceOf(probes.land);

    -- no sleep(1) after the last `game.startBuild(0)`, because nothing reads its result

    local result;
    if hasCost then
        if cost == probes.landCost then
            result = LAND;
        elseif cost == probes.waterCost and probes.water == nil then
            -- single-probe regions only: where a road IS the quay, its price is the water reading
            result = WATER;
        else
            result = SOMETHING_THERE;
        end
    elseif probes.water ~= nil then
        -- The land probe declined to quote. In a two-probe region that is not yet an answer --
        -- water looks exactly like blocked ground from here -- so ask the water probe as well.
        local hasWaterCost, waterCost = PriceOf(probes.water);
        cost = waterCost;

        if hasWaterCost and waterCost == probes.waterCost then
            result = WATER;
        elseif hasWaterCost then
            result = SOMETHING_THERE;
        elseif canBeDestroyed then
            result = SOMETHING_THERE;
        else
            result = NOT_ACCESSIBLE;
        end
    else
        if canBeDestroyed then
            result = SOMETHING_THERE;
        else
            result = NOT_ACCESSIBLE;
        end
    end

    return {
        Destruction = canBeDestroyed,
        Cost = cost,
        Result = result
    }
end

local function encodeResult(r)
    if r == LAND then
        return "L";
    end
    if r == WATER then
        return "W";
    end
    if r == SOMETHING_THERE then
        return "S";
    end
    if r == NOT_ACCESSIBLE then
        return "N";
    end
    if r == WATER_ACCESS_POINT then
        return "w";
    end
    return "?";
end

---


local function PackCoordinates(x, y)
    return string.format("%d,%d", x, y);
end

local function UnpackCoordinates(key)
    local commaPos = string.find(key, ",");
    local xStr = string.sub(key, 1, commaPos - 1);
    local yStr = string.sub(key, commaPos + 1);
    return tonumber(xStr), tonumber(yStr);
end

---

local P25 = 25;
local P11 = 11;

-- How far the camera may step between samples without stepping over an island. A property of the
-- preset's zoom, not of the map -- where the sweep starts and stops is per region, in `_regions.lua`.
--
-- The X0/Y0/X1/Y1 in the P25 block below are the old, whole-map form these took when the preset was
-- a fixed rectangle; kept as the measurement notes they are.
local presets = {
    --P25 = {
    --    X0 = 420, -- it is more of 450
    --    Y0 = 350, -- it should be 250 (450 * 9/16)
    --    DeltaX = 420,
    --    DeltaY = 233, -- 350 * (2/3)
    --    X1 = 1900,
    --    Y1 = 1750
    --},
    P11 = {
        DeltaX = 90,
        DeltaY = 50,
    }
};

local preset = "P11";

--session.setCameraToPreset(preset);

local cityNameToShortName = {};
local shortNameToCityName = {};

local function getCityShortName(cityName)
    local sn = cityNameToShortName[cityName];
    if sn == nil then
        for i = 1, #cityName do
            local candidate = string.sub(cityName, i, i);
            if shortNameToCityName[candidate] == nil then
                cityNameToShortName[cityName] = candidate;
                shortNameToCityName[candidate] = cityName;
                return candidate;
            end
        end
    end
    return sn;
end

local function sessionScanner()
    local region = Anno.Region_Current()
    if region == nil then
        error("map scanner: session guid=" .. Regions.CurrentGuid() .. " is not in the region " ..
            "registry -- add a row for it in trade_route_automation/_regions.lua");
    end

    -- A region without bounds is one nobody has measured yet. Fail loudly and say where to put
    -- them, rather than the "'for' limit must be a number" this used to raise.
    local bounds = Regions.Bounds(region);
    if bounds == nil then
        error("map scanner: region " .. region .. " has no bounds -- measure them and fill them " ..
            "in in trade_route_automation/_regions.lua (see docs/regions.md)");
    end

    local step = presets[preset];
    local results = {};

    for y = bounds.y1, bounds.y0, -step.DeltaY do
        for x = bounds.x0, bounds.x1, step.DeltaX do
            x = math.floor(x);
            y = math.floor(y);

            MoveCameraTo(x, y);
            sleep(1);

            local areaID = serpLight.AreatableToAreaID(ts.Area.Current.ID);

            local cityIndexStr = "";
            local q = objectAccessor.AreaFromID(areaID).CityName;
            if q == nil or q == "" then
                cityIndexStr = ".";
            else
                local sn = getCityShortName(q);
                cityIndexStr = sn;
            end

            results[PackCoordinates(x, y)] = { city_index = cityIndexStr, area_id = areaID };
        end
    end

    return results;
end

---

local function sessionScanner_areaGrids(res)
    local areaGrids = {};

    for key, v in pairs(res) do
        local x, y = UnpackCoordinates(key);
        local areaId = v.area_id;
        if v.city_index == "." then
            goto continue;
        end

        local grid = areaGrids[areaId];
        if grid == nil then
            grid = {
                min_x = x,
                min_y = y,
                max_x = x,
                max_y = y,
            };
        end
        if x < grid.min_x then
            grid.min_x = x;
        end
        if x > grid.max_x then
            grid.max_x = x;
        end
        if y < grid.min_y then
            grid.min_y = y;
        end
        if y > grid.max_y then
            grid.max_y = y;
        end
        areaGrids[areaId] = grid;

        :: continue ::
    end

    return areaGrids;
end

---

---@param config ScanConfig|nil
local function areaScanner_grid(minX, minY, maxX, maxY, config)
    for x = minX, maxX, 10 do
        for y = minY, maxY, 10 do
            local res = IdentifyCoordinates(x, y, config);

            local c = "";
            if res.Result == LAND then
                c = "L";
            end
            if res.Result == WATER then
                c = "W";
            end
            if res.Result == SOMETHING_THERE then
                c = "S";
            end
            if res.Result == NOT_ACCESSIBLE then
                c = "N";
            end
            -- no logger in scope here; pass one in as an argument before re-enabling
            -- L.logf("%d,%d,%s", x, y, c);
        end
    end
end

---

---@param config ScanConfig|nil which probes to use; see ProbesFor. nil = Old/New World behaviour.
local function areaScanner_dfs(L, minX, minY, maxX, maxY, resolution, config)
    local dx = resolution;
    local dy = resolution;

    -- then, go ccw around border
    local UP = { dx = 0, dy = dy, name = "up" };
    local DOWN = { dx = 0, dy = -dy, name = "down" };
    local LEFT = { dx = -dx, dy = 0, name = "left" };
    local RIGHT = { dx = dx, dy = 0, name = "right" };

    local CCW = {
        [UP] = LEFT,
        [LEFT] = DOWN,
        [DOWN] = RIGHT,
        [RIGHT] = UP
    };
    local CW = {
        [UP] = RIGHT,
        [RIGHT] = DOWN,
        [DOWN] = LEFT,
        [LEFT] = UP
    };
    local INVERT = {
        [UP] = DOWN,
        [DOWN] = UP,
        [LEFT] = RIGHT,
        [RIGHT] = LEFT
    };

    local function encodeDirection(d)
        if d == UP then
            return "U";
        end
        if d == DOWN then
            return "D";
        end
        if d == LEFT then
            return "L";
        end
        if d == RIGHT then
            return "R";
        end
        return "?";
    end

    ---

    local visited = {};
    local visitedResult = {};

    local function _visit(_x, _y, srcResult)
        local outOfBounds = _x < minX or _x > maxX or _y < minY or _y > maxY;
        local srcIsNotAccessible = srcResult == NOT_ACCESSIBLE;
        if outOfBounds and srcIsNotAccessible then
            return true, NOT_ACCESSIBLE;
        end

        local key = PackCoordinates(_x, _y);
        if visited[key] then
            return true, visitedResult[key];
        end

        local u = PackCoordinates(_x + UP.dx, _y + UP.dy);
        local d = PackCoordinates(_x + DOWN.dx, _y + DOWN.dy);
        local l = PackCoordinates(_x + LEFT.dx, _y + LEFT.dy);
        local r = PackCoordinates(_x + RIGHT.dx, _y + RIGHT.dy);
        local uT, uR = visited[u], visitedResult[u];
        local dT, dR = visited[d], visitedResult[d];
        local lT, lR = visited[l], visitedResult[l];
        local rT, rR = visited[r], visitedResult[r];
        if uT and dT and lT and rT then
            if uR == LAND and dR == LAND and lR == LAND and rR == LAND then
                visited[key] = true;
                visitedResult[key] = LAND;
                return true, LAND;
            end
        end

        local res = IdentifyCoordinates(_x, _y, config);
        visited[key] = true;
        visitedResult[key] = res.Result;
        return false, res.Result;
    end

    ---

    -- start mid-top
    local x0 = math.floor((minX + maxX) / 2 / 10) * 10;
    local y0 = maxY;

    -- go to bottom until we hit something
    while y0 >= minY do
        local _, res = _visit(x0, y0, NOT_ACCESSIBLE);
        L.logf("%d,%d,%s,%s", x0, y0, encodeResult(res), encodeDirection(DOWN));
        if res ~= NOT_ACCESSIBLE then
            break;
        end

        y0 = y0 - dy;
        :: continue ::
    end

    L.logf("Starting DFS at %d,%d", x0, y0);
    L.logf("%d,%d,Y,D", x0, y0);

    local _dfs_visit_inv = 0;

    local function _dfs_visit(x, y, dir)
        local function is_origin(_x, _y)
            return _x == x0 and _y == y0 and dir ~= DOWN;
        end
        local function halt_on_origin(_x, _y)
            if is_origin(_x, _y) then
                L.log("DFS visit halting due to return to origin");
                _dfs_visit_inv = 10000;
                return true;
            end
            return false;
        end
        local function halt_on_too_many_invocations()
            if _dfs_visit_inv > 200 then
                L.log("DFS visit halting due to too many invocations");
                return true;
            end
            return false;
        end
        local function halt()
            if halt_on_origin(x, y) then
                return true;
            end
            if halt_on_too_many_invocations() then
                return true;
            end
            return false;
        end
        local function log_dfs(_x, _y, _res, _dir)
            L.logf("%d,%d,%s,%s", _x, _y, encodeResult(_res), encodeDirection(_dir));
        end

        _dfs_visit_inv = _dfs_visit_inv + 1;
        if halt() then
            return;
        end

        local t = CCW[dir];
        while true do
            if halt_on_too_many_invocations() then
                return;
            end

            local tX = x + t.dx;
            local tY = y + t.dy;

            local xy = PackCoordinates(tX, tY);
            local xy_res = visitedResult[xy];

            local isVisited, res = _visit(tX, tY, xy_res);
            log_dfs(tX, tY, res, t);
            if isVisited or res == NOT_ACCESSIBLE then
                if halt_on_origin(tX, tY) then
                    return;
                end
                goto continue;
            end

            _dfs_visit(tX, tY, t);

            :: continue ::
            t = CW[t];

            if t == INVERT[dir] then
                break;
            end
        end
    end

    L.logf("start at %s time", os.date("%Y-%m-%d %H:%M:%S"));
    _dfs_visit(x0, y0, DOWN);
    L.logf("end at %s time", os.date("%Y-%m-%d %H:%M:%S"));

    return visitedResult;
end

---

local function visualizationTsvs(L, areas)
    for areaID, grid in pairs(areas) do
        local area = objectAccessor.AreaFromID(areaID);
        L.logf("%s / %d (owner=%d %s) grid{ minX=%d minY=%d maxX=%d maxY=%d }",
            area.CityName,
            areaID,
            area.Owner,
            area.OwnerName,
            tostring(grid.min_x),
            tostring(grid.min_y),
            tostring(grid.max_x),
            tostring(grid.max_y)
        );

        if area.Owner ~= 0 then
            goto continue;
        end

        -- these used to reference `cache` and `map_scanner`, neither of which is in scope in this
        -- file, so this function threw on its first call. `map_scanner.X` is this very module --
        -- the names below are what its return table maps those exports to.
        local scan = cache.GetOrSetR(function(a, b, c, d, e)
            return areaScanner_dfs(L, a, b, c, d, e);
        end, "areaScanner_dfs", grid.min_x, grid.min_y, grid.max_x, grid.max_y, 20);
        L.logf("area returned %d scanned objects", #scan);

        local cityName = area.CityName:gsub("%s+", "_");

        local lq = L.logger("area_scan_" .. cityName .. ".tsv");
        for k, v in pairs(scan) do
            local x, y = UnpackCoordinates(k);
            lq.logf("%d,%d,%s", x, y, encodeResult(v));
        end

        :: continue ::
    end
end

---

return {
    Session_Areas_Grid = sessionScanner,
    Area_WaterPoints = areaScanner_dfs,
    Session_Areas_Rectangles = sessionScanner_areaGrids,

    Coordinate_Land = LAND,
    Coordinate_Water = WATER,
    Coordinate_SomethingThere = SOMETHING_THERE,
    Coordinate_NotAccessible = NOT_ACCESSIBLE,
    Coordinate_WaterAccessPoint = WATER_ACCESS_POINT,
    Coordinate_ToLetter = encodeResult,

    PackCoordinates = PackCoordinates,
    UnpackCoordinates = UnpackCoordinates,
}
