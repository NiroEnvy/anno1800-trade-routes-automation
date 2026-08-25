-- luacheck configuration. See `make lint`.
--
-- Install: sudo pacman -S luacheck
--
-- Philosophy: this target is meant to stay green, so that a new warning means something. It keeps
-- the bug-shaped checks fatal (undefined variables, shadowing, unreachable code, empty branches)
-- and drops the pervasive style ones. If you want the full firehose:
--
--     luacheck trade_route_automation tests --no-config

std = "lua54"

max_line_length = 160

-- Plenty of methods legitimately do not touch `self`.
self = false

-- Globals the Anno 1800 Lua host injects. The mod never defines these; it only reads them.
read_globals = {
    "ts",          -- text-source / cheat interface, the main game handle
    "session",     -- current session: objects, GUIDs, object groups
    "game",        -- GUIManager, ScriptManager, MetaGameManager, ...
    "system",      -- system.start, used to spawn the mod's own threads
    "event",       -- game event tables the mod hooks into
    "g_LTL_Serp",  -- Serp's LuaLight shared library, published as a global by the game
}

-- Globals the mod deliberately publishes, for the game (or the player's console) to call.
globals = {
    "trade_route_automation_enable",
    "trade_route_automation_disable",
    "trade_route_automation_restart",
    "TradeRouteAutomationThread",
    "TRA_restart",
    "tostring_quote",
    "g_bint_Library051",  -- serp/bint.lua publishes itself globally on purpose
}

-- Style and idiom, dropped so that a warning that does fire is worth reading. Nothing bug-shaped
-- is in this list: undefined variables (1xx), unreachable code and unused labels (5xx) all stay
-- fatal.
--
-- 211/212/213/214 are almost all copy-pasted `require` blocks a module never ended up using
-- (mod_map_scanner_hl.lua alone has 12). Trimming those is a worthwhile cleanup on its own:
--
--     luacheck trade_route_automation --only 211
ignore = {
    "211",  -- unused local variable / function
    "212",  -- unused argument
    "213",  -- unused loop variable
    "214",  -- used variable with an unused hint (_foo that is in fact used)
    "412",  -- shadowing an argument -- `local L = L.with(...)` is the house idiom
    "431",  -- shadowing an upvalue  -- ditto
    "581",  -- `not (x > y)` could be `x <= y`; a suggestion, not a defect
}

exclude_files = {
    -- vendored third-party code, not ours to lint
    "trade_route_automation/serp/**",
    "trade_route_automation/rxi/**",
    "trade_route_automation/iskolbin/**",

    -- produced by `make install`, a copy of trade_route_automation/
    "mods/dev/data/**",

    "webapp/**",
    "dist/**",
}

-- Nothing is suppressed per-file. If a bug-shaped warning fires, fix the code.
