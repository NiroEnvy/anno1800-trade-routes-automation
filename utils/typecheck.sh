#!/usr/bin/env bash
#
# Runs lua-language-server in --check mode: the same annotation and type diagnostics the editor
# shows, in a form a Makefile can fail on. This is the check that catches things like
# `---@return FakeWorld` where FakeWorld was never declared with `---@class`.
#
# Configuration lives in .luarc.json at the repo root: globals the game injects, directories to
# skip, and which diagnostics matter.
#
# Install: sudo pacman -S lua-language-server
#
# Exits 0 when clean or when the tool is absent, non-zero when it reports problems.

set -uo pipefail

LUALS="${LUALS:-lua-language-server}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOGDIR="${TMPDIR:-/tmp}/tra-luals-check"

if ! command -v "$LUALS" >/dev/null 2>&1; then
    echo "typecheck: skipped -- $LUALS not installed (sudo pacman -S lua-language-server)"
    exit 0
fi

rm -rf "$LOGDIR"
mkdir -p "$LOGDIR"

# 3.18.2 reports to stdout and signals findings through its exit code; it writes no check.json.
"$LUALS" \
    --check "$ROOT" \
    --configpath "$ROOT/.luarc.json" \
    --checklevel=Warning \
    --logpath="$LOGDIR"
status=$?

if [ $status -eq 0 ]; then
    echo "typecheck: clean"
else
    echo
    echo "typecheck: FAILED (logs in $LOGDIR)"
fi

exit $status
