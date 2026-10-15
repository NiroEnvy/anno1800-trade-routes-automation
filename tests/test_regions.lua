--[[
    Tests for the region registry.

    `_regions.lua` decides which regions exist, which of them the mod drives, and what the map
    scanner sweeps -- so a mistake here is a region that silently never runs, or an Old World that
    gets scanned with the wrong box. It holds module-level state, so every test that mutates it
    takes a fresh copy.
]]

local T = require("tests/lib/t");

local MODULE = "trade_route_automation/_regions";

--- A registry with no mutations from another test in it.
local function fresh()
    package.loaded[MODULE] = nil;
    return require(MODULE);
end

--- `_regions` reads `session.getSessionGUID()`; the game global does not exist out here.
local function inSession(guid, fn)
    local saved = _G.session;
    _G.session = { getSessionGUID = function() return guid; end };
    local ok, err = pcall(fn);
    _G.session = saved;
    if not ok then
        error(err, 0);
    end
end

---

T.test("regions: the shipped table is the five base-game sessions", function()
    local R = fresh();

    T.len(R.All(), 5, "regions known");

    local codes = {};
    for _, r in ipairs(R.All()) do
        table.insert(codes, r.code);
    end
    T.deep_eq(codes, { "OW", "NW", "EN", "AR", "CT" }, "codes, in declaration order");
end);

T.test("regions: only regions with bounds are enabled", function()
    local R = fresh();

    local codes = {};
    for _, r in ipairs(R.Enabled()) do
        table.insert(codes, r.code);
    end
    T.deep_eq(codes, { "OW", "NW", "EN", "AR" }, "enabled out of the box");

    T.deep_eq(R.Bounds("EN"), { x0 = 250, y0 = 250, x1 = 2000, y1 = 2000 }, "Enbesa ships with bounds");
    T.deep_eq(R.Bounds("AR"), { x0 = 250, y0 = 250, x1 = 2000, y1 = 2000 }, "the Arctic ships with bounds");
    T.nil_(R.Bounds("CT"), "Cape Trelawney has no bounds yet");
end);

T.test("regions: OW and NW bounds are what the scanner used to hardcode", function()
    local R = fresh();

    T.deep_eq(R.Bounds("OW"), { x0 = 250, y0 = 250, x1 = 2600, y1 = 2600 }, "Old World box");
    T.deep_eq(R.Bounds("NW"), { x0 = 250, y0 = 250, x1 = 2120, y1 = 2120 }, "New World box");
end);

T.test("regions: the current session resolves through the GUID", function()
    local R = fresh();

    inSession(180023, function()
        T.eq(R.Current().code, "OW", "session 180023");
    end);
    inSession(110934, function()
        T.eq(R.Current().code, "CT", "session 110934, registered but not enabled");
    end);
    inSession(999999, function()
        T.nil_(R.Current(), "a session no row describes");
        T.eq(R.CurrentGuid(), "999999", "its GUID is still reportable, for the error message");
    end);
end);

T.test("regions: supplying bounds is all it takes to enable a region", function()
    local R = fresh();

    R.Register { guid = "110934", code = "CT", name = "Cape Trelawney",
        bounds = { x0 = 250, y0 = 250, x1 = 2000, y1 = 2000 } };

    local codes = {};
    for _, r in ipairs(R.Enabled()) do
        table.insert(codes, r.code);
    end
    T.deep_eq(codes, { "OW", "NW", "EN", "AR", "CT" }, "Cape Trelawney joins, keeping its declared slot");
    T.len(R.All(), 5, "and overrode its row rather than adding a second one");
end);

T.test("regions: a modded session can be added at runtime", function()
    local R = fresh();

    R.Register { guid = 4200001, code = "MO", name = "Modded",
        bounds = { x0 = 250, y0 = 250, x1 = 1500, y1 = 1500 } };

    T.len(R.All(), 6, "appended after the built-ins");
    T.eq(R.ByGuid("4200001").name, "Modded", "found by string GUID");
    T.eq(R.ByGuid(4200001).name, "Modded", "and by number, since the game returns one");
    T.eq(R.ByCode("MO").guid, "4200001", "GUID normalised to a string");

    inSession(4200001, function()
        T.eq(R.Current().code, "MO", "and it is the current region when you are standing in it");
    end);
end);

T.test("regions: two regions cannot share a code", function()
    local R = fresh();

    -- the code is what `TRA_<code>` and every cache filename are keyed by, so a collision would
    -- quietly cross two regions' ships and caches
    local ok, err = pcall(R.Register, { guid = "777", code = "OW", name = "Impostor" });
    T.falsy(ok, "refused");
    T.truthy(tostring(err):find("already taken", 1, true), "and says why: " .. tostring(err));

    T.eq(R.ByCode("OW").guid, "180023", "the incumbent is untouched");
    T.len(R.All(), 5, "and nothing was added");
end);

T.test("regions: re-registering the same GUID replaces it in place", function()
    local R = fresh();

    R.Register { guid = "180025", code = "NW", name = "New World",
        bounds = { x0 = 0, y0 = 0, x1 = 3000, y1 = 3000 } };

    T.len(R.All(), 5, "still five");
    T.deep_eq(R.Bounds("NW"), { x0 = 0, y0 = 0, x1 = 3000, y1 = 3000 }, "with the new box");
end);
