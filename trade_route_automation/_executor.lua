--[[
    Scratch-script executor: a REPL into the running game over the filesystem.

    Polls for a file, runs it, deletes it. `make install-script` on the dev machine writes that
    file. See docs/in-game-testing.md.

    OFF BY DEFAULT. It only starts when the marker file below exists, because a poller that
    executes any Lua dropped at a known path is arbitrary code execution for anything that can
    write there -- fine on a dev box, not something to ship switched on. `make install-script`
    creates the marker; `make install-script/off` removes it.

    Paths are relative to the game's working directory (the install root), not the mod directory.
]]

local root = "lua/trade-automation"
local enabled = root .. "/" .. "executor-enabled"
local stopme = root .. "/" .. "stopme"
local execute = root .. "/" .. "execute.lua"

-- Survives the package.loaded reset that _init.lua does on every restart, so a mod reload does not
-- leave a second poller running alongside the first.
local RUNNING = "trade_automation_executor_running"

local function file_exists(path)
    local file = io.open(path, "r")
    if file then
        file:close()
        return true
    end
    return false
end

local function log(msg)
    print("[executor] " .. msg)
end

local function em_do(file)
    -- claim it first: renaming means a file still being copied is never picked up twice, and a
    -- crash leaves a .running behind to show what was in flight
    os.rename(file, file .. ".running")
    file = file .. ".running"

    log("dofile(..) " .. file)
    local success, err = pcall(dofile, file)
    if not success then
        log("success:" .. tostring(success))
        if err then
            log("ERROR executing script: " .. tostring(err))
        end
    end
    log("dofile(..) " .. file .. " complete!")

    log("os.remove(execute)")
    os.remove(file)
end

local function executor_manager()
    _G[RUNNING] = true
    log("executor_manager started, watching " .. execute)

    local ok, err = xpcall(function()
        while true do
            if file_exists(stopme) then
                os.remove(stopme)
                return
            end

            if file_exists(execute) then
                system.start(function()
                    em_do(execute)
                end)
            end

            coroutine.yield()
        end
    end, debug.traceback)

    if not ok then
        log("executor_manager crashed: " .. tostring(err))
    end

    _G[RUNNING] = false
    log("executor_manager stopped")
end

if not file_exists(enabled) then
    log("disabled: " .. enabled .. " not present (run `make install-script` to enable)")
    return {}
end

if _G[RUNNING] then
    -- the previous thread survived the mod reload and is still polling; leave it alone
    log("an executor thread is already running, not starting another")
    return {}
end

system.start(executor_manager, "trade-automation-executor-2")

return {}
