#!/bin/bash
# Copies every mod under a mods folder into the app's Resources, as a clean tree: no generated
# types, no tsconfig, no tests, no node_modules, no .DS_Store. A folder there without
# .claude-plugin/plugin.json is not a mod and stops the build, as does a folder with no mods.
# Usage: ./scripts/bundle-mods.sh <mods folder> <destination>
set -euo pipefail

[[ $# -eq 2 ]] || { echo "usage: $(basename "$0") <mods folder> <destination>" >&2; exit 2; }
SRC="$1"
DST="$2"

if [[ ! -d "$SRC" ]]; then
    echo "ERROR: $SRC not found — refusing to ship without the mods." >&2
    exit 1
fi

shipped=0
for mod in "$SRC"/*/; do
    [[ -d "$mod" ]] || continue
    name="$(basename "$mod")"
    if [[ ! -f "$mod/.claude-plugin/plugin.json" ]]; then
        echo "ERROR: mods/$name has no .claude-plugin/plugin.json — it is not a mod." >&2
        exit 1
    fi
    echo "==> Bundling mods/$name into Resources"
    mkdir -p "$DST/$name"
    rsync -a \
        --exclude '.claude-plugin/types/' \
        --exclude 'tsconfig.json' \
        --exclude '*.test.tsx' \
        --exclude '.DS_Store' \
        --exclude 'node_modules' \
        "$mod" "$DST/$name/"
    shipped=$((shipped + 1))
done

if [[ $shipped -eq 0 ]]; then
    echo "ERROR: $SRC holds no mods — refusing to ship without them." >&2
    exit 1
fi
