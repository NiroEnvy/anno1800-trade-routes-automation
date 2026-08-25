--[[
    Minimal test framework.

    There is no busted/luarocks on the dev machine, and pulling one in for ~200 lines of
    assertions is not worth it. This is the whole framework.

        local T = require("tests/lib/t")

        T.test("ships get packed", function()
            T.eq(actual, expected, "slots used")
        end)

    `tests/run.lua` loads every tests/test_*.lua and calls T.run().

    It also runs INSIDE the game, where there is no stdout worth reading -- the in-game contract
    suite (tests/game/) points T.out at the mod's logger instead. Keep this file free of anything
    the game's Lua will not have.
]]

local T = {
    tests = {},
    _current = nil,
}

--- Where results go. Replaced by the in-game runner with a logger-backed writer.
T.out = function(s)
    io.write(s);
end

---@param name string
---@param fn fun()
function T.test(name, fn)
    table.insert(T.tests, { name = name, fn = fn })
end

--- Renders a value for assertion messages. Tables are sorted by key so output is stable.
---@param v any
---@param depth number|nil
function T.show(v, depth)
    depth = depth or 0;
    if type(v) ~= "table" then
        if type(v) == "string" then
            return string.format("%q", v);
        end
        return tostring(v);
    end
    if depth > 4 then
        return "{...}";
    end

    local keys = {};
    for k in pairs(v) do
        table.insert(keys, k);
    end
    table.sort(keys, function(a, b)
        if type(a) == type(b) then
            return tostring(a) < tostring(b);
        end
        return type(a) < type(b);
    end);

    local parts = {};
    for _, k in ipairs(keys) do
        table.insert(parts, string.format("%s=%s", tostring(k), T.show(v[k], depth + 1)));
    end
    return "{" .. table.concat(parts, ", ") .. "}";
end

local function fail(msg)
    error(msg, 3);
end

function T.fail(msg)
    fail(msg);
end

---@param actual any
---@param expected any
---@param ctx string|nil
function T.eq(actual, expected, ctx)
    if actual ~= expected then
        fail(string.format("%s: expected %s, got %s",
            ctx or "eq", T.show(expected), T.show(actual)));
    end
end

function T.ne(actual, unexpected, ctx)
    if actual == unexpected then
        fail(string.format("%s: expected anything but %s", ctx or "ne", T.show(unexpected)));
    end
end

function T.truthy(v, ctx)
    if not v then
        fail(string.format("%s: expected truthy, got %s", ctx or "truthy", T.show(v)));
    end
end

function T.falsy(v, ctx)
    if v then
        fail(string.format("%s: expected falsy, got %s", ctx or "falsy", T.show(v)));
    end
end

function T.nil_(v, ctx)
    if v ~= nil then
        fail(string.format("%s: expected nil, got %s", ctx or "nil", T.show(v)));
    end
end

---@param actual number
---@param expected number
---@param tolerance number
function T.approx(actual, expected, tolerance, ctx)
    if type(actual) ~= "number" or math.abs(actual - expected) > tolerance then
        fail(string.format("%s: expected %s +/- %s, got %s",
            ctx or "approx", tostring(expected), tostring(tolerance), T.show(actual)));
    end
end

local function deep_eq(a, b)
    if a == b then
        return true;
    end
    if type(a) ~= "table" or type(b) ~= "table" then
        return false;
    end
    for k, v in pairs(a) do
        if not deep_eq(v, b[k]) then
            return false;
        end
    end
    for k in pairs(b) do
        if a[k] == nil then
            return false;
        end
    end
    return true;
end

function T.deep_eq(actual, expected, ctx)
    if not deep_eq(actual, expected) then
        fail(string.format("%s: expected %s, got %s",
            ctx or "deep_eq", T.show(expected), T.show(actual)));
    end
end

---@param list table
---@param n number
function T.len(list, n, ctx)
    local c = 0;
    for _ in pairs(list) do
        c = c + 1;
    end
    if c ~= n then
        fail(string.format("%s: expected %d entries, got %d in %s",
            ctx or "len", n, c, T.show(list)));
    end
end

---

---@param filter string|nil only run tests whose name contains this
---@return number failures
function T.run(filter)
    local passed, failed, skipped = 0, 0, 0;
    local failures = {};

    for _, tc in ipairs(T.tests) do
        if filter and not tc.name:find(filter, 1, true) then
            skipped = skipped + 1;
            goto continue;
        end

        T._current = tc.name;
        local ok, err = xpcall(tc.fn, function(e)
            return { message = tostring(e), traceback = debug.traceback("", 2) };
        end);

        if ok then
            passed = passed + 1;
            T.out(string.format("  ok   %s\n", tc.name));
        else
            failed = failed + 1;
            T.out(string.format("  FAIL %s\n", tc.name));
            T.out(string.format("       %s\n", err.message));
            table.insert(failures, { name = tc.name, err = err });
        end

        :: continue ::
    end

    T.out("\n");
    if #failures > 0 then
        T.out("failures:\n");
        for _, f in ipairs(failures) do
            T.out(string.format("\n--- %s\n%s\n%s\n", f.name, f.err.message, f.err.traceback));
        end
    end

    T.out(string.format("%d passed, %d failed", passed, failed));
    if skipped > 0 then
        T.out(string.format(", %d skipped", skipped));
    end
    T.out("\n");

    return failed;
end

--- Forgets all registered tests. The in-game runner is dofile'd repeatedly into one long-lived
--- Lua state, so without this every run would re-register on top of the last.
function T.reset()
    T.tests = {};
    T._current = nil;
end

return T;