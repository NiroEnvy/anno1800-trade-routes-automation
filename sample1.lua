-- PROBE: which asset GUID is the quay in THIS region, and what does build mode say about it?
--
-- Background. `mod_map_scanner.IdentifyCoordinates` classifies a world coordinate by putting a
-- Dirt Road (1000178) into build mode and reading the price: 3 = land, 20 = water. That works
-- because in the Old/New World a road dragged over water silently becomes a quay. In Enbesa it
-- does not -- road-over-water is unavailable and the quay must be picked by hand -- so every water
-- tile there comes back with an empty cost and falls through to NOT_ACCESSIBLE.
--
-- To fix the scanner we need the GUID of the building that IS placeable on water in this region.
-- texts.json has exactly 25 assets named "Quay"; only one of them is this region's.
--
-- Two ways to find it, and this script does both:
--   Phase 1  read it straight off build mode after YOU select the quay in the construction menu.
--            `ts.BuildMode.BuildMode.Object.GUID` names whatever is currently held. One answer,
--            no guessing. (docs/lua-inspector/ts.BuildMode.yaml:3304 is exactly this, captured
--            while a Harbourmaster's Office was held: `GUID: 100586`.)
--   Phase 2  walk all 25 candidates and log what each one costs where the camera is pointing.
--            Slower, but it also tells us what the OTHER 24 do, which is what stops us from
--            picking a GUID that happens to work here and breaks in the next region.
--
-- WHERE IT PROBES: the camera centre, not the mouse pointer. `MoveCameraTo` is how the scanner
-- aims, so aim the camera at open water before running this, or set PROBE_X/PROBE_Y below.
--
-- Read-only: build mode is entered and cancelled, nothing is ever placed.

local objectAccessor = require("trade_route_automation/anno_object_accessor");

local L = require("trade_route_automation/utils_logger");
L = L.logger("quay-probe.log", true);

---------------------------------------------------------------------------- config

-- nil = probe wherever the camera is already pointing. Set both once you have a water coordinate
-- you want to re-probe repeatably.
local PROBE_X, PROBE_Y = nil, nil;

-- Frames to wait before Phase 1 reads build mode, so you can alt-tab back into the game and pick
-- the quay from the construction menu. 0 skips the wait and just reads whatever is held right now.
--
-- NOT ~60/sec: a yield is a game tick, so on the slowest game speed 900 of these took 107 seconds.
-- Set it to 0 unless you actually intend to pick something by hand.
local READBACK_WAIT_FRAMES = 0;

-- Frames to let the UI settle after each startBuild. The scanner uses 1; 2 is cheap insurance
-- when we care about the value being right rather than about scan throughput.
local SETTLE_FRAMES = 2;

-- Every asset whose text is exactly "Quay", ascending. Generated from
-- trade_route_automation/generator/texts.json.
local CANDIDATES = {
    22441, 22472, 100446, 100452, 100691, 100694, 100695, 101008, 101339,
    102459, 102460, 113459, 113478, 114826, 117729, 117730, 117731, 131865,
    131866, 131867, 132528, 132529, 601492, 601493, 1010567,
};

-- The two known-good probes, logged alongside for calibration: whatever the quay reads, we want
-- to see it next to what Dirt Road reads at the same spot.
local DIRT_ROAD = 1000178;

-- What we are looking for. The Enbesa quay is 5 credits + Wanza Timber (114356); the timber half
-- is NOT visible from Lua (see the note at the bottom of this file), so money is the tell.
local EXPECT_MONEY = 5;

---------------------------------------------------------------------------- helpers

local function say(fmt, ...)
    local msg = select("#", ...) > 0 and string.format(fmt, ...) or fmt;
    print("[QUAY] " .. msg);
    L.log(msg);
end

local function sleep(frames)
    for _ = 1, frames do
        coroutine.yield();
    end
end

-- Every read goes through here. Build mode may hold nothing at all, in which case traversing
-- .BuildMode.Object.GUID throws rather than returning nil, and one bad field must not take the
-- whole sweep down.
local function get(acc, ...)
    local path = { ... };
    local ok, v = pcall(function()
        local o = acc;
        for _, part in ipairs(path) do
            o = o[part];
        end
        return o;
    end);
    if not ok then
        return nil;
    end
    return v;
end

local function s(v)
    if v == nil then
        return "-";
    end
    return tostring(v);
end

-- A fresh accessor per call: `anno_object_accessor` exists because a plain `ts.X.Y.Z` chain caches
-- the first field you touch and hands you the same value for the next one.
local function buildMode()
    return objectAccessor.Generic(function()
        return ts.BuildMode;
    end);
end

-- Everything CBuildCost and CBuildModeObject expose, per docs/lua-inspector/ts.BuildMode.yaml.
local function snapshot()
    local bm = buildMode();
    return {
        objGuid       = get(bm, "BuildMode", "Object", "GUID"),
        currentMode   = get(bm, "CurrentBuildMode"),
        isDefaultMode = get(bm, "IsDefaultMode"),
        isStreetMode  = get(bm, "IsStreetMode"),

        costEmpty     = get(bm, "Costs", "Empty"),
        money         = get(bm, "Costs", "MoneyCost"),
        payable       = get(bm, "Costs", "IsPayable"),
        inflCost      = get(bm, "Costs", "InfluenceCost"),
        inflUsage     = get(bm, "Costs", "InfluenceUsageCost"),
        inflPayback   = get(bm, "Costs", "InfluencePayback"),
        inflChanges   = get(bm, "Costs", "HasInfluenceChanges"),
        inflPayable   = get(bm, "Costs", "InfluencePayable"),

        terrainValid  = get(bm, "BuildMode", "IsTerrainTypeValid"),
        areaBlocked   = get(bm, "BuildMode", "IsAreaBlocked"),
        notAdjacent   = get(bm, "BuildMode", "IsNotAdjacent"),
        snapped       = get(bm, "BuildMode", "IsSnapped"),
        fertility     = get(bm, "BuildMode", "HasNeededFertility"),
        irrigation    = get(bm, "BuildMode", "IsIrrigationMissing"),
        overlapping   = get(bm, "BuildMode", "IsOverlappingSameGUIDRadius"),
        isMove        = get(bm, "BuildMode", "IsMove"),
        mainModule    = get(bm, "BuildMode", "IsMainModule"),
        moduleLimit   = get(bm, "BuildMode", "IsModuleLimitReached"),
        blueprint     = get(bm, "BuildMode", "IsInBlueprintMode"),
    };
end

local HEADER = table.concat({
    "guid", "objGuid", "mode", "costEmpty", "money", "payable",
    "inflCost", "inflUsage", "terrainValid", "areaBlocked", "notAdjacent",
    "snapped", "fertility", "irrigation", "overlap",
}, "\t");

local function row(guid, snap)
    return table.concat({
        s(guid), s(snap.objGuid), s(snap.currentMode), s(snap.costEmpty), s(snap.money),
        s(snap.payable), s(snap.inflCost), s(snap.inflUsage), s(snap.terrainValid),
        s(snap.areaBlocked), s(snap.notAdjacent), s(snap.snapped), s(snap.fertility),
        s(snap.irrigation), s(snap.overlapping),
    }, "\t");
end

-- Anything with a real cost gets the long form too, because the TSV is for scanning and this is
-- for reading.
local function verbose(guid, snap)
    say("  ---- %d in full ----", guid);
    for _, k in ipairs({
        "objGuid", "currentMode", "isDefaultMode", "isStreetMode",
        "costEmpty", "money", "payable", "inflCost", "inflUsage", "inflPayback",
        "inflChanges", "inflPayable",
        "terrainValid", "areaBlocked", "notAdjacent", "snapped", "fertility",
        "irrigation", "overlapping", "isMove", "mainModule", "moduleLimit", "blueprint",
    }) do
        say("      %-14s %s", k, s(snap[k]));
    end
end

-- Long shot, one call: if the asset itself carries its build cost, the Wanza Timber requirement
-- would be visible here and we would not need the money value as a proxy at all.
local function dumpAssetData(guid)
    local ok, ad = pcall(ts.GetAssetData, guid);
    if not ok or ad == nil then
        say("      GetAssetData(%d) -> %s", guid, tostring(ad));
        return;
    end
    local names = {};
    local okK = pcall(function()
        for k, v in pairs(ad) do
            if type(k) == "string" then
                table.insert(names, k .. ":" .. type(v));
            end
        end
    end);
    if okK and #names > 0 then
        table.sort(names);
        say("      GetAssetData(%d) members: %s", guid, table.concat(names, ", "));
    else
        say("      GetAssetData(%d) -> opaque (%s)", guid, type(ad));
    end
end

local function probeGuid(guid)
    game.startBuild(guid);
    sleep(SETTLE_FRAMES);
    local snap = snapshot();
    game.startBuild(0);
    sleep(SETTLE_FRAMES);
    return snap;
end

---------------------------------------------------------------------------- phases

local function phase0()
    say("=== 0. where we are ===");
    say("  session guid = %s", tostring(session.getSessionGUID()));
    if PROBE_X ~= nil and PROBE_Y ~= nil then
        say("  moving camera to %d,%d", PROBE_X, PROBE_Y);
        ts.SessionCamera.ToWorldPos(PROBE_X, PROBE_Y);
        sleep(SETTLE_FRAMES);
    else
        say("  probing wherever the camera already points (SessionCamera has no position readback,");
        say("  so this run is not reproducible -- set PROBE_X/PROBE_Y once you find a good spot)");
    end
    say("");
end

local function phase1()
    say("=== 1. readback: what is in build mode right now ===");
    if READBACK_WAIT_FRAMES > 0 then
        say("  waiting ~%d frames -- alt-tab back into the game and pick the quay from the",
            READBACK_WAIT_FRAMES);
        say("  construction menu now. Leave it held, do not place it.");
        sleep(READBACK_WAIT_FRAMES);
    end

    local snap = snapshot();
    if snap.objGuid == nil or snap.objGuid == 0 then
        -- Not necessarily "nothing held". The Enbesa run landed here with IsDefaultMode=false,
        -- i.e. build mode WAS holding something and Object.GUID reported 0 anyway. Dump the whole
        -- snapshot rather than nothing, so that case leaves evidence instead of a shrug.
        say("  objGuid=%s -- no asset id. Full state anyway:", s(snap.objGuid));
        verbose(0, snap);
    else
        say("  >>> HELD ASSET GUID = %s <<<", s(snap.objGuid));
        verbose(snap.objGuid, snap);
        dumpAssetData(snap.objGuid);
    end
    say("");
end

local function phase2()
    say("=== 2. calibration: Dirt Road (%d) at this spot ===", DIRT_ROAD);
    say(HEADER);
    local dirt = probeGuid(DIRT_ROAD);
    say(row(DIRT_ROAD, dirt));
    verbose(DIRT_ROAD, dirt);
    say("");
    say("  (in the Old/New World this reads money=20 over water and money=3 over land. If it is");
    say("   empty here, that is the Enbesa breakage this whole probe is about.)");
    say("");

    say("=== 3. all 25 quay candidates ===");
    say(HEADER);

    local hits = {};
    for _, guid in ipairs(CANDIDATES) do
        local snap = probeGuid(guid);
        say(row(guid, snap));

        local entered = snap.objGuid ~= nil and snap.objGuid ~= 0;
        local hasCost = snap.costEmpty == false;
        if entered or hasCost then
            table.insert(hits, { guid = guid, snap = snap });
        end
    end

    say("");
    say("=== 4. candidates that did anything at all ===");
    if #hits == 0 then
        say("  none. Either none of the 25 is this region's quay, or the camera is not over water,");
        say("  or startBuild refuses a building that is not unlocked/available. Check that you can");
        say("  place the quay by hand at this exact spot first.");
        return;
    end
    for _, h in ipairs(hits) do
        local mark = (h.snap.money == EXPECT_MONEY)
            and "  <== same price as Enbesa's quay (reference only, not proof)" or "";
        say("  %d  objGuid=%s money=%s terrainValid=%s%s",
            h.guid, s(h.snap.objGuid), s(h.snap.money), s(h.snap.terrainValid), mark);
        verbose(h.guid, h.snap);
        dumpAssetData(h.guid);
    end
end

---------------------------------------------------------------------------- run

local function probe()
    phase0();
    phase1();
    phase2();
end

local success, err = xpcall(probe, debug.traceback);

-- Never leave the player holding a building because the probe threw.
pcall(function() game.startBuild(0) end);
pcall(function() game.startMouseMode(0) end);

print("SAMPLE result=", success, err);
L.logf("SAMPLE result=%s %s", tostring(success), tostring(err));

--[[
    WHAT THIS CANNOT TELL YOU

    `CBuildCost` -- the type behind `ts.BuildMode.Costs` -- has exactly these members
    (docs/lua-inspector/ts.BuildMode.yaml:10973-11003):

        Empty  HasInfluenceChanges  InfluenceCost  InfluencePayable  InfluencePayback
        InfluenceUsageCost  IsPayable  MoneyCost

    There is no product or resource list. So the "and one Wanza Timber (114356)" half of the price
    is invisible from Lua, and MoneyCost == 5 is the only signal we get.

    Which also means: do not reach for `IsPayable` as the discriminator. It is false when you
    cannot afford the building, and you cannot afford the Enbesa quay until you have Wanza Timber
    in that island's stock -- so it would report differently on a rich island and a poor one.
    `IdentifyCoordinates` is right to ignore it.
]]
