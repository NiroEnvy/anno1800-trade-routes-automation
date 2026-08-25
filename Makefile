include Makefile.vars

TRA_DIR ?= trade-route-automation
REGIONS ?= OW NW ER AR CT

BASE ?= $(INSTALL_BASEDIR_E)

install: install/mkdir
	mkdir -p mods/dev/data/trade_route_automation
	cp -r trade_route_automation/* mods/dev/data/trade_route_automation
	cp -r mods/dev/* "$(INSTALL_BASEDIR)"

# Drops sample1.lua where the in-game executor thread will pick it up, and creates the marker
# that lets that thread start at all. See docs/in-game-testing.md.
install-script:
	mkdir -p "$(INSTALL_BASEDIR_E)/trade-automation"
	touch "$(INSTALL_BASEDIR_E)/trade-automation/executor-enabled"
	cp sample1.lua "$(INSTALL_BASEDIR_E)/trade-automation/execute.lua"

# Stops the poller and makes sure it does not come back on the next mod reload.
install-script/off:
	-rm -f "$(INSTALL_BASEDIR_E)/trade-automation/executor-enabled"
	touch "$(INSTALL_BASEDIR_E)/trade-automation/stopme"

# Runs the contract suite inside the running game: does Anno still behave the way the fake in
# tests/lib/world.lua claims? Needs a TRA_TEST route with one ship of 3+ slots.
# Results: <Documents>/Anno 1800/log/TrRAt_<profile>_game-tests.log
test/game:
	mkdir -p "$(INSTALL_BASEDIR_E)/trade-automation"
	touch "$(INSTALL_BASEDIR_E)/trade-automation/executor-enabled"
	cp tests/lib/t.lua "$(INSTALL_BASEDIR_E)/trade-automation/t.lua"
	cp tests/game/game_env.lua "$(INSTALL_BASEDIR_E)/trade-automation/game_env.lua"
	cp tests/game/contract_cargo.lua "$(INSTALL_BASEDIR_E)/trade-automation/contract_cargo.lua"
	cp tests/game/run.lua "$(INSTALL_BASEDIR_E)/trade-automation/execute.lua"
	@echo ""
	@echo "dropped. the in-game executor picks it up within a frame."
	@echo "results: $(LOGS_DIR)/$(LOGS_MARKER)<profile>_game-tests.log"

install/mkdir:
	mkdir -p "$(INSTALL_BASEDIR)"

stop:
	touch "$(BASE)/stop-trade-route-async-watcher"
	touch "$(BASE)/stop-trade-route-loop-ow"
	touch "$(BASE)/stop-trade-route-loop-nw"
	touch "$(BASE)/stop-trade-executor-heartbeat"
	touch "$(BASE)/stop-trade-routes-automation-owner"

interrupt: stop

clean/interrupt:
	rm -f "$(BASE)/stop-trade-route-async-watcher" || true
	rm -f "$(BASE)/stop-trade-route-loop-ow" || true
	rm -f "$(BASE)/stop-trade-route-loop-nw" || true
	rm -f "$(BASE)/stop-trade-executor-heartbeat" || true

clean/logs:
	-@rm "$(LOGS_DIR)"/"$(LOGS_MARKER)"*.log
	-@rm "$(LOGS_DIR)"/"$(LOGS_MARKER)"*.hub
	-@rm "$(LOGS_DIR)"/"$(LOGS_MARKER)"*.tsv

clean:
	-make clean/interrupt
	-make clean/logs

###

LUA      ?= lua5.4
LUAC     ?= luac5.4
LUACHECK ?= luacheck

# every Lua file we ship or test with, vendored libraries included
LUA_ALL  := $(shell find trade_route_automation tests -name '*.lua' 2>/dev/null)
# our own code only -- serp/, rxi/ and iskolbin/ are third-party
LUA_OURS := $(shell find trade_route_automation tests -name '*.lua' \
              -not -path '*/serp/*' -not -path '*/rxi/*' -not -path '*/iskolbin/*' 2>/dev/null)

# check: the one target to run before committing, and the one CI should run.
#        syntax and test need nothing installed; lint and typecheck skip themselves
#        with an install hint if their tool is missing.
#
#        Runs every step even when an earlier one fails, so that a legacy lint warning does not
#        hide a broken test, then reports which steps failed.
check:
	@failed=""; \
	 for step in syntax lint typecheck test; do \
	   echo ""; echo "=== $$step ==="; \
	   $(MAKE) --no-print-directory $$step || failed="$$failed $$step"; \
	 done; \
	 echo ""; \
	 if [ -n "$$failed" ]; then echo "check: FAILED ->$$failed"; exit 1; fi; \
	 echo "check: all green"

# syntax: does every file still parse? zero dependencies, always runs.
syntax:
	@fail=0; for f in $(LUA_ALL); do $(LUAC) -p "$$f" || fail=1; done; \
	 if [ $$fail -ne 0 ]; then echo "syntax: FAILED"; exit 1; fi; \
	 echo "syntax: $(words $(LUA_ALL)) files compile"

# lint: undefined globals, unused locals, shadowing. Config in .luacheckrc.
lint:
	@if command -v $(LUACHECK) >/dev/null 2>&1; then \
	   $(LUACHECK) $(LUA_OURS); \
	 else \
	   echo "lint: skipped -- luacheck not installed (sudo pacman -S luacheck)"; \
	 fi

# typecheck: EmmyLua annotations, via lua-language-server. Config in .luarc.json.
typecheck:
	@./utils/typecheck.sh

# make test           -- everything
# make test T=packing -- only tests whose name contains "packing"
test:
	@$(LUA) tests/run.lua $(T)

.PHONY: check syntax lint typecheck test

###

run: install-script

###

area-visualizations:
	@for f in $(wildcard $(BASE)/area*.tsv); do \
		python3 ./utils/area-visualizer.py "$$f" "$$f.png"; \
	done
	for f in $(ls $(BASE)/area*.tsv); do \
		python3 ./utils/area-visualizer.py "$f" "$f.png"; \
	done

texts-to-yaml:
	python3 ./utils/texts-to-guid.py ./trade_route_automation/texts.json /data/games/steam/steamapps/common/Anno\ 1800/maindata/data*.rda.unpack/data/config/gui/texts_english.xml

###

SRC=mods/dev
TARGET=dist/TradeRoutesAutomation_DEV_$(shell git describe --tags).zip

release: install
	mkdir -p ./dist
	rm -f $(TARGET) || true
	pushd $(SRC) && zip -r ../../$(TARGET) .
