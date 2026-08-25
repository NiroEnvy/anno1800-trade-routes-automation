--[[
    The stock thresholds in supplyRequest_Build, and the Wood oscillation they used to produce.

    Diagnosed from a real save on 2026-08-23: Wood accounted for 92 of 239 voyages, and every
    island was both sending and receiving it (R2 sent 18 / received 14, C5 sent 17 / received 21).

    Two causes, both fixed. The gate for exporting and the amount exported disagreed -- an island
    was only cleared to export a good it consumed if it held more than o8, but then offered
    everything down to o2. And an island asked for o6 as a LEVEL rather than for the shortfall,
    so a delivery landed it above o8 and re-qualified it to export what it had just received.

    Now: the floor an island exports down to is the level that qualified it to export, and the ask
    is `o6 - stock`. Issue #14.

    Capacity 1000 throughout, which is what the real islands had:
        o2 = min(200, 1000 * 0.2)            = 200   -- request below this
        o4 = min(225, 1000 * 0.4)            = 225   -- a producer exports down to this
        o6 = min(o2 + 300, 500, 600)         = 500   -- and everyone refills TO this
        o8 = min(o4 + 300, 525, 800)         = 525   -- a consumer exports down to this
]]

local T = require("tests/lib/t");
local World = require("tests/lib/world");
local Harness = require("tests/lib/harness");
local G = require("tests/lib/goods");

local C6, C4 = 10, 20;

local O2, O6, O8 = 200, 500, 525;

--- Two islands that both consume Wood. Every island requests the construction goods, Wood among
--- them, so nothing has to be declared: this is the real standing request, not a test fixture.
local function world(opts)
    opts = opts or {};
    return World.new {
        region = "OW",
        areas = {
            { id = C6, name = "C6", capacity = 1000, at = { x = 100, y = 100 },
              stock = { [G.Wood] = opts.c6 or 946 } },
            { id = C4, name = "C4", capacity = 1000, at = { x = 900, y = 100 },
              stock = { [G.Wood] = opts.c4 or 50 } },
        },
        ships = {
            -- 10 slots, so the hull is never the binding constraint and the thresholds are what
            -- the test is actually measuring.
            { oid = 900, name = "a", slots = 10, speed = 400, at = { x = 100, y = 100 } },
        },
    };
end

---

T.test("thresholds: Wood is requested by every island, with no fixture saying so", function()
    local h = Harness.new(world());
    local srt = h.TradePlannerLL.SupplyRequest_Build(h.L, "OW", {}, h:areas(), h:state());

    T.eq(srt.Request[C4][G.Wood], O6 - 50, "a short island asks for the shortfall against o6");
    T.nil_(srt.Request[C6][G.Wood], "a well stocked one does not ask");
end);

T.test("thresholds: a consumer exports down to o8, the level that qualified it to export", function()
    -- This was THE BUG: C6 holds 946, may export because 946 > o8, and used to offer 731 --
    -- leaving 215, barely above the o2 = 200 line at which it starts asking for o6 back.
    local h = Harness.new(world());

    -- Its last Wood movement was inbound, so the planner treats it as a consumer of Wood.
    local state = h:state({ [C6] = { [G.Wood] = "In" } });
    local srt = h.TradePlannerLL.SupplyRequest_Build(h.L, "OW", {}, h:areas(), state);

    local offered = srt.Supply[C6][G.Wood];
    T.eq(offered, 946 - O8, "offers everything above o8, the level that cleared it to export");
    T.eq(946 - offered, O8, "which leaves it holding exactly o8 = 525");
    T.truthy(946 - offered > O6, "above o6, so it has no reason to ask for any of it back");
end);

T.test("thresholds: a producer exports down to o4", function()
    -- Same island, but its last Wood movement was outbound, so it is read as producing Wood and
    -- keeps only its own working buffer, o4 = 225.
    local h = Harness.new(world { c6 = 300 });

    local state = h:state({ [C6] = { [G.Wood] = "Out" } });
    local srt = h.TradePlannerLL.SupplyRequest_Build(h.L, "OW", {}, h:areas(), state);

    T.eq(srt.Supply[C6][G.Wood], 75, "300 - o4, from an island holding well under o8");
end);

T.test("thresholds: a surplus below one minimum transfer is not offered at all", function()
    -- The floor and the gate are now the same number, so `surplus >= 25` is the only gate there
    -- is: an island 20 units over its floor advertises nothing rather than sailing for 20.
    local h = Harness.new(world { c6 = 240 });

    local state = h:state({ [C6] = { [G.Wood] = "Out" } });
    local srt = h.TradePlannerLL.SupplyRequest_Build(h.L, "OW", {}, h:areas(), state);

    T.nil_(srt.Supply[C6][G.Wood], "15 over o4 is not worth a cargo slot");
end);

---

--- The whole low-level pipeline, as mod_trade_planner_hl runs it.
local function dispatch(h, state)
    local srt = h.TradePlannerLL.SupplyRequest_Build(h.L, "OW", {}, h:areas(), state);
    local orders = h.TradePlannerLL.SupplyRequest_ToOrders(h.L, srt, h:areas());
    local ships = h:availableShips();
    local commands = h.TradePlannerLL.SupplyRequestOrders_ToShipCommands(
        h.L, h:areas(), ships, orders, state);
    return h.TradePlannerLL.SupplyRequestShipCommands_Execute(h.L, "OW", srt, commands, ships), srt;
end

T.test("thresholds: a delivered island does not turn round and ship it straight back", function()
    -- The oscillation, end to end and without modelling any consumption at all. C4 used to be
    -- sent a flat o6 on top of what it held, which pushed it over o8 -- and being over o8 is the
    -- whole qualification for exporting. It now asks for the shortfall, so it lands below o8.
    local h = Harness.new(world());
    local state = h:state({ [C6] = { [G.Wood] = "In" } });

    local trades = dispatch(h, state);
    T.len(trades, 1, "one voyage");
    h:run();
    T.deep_eq(h:taskErrors(), {}, "no errors");

    T.eq(h.world:stock(C4, G.Wood), 471, "50 + the 421 C6 could spare above o8");
    T.eq(h.world:stock(C6, G.Wood), O8, "946 - 421, which is o8 exactly");

    -- Next cycle. C4's last Wood movement was inbound, exactly as activeTrades_Add would record.
    local next_state = h:state({ [C4] = { [G.Wood] = "In" }, [C6] = { [G.Wood] = "Out" } });
    local srt = h.TradePlannerLL.SupplyRequest_Build(h.L, "OW", {}, h:areas(), next_state);

    T.nil_(srt.Supply[C4][G.Wood],
        "C4 holds 471, below the o8 = 525 that would qualify it to export: the sawtooth is gone");
    T.nil_(srt.Request[C4][G.Wood], "and it is well above o2, so it does not ask for more either");

    T.eq(srt.Supply[C6][G.Wood], O8 - 225,
        "C6's one export flipped it to a producer, so it now offers down to o4 = 225 instead");
end);

T.test("thresholds: the sawtooth does not close -- an exporter is 33 ticks from asking, not 2", function()
    -- The old loop: export down to 215, and two ticks of the island's own Sawmill put it under
    -- o2 = 200, asking a flat 500 straight back. A consumer that exports now stops at o8 = 525,
    -- so the same consumption takes 33 ticks to bring it back to the asking line.
    local h = Harness.new(world { c6 = O8 });
    h.world:area(C6).consumption[G.Wood] = 10;

    local ticks = 0;
    while h.world:stock(C6, G.Wood) >= O2 do
        h.world:tick();
        ticks = ticks + 1;
    end
    T.eq(ticks, 33, "33 ticks from the export floor down to the asking line, at 10 a tick");
    T.eq(h.world:stock(C6, G.Wood), 195, "525 - 330");

    local srt = h.TradePlannerLL.SupplyRequest_Build(
        h.L, "OW", {}, h:areas(), h:state({ [C6] = { [G.Wood] = "In" } }));

    T.eq(srt.Request[C6][G.Wood], O6 - 195,
        "and it asks for the 305 that puts it back on o6, not for a flat 500");
end);

---
--- The threshold ladder, and the two properties a non-oscillating tuning has to satisfy.
---
--- Capacity is not a free parameter: the smallest city holds 75, and raising it is not an early
--- game priority, so it climbs in steps of 50/75/150 and every value below is one a real island
--- actually has.
---

local LADDER = {
    -- cap,    o2,   o4,   o6,   o8
    {    75,   15,   30,   45,   60 },
    {   125,   25,   50,   75,  100 },
    {   150,   30,   60,   90,  120 },
    {   250,   50,  100,  150,  200 },
    {   400,   80,  160,  240,  320 },
    {   650,  130,  225,  390,  520 },
    {  1000,  200,  225,  500,  525 },
    {  2000,  200,  225,  500,  525 },
};

T.test("thresholds: the ladder, so any tuning shows up as a diff here", function()
    local TP = require("trade_route_automation/mod_trade_planner_ll");

    for _, row in ipairs(LADDER) do
        local cap, e2, e4, e6, e8 = row[1], row[2], row[3], row[4], row[5];
        local o2, o4, o6, o8 = TP.Thresholds(cap);
        T.eq(o2, e2, string.format("cap %d: o2", cap));
        T.eq(o4, e4, string.format("cap %d: o4", cap));
        T.eq(o6, e6, string.format("cap %d: o6", cap));
        T.eq(o8, e8, string.format("cap %d: o8", cap));
    end
end);

T.test("thresholds: the band an island swings through is 0.4*cap, pinned at 300 once cap passes 750", function()
    -- An island fills to o6 and is drained to o2, so o6-o2 IS the oscillation amplitude. This is
    -- what the `+ 300` terms are for: they cap that amplitude on large islands.
    local TP = require("trade_route_automation/mod_trade_planner_ll");

    for _, row in ipairs(LADDER) do
        local cap = row[1];
        local o2, _, o6 = TP.Thresholds(cap);
        local band = o6 - o2;

        if cap <= 650 then
            T.eq(band, math.floor(cap * 4 / 10), string.format("cap %d: band is 0.4*cap", cap));
        else
            T.eq(band, 300, string.format("cap %d: band is pinned at 300", cap));
        end
    end
end);

T.test("thresholds: PROPERTY VIOLATED -- the export gate and the ask level converge on big islands", function()
    -- o8 is the bar for "well stocked enough to export"; o6 is what a short island asks for. An
    -- island that has just been filled to o6 should be comfortably below o8, or it qualifies to
    -- export again almost immediately.
    --
    -- `o2` clamps at 200 but `o4` clamps at 225, so o6 lands on 500 and o8 on 525: exactly one
    -- minimum transfer apart. This is why the worst churn in the field was on capacity-1000
    -- islands and not on small ones.
    local TP = require("trade_route_automation/mod_trade_planner_ll");

    local headroom = {};
    for _, row in ipairs(LADDER) do
        local cap = row[1];
        local _, _, o6, o8 = TP.Thresholds(cap);
        headroom[cap] = o8 - o6;
    end

    T.eq(headroom[250], 50, "small island: 50 units of headroom");
    T.eq(headroom[650], 130, "mid island: 130 units, comfortable");
    T.eq(headroom[1000], 25, "large island: 25 -- one minimum transfer, a knife edge");
    T.eq(headroom[2000], 25, "and it never gets better, however big the island");
end);

---
--- Role x stock-band scenarios.
---
--- The planner does not see "produces" or "consumes" directly. It sees three things: whether the
--- island REQUESTS the good, how much it HOLDS, and which way the good last MOVED. Production
--- only reaches it through stock. So that triple is the real role matrix, and this is it.
---
--- Alpaca Wool rather than Wood, because Wood is a construction good that every island requests
--- automatically -- there would be no way to model a pure producer with it.
---

local UNDER_TEST, ELSEWHERE = 60, 70;

--- One island of `cap` holding `stock`, which either consumes the good or merely holds it, whose
--- last movement of it was `last` ("In", "Out", or nil for never traded).
---@return Amount|nil supply, Amount|nil request
local function probe(opts)
    local spec = {
        id = UNDER_TEST, name = "x", capacity = opts.cap, at = { x = 100, y = 100 },
        stock = { [G.AlpacaWool] = opts.stock },
    };
    if opts.requests then
        spec.requests = { G.AlpacaWool };
    end

    local h = Harness.new(World.new {
        region = "OW",
        areas = {
            spec,
            -- Somebody has to want the good or the planner never considers it at all.
            { id = ELSEWHERE, name = "y", capacity = 1000, at = { x = 900, y = 100 },
              requests = { G.AlpacaWool }, stock = { [G.AlpacaWool] = 0 } },
        },
        ships = { { oid = 900, name = "a", slots = 6, speed = 400, at = { x = 100, y = 100 } } },
    });

    local dirs = nil;
    if opts.last then
        dirs = { [UNDER_TEST] = { [G.AlpacaWool] = opts.last } };
    end

    local srt = h.TradePlannerLL.SupplyRequest_Build(h.L, "OW", {}, h:areas(), h:state(dirs));
    return (srt.Supply[UNDER_TEST] or {})[G.AlpacaWool],
           (srt.Request[UNDER_TEST] or {})[G.AlpacaWool];
end

T.test("roles: an island that does not consume a good offers all of it, at any capacity", function()
    -- A pure producer. No thresholds apply -- there is no level it needs to keep back, because it
    -- never uses any itself.
    for _, cap in ipairs({ 75, 250, 1000 }) do
        local supply, request = probe { cap = cap, requests = false, stock = 100 };
        T.eq(supply, 100, string.format("cap %d: the whole lot is on offer", cap));
        T.nil_(request, string.format("cap %d: and it asks for nothing", cap));
    end
end);

T.test("roles: an island that neither consumes nor holds a good is invisible", function()
    local supply, request = probe { cap = 250, requests = false, stock = 0 };
    T.nil_(supply, "nothing to offer");
    T.nil_(request, "nothing to ask for");
end);

T.test("roles: a small consumer island, band by band (cap 250: o2=50 o4=100 o6=150 o8=200)", function()
    -- Early game sizes, where holding stock back actually matters.
    local supply, request = probe { cap = 250, requests = true, stock = 40, last = "In" };
    T.nil_(supply, "below o2: nothing to spare");
    T.eq(request, 110, "and it asks for the 110 that would put it on o6");

    supply, request = probe { cap = 250, requests = true, stock = 100, last = "In" };
    T.nil_(supply, "between o2 and o8, having just received: holds what it has");
    T.nil_(request, "and asks for nothing more");

    supply, request = probe { cap = 250, requests = true, stock = 100, last = "Out" };
    T.nil_(supply, "same stock, but read as a producer: 100 IS o4, so there is nothing above it");
    T.nil_(request, "still asks for nothing");

    supply = probe { cap = 250, requests = true, stock = 160, last = "Out" };
    T.eq(supply, 60, "a producer offers everything above o4 = 100");

    supply, request = probe { cap = 250, requests = true, stock = 220, last = "In" };
    T.nil_(supply, "20 above o8 is under the 25-unit minimum transfer, so nothing is offered");
    T.nil_(request, "and a full island asks for nothing");

    supply = probe { cap = 250, requests = true, stock = 240, last = "In" };
    T.eq(supply, 40, "40 above o8 clears it: a consumer exports down to o8, not to o2");
end);

T.test("roles: the direction memory is the only thing separating a supplier from a consumer", function()
    -- Same island, same stock, same capacity. The only difference is which way the good last
    -- moved -- and that flips it between holding its stock and giving most of it away.
    local held = probe { cap = 1000, requests = true, stock = 400, last = "In" };
    local given = probe { cap = 1000, requests = true, stock = 400, last = "Out" };

    T.nil_(held, "last movement inbound: read as a consumer, holds all 400 -- it is under o8");
    T.eq(given, 175, "last movement outbound: read as a producer, gives away everything above o4");
end);

T.test("roles: PROPERTY -- an island that has exported is not on the edge of asking again", function()
    -- The core property, as a property rather than one worked example. Whatever the capacity, an
    -- island stops at the level that qualified it to export -- o4 for a producer, o8 for a
    -- consumer -- and both sit above o2, the level at which it starts asking.
    --
    -- This is what used to be violated: both roles drained to o2 (or o2+15) exactly.
    for _, row in ipairs(LADDER) do
        local cap, o2, o4, _, o8 = row[1], row[2], row[3], row[4], row[5];

        local afterExport = probe { cap = cap, requests = true, stock = cap, last = "Out" };
        T.eq(cap - afterExport, o4, string.format("cap %d: a producer retains exactly o4", cap));

        local afterExportIn = probe { cap = cap, requests = true, stock = cap, last = "In" };
        if cap - o8 >= 25 then
            T.eq(cap - afterExportIn, o8, string.format("cap %d: a consumer retains exactly o8", cap));
        else
            -- cap 75: a full island is only 15 above o8, under the minimum transfer.
            T.nil_(afterExportIn,
                string.format("cap %d: a full consumer is under 25 above o8, so offers nothing", cap));
        end

        T.truthy(o4 > o2, string.format("cap %d: and a producer's floor is above the ask line", cap));
        T.truthy(o8 > o2, string.format("cap %d: as is a consumer's", cap));
    end
end);

T.test("roles: PROPERTY -- how much headroom that gap actually leaves", function()
    -- The distance from where an island STOPS to where it starts asking again. The consumer
    -- column is roomy everywhere. The producer column is the remaining thin edge: o2 clamps at
    -- 200 but o4 at 225, so a capacity-1000 producer stops one minimum transfer above the line.
    --
    -- It is self-limiting -- a producer refills itself, and one inbound delivery flips it to a
    -- consumer with the roomy o8 floor -- but it is what a future tuning of o4_cap would target.
    local expected = {
        --  cap    consumer (o8-o2)   producer (o4-o2)
        {    75,          45,               15 },
        {   250,         150,               50 },
        {   650,         390,               95 },
        {  1000,         325,               25 },
        {  2000,         325,               25 },
    };

    local TP = require("trade_route_automation/mod_trade_planner_ll");
    for _, row in ipairs(expected) do
        local cap, consumer, producer = row[1], row[2], row[3];
        local o2, o4, _, o8 = TP.Thresholds(cap);
        T.eq(o8 - o2, consumer, string.format("cap %d: consumer headroom", cap));
        T.eq(o4 - o2, producer, string.format("cap %d: producer headroom", cap));
    end
end);
