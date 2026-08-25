--[[
    Tests for the fake world itself.

    The fake is the thing every other test leans on, so it gets checked first. Nothing here
    touches the mod.
]]

local T = require("tests/lib/t");
local World = require("tests/lib/world");
local G = require("tests/lib/goods");

local function twoIslands()
    return World.new {
        region = "OW",
        areas = {
            { id = 10, name = "Sassenberg", capacity = 400, at = { x = 100, y = 100 }, stock = { [G.Bricks] = 300 } },
            { id = 20, name = "Siphington", capacity = 400, at = { x = 900, y = 100 }, requests = { G.Bricks } },
        },
        ships = {
            { oid = 900, name = "a", slots = 4, speed = 200, at = { x = 100, y = 100 } },
        },
    };
end

T.test("world: ships take time to sail and then stop", function()
    local w = twoIslands();

    T.falsy(w:ship(900).moving, "idle before being told to move");

    w:moveTo(900, 900, 100);
    T.truthy(w:ship(900).moving, "moving once told to");

    w:tick();
    T.truthy(w:ship(900).moving, "still moving after one tick of an 800-unit trip at speed 200");
    T.eq(w:ship(900).at.x, 300, "moved one tick's worth");

    for _ = 1, 3 do
        w:tick();
    end
    T.falsy(w:ship(900).moving, "arrived after four ticks");
    T.eq(w:ship(900).at.x, 900, "sitting exactly on the destination");
end);

T.test("world: cargo fills one slot at a time up to the stack limit", function()
    local w = twoIslands();

    T.eq(w:load(900, G.Bricks, 120), 120, "all of it fit");
    T.eq(w:slotsUsed(900), 3, "120 units needs three slots");

    local ship = w:ship(900);
    T.eq(ship.cargo[0].Value, 50, "first slot full");
    T.eq(ship.cargo[1].Value, 50, "second slot full");
    T.eq(ship.cargo[2].Value, 20, "third slot holds the remainder");

    T.deep_eq(w:cargo(900), { [G.Bricks] = 120 }, "cargo summary");
end);

T.test("world: a ship cannot carry more than its slots hold", function()
    local w = twoIslands();

    -- 4 slots x 50 = 200
    T.eq(w:load(900, G.Bricks, 500), 200, "only 200 fit aboard");
    T.eq(w:slotsUsed(900), 4, "every slot used");
end);

T.test("world: different goods take separate slots", function()
    local w = twoIslands();

    w:load(900, G.Bricks, 60);
    w:load(900, G.Windows, 30);

    T.eq(w:slotsUsed(900), 3, "50 + 10 of Bricks, then 30 of Windows");
    T.deep_eq(w:cargo(900), { [G.Bricks] = 60, [G.Windows] = 30 }, "both goods aboard");
end);

T.test("world: islands clamp at capacity and count what they destroyed", function()
    local w = twoIslands();

    w:addGood(10, G.Bricks, 200); -- 300 + 200 = 500, capacity is 400
    T.eq(w:stock(10, G.Bricks), 400, "clamped to capacity");
    T.eq(w.destroyed[G.Bricks], 100, "100 units vanished, and the world noticed");
end);

T.test("world: islands clamp at zero and count what they invented", function()
    local w = twoIslands();

    w:addGood(10, G.Bricks, -500); -- only 300 there
    T.eq(w:stock(10, G.Bricks), 0, "clamped to zero");
    T.eq(w.created[G.Bricks], 200, "200 units came from nowhere, and the world noticed");
end);

T.test("world: goods are conserved when nothing clamps", function()
    local w = twoIslands();
    local before = w:total(G.Bricks);

    w:addGood(10, G.Bricks, -100);
    w:load(900, G.Bricks, 100);
    T.eq(w:total(G.Bricks), before, "goods in transit still count");

    w:addGood(20, G.Bricks, 100);
    w:clearSlot(900, 0);
    w:clearSlot(900, 1);
    T.eq(w:total(G.Bricks), before, "and after delivery");
    T.nil_(w.destroyed[G.Bricks], "nothing destroyed");
    T.nil_(w.created[G.Bricks], "nothing created");
end);

T.test("world: islands produce and consume each tick", function()
    local w = World.new {
        region = "OW",
        areas = {
            { id = 10, at = { x = 1, y = 1 }, capacity = 400, stock = { [G.Bricks] = 100, [G.Beer] = 10 },
              production = { [G.Bricks] = 5 }, consumption = { [G.Beer] = 4 } },
        },
    };

    w:tick();
    T.eq(w:stock(10, G.Bricks), 105, "produced");
    T.eq(w:stock(10, G.Beer), 6, "consumed");

    w:tick();
    w:tick();
    T.eq(w:stock(10, G.Beer), 0, "consumption stops at empty, it does not go negative");
    T.nil_(w.created[G.Beer], "and nothing was invented to get there");
end);