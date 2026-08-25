--[[
    Whole-system scenarios, as a table of cases.

    Each case puts a region into a state, lets the automation run, and states what should be true
    afterwards. A case can assert declaratively (final stock, no oscillation, units moved) or drop
    into `check` and interrogate the run directly -- most usefully through the per-island view,
    `r:flow(city, good)`, which is the list of every movement in or out with its direction, cycle
    and amount.

    Most of these run a STATIC world: nothing is produced, nothing is consumed. That makes the
    fixed point meaningful -- the only thing that can change any island's stock is a trade the mod
    chose to make, so a sound planner has to stop, and "it never stopped" is proof rather than
    suspicion.

    Alpaca Wool throughout. Every island carries a standing request for the nine construction
    goods, so with those there is no way to express "supplies this and does not consume it".

    Thresholds for the capacities used here:
        cap  250 -> o2  50  o4 100  o6 150  o8 200
        cap  650 -> o2 130  o4 225  o6 390  o8 520
        cap 1000 -> o2 200  o4 225  o6 500  o8 525
]]

local T = require("tests/lib/t");
local Sim = require("tests/lib/sim");
local G = require("tests/lib/goods");

local WOOL = G["Alpaca Wool"];

--- An island. `requests` marks it a consumer of the good; without it the island merely holds it.
local function area(id, name, cap, x, stock, requests)
    local a = {
        id = id, name = name, capacity = cap,
        at = { x = x, y = 100 },
        stock = { [WOOL] = stock },
    };
    if requests then a.requests = { WOOL } end
    return a;
end

local function ship(oid, name, x)
    return { oid = oid, name = name, slots = 6, speed = 400, at = { x = x, y = 100 } };
end

---------------------------------------------------------------------------------------------
-- Cases
---------------------------------------------------------------------------------------------

local SUP, SMALL, MID, BIG = 1, 10, 20, 30;
local A, B, C, D = 40, 50, 60, 70;

---@class Scenario
---@field name string
---@field areas FakeWorld.AreaSpec[]
---@field ships FakeWorld.ShipSpec[]
---@field cycles? number
---@field mode? "sequential"|"overlapped"
--- expectations, all optional:
---@field settles? boolean                     reaches a cycle that dispatches nothing
---@field firstVoyageAt? number                cycle the first voyage left on
---@field stock? table<AreaID, Amount>         exact final stock of WOOL
---@field stockAtLeast? table<AreaID, Amount>  lower bounds on final stock
---@field noOscillation? boolean               no island both received and sent WOOL
---@field units? Amount                        exact units moved -- a pinned baseline
---@field maxUnits? Amount
---@field check? fun(r: Sim.Result)            anything else

---@type Scenario[]
local CASES = {
    {
        name = "one producer fills three empty consumers, then stops",
        -- 1500 available against 1040 of demand (o6 of 150 + 390 + 500). Nothing is consumed, so
        -- the only right answer is: place the goods once and stop.
        areas = {
            area(SUP,   "sup",   2000, 100, 1500, false),
            area(SMALL, "small",  250, 300,    0, true),
            area(MID,   "mid",    650, 500,    0, true),
            area(BIG,   "big",   1000, 700,    0, true),
        },
        ships = { ship(901, "a", 100), ship(902, "b", 100), ship(903, "c", 100) },

        settles = true,
        firstVoyageAt = 1,                                    -- GOAL 3
        stockAtLeast = { [SMALL] = 50, [MID] = 130, [BIG] = 200 },  -- GOAL 1, everyone above o2
        noOscillation = true,                                 -- GOAL 2
        maxUnits = 1300,                                      -- 1040 had to move
        check = function(r)
            for _, t in ipairs(r.trades) do
                T.eq(t.from, SUP, "with one source, every voyage should start there");
            end
        end,
    },

    {
        name = "a consumer already holding enough is left alone",
        -- BIG sits above o2 with no one else short. Nothing should move at all.
        areas = {
            area(SUP, "sup", 2000, 100, 1500, false),
            area(BIG, "big", 1000, 700,  600, true),
        },
        ships = { ship(901, "a", 100) },

        settles = true,
        units = 0,
        check = function(r)
            T.nil_(r.firstVoyageAt, "no voyage was ever dispatched: " .. r:summary());
        end,
    },

    {
        name = "a producer with less than a minimum transfer to spare does not sail",
        -- GOAL 3 has a floor: "as soon as it may" still means it has to be worth a slot. SMALL is
        -- 20 short of o6, which is under the 25-unit minimum.
        areas = {
            area(SUP,   "sup",   2000, 100, 1500, false),
            area(SMALL, "small",  250, 300,  130, true),   -- o2 50, so not short at all
        },
        ships = { ship(901, "a", 100) },

        settles = true,
        units = 0,
    },

    {
        name = "levelling four islands moves only what was short, and makes no middleman",
        -- The field shape. Four equal islands, all consumers, wildly different stock, and 1730
        -- units in a region where nothing is produced or consumed. C is 350 short of o6 and D is
        -- 420, so 770 units have to travel -- and 770 is exactly what moves.
        --
        -- This used to move 1000: C was handed 500 and shipped 435 straight back out, used as a
        -- staging post for goods that were always destined for D. Both branches exported down to
        -- o2, which is also the level at which an island starts asking, and the ask was a level
        -- rather than a shortfall so a delivery overshot past o8. Issue #14.
        areas = {
            area(A, "a", 1000,  100, 900, true),
            area(B, "b", 1000,  400, 600, true),
            area(C, "c", 1000,  700, 150, true),
            area(D, "d", 1000, 1000,  80, true),
        },
        ships = { ship(911, "a", 100), ship(912, "b", 400), ship(913, "c", 700) },
        cycles = 30,

        settles = true,
        units = 770,            -- pinned: all of it was necessary
        noOscillation = true,
        stock = { [A] = 505, [B] = 225, [C] = 500, [D] = 500 },
        check = function(r)
            T.eq(r:reversals(C, WOOL), 0, "C is no longer a staging post: " .. r:summary());
            -- A and B, having exported, are read as producers and rest on o4 = 225 or above;
            -- C and D, having received, rest on exactly o6.
            T.truthy(r:stock(A, WOOL) >= 225, "A rests at or above its producer floor");
            T.eq(r:stock(B, WOOL), 225, "B rests exactly on o4");
        end,
    },

    {
        name = "goods are conserved across a whole run",
        areas = {
            area(A, "a", 1000,  100, 900, true),
            area(B, "b", 1000,  400, 600, true),
            area(C, "c", 1000,  700, 150, true),
            area(D, "d", 1000, 1000,  80, true),
        },
        ships = { ship(911, "a", 100), ship(912, "b", 400), ship(913, "c", 700) },
        cycles = 30,

        check = function(r)
            local total = 0;
            for _, id in ipairs({ A, B, C, D }) do total = total + r:stock(id, WOOL) end
            T.eq(total, 1730, "the region still holds what it started with");
            T.deep_eq(r.world.created, {}, "nothing invented");
            T.deep_eq(r.world.destroyed, {}, "nothing destroyed");
        end,
    },

    {
        name = "voyages still in flight do not cause a second round of the same delivery",
        -- The same distribution, but voyages stay in the water across cycles, so in-flight
        -- accounting decides whether the planner sends more ships after the same shortage.
        mode = "overlapped",
        ticksPerCycle = 12,
        cycles = 40,
        areas = {
            area(SUP, "sup", 2000, 100, 1500, false),
            area(BIG, "big", 1000, 900,    0, true),
        },
        ships = { ship(901, "a", 100), ship(902, "b", 100), ship(903, "c", 100), ship(904, "d", 100) },

        noOscillation = true,
        maxUnits = 700,   -- BIG wants 500; more than 700 means it was over-served
        check = function(r)
            T.truthy(r:stock(BIG, WOOL) <= 1000, "never overfilled: " .. tostring(r:stock(BIG, WOOL)));
            T.deep_eq(r.world.destroyed, {}, "so nothing was destroyed on unload");
        end,
    },
};

---------------------------------------------------------------------------------------------
-- Runner
---------------------------------------------------------------------------------------------

---@param case Scenario
local function verify(case, r)
    if case.settles ~= nil then
        T.eq(r.settled, case.settles, "settles: " .. r:summary());
    end
    if case.firstVoyageAt ~= nil then
        T.eq(r.firstVoyageAt, case.firstVoyageAt, "first voyage cycle: " .. r:summary());
    end
    if case.units ~= nil then
        T.eq(r:units(), case.units, "units moved: " .. r:summary());
    end
    if case.maxUnits ~= nil then
        T.truthy(r:units() <= case.maxUnits,
            string.format("moved %d units, budget %d: %s", r:units(), case.maxUnits, r:summary()));
    end
    if case.noOscillation then
        local osc = r:oscillations();
        local desc = {};
        for _, o in ipairs(osc) do
            table.insert(desc, string.format("area %d good %d in=%d out=%d", o.area, o.good, o.inn, o.out));
        end
        T.eq(#osc, 0, "no island should both receive and send: " .. table.concat(desc, "; "));
    end
    for areaID, want in pairs(case.stock or {}) do
        T.eq(r:stock(areaID, WOOL), want, string.format("final stock at %d", areaID));
    end
    for areaID, floor in pairs(case.stockAtLeast or {}) do
        T.truthy(r:stock(areaID, WOOL) >= floor,
            string.format("area %d holds %d, wanted at least %d", areaID, r:stock(areaID, WOOL), floor));
    end
    if case.check then
        case.check(r);
    end
end

for _, case in ipairs(CASES) do
    T.test("scenario: " .. case.name, function()
        local r = Sim.run(case);
        T.deep_eq(r.harness:taskErrors(), {}, "no errors raised inside a voyage");
        verify(case, r);
    end);
end

---

T.test("scenario: the same starting state dispatches the same voyages every run", function()
    -- Areas and goods are walked with `pairs`, whose order is undefined. If anything downstream
    -- depends on it, two runs of an identical world diverge -- and nothing measured above would
    -- mean very much.
    local function build()
        return {
            areas = {
                area(A, "a", 1000,  100, 900, true),
                area(B, "b", 1000,  400, 600, true),
                area(C, "c", 1000,  700, 150, true),
                area(D, "d", 1000, 1000,  80, true),
            },
            ships = { ship(911, "a", 100), ship(912, "b", 400), ship(913, "c", 700) },
            cycles = 30,
        };
    end

    local first = Sim.run(build()):fingerprint();
    for run = 2, 4 do
        T.eq(Sim.run(build()):fingerprint(), first, "run " .. run .. " matched run 1");
    end
end);
