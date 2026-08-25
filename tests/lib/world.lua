--[[
    A fake Anno 1800.

    Not a mock — there are no expectations to record and no call assertions. This is a small
    imitation of the parts of the game the mod actually touches: islands that hold goods up to a
    capacity, ships that carry cargo in slots and take time to sail somewhere. You set up a world,
    let the mod run against it for a while, and then look at what the world looks like afterwards.

    Where the real game clamps (an island cannot hold more than its capacity, nor less than zero)
    this clamps too, and it counts how many units it had to invent or destroy to do so. That
    counter is how tests catch goods vanishing on overfull unloads.

    Units are *displayed* units throughout, the same units the mod's planner reasons in. The
    real anno_interface halves them on the way into the game; that halving is a detail of the
    text-source protocol and is not modelled here.

    Usage:
        local World = require("tests/lib/world")
        local w = World.new{
            region = "OW",
            products = { [1] = "Bricks", [2] = "Windows" },
            areas = {
                { id = 10, name = "Sassenberg", capacity = 400, at = { x = 100, y = 100 },
                  stock = { [1] = 600 } },
                { id = 20, name = "Siphington", capacity = 400, at = { x = 400, y = 100 },
                  requests = { 1 }, stock = { [1] = 20 } },
            },
            ships = {
                { oid = 900, name = "a", slots = 4, at = { x = 100, y = 100 } },
            },
        }
]]

local Goods = require("tests/lib/goods");

---@class FakeWorld
---@field region RegionID
---@field products table<ProductGUID, string>   overrides for generator/product_info.json
---@field construction boolean                  every island requests the 9 construction goods
---@field ticks number
---@field created table<ProductGUID, Amount>    units invented to keep stock >= 0
---@field destroyed table<ProductGUID, Amount>  units destroyed to keep stock <= capacity
---@field goods_log FakeWorld.GoodsLogEntry[]
---@field areas table<AreaID, FakeWorld.Area>
---@field area_order AreaID[]
---@field ships table<ShipID, FakeWorld.Ship>
---@field ship_order ShipID[]
local World = {};
World.__index = World;

--- Units one cargo slot holds. Same constant the mod assumes.
World.SLOT_SIZE = 50;

--- How far a ship travels per tick when no per-ship speed is given.
World.DEFAULT_SPEED = 250;

--[[
    `ClearSlot(i)` empties REAL SLOT i.

    This was an open question until it was measured in-game on 2026-08-22, and the answer matters
    more than it looks: the cargo *vector* returned by Ship_Cargo_Get is dense, so a key from it is
    a position, not a slot. The two coincide only while the hold has no gaps.

    Also settled at the same time: the unbalanced `ClearSlot(i))]` string the mod actually sends
    (anno_interface.lua:192) is accepted by the parser -- it is untidy, not broken.

    Both facts are pinned by tests/game/contract_cargo.lua, which runs against the live game.
]]

---@class FakeWorld.CargoSlot
---@field Guid ProductGUID
---@field Value Amount

---@class FakeWorld.GoodsLogEntry
---@field tick number
---@field area AreaID
---@field guid ProductGUID
---@field amount Amount     what was asked for, before clamping
---@field before Amount
---@field after Amount

---@class FakeWorld.Area
---@field id AreaID
---@field name string
---@field capacity Amount
---@field at Coordinate
---@field water_points Coordinate[]
---@field stock table<ProductGUID, Amount>
---@field requests table<ProductGUID, boolean>   goods this island consumes (drives mod_area_requests)
---@field production table<ProductGUID, Amount>  units produced per tick
---@field consumption table<ProductGUID, Amount> units consumed per tick

---@class FakeWorld.Ship
---@field oid ShipID
---@field name string
---@field route string
---@field slots number
---@field speed number
---@field at Coordinate
---@field cargo table<number, FakeWorld.CargoSlot>  0-indexed, one entry per used slot
---@field moving boolean
---@field target Coordinate|nil

---

--- One island, as handed to `World.new`.
---@class FakeWorld.AreaSpec
---@field id AreaID
---@field at Coordinate
---@field name? string                            defaults to "area-<id>"
---@field capacity? Amount                        defaults to 400
---@field water_points? Coordinate[]              defaults to { at }
---@field stock? table<ProductGUID, Amount>
---@field requests? ProductGUID[]                 goods this island consumes
---@field production? table<ProductGUID, Amount>  units produced per tick
---@field consumption? table<ProductGUID, Amount> units consumed per tick

--- One ship, as handed to `World.new`.
---@class FakeWorld.ShipSpec
---@field oid ShipID
---@field at Coordinate
---@field name? string                     defaults to tostring(oid)
---@field route? string                    defaults to "TRA_<region>"
---@field slots? number                    defaults to 4
---@field speed? number                    defaults to World.DEFAULT_SPEED
---@field cargo? FakeWorld.CargoSlot[]     1-indexed here, stored 0-indexed

---@class FakeWorld.Spec
---@field region? RegionID                       defaults to "OW"
---@field areas? FakeWorld.AreaSpec[]
---@field ships? FakeWorld.ShipSpec[]
---@field products? table<ProductGUID, string>   overrides generator/product_info.json
---@field construction? boolean                  defaults to true

local function copy_coord(c)
    return { x = c.x, y = c.y };
end

---@param spec FakeWorld.Spec
---@return FakeWorld
function World.new(spec)
    local w = setmetatable({}, World);

    w.region = spec.region or "OW";
    w.products = spec.products or {};
    w.ticks = 0;

    -- Every player island carries a standing request for the 9 construction goods
    -- (mod_area_requests.Construction). On by default, because that is the game. Turn it off only
    -- to isolate something, and say why.
    w.construction = spec.construction ~= false;

    -- units the world had to invent (below-zero loads) or destroy (over-capacity unloads)
    w.created = {};
    w.destroyed = {};

    -- every Area_AddGood, in order; handy when a test wants to see the sequence rather than the sum
    w.goods_log = {};

    w.areas = {};
    w.area_order = {};
    for _, a in ipairs(spec.areas or {}) do
        local requests = {};
        for _, guid in ipairs(a.requests or {}) do
            requests[guid] = true;
        end

        local water_points = a.water_points;
        if water_points == nil then
            water_points = { copy_coord(a.at) };
        end

        local stock = {};
        for guid, amount in pairs(a.stock or {}) do
            stock[guid] = amount;
        end

        w.areas[a.id] = {
            id = a.id,
            name = a.name or ("area-" .. tostring(a.id)),
            capacity = a.capacity or 400,
            at = copy_coord(a.at),
            water_points = water_points,
            stock = stock,
            requests = requests,
            production = a.production or {},
            consumption = a.consumption or {},
        };
        table.insert(w.area_order, a.id);
    end

    w.ships = {};
    w.ship_order = {};
    for _, s in ipairs(spec.ships or {}) do
        local cargo = {};
        for i, item in ipairs(s.cargo or {}) do
            cargo[i - 1] = { Guid = item.Guid, Value = item.Value };
        end

        w.ships[s.oid] = {
            oid = s.oid,
            name = s.name or tostring(s.oid),
            route = s.route or ("TRA_" .. w.region),
            slots = s.slots or 4,
            speed = s.speed or World.DEFAULT_SPEED,
            at = copy_coord(s.at),
            cargo = cargo,
            moving = false,
            target = nil,
        };
        table.insert(w.ship_order, s.oid);
    end

    return w;
end

---

---@param areaID number
---@return FakeWorld.Area
function World:area(areaID)
    local a = self.areas[areaID];
    if a == nil then
        error("no such area in fake world: " .. tostring(areaID));
    end
    return a;
end

---@param oid number
---@return FakeWorld.Ship
function World:ship(oid)
    local s = self.ships[oid];
    if s == nil then
        error("no such ship in fake world: " .. tostring(oid));
    end
    return s;
end

---@param areaID AreaID
---@param guid ProductGUID
---@return Amount
function World:stock(areaID, guid)
    return self:area(areaID).stock[guid] or 0;
end

---@param areaID AreaID
---@param guid ProductGUID
---@param amount Amount
function World:setStock(areaID, guid, amount)
    self:area(areaID).stock[guid] = amount;
end

--- Adds (or removes, if negative) goods, clamping to [0, capacity] exactly as the game does.
--- Records whatever had to be invented or destroyed to stay inside those bounds.
---@param areaID AreaID
---@param guid ProductGUID
---@param amount Amount
---@return Amount stock after clamping
function World:addGood(areaID, guid, amount)
    local area = self:area(areaID);
    local before = area.stock[guid] or 0;
    local want = before + amount;

    local after = want;
    if after > area.capacity then
        after = area.capacity;
        self.destroyed[guid] = (self.destroyed[guid] or 0) + (want - after);
    elseif after < 0 then
        after = 0;
        self.created[guid] = (self.created[guid] or 0) + (after - want);
    end

    area.stock[guid] = after;
    table.insert(self.goods_log, {
        tick = self.ticks,
        area = areaID,
        guid = guid,
        amount = amount,
        before = before,
        after = after,
    });
    return after;
end

--- Total units of `guid` anywhere in the world: on islands and in holds.
--- Combined with `created`/`destroyed` this is a conservation check.
---@param guid ProductGUID
---@return Amount
function World:total(guid)
    local sum = 0;
    for _, area in pairs(self.areas) do
        sum = sum + (area.stock[guid] or 0);
    end
    for _, ship in pairs(self.ships) do
        for _, item in pairs(ship.cargo) do
            if item.Guid == guid then
                sum = sum + item.Value;
            end
        end
    end
    return sum;
end

--- Ship cargo collapsed to guid -> amount (the per-slot layout is in `ship.cargo`).
---@param oid ShipID
---@return table<ProductGUID, Amount>
function World:cargo(oid)
    local ret = {};
    for _, item in pairs(self:ship(oid).cargo) do
        if item.Value > 0 then
            ret[item.Guid] = (ret[item.Guid] or 0) + item.Value;
        end
    end
    return ret;
end

--- Number of slots currently holding something.
---@param oid ShipID
---@return number
function World:slotsUsed(oid)
    local n = 0;
    for _, item in pairs(self:ship(oid).cargo) do
        if item.Value > 0 then
            n = n + 1;
        end
    end
    return n;
end

---

--- Puts `amount` of `guid` aboard, filling partly-used slots of the same good first, then empty
--- slots. Imitates `CheatItemInSlot`, which likewise picks the slot itself. Returns how much
--- actually fit.
---@param oid ShipID
---@param guid ProductGUID
---@param amount Amount
---@return Amount how much fit
function World:load(oid, guid, amount)
    local ship = self:ship(oid);
    local left = amount;

    for slot = 0, ship.slots - 1 do
        if left <= 0 then
            break;
        end
        local item = ship.cargo[slot];
        if item ~= nil and item.Guid == guid and item.Value < World.SLOT_SIZE then
            local room = World.SLOT_SIZE - item.Value;
            local put = math.min(room, left);
            item.Value = item.Value + put;
            left = left - put;
        end
    end

    for slot = 0, ship.slots - 1 do
        if left <= 0 then
            break;
        end
        local item = ship.cargo[slot];
        if item == nil or item.Value <= 0 then
            local put = math.min(World.SLOT_SIZE, left);
            ship.cargo[slot] = { Guid = guid, Value = put };
            left = left - put;
        end
    end

    return amount - left;
end

--- Empties real slot `slot`. Not a cargo-vector position -- see the note on ClearSlot above.
---@param oid ShipID
---@param slot number 0-indexed real slot
function World:clearSlot(oid, slot)
    self:ship(oid).cargo[slot] = nil;
end

---@param oid ShipID
---@param x number
---@param y number
function World:moveTo(oid, x, y)
    local ship = self:ship(oid);
    ship.target = { x = x, y = y };
    ship.moving = true;
end

---

--- Advances the world one tick: ships sail, islands produce and consume.
function World:tick()
    self.ticks = self.ticks + 1;

    for _, oid in ipairs(self.ship_order) do
        local ship = self.ships[oid];
        if ship.moving and ship.target ~= nil then
            local dx = ship.target.x - ship.at.x;
            local dy = ship.target.y - ship.at.y;
            local dist = math.sqrt(dx * dx + dy * dy);

            if dist <= ship.speed then
                ship.at = copy_coord(ship.target);
                ship.target = nil;
                ship.moving = false;
            else
                -- game coordinates are integers, and the mod base62-encodes them into ship names
                ship.at.x = math.floor(ship.at.x + dx / dist * ship.speed);
                ship.at.y = math.floor(ship.at.y + dy / dist * ship.speed);
            end
        end
    end

    for _, areaID in ipairs(self.area_order) do
        local area = self.areas[areaID];
        for guid, rate in pairs(area.production) do
            self:addGood(areaID, guid, rate);
        end
        for guid, rate in pairs(area.consumption) do
            local have = area.stock[guid] or 0;
            self:addGood(areaID, guid, -math.min(rate, have));
        end
    end
end

---

--- Human-readable snapshot. Print it when a test fails and you want to see the board.
---@return string
function World:describe()
    local out = { string.format("world %s @ tick %d", self.region, self.ticks) };

    for _, areaID in ipairs(self.area_order) do
        local area = self.areas[areaID];
        local goods = {};
        local guids = {};
        for guid in pairs(area.stock) do
            table.insert(guids, guid);
        end
        table.sort(guids);
        for _, guid in ipairs(guids) do
            if area.stock[guid] ~= 0 then
                table.insert(goods, string.format("%s=%d", self.products[guid] or Goods.name[guid] or guid, area.stock[guid]));
            end
        end
        table.insert(out, string.format("  area %d %-14s cap=%-5d %s",
            areaID, area.name, area.capacity, table.concat(goods, " ")));
    end

    for _, oid in ipairs(self.ship_order) do
        local ship = self.ships[oid];
        local slots = {};
        for slot = 0, ship.slots - 1 do
            local item = ship.cargo[slot];
            if item == nil or item.Value <= 0 then
                table.insert(slots, "-");
            else
                table.insert(slots, string.format("%s:%d", self.products[item.Guid] or Goods.name[item.Guid] or item.Guid, item.Value));
            end
        end
        table.insert(out, string.format("  ship %d %-10s at=(%d,%d) %s [%s]",
            oid, ship.name, ship.at.x, ship.at.y,
            ship.moving and "sailing" or "idle", table.concat(slots, " ")));
    end

    return table.concat(out, "\n");
end

return World;