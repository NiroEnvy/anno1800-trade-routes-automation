--[[
    Tests for the per-region construction goods list.

    Every island carries a standing request for the goods it needs to BUILD with, and until Enbesa
    that was one list for the whole game. Enbesa builds with Wanza Timber and Mud Bricks, which no
    other region can lay a brick with -- so the list is now keyed by region, and the two failure
    modes worth guarding are opposite: Enbesa silently missing its own two materials, and the Old
    World being handed materials it cannot use.
]]

local T = require("tests/lib/t");

local MOD = "trade_route_automation/mod_area_requests";
local ANNO = "trade_route_automation/anno_interface";
local PRODUCTS = "trade_route_automation/generator/products";

local WOOD = 120008;
local WANZA_TIMBER = 114356;
local MUD_BRICKS = 114402;

--- `mod_area_requests` reads region codes off `anno_interface` when it loads, and requiring the
--- real one out here drags in the whole game surface. Stand in a table with just the constants,
--- then put back whatever was there so the harness-based suites are unaffected.
local function withAreaRequests(fn)
    local saved = {
        [ANNO] = package.loaded[ANNO],
        [MOD] = package.loaded[MOD],
        [PRODUCTS] = package.loaded[PRODUCTS],
    };

    package.loaded[ANNO] = {
        Region_OldWorld = "OW",
        Region_NewWorld = "NW",
        Region_Enbesa = "EN",
        Region_Arctic = "AR",
        Region_CapeTrelawney = "CT",
    };
    package.loaded[PRODUCTS] = {};
    package.loaded[MOD] = nil;

    local ok, err = pcall(fn, require(MOD));

    for k, v in pairs(saved) do
        package.loaded[k] = v;
    end

    if not ok then
        error(err, 0);
    end
end

local function has(list, guid)
    for _, g in ipairs(list) do
        if g == guid then
            return true;
        end
    end
    return false;
end

T.test("construction goods: Enbesa gets Wanza Timber and Mud Bricks on top of the base list",
    function()
        withAreaRequests(function(AreaRequests)
            local base = AreaRequests.ConstructionGoods;
            local en = AreaRequests.ConstructionGoodsFor("EN");

            T.truthy(has(en, WANZA_TIMBER), "Enbesa requests Wanza Timber");
            T.truthy(has(en, MUD_BRICKS), "Enbesa requests Mud Bricks");

            -- additive, not replacing: the base nine still have to be in there
            T.truthy(has(en, WOOD), "Enbesa still requests Wood");
            T.len(en, #base + 2, "exactly two goods added");
        end);
    end);

T.test("construction goods: other regions are not handed Enbesa's materials", function()
    withAreaRequests(function(AreaRequests)
        local base = AreaRequests.ConstructionGoods;

        for _, region in ipairs({ "OW", "NW", "AR", "CT" }) do
            local goods = AreaRequests.ConstructionGoodsFor(region);
            T.falsy(has(goods, WANZA_TIMBER), region .. " does not request Wanza Timber");
            T.falsy(has(goods, MUD_BRICKS), region .. " does not request Mud Bricks");
            T.len(goods, #base, region .. " gets the base list unchanged");
        end
    end);
end);

T.test("construction goods: a nil or unknown region falls back to the base list", function()
    withAreaRequests(function(AreaRequests)
        local base = AreaRequests.ConstructionGoods;

        T.len(AreaRequests.ConstructionGoodsFor(nil), #base, "nil region");
        T.len(AreaRequests.ConstructionGoodsFor("ZZ"), #base, "a region nobody has listed");
    end);
end);

--- The base case returns the shared module table rather than a copy, so a caller that asked for
--- Enbesa first must not have grown it by two.
T.test("construction goods: asking for Enbesa does not mutate the shared base list", function()
    withAreaRequests(function(AreaRequests)
        local before = #AreaRequests.ConstructionGoods;

        AreaRequests.ConstructionGoodsFor("EN");
        AreaRequests.ConstructionGoodsFor("EN");

        T.len(AreaRequests.ConstructionGoods, before, "base list is the same length as before");
        T.falsy(has(AreaRequests.ConstructionGoods, WANZA_TIMBER),
            "Wanza Timber did not leak into the base list");
    end);
end);
