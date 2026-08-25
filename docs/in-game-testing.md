# Testing a small change inside the running game

`make install-script` is one half of a hot-reload loop: you drop a Lua file into the game's
directory and a thread already running inside the game picks it up, runs it, and deletes it. No
restart, no reloading a save.

Use it for the things the fake world in `tests/` cannot answer — what a game API actually returns,
whether a command string is accepted, what a property looks like on a real object. For logic that
does not need the game, `make test` is faster and repeatable.

## The pieces

**`trade_route_automation/_executor.lua`** — a polling loop, started once inside the game. Every
frame it checks for two files, relative to the game's working directory:

```
lua/trade-automation/stopme        -- delete this loop
lua/trade-automation/execute.lua   -- run this, then delete it
```

When it finds `execute.lua` it renames it to `execute.lua.running` first — so a half-written file
is never run twice — then `dofile`s it on its own thread and removes it.

**`make install-script`** — the other half, on your machine:

```make
install-script:
	mkdir -p "$(INSTALL_BASEDIR_E)/trade-automation"
	cp sample1.lua "$(INSTALL_BASEDIR_E)/trade-automation/execute.lua"
```

with `INSTALL_BASEDIR_E = <steam>/steamapps/common/Anno 1800/lua` (`Makefile.vars`). `make run` is
an alias for it.

**`sample1.lua`** — the scratch file you actually edit. It requires every mod module, points the
logger at its own file, and runs one function under `xpcall`:

```lua
L = L.logger("sample.log", true);        -- true = truncate; lands in the mod's log dir

local f = function()
    -- whatever you are poking at
end

local success, err = xpcall(f, debug.traceback);
print("SAMPLE result=", success, err);   -- game log
L.logf("SAMPLE result=%s", tostring(success));
```

## The loop

1. **Once per game session**, from the in-game console (Serp's LuaLight — `console.toggleVisibility()`):

   ```lua
   require("trade_route_automation/_executor")
   ```

   That line is sitting commented at the top of `sample1.lua` so it is easy to copy. It starts a
   thread named `trade-automation-executor-2`.

2. **Per iteration**: edit `sample1.lua`, then

   ```sh
   make run          # == make install-script
   ```

3. Read the result in `<Documents>/Anno 1800/mods/TradeRoutesAutomation_DEV/logs/TrRAt_<profile>_sample.log`,
   or the game log for the `print` lines.

4. To stop the poller: `touch "<install>/lua/trade-automation/stopme"`.

## Why the paths look odd

Two different roots are in play, and it is worth keeping them straight:

| what | where | why |
|---|---|---|
| the mod itself | `<Documents>/Anno 1800/mods/TradeRoutesAutomation_DEV/` | where the game loads mods from |
| scratch scripts, stop-files | `<install>/Anno 1800/` | the game's **working directory**, which is what bare relative paths in Lua resolve against |
| logs, TSV dumps | `<Documents>/Anno 1800/mods/.../logs/` | `_init.lua` derives this from `ts.GameSetup.SettingsFileName` |

The working directory being the install root is inferred, not verified from here: the exe lives in
`Bin/Win64/` but `maindata/` sits at the install root and the game has to find it, and
`INSTALL_BASEDIR_E` was set to exactly `<install>/lua` by someone for whom this worked.

## `dofile` does not reload modules

`dofile` re-runs the script every time, but `require`d modules stay cached in `package.loaded`. So
editing `sample1.lua` takes effect immediately, and **editing a module does not**.

To pick up a change inside `trade_route_automation/*.lua`:

```sh
make install      # copy the mod into the Documents mods dir
```

then, in game, `trade_route_automation_restart()` — which goes through `package_requireAll`
(`_init.lua:6-10`), and that clears every `package.loaded` key starting with
`trade_route_automation` before re-requiring.

## Two Makefile targets that no longer point anywhere real

Found while tracing this; **not fixed**, since changing them without the game to confirm against is
guesswork.

**`make stop` / `make interrupt` / `make clean/interrupt`** touch `$(BASE)/stop-*` with
`BASE ?= $(INSTALL_BASEDIR_E)`, i.e. `<install>/lua/stop-trade-route-async-watcher`.

But `_main.lua:121-125` looks for them somewhere else entirely:

```lua
interrupt_on_file("trade_route_automation/stop-trade-route-async-watcher")
```

which resolves to `<install>/trade_route_automation/stop-…` — a different directory, and one that
does not exist on this machine, so `touch` would fail before it even mattered. Either `BASE` should
be `<install>/trade_route_automation`, or `_main.lua` should look under `lua/` next to the executor.

**`make area-visualizations`** globs `$(BASE)/area*.tsv`, but the scanner writes its TSVs through
`L.logger("area_scan_" .. cityName .. ".tsv")`, and `utils_logger` prefixes any name without a
slash with `L.__base` — putting them at
`<Documents>/…/logs/TrRAt_<profile>_area_scan_<City>.tsv`, exactly as the README's file listing
shows. The glob should be `$(LOGS_DIR)/$(LOGS_MARKER)*area_scan*.tsv`.

## Related

- [testing-index.md](testing-index.md) — both test suites
- [testing-infra-contract.md](testing-infra-contract.md) — the same executor, used to run the
  contract suite rather than an ad-hoc script
- [possible_issues_2026-08-22.md](possible_issues_2026-08-22.md) — findings, marked *proven* or
  *read-only*
