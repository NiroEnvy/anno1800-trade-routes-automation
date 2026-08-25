--[[
    Characterization tests for TradePlannerLL.Ships_ForceUnloadStoppedShips.

    When automation restarts, ships may be sitting around still holding cargo. Before they can be
    used they have to be emptied somewhere.
]]

local T = require("tests/lib/t");
local World = require("tests/lib/world");
local Harness = require("tests/lib/harness");
local G = require("tests/lib/goods");

local SASSENBERG, SIPHINGTON, STOCKFISK = 10, 20, 30;

local function world()
    return World.new {
        region = "OW",
        areas = {
            -- 400 free
            { id = SASSENBERG, name = "Sassenberg", capacity = 1000, at = { x = 100, y = 100 },
              stock = { [G.Bricks] = 600, [G.Windows] = 600 } },
            -- 950 free: the roomiest, so this is where a stuck ship should end up
            { id = SIPHINGTON, name = "Siphington", capacity = 1000, at = { x = 900, y = 100 },
              requests = { G.Bricks, G.Windows }, stock = { [G.Bricks] = 50, [G.Windows] = 50 } },
            -- 200 free
            { id = STOCKFISK, name = "Stockfisk", capacity = 1000, at = { x = 500, y = 700 },
              requests = { G.Bricks }, stock = { [G.Bricks] = 800 } },
        },
        ships = {
            { oid = 900, name = "a", slots = 6, speed = 400, at = { x = 100, y = 100 } },
        },
    };
end

---

T.test("force unload: a stuck ship is emptied at the roomiest island", function()
    local h = Harness.new(world());
    h.world:load(900, G.Bricks, 100);

    local trades = h.TradePlannerLL.Ships_ForceUnloadStoppedShips(
        h.L, "OW", h:areas(), { [900] = {} });

    T.len(trades, 1, "one unload voyage");
    T.eq(trades[1].command.Key.Order.AreaID_to, SIPHINGTON, "the island with the most free space");

    h:run();
    T.deep_eq(h:taskErrors(), {}, "no errors");

    T.deep_eq(h.world:cargo(900), {}, "hold emptied");
    T.eq(h.world:stock(SIPHINGTON, G.Bricks), 150, "50 + 100 ashore");
    T.eq(h.world:ship(900).at.x, 900, "ship is at that island");
end);

T.test("force unload: goods are conserved", function()
    local h = Harness.new(world());
    h.world:load(900, G.Bricks, 100);
    local before = h.world:total(G.Bricks);

    h.TradePlannerLL.Ships_ForceUnloadStoppedShips(h.L, "OW", h:areas(), { [900] = {} });
    h:run();

    T.eq(h.world:total(G.Bricks), before, "same bricks in the world");
    T.deep_eq(h.world.destroyed, {}, "nothing destroyed");
end);

T.test("force unload: an empty ship needs no voyage", function()
    local h = Harness.new(world());

    local trades = h.TradePlannerLL.Ships_ForceUnloadStoppedShips(
        h.L, "OW", h:areas(), { [900] = {} });

    T.len(trades, 0, "nothing to do");
end);

T.test("force unload: an island without room for the whole load is passed over", function()
    local h = Harness.new(world());
    h.world:load(900, G.Bricks, 300);
    -- leave only Stockfisk (200 free) and Sassenberg (400 free) as options
    h.world:setStock(SIPHINGTON, G.Bricks, 900); -- 100 free

    local trades = h.TradePlannerLL.Ships_ForceUnloadStoppedShips(
        h.L, "OW", h:areas(), { [900] = {} });

    T.len(trades, 1, "still unloaded");
    T.eq(trades[1].command.Key.Order.AreaID_to, SASSENBERG, "the only island that can take all 300");
end);

---

T.test("force unload: a ship with two goods aboard is emptied like any other", function()
    -- This used to abandon the ship outright -- "has mixed cargo, cannot proceed" -- which was
    -- harmless only while a hull could never carry more than one good. A packed voyage that gets
    -- interrupted lands exactly here, and stranding the ship permanently is not an option.
    local h = Harness.new(world());
    h.world:load(900, G.Bricks, 100);
    h.world:load(900, G.Windows, 50);

    local trades = h.TradePlannerLL.Ships_ForceUnloadStoppedShips(
        h.L, "OW", h:areas(), { [900] = {} });

    T.len(trades, 1, "one unload voyage");
    T.eq(trades[1].command.Key.Order.AreaID_to, SIPHINGTON, "the island with room for both goods");

    h:run();
    T.deep_eq(h:taskErrors(), {}, "no errors");

    T.deep_eq(h.world:cargo(900), {}, "hold emptied");
    T.eq(h.world:stock(SIPHINGTON, G.Bricks), 150, "50 + 100 bricks ashore");
    T.eq(h.world:stock(SIPHINGTON, G.Windows), 100, "50 + 50 windows ashore -- and not deleted");
end);

T.test("force unload: a mixed hold needs one island with room for all of it", function()
    -- The unload puts the whole hold ashore in one go, so an island that can take the bricks but
    -- not the windows is no good, however roomy it looks for either good alone.
    local h = Harness.new(world());
    h.world:load(900, G.Bricks, 100);
    h.world:load(900, G.Windows, 100);

    -- Siphington keeps room for the bricks but runs out of room for the windows.
    h.world:setStock(SIPHINGTON, G.Windows, 950);

    local trades = h.TradePlannerLL.Ships_ForceUnloadStoppedShips(
        h.L, "OW", h:areas(), { [900] = {} });

    T.len(trades, 1, "still unloaded");
    T.eq(trades[1].command.Key.Order.AreaID_to, SASSENBERG, "the only island that can take both");
end);

T.test("force unload: two stuck ships do not both claim the same room", function()
    -- Both ships are full: 6 slots x 50 = 300 bricks each. Sassenberg and Stockfisk are left with
    -- 200 free apiece, so Siphington's 400 is the only place either can go -- and it has room for
    -- one of them. Once the first has claimed it the second must find nowhere rather than
    -- overfill the island.
    local h = Harness.new(world());
    h.world.ships[901] = {
        oid = 901, name = "b", route = "TRA_OW", slots = 6, speed = 400,
        at = { x = 100, y = 100 }, cargo = {}, moving = false, target = nil,
    };
    table.insert(h.world.ship_order, 901);

    h.world:setStock(SASSENBERG, G.Bricks, 800); -- 200 free
    h.world:setStock(SIPHINGTON, G.Bricks, 600); -- 400 free
    -- Stockfisk already holds 800: 200 free

    T.eq(h.world:load(900, G.Bricks, 300), 300, "ship a is full");
    T.eq(h.world:load(901, G.Bricks, 300), 300, "ship b is full");

    local trades = h.TradePlannerLL.Ships_ForceUnloadStoppedShips(
        h.L, "OW", h:areas(), { [900] = {}, [901] = {} });

    T.len(trades, 1, "only one ship can be placed");
    T.eq(trades[1].command.Key.Order.AreaID_to, SIPHINGTON, "at the only island with 500 free");
end);
