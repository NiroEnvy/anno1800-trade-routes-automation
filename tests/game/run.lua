--[[
    In-game contract suite entry point.

    `make install-game-tests` copies this file to lua/trade-automation/execute.lua, alongside the
    suite files and a copy of tests/lib/t.lua, and the executor thread dofile's it.

    Results go to the mod's log directory as TrRAt_<profile>_game-tests.log.
]]

-- The executor dofile's this from the game's working directory, so the copied test files are not
-- on package.path yet.
local TESTS_DIR = "lua/trade-automation";
local entry = TESTS_DIR .. "/?.lua";
if package.path:find(entry, 1, true) == nil then
    package.path = package.path .. ";" .. entry;
end

-- Fresh copies every run: this is dofile'd repeatedly into one long-lived Lua state, so a stale
-- module would silently pin an old assertion.
for _, name in ipairs({ "t", "game_env", "contract_cargo" }) do
    package.loaded[name] = nil;
end

local T = require("t");
local G = require("game_env");

local L = require("trade_route_automation/utils_logger").logger("game-tests.log", true);

-- T writes with trailing newlines; the logger adds its own, so strip them.
T.out = function(s)
    for line in tostring(s):gmatch("([^\n]*)\n?") do
        if line ~= "" then
            print("[game-tests] " .. line);
            L.log(line);
        end
    end
end

G.log = function(msg)
    print("[game-tests] " .. msg);
    L.log(msg);
end

T.reset();

require("contract_cargo");

T.out(string.format("running %d contract tests against the live game\n\n", #T.tests));

local failed = T.run();

if failed == 0 then
    T.out("\nthe fake in tests/lib/world.lua matches the game on every checked point.\n");
else
    T.out(string.format(
        "\n%d contract(s) BROKEN: the offline suite is testing something the game no longer does.\n",
        failed));
end

-- Leave the test ship as we found it even if a test blew up partway through.
pcall(function()
    G.emptyHold(G.ship());
end);
