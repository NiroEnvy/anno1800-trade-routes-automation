--[[
    Region registry -- the one place that says which regions the mod knows about.

    `Anno.Region_*`, the map scanner's camera sweep and the per-region planner threads in `_main.lua`
    all read from the table below, so adding a region is one row here rather than an edit in three
    files. A modded session is added the same way, or at runtime via `Regions.Register`.

    A region is ENABLED only once it has `bounds`, and only enabled regions get a planner thread.
    Enbesa, the Arctic and Cape Trelawney ship without bounds on purpose: nothing in the game's Lua
    surface reports a session's extents (`ts.Area` has no enumeration, and there is no map-size
    property anywhere in docs/lua-inspector/ts.yaml), and the extents depend on how the save was
    generated anyway. So the numbers get measured by hand, once, per region.

    See docs/regions.md for how to measure them and what they mean.
]]

---@class RegionBounds
--- World coordinates -- the same ones `ts.SessionCamera.ToWorldPos` takes. `x0,y0` is where the
--- sweep starts and `x1,y1` where it stops; the step between samples belongs to the camera preset
--- and lives in `mod_map_scanner.lua`. Too small a box silently misses islands. Too large a box
--- only costs sweep time -- roughly `((x1-x0)/DeltaX) * ((y1-y0)/DeltaY)` camera moves.
---@field x0 number
---@field y0 number
---@field x1 number
---@field y1 number

---@class Region
---@field guid string              session GUID as a string; what `session.getSessionGUID()` returns
---@field code RegionID            2 letters; ends up in `TRA_<code>` route names and cache filenames
---@field name string              for logs and error messages only
---@field bounds RegionBounds|nil  nil = not measured yet, so the region stays disabled

local Regions = {};

--- Region codes. Named because call sites read better with them, but the table below is what
--- actually defines a region -- these are just its `code` field, hoisted out to be referenced.
Regions.OldWorld      = "OW";
Regions.NewWorld      = "NW";
Regions.Enbesa        = "EN";
Regions.Arctic        = "AR";
Regions.CapeTrelawney = "CT";

--- Declaration order is the order planner threads are spawned in.
---@type Region[]
local REGIONS = {
    {
        guid   = "180023",
        code   = Regions.OldWorld,
        name   = "Old World",
        bounds = { x0 = 250, y0 = 250, x1 = 2600, y1 = 2600 },
    },
    {
        guid   = "180025",
        code   = Regions.NewWorld,
        name   = "New World",
        bounds = { x0 = 250, y0 = 250, x1 = 2120, y1 = 2120 },
    },
    {
        guid   = "112132",
        code   = Regions.Enbesa,
        name   = "Enbesa",
        bounds = { x0 = 250, y0 = 250, x1 = 2000, y1 = 2000 },
    },
    {
        guid   = "180045",
        code   = Regions.Arctic,
        name   = "Arctic",
        bounds = { x0 = 250, y0 = 250, x1 = 2000, y1 = 2000 },
    },
    {
        guid   = "110934",
        code   = Regions.CapeTrelawney,
        name   = "Cape Trelawney",
        bounds = nil,
    },
};

---

---@type table<string, Region>
local _byGuid = {};
---@type table<RegionID, Region>
local _byCode = {};

--- Five rows, so this is eager rather than lazy: `Register` just calls it again.
local function _reindex()
    _byGuid = {};
    _byCode = {};
    for _, r in ipairs(REGIONS) do
        _byGuid[r.guid] = r;
        _byCode[r.code] = r;
    end
end

_reindex();

---@param guid string|number
---@return Region|nil
function Regions.ByGuid(guid)
    return _byGuid[tostring(guid)];
end

---@param code RegionID
---@return Region|nil
function Regions.ByCode(code)
    return _byCode[code];
end

--- Every known region, in declaration order, whether or not it has bounds.
---@return Region[]
function Regions.All()
    local ret = {};
    for _, r in ipairs(REGIONS) do
        table.insert(ret, r);
    end
    return ret;
end

--- The regions the mod will actually drive: the ones whose bounds have been measured.
---@return Region[]
function Regions.Enabled()
    local ret = {};
    for _, r in ipairs(REGIONS) do
        if r.bounds ~= nil then
            table.insert(ret, r);
        end
    end
    return ret;
end

---@param code RegionID
---@return RegionBounds|nil
function Regions.Bounds(code)
    local r = Regions.ByCode(code);
    if r == nil then
        return nil;
    end
    return r.bounds;
end

--- The session the player is in, as a string. Separate from `Current` so that error messages can
--- name a GUID the registry does not know.
---@return string
function Regions.CurrentGuid()
    return tostring(session.getSessionGUID());
end

--- nil when the player is in a session no row above describes -- a modded region, most likely.
---@return Region|nil
function Regions.Current()
    return Regions.ByGuid(Regions.CurrentGuid());
end

--- Add a region without editing this file -- for modded sessions, or to supply bounds from the
--- console while measuring them. Replacing an existing GUID is allowed and is how you override a
--- built-in; taking a code that another GUID already holds is not, because the code is what the
--- player's `TRA_<code>` trade route and every cache file are keyed by.
---
--- Call it before the mod's threads start, i.e. from `_init.lua`, or follow it with a restart.
---@param region Region
function Regions.Register(region)
    assert(type(region) == "table", "Regions.Register: expected a table");
    assert(type(region.guid) == "string" or type(region.guid) == "number",
        "Regions.Register: region.guid must be a string or a number");
    assert(type(region.code) == "string" and #region.code > 0,
        "Regions.Register: region.code must be a non-empty string");

    local entry = {
        guid   = tostring(region.guid),
        code   = region.code,
        name   = region.name or region.code,
        bounds = region.bounds,
    };

    local clash = Regions.ByCode(entry.code);
    if clash ~= nil and clash.guid ~= entry.guid then
        error(string.format(
            "Regions.Register: code %s is already taken by session %s (%s); pick another one",
            entry.code, clash.guid, clash.name));
    end

    for i, r in ipairs(REGIONS) do
        if r.guid == entry.guid then
            REGIONS[i] = entry;
            _reindex();
            return entry;
        end
    end

    table.insert(REGIONS, entry);
    _reindex();
    return entry;
end

return Regions;
