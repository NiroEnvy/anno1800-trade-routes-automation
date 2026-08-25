--[[
    Runs the real planner over a whole world for many cycles, and hands back something you can
    make assertions about.

    Every other part of the suite checks one arithmetic step. This checks behaviour: put a region
    into a state, let the automation run, and look at what it did. Two questions it exists to
    answer:

      does it oscillate?          -- did any island both receive and send the same good
      does it schedule well?      -- how many units and voyages did it spend getting there

    A cycle mirrors `tradeExecutor_iteration`: work out what is in flight, plan, dispatch, let the
    world turn. Two modes:

      sequential (default)  each cycle's voyages finish before the next is planned. Deterministic,
                            and isolates the planner's decisions from ship timing.
      overlapped            voyages stay in flight across cycles and in-flight accounting matters,
                            which is how the mod really runs.

    A world with no production and no consumption MUST reach a fixed point -- nothing but the
    mod's own trades can change anything -- so `settled` is a real signal there, not a heuristic.
]]

local World = require("tests/lib/world");
local Harness = require("tests/lib/harness");

local Sim = {};

local IN, OUT = "In", "Out";

Sim.IN = IN;
Sim.OUT = OUT;

---------------------------------------------------------------------------------------------
-- Result
---------------------------------------------------------------------------------------------

--- One movement of one good, from the point of view of the whole run.
---@class Sim.Trade
---@field from AreaID|nil
---@field to AreaID
---@field good ProductGUID
---@field amount Amount
---@field iteration number   the cycle it was dispatched on
---@field phase "main"|"hub" which pass dispatched it

--- One movement, from the point of view of a single island.
---@class Sim.Flow
---@field direction "In"|"Out"
---@field good ProductGUID
---@field iteration number
---@field amount Amount

---@class Sim.Result
---@field settled boolean            a cycle passed with nothing dispatched
---@field settledAt number|nil
---@field cycles number              cycles actually run
---@field trades Sim.Trade[]         every movement, in dispatch order
---@field perCycle number[]          voyages dispatched per cycle
---@field firstVoyageAt number|nil
---@field world FakeWorld
---@field harness Harness
local Result = {};
Result.__index = Result;

--- Final stock of `good` on `areaID`.
function Result:stock(areaID, good)
    return self.world:stock(areaID, good);
end

--- Everything that moved in or out of one island for one good, in cycle order.
--- This is the `(city, good) -> trades` view.
---@return Sim.Flow[]
function Result:flow(areaID, good)
    local out = {};
    for _, t in ipairs(self.trades) do
        if t.good == good then
            if t.to == areaID then
                table.insert(out, { direction = IN, good = good, iteration = t.iteration, amount = t.amount });
            elseif t.from == areaID then
                table.insert(out, { direction = OUT, good = good, iteration = t.iteration, amount = t.amount });
            end
        end
    end
    return out;
end

--- Units in and out for one island and good.
---@return Amount inbound, Amount outbound
function Result:totals(areaID, good)
    local inn, out = 0, 0;
    for _, f in ipairs(self:flow(areaID, good)) do
        if f.direction == IN then inn = inn + f.amount else out = out + f.amount end
    end
    return inn, out;
end

--- How many times an island changed its mind about which way a good should travel. A settled
--- region should be 0; anything above 1 is goods going round in circles.
function Result:reversals(areaID, good)
    local n, last = 0, nil;
    for _, f in ipairs(self:flow(areaID, good)) do
        if last ~= nil and f.direction ~= last then
            n = n + 1;
        end
        last = f.direction;
    end
    return n;
end

--- Movements that came back: a good that went A -> B and later B -> A.
---
--- This is the strict definition of needless work -- the same good returning to the island it
--- came from. `oscillations()` is broader and flags any island that both received and sent, which
--- a HUB does by design: collecting on idle ships and reselling from the middle is the point of
--- one. So judge a hub region by this, and a hub-free one by either.
---@param good? ProductGUID  restrict to one good
---@return { from: AreaID, to: AreaID, good: ProductGUID, outAt: number, backAt: number, outAmount: Amount, backAmount: Amount }[]
function Result:roundTrips(good)
    local out = {};
    for i, a in ipairs(self.trades) do
        if a.from ~= nil and (good == nil or a.good == good) then
            for j = i + 1, #self.trades do
                local b = self.trades[j];
                if b.from == a.to and b.to == a.from and b.good == a.good then
                    table.insert(out, {
                        from = a.from, to = a.to, good = a.good,
                        outAt = a.iteration, backAt = b.iteration,
                        outAmount = a.amount, backAmount = b.amount,
                    });
                    break;
                end
            end
        end
    end
    return out;
end

--- Units moved by one pass.
---@param phase "main"|"hub"
function Result:unitsIn(phase)
    local n = 0;
    for _, t in ipairs(self.trades) do
        if t.phase == phase then n = n + t.amount end
    end
    return n;
end

--- Every (island, good) that both received and sent. In a static world this is pure waste.
---@return { area: AreaID, good: ProductGUID, inn: Amount, out: Amount }[]
function Result:oscillations()
    local seen, pairsList = {}, {};
    for _, t in ipairs(self.trades) do
        for _, areaID in ipairs({ t.from, t.to }) do
            if areaID ~= nil then
                local key = areaID .. ":" .. t.good;
                if not seen[key] then
                    seen[key] = true;
                    table.insert(pairsList, { area = areaID, good = t.good });
                end
            end
        end
    end

    local out = {};
    for _, p in ipairs(pairsList) do
        local inn, sent = self:totals(p.area, p.good);
        if inn > 0 and sent > 0 then
            table.insert(out, { area = p.area, good = p.good, inn = inn, out = sent });
        end
    end
    table.sort(out, function(a, b)
        if a.area ~= b.area then return a.area < b.area end
        return a.good < b.good;
    end);
    return out;
end

--- Total units moved across the whole run.
function Result:units()
    local n = 0;
    for _, t in ipairs(self.trades) do n = n + t.amount end
    return n;
end

function Result:voyages()
    return #self.trades;
end

--- A one-line description, for assertion messages.
function Result:summary()
    local per = {};
    for i = 1, self.cycles do table.insert(per, tostring(self.perCycle[i] or 0)) end
    return string.format("settled=%s at=%s per-cycle=[%s] units=%d moves=%d",
        tostring(self.settled), tostring(self.settledAt), table.concat(per, ","),
        self:units(), #self.trades);
end

--- Stable description of what was dispatched, for comparing two runs.
function Result:fingerprint()
    local parts = {};
    for _, t in ipairs(self.trades) do
        table.insert(parts, string.format("%s>%d:%d:%d", tostring(t.from), t.to, t.good, t.amount));
    end
    return table.concat(parts, " ");
end

---------------------------------------------------------------------------------------------
-- Runner
---------------------------------------------------------------------------------------------

---@class Sim.Spec
---@field region? RegionID
---@field areas FakeWorld.AreaSpec[]
---@field ships FakeWorld.ShipSpec[]
---@field cycles? number             default 25
---@field mode? "sequential"|"overlapped"
---@field ticksPerCycle? number      overlapped only; default 40
---@field runAllCycles? boolean      do not stop at the first quiet cycle. `settled` only means
---                                 something in a world with no production and no consumption;
---                                 once islands consume, a quiet cycle is just a lull, and
---                                 stopping there freezes the clock so nothing ever gets hungry.
---@field hubs? boolean              run the hub pass on whatever ships the main pass left idle

--- Builds the world, runs the automation, returns what happened.
---@param spec Sim.Spec
---@return Sim.Result
function Sim.run(spec)
    local region = spec.region or "OW";
    local maxCycles = spec.cycles or 25;
    local overlapped = spec.mode == "overlapped";
    local ticks = spec.ticksPerCycle or 40;
    local hubs = spec.hubs == true;

    local h = Harness.new(World.new {
        region = region,
        areas = spec.areas,
        ships = spec.ships,
    });

    local TP = h.TradePlannerLL;
    local state = h:state();

    local r = setmetatable({
        settled = false, settledAt = nil, cycles = 0,
        trades = {}, perCycle = {}, firstVoyageAt = nil,
        world = h.world, harness = h,
    }, Result);

    local active = {};

    for cycle = 1, maxCycles do
        r.cycles = cycle;

        -- Drop voyages that have finished.
        local live = {};
        for _, t in ipairs(active) do
            local task = h.async.get_task(t.coroutineID);
            if task ~= nil and not h.async.is_finished(task) then
                table.insert(live, t);
            end
        end
        active = live;

        local inFlight = overlapped and TP.Ships_StockInFlight(h.L, region, active) or {};

        -- Ships not already committed, and empty.
        local busy = {};
        for _, t in ipairs(active) do busy[t.command.Key.ShipID] = true end
        local free = {};
        for _, oid in ipairs(h.world.ship_order) do
            if not busy[oid] and h.world:slotsUsed(oid) == 0 then
                table.insert(free, oid);
            end
        end
        local ships = h:availableShips(free);

        --- Plan, dispatch and record one pass.
        ---
        --- `ships` is drawn down by Execute (`ships[ship] = nil`), so whatever is still in it
        --- after the main pass is exactly the idle fleet -- the same quantity
        --- `mod_trade_planner_hl` reports as `ships_available_after`. Passing the same table into
        --- the hub pass is therefore the whole of "hub trades run on unused capacity".
        local function pass(srt, phase)
            if srt == nil then
                return 0;
            end
            local orders   = TP.SupplyRequest_ToOrders(h.L, srt, h:areas());
            local commands = TP.SupplyRequestOrders_ToShipCommands(h.L, h:areas(), ships, orders, state);
            local spawned  = TP.SupplyRequestShipCommands_Execute(h.L, region, srt, commands, ships);

            for _, t in ipairs(spawned) do
                table.insert(active, t);
                local o = t.command.Key.Order;
                for _, g in ipairs(o.Goods) do
                    table.insert(r.trades, {
                        from = o.AreaID_from, to = o.AreaID_to,
                        good = g.GoodID, amount = g.Amount, iteration = cycle, phase = phase,
                    });
                    -- What mod_trade_planner_hl's activeTrades_Add does.
                    if o.AreaID_from ~= nil then state:set(o.AreaID_from, g.GoodID, OUT) end
                    state:set(o.AreaID_to, g.GoodID, IN);
                end
            end
            return #spawned;
        end

        local dispatched = pass(TP.SupplyRequest_Build(h.L, region, inFlight, h:areas(), state), "main");
        if hubs then
            dispatched = dispatched + pass(
                TP.SupplyRequest_BuildHubs(h.L, region, inFlight, h:areas(), state), "hub");
        end

        r.perCycle[cycle] = dispatched;
        if dispatched > 0 and r.firstVoyageAt == nil then
            r.firstVoyageAt = cycle;
        end

        if overlapped then
            for _ = 1, ticks do h:step() end
        else
            h:run();   -- returns as soon as nothing is still sailing
        end

        if dispatched == 0 and #active == 0 then
            if r.settledAt == nil then
                r.settled = true;
                r.settledAt = cycle;
            end
            if not spec.runAllCycles then
                break;
            end
        end
    end

    return r;
end

return Sim;
