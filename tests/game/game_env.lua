--[[
    The in-game side of the test harness: finding the test ship, waiting for the game to catch up,
    and putting things back afterwards.

    Offline, tests/lib/harness.lua builds a world out of nothing. Here the world already exists and
    belongs to a running save, so this file is mostly about being careful with it:

      - only ever touches the ship on the TRA_TEST route, which the automation loop ignores
        because it does not match `^TRA_<region>`
      - never touches island stock; cargo is cheated in and cleared out
      - empties the hold before each test rather than trusting the last one
]]

local Anno = require("trade_route_automation/anno_interface");
local serpLight = require("trade_route_automation/serp/lighttools");

local G = {
    ROUTE = "TRA_TEST",
};

--- Set by the runner so notes land in the same log as the results.
G.log = print;

function G.note(fmt, ...)
    local msg = select("#", ...) > 0 and string.format(fmt, ...) or fmt;
    G.log(msg);
end

--[[
    Cheat commands do not take effect within the frame that issues them -- a read in the same frame
    sees the old state. mod_trade_executor.lua yields twice after loading for this reason.

    Three frames rather than two: the margin is free and a flaky contract suite is worse than a
    slow one.
]]
function G.settle()
    for _ = 1, 3 do
        coroutine.yield();
    end
end

local _ship = nil;

--- The ship assigned to TRA_TEST. Cached, because scanning every ship is not free.
---@return ShipID
function G.ship()
    if _ship ~= nil then
        return _ship;
    end

    local region = Anno.Region_Current();
    local ships = Anno.Region_Ships_GetAll(region);
    if ships == nil then
        error("Region_Ships_GetAll returned nil for region " .. tostring(region) ..
            " -- is the region scanned and cached?");
    end

    for _, oid in pairs(ships) do
        if Anno.Ship_TradeRoute_GetName(oid) == G.ROUTE then
            _ship = oid;
            return _ship;
        end
    end

    error("no ship found on a trade route named exactly '" .. G.ROUTE ..
        "'. Create it and assign one ship of at least 3 slots.");
end

function G.forgetShip()
    _ship = nil;
end

--- Sends a raw text-source command against the ship. `suffix` continues after the object selector.
function G.raw(suffix, oid)
    local cmd = '[MetaObjects SessionGameObject(' .. tostring(oid) .. ') ' .. suffix;
    return serpLight.DoForSessionGameObjectRaw(cmd);
end

--- Clears every slot index, which is the only way to empty a hold without assuming that a cargo
--- vector position is a slot number. (It is not -- see contract_cargo.lua.)
function G.emptyHold(oid)
    local slots = Anno.__Ship_Cargo_SlotCapacity(oid) or 8;
    for i = 0, slots + 1 do
        Anno.Ship_Cargo_Clear(oid, i);
    end
    G.settle();

    local left = 0;
    for _ in pairs(Anno.Ship_Cargo_Get(oid)) do
        left = left + 1;
    end
    if left > 0 then
        error("could not empty the test ship's hold: " .. left .. " stack(s) remain");
    end
end

--- Loads one full stack of each good, in order, settling between so slot order is deterministic.
function G.load(oid, guids)
    for i, guid in ipairs(guids) do
        Anno.Ship_Cargo_Set(oid, i - 1, { Guid = guid, Value = 50 });
        G.settle();
    end
end

return G;
