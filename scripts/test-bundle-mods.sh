#!/bin/bash
# Tests scripts/bundle-mods.sh against throwaway mods folders: every mod is shipped without what
# the engine or a developer makes beside it, and a folder that is not a mod stops the build.
# Usage: ./scripts/test-bundle-mods.sh
set -euo pipefail

BUNDLE="$(cd "$(dirname "$0")" && pwd)/bundle-mods.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAILED=0
CASES=0

fail() { # fail <case name> <why>
    echo "FAIL: $1 — $2"
    FAILED=$((FAILED + 1))
}

mod() { # mod <mods folder> <name> — a mod with the files a mod ships and the files it must not
    local root="$1/$2"
    mkdir -p "$root/.claude-plugin/types/claude-code" "$root/hooks" "$root/types" "$root/node_modules/x"
    echo "{\"name\": \"$2\"}" > "$root/.claude-plugin/plugin.json"
    echo '{ "modules": ["./register.tsx"] }' > "$root/hooks/hooks.json"
    echo 'export const register = () => {}' > "$root/hooks/register.tsx"
    echo 'test' > "$root/hooks/register.test.tsx"
    echo 'export {}' > "$root/types/index.d.ts"
    echo '{}' > "$root/tsconfig.json"
    echo 'generated' > "$root/.claude-plugin/types/claude-code/index.d.ts"
    echo 'junk' > "$root/.DS_Store"
    echo 'dep' > "$root/node_modules/x/index.js"
}

run() { # run <case name> <source> <destination> — the bundle's exit status in $STATUS, output in $OUT
    CASES=$((CASES + 1))
    STATUS=0
    OUT="$("$BUNDLE" "$2" "$3" 2>&1)" || STATUS=$?
}

# --- every mod ships, without generated types, tests, tsconfig, node_modules or .DS_Store ------
mkdir -p "$WORK/a/mods"
mod "$WORK/a/mods" first
mod "$WORK/a/mods" second
echo 'notes' > "$WORK/a/mods/README.md"
run "every mod ships" "$WORK/a/mods" "$WORK/a/out"
if [[ $STATUS -ne 0 ]]; then
    fail "every mod ships" "exit $STATUS: $OUT"
else
    shipped="$(cd "$WORK/a/out" && find . -type f | sort | tr '\n' ' ')"
    want="./first/.claude-plugin/plugin.json ./first/hooks/hooks.json ./first/hooks/register.tsx ./first/types/index.d.ts ./second/.claude-plugin/plugin.json ./second/hooks/hooks.json ./second/hooks/register.tsx ./second/types/index.d.ts "
    if [[ "$shipped" != "$want" ]]; then
        fail "every mod ships" "shipped: $shipped"
    else
        echo "ok:   every mod ships"
    fi
fi

# --- a folder that is not a mod stops the build, naming it --------------------------------------
mkdir -p "$WORK/b/mods/stray"
mod "$WORK/b/mods" good
run "a folder without a manifest is refused" "$WORK/b/mods" "$WORK/b/out"
if [[ $STATUS -ne 1 || "$OUT" != *"stray"* ]]; then
    fail "a folder without a manifest is refused" "exit $STATUS: $OUT"
else
    echo "ok:   a folder without a manifest is refused"
fi

# --- a missing mods folder stops the build ------------------------------------------------------
run "a missing mods folder is refused" "$WORK/none" "$WORK/c/out"
if [[ $STATUS -ne 1 || "$OUT" != *"$WORK/none"* ]]; then
    fail "a missing mods folder is refused" "exit $STATUS: $OUT"
else
    echo "ok:   a missing mods folder is refused"
fi

# --- a mods folder with no mods stops the build -------------------------------------------------
mkdir -p "$WORK/d/mods"
run "an empty mods folder is refused" "$WORK/d/mods" "$WORK/d/out"
if [[ $STATUS -ne 1 ]]; then
    fail "an empty mods folder is refused" "exit $STATUS: $OUT"
else
    echo "ok:   an empty mods folder is refused"
fi

echo "$((CASES - FAILED))/$CASES passed"
[[ $FAILED -eq 0 ]]
