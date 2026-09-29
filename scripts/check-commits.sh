#!/bin/bash
# Checks the commits in a range, the same way CI does:
#   - no attribution trailers (Co-Authored-By, "Generated with", session links),
#   - never the words claude or anthropic (any case) in a commit message,
#   - `git diff --check` finds no whitespace errors in what the range changes.
# Usage: ./scripts/check-commits.sh <base>..<head>     e.g. origin/main..HEAD
# Exit: 0 clean, 1 a problem was found, 2 the range could not be checked.
set -uo pipefail

usage() {
    echo "usage: $(basename "$0") <base>..<head>" >&2
    exit 2
}

[[ $# -eq 1 ]] || usage
RANGE="$1"
[[ "$RANGE" == *..* ]] || { echo "error: '$RANGE' is not a range; expected <base>..<head>" >&2; usage; }
BASE="${RANGE%%..*}"
HEAD_REF="${RANGE#*..}"
[[ -n "$BASE" && -n "$HEAD_REF" && "$HEAD_REF" != .* ]] || { echo "error: '$RANGE' is not a range; expected <base>..<head>" >&2; usage; }

if ! COMMITS="$(git rev-list "$BASE..$HEAD_REF" 2>&1)"; then
    echo "error: cannot list commits in $RANGE:" >&2
    echo "$COMMITS" >&2
    exit 2
fi

PROBLEMS=0
problem() { # problem <commit> <reason>
    echo "$(git log -1 --format='%h %s' "$1"): $2"
    PROBLEMS=$((PROBLEMS + 1))
}

for commit in $COMMITS; do
    message="$(git log -1 --format=%B "$commit")"
    if grep -qiE '^[[:space:]]*co-authored-by:' <<<"$message"; then
        problem "$commit" "has a Co-Authored-By attribution trailer"
    fi
    if grep -q 'Generated with' <<<"$message"; then
        problem "$commit" "has a \"Generated with\" attribution line"
    fi
    if grep -qE 'https?://[^[:space:]]*/session_[A-Za-z0-9]+' <<<"$message"; then
        problem "$commit" "links to a session (session link)"
    fi
    if grep -qi 'claude' <<<"$message"; then
        problem "$commit" "mentions claude"
    fi
    if grep -qi 'anthropic' <<<"$message"; then
        problem "$commit" "mentions anthropic"
    fi
done

# Whitespace errors in what the range changes, measured from where the head left the base.
if ! MERGE_BASE="$(git merge-base "$BASE" "$HEAD_REF" 2>&1)"; then
    echo "error: no merge base for $RANGE:" >&2
    echo "$MERGE_BASE" >&2
    exit 2
fi
if ! DIFF_CHECK="$(git diff --check "$MERGE_BASE" "$HEAD_REF" 2>&1)"; then
    echo "whitespace errors in $RANGE (git diff --check):"
    echo "$DIFF_CHECK" | sed 's/^/    /'
    PROBLEMS=$((PROBLEMS + 1))
fi

if [[ $PROBLEMS -ne 0 ]]; then
    echo "check-commits: $PROBLEMS problem(s) in $RANGE" >&2
    exit 1
fi
echo "check-commits: $RANGE is clean ($(echo "$COMMITS" | grep -c . || true) commit(s))"
