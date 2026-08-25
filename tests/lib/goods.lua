--[[
    The real product table, straight out of trade_route_automation/generator/product_info.json.

    Tests should not carry their own guesses at what Bricks' GUID is. Index by name:

        local G = require("tests/lib/goods")
        G.Bricks   -- 1010205
        G.name[1010205] -- "Bricks"

    An unknown name raises rather than returning nil, so a typo fails loudly instead of turning
    into a nil GUID somewhere deep in the planner.
]]

local json = require("trade_route_automation/rxi/json");

local PATH = "trade_route_automation/generator/product_info.json";

local f = io.open(PATH, "r");
if f == nil then
    error("cannot open " .. PATH .. " (run tests from the repo root)");
end
local raw = json.decode(f:read("a"));
f:close();

local byName = {};
local name = {};

for guidStr, product in pairs(raw) do
    local guid = tonumber(guidStr);
    if guid == nil then
        error("non-numeric product key in " .. PATH .. ": " .. tostring(guidStr));
    end
    name[guid] = product.Name;
    byName[product.Name] = guid;
end

---@class Goods
---@field byName table<string, ProductGUID>  "Bricks" -> 1010205
---@field name table<ProductGUID, string>    1010205 -> "Bricks"
---@field [string] ProductGUID               G.Bricks; raises on an unknown name
local Goods = setmetatable({
    byName = byName,
    name = name,
}, {
    __index = function(_, key)
        local guid = byName[key];
        if guid == nil then
            error("no product named " .. tostring(key) .. " in " .. PATH, 2);
        end
        return guid;
    end,
});

return Goods;
