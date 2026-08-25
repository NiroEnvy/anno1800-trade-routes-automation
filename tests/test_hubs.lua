--[[
    Hub cities: the second pass, and what the donor floor costs.

    A hub is an island the player has suffixed `(h)` (collect everything) or `(hc)` (collect
    construction goods). The hub pass runs AFTER the main loop, using only the ships the main loop
    left idle, and fills hubs towards 90% of capacity.

    Three questions these answer, in the order they were asked:

      1. does a hub pull goods back out again, and is that waste or resale?
      2. what does the donor floor actually change, and on which islands?
      3. what can a hub never collect?

    THE MEASURE. `oscillations()` -- "an island both received and sent" -- is the wrong test for a
    hub region, because a hub does that BY DESIGN: it collects on idle ships and resells from the
    middle. The right test is `roundTrips()`: the same good going A -> B and later B -> A. That is
    the needless work, and it is what these cases assert on.

    DONORS USE THE MAIN PASS'S FLOORS. A separate, higher hub-pass floor was built and measured,
    and then dropped: it did nothing for producers, which refill past the asking line and never
    re-request, and nothing for oversupply, where a non-consumer offers everything regardless of
    any floor. docs/hubs.md records what it was worth.

    THRESHOLDS. Wood and Alpaca Wool at the capacities used here:
        cap  250 -> o2  50  o4 100  o6 150  o8 200   hub target  225
        cap 1000 -> o2 200  o4 225  o6 500  o8 525   hub target  900
        cap 2000 -> o2 200  o4 225  o6 500  o8 525   hub target 1800
        cap 3000 -> o2 200  o4 225  o6 500  o8 525   hub target 2700

    The hub target diverges from the ladder completely, and that is the point: the ladder
    describes an island living off the good, a hub is a warehouse.
]]

local T   = require("tests/lib/t");
local Sim = require("tests/lib/sim");
local G   = require("tests/lib/goods");
local TP  = require("trade_route_automation/mod_trade_planner_ll");

local WOOL, WOOD = G["Alpaca Wool"], G.Wood;
local HUB, A, B, C = 10, 20, 30, 40;

local function ship(oid, x)
    return { oid = oid, name = "s" .. oid, slots = 6, speed = 400, at = { x = x, y = 100 } };
end

--- `requests` is what makes an island a CONSUMER of the good, and consumers are the only islands
--- the donor floor governs -- see the property case below.
local function area(id, name, cap, x, stock, requests)
    local a = { id = id, name = name, capacity = cap, at = { x = x, y = 100 }, stock = stock };
    if requests then a.requests = requests end
    return a;
end

---------------------------------------------------------------------------------------------

T.test("hubs: `(h)` collects every good, `(hc)` only construction goods", function()
    local areas = {
        [1] = { city_name = "plain" },
        [2] = { city_name = "warehouse (h)" },
        [3] = { city_name = "buildsite (hc)" },
        [4] = { city_name = "not a hub (h) really" },   -- suffix only
    };
    local hubs = TP.Hubs(areas);

    T.eq(hubs[1], nil, "an unmarked island is not a hub");
    T.eq(hubs[2], true, "`(h)` takes every good");
    T.eq(hubs[4], nil, "the marker is a SUFFIX, not a substring");

    T.truthy(hubs[3] ~= nil and hubs[3] ~= true, "`(hc)` is a restricted set, not `true`");
    T.eq(hubs[3][WOOD], true, "wood is a construction good");
    T.eq(hubs[3][WOOL], nil, "alpaca wool is not");

    -- `(hc)` also ends in `c)`; if `(h)` were tested first it would swallow it.
    T.eq(TP.Hubs({ [9] = { city_name = "x (hc)" } })[9][WOOD], true, "`(hc)` is matched before `(h)`");
end);

T.test("hubs: the target is 90% of capacity, and nothing like the ladder", function()
    T.eq(TP.HubTarget(1000), 900, "cap 1000");
    T.eq(TP.HubTarget(3000), 2700, "cap 3000");

    local _, _, _, o8 = TP.Thresholds(3000);
    T.eq(o8, 525, "the ladder clamps o8 at 525 however big the island");
    T.truthy(TP.HubTarget(3000) - o8 == 2175,
        "so a warehouse holds 2175 units more than the ladder's idea of 'more than I need'");
end);

---------------------------------------------------------------------------------------------
-- 2a. Ingesting oversupply.
---------------------------------------------------------------------------------------------

T.test("hubs: a hub ingests a good nobody consumes, and none of it comes back", function()
    -- A and B sit on wool neither of them consumes. C is a small consumer, present only because
    -- of the limitation pinned two cases down. Static world: nothing produced, nothing consumed,
    -- so a fixed point is a real signal.
    local r = Sim.run({
        areas = {
            area(HUB, "warehouse (h)", 3000, 400, { [WOOL] = 0 }),
            area(A,   "a",             1000, 100, { [WOOL] = 800 }),
            area(B,   "b",             1000, 250, { [WOOL] = 700 }),
            area(C,   "c",              250, 700, { [WOOL] = 0 }, { WOOL }),
        },
        ships = { ship(901, 400), ship(902, 100) },
        cycles = 10, hubs = true,
    });

    T.deep_eq(r.harness:taskErrors(), {}, "no errors raised inside a voyage");
    T.eq(#r:roundTrips(WOOL), 0, "nothing went back where it came from");
    T.eq(r:stock(HUB, WOOL), 1350, "the hub holds everything that was spare");
    T.eq(r:unitsIn("hub"), 1350, "and the hub pass moved it, on idle ships");
    T.eq(r:unitsIn("main"), 150, "the main pass served C's real deficit, as always");

    -- No floor was consulted for A or B at any point: neither requests wool, so both take the
    -- `not doesAreaRequestProduct` branch and offer every unit they hold.
    T.eq(r:stock(A, WOOL), 0, "a non-consumer gives all of it");
    T.eq(r:stock(B, WOOL), 0, "so does the other one");
end);

T.test("hubs: a hub cannot collect a good no island in the region requests", function()
    -- A real limitation, not a tuning choice. `supplyRequest_Build` derives the goods it
    -- considers from the union of the REQUEST tables, so a good that nobody consumes anywhere is
    -- invisible to the planner -- including to a hub whose whole purpose is to absorb it.
    -- Worth knowing before relying on `(h)` to mop up a truly unwanted good.
    local r = Sim.run({
        areas = {
            area(HUB, "warehouse (h)", 3000, 400, { [WOOL] = 0 }),
            area(A,   "a",             1000, 100, { [WOOL] = 800 }),
        },
        ships = { ship(901, 400) },
        cycles = 5, hubs = true,
    });

    T.eq(r:voyages(), 0, "nothing moves");
    T.eq(r:stock(A, WOOL), 800, "the wool stays where it is, unseen");
end);

---------------------------------------------------------------------------------------------
-- The pump. This is the case the donor floor exists for.
---------------------------------------------------------------------------------------------

T.test("hubs: PROPERTY -- only a NET CONSUMER pumps; a producer drained to o4 never asks back", function()
    -- The knife edge in issue 14b is that a donor is left on o4 = 225 with the asking line at
    -- o2 = 200 -- 25 units apart. But the request gate is `_stock < o2`, so being left on 225
    -- asks for nothing. Something has to EAT through those 25 units first.
    --
    -- So the hazard is narrower than 14b's arithmetic suggests, and this pins where the edge
    -- actually is. Note "producer" in this planner means LAST MOVEMENT WAS OUTBOUND, not
    -- "produces the good" -- which is why an island can be floored as a producer at o4 while
    -- being a net consumer. That combination, and only it, pumps.
    --
    -- `runAllCycles` because a consuming world has no fixed point: stopping at the first quiet
    -- cycle freezes the clock before the island ever gets hungry, which is exactly how an
    -- earlier version of this experiment concluded there was no problem at all.
    local function pump(production, consumption)
        local spec = {
            areas = {
                area(HUB, "hub (h)", 3000, 100, { [WOOL] = 0 }),
                area(A,   "p",       1000, 260, { [WOOL] = 900 }, { WOOL }),
            },
            ships = { ship(901, 100) },
            cycles = 30, mode = "overlapped", ticksPerCycle = 20,
            hubs = true, runAllCycles = true,
        };
        spec.areas[2].production  = { [WOOL] = production };
        spec.areas[2].consumption = { [WOOL] = consumption };
        local r = Sim.run(spec);

        local returned = 0;
        for _, t in ipairs(r.trades) do
            if t.to == A then returned = returned + t.amount end
        end
        return r, returned;
    end

    local grow,     grownBack   = pump(3, 2);   -- net +1
    local level,    levelBack   = pump(2, 2);   -- net  0
    local shrink,   shrunkBack  = pump(2, 3);   -- net -1

    T.eq(#grow:roundTrips(WOOL), 0, "a genuine producer never asks for it back");
    T.eq(grownBack, 0, "and nothing is ever shipped to it");
    T.eq(grow:stock(A, WOOL), 265, "it refills past o2 = 200 under its own steam and stays there");

    T.eq(#level:roundTrips(WOOL), 0, "break-even is safe too");
    T.eq(levelBack, 0, "it rests on o4 = 225, 25 above the line, and never crosses");
    T.eq(level:stock(A, WOOL), 225, "exactly the floor it was drained to");

    T.truthy(#shrink:roundTrips(WOOL) > 0,
        "only a NET CONSUMER pumps: " .. shrink:summary());
    T.eq(shrunkBack, 600, "600 units hauled back out of the hub, on main-pass ships");
end);

T.test("hubs: a relay is not a round trip", function()
    -- Producer -> hub -> consumer. The hub both receives and sends, so `oscillations()` flags it;
    -- nothing goes back where it came from, so `roundTrips()` does not. That gap is the whole
    -- reason `roundTrips` exists: reselling from the middle is what a hub is FOR.
    local spec = {
        areas = {
            area(A,   "p",       1000, 100, { [WOOL] = 900 }),
            area(HUB, "hub (h)", 3000, 300, { [WOOL] = 0 }),
            area(C,   "c",       1000, 500, { [WOOL] = 0 }, { WOOL }),
        },
        ships = { ship(901, 300), ship(902, 100) },
        cycles = 12, hubs = true,
    };
    spec.areas[1].production  = { [WOOL] = 10 };
    spec.areas[3].consumption = { [WOOL] = 5 };

    local r = Sim.run(spec);
    T.deep_eq(r.harness:taskErrors(), {}, "no errors raised inside a voyage");

    T.eq(#r:roundTrips(WOOL), 0, "no wool returns to the island it came from");
    T.truthy(#r:oscillations() > 0, "but the hub does both receive and send, by design");

    local inn, out = r:totals(HUB, WOOL);
    T.truthy(inn > 0 and out > 0, "hub in=" .. inn .. " out=" .. out);
    for _, t in ipairs(r.trades) do
        if t.to == HUB then
            T.eq(t.phase, "hub", "every delivery INTO the hub rides the idle-ship pass");
        end
    end
end);

---------------------------------------------------------------------------------------------
-- 2c. The construction hub, where every donor is a consumer.
---------------------------------------------------------------------------------------------

T.test("hubs: `(hc)` collects construction goods, from islands that all request them", function()
    -- Every island carries a standing request for the nine construction goods, so for wood there
    -- are no non-consumers anywhere: every donor is on the consumer branch, exporting down to its
    -- own floor. The opposite of the oversupply case, where no donor was.
    local r = Sim.run({
        areas = {
            area(HUB, "buildsite (hc)", 2000, 400, { [WOOD] = 0 }),
            area(A,   "a",              1000, 100, { [WOOD] = 900 }),
            area(B,   "b",              1000, 700, { [WOOD] = 900 }),
        },
        ships = { ship(901, 400), ship(902, 100) },
        cycles = 12, hubs = true,
    });

    T.eq(TP.HubTarget(2000), 1800, "the site wants 1800");
    T.eq(r:stock(HUB, WOOD), 1350, "it gets 1350 of it, and both donors rest on o4 = 225");
    T.eq(r:stock(A, WOOD), 225, "donor a");
    T.eq(r:stock(B, WOOD), 225, "donor b");

    -- Static world, so nothing eats through the 25 units above o2 and nothing comes back. What
    -- makes that safe is the absence of consumption, not the floor -- see the property above.
    T.eq(#r:roundTrips(WOOD), 0, "nothing returns");
end);

T.test("hubs: the hub pass only gets ships the main pass did not want", function()
    -- One ship, and a genuine deficit at C. The main pass must win it; the hub waits.
    local r = Sim.run({
        areas = {
            area(HUB, "hub (h)", 3000, 400, { [WOOL] = 0 }),
            area(A,   "a",       1000, 100, { [WOOL] = 900 }),
            area(C,   "c",        250, 150, { [WOOL] = 0 }, { WOOL }),
        },
        ships = { ship(901, 100) },
        cycles = 1, hubs = true,
    });

    T.eq(r:voyages(), 1, "one ship, one voyage");
    T.eq(r.trades[1].phase, "main", "and the real deficit had it");
    T.eq(r.trades[1].to, C, "the goods went to the island that was short, not to the warehouse");
end);
