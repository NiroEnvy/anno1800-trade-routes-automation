--[[
    Test runner. From the repo root:

        lua tests/run.lua              -- everything
        lua tests/run.lua packing      -- only tests whose name contains "packing"

    Or `make test`.
]]

package.path = "./?.lua;" .. package.path;

local T = require("tests/lib/t");

local files = {
    "tests/test_regions",
    "tests/test_construction_goods",
    "tests/test_world",
    "tests/test_executor",
    "tests/test_planner",
    "tests/test_in_flight",
    "tests/test_force_unload",
    "tests/test_thresholds",
    "tests/test_scenarios",
    "tests/test_hubs",
};

for _, f in ipairs(files) do
    require(f);
end

io.write(string.format("running %d tests\n\n", #T.tests));

local failed = T.run(arg[1]);
os.exit(failed == 0 and 0 or 1);