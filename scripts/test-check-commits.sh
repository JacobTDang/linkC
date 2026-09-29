#!/bin/bash
# Tests scripts/check-commits.sh against a throwaway repository with good and bad commits:
# each rule must reject its own bad case, and clean history must pass.
# Usage: ./scripts/test-check-commits.sh
set -euo pipefail

CHECK="$(cd "$(dirname "$0")" && pwd)/check-commits.sh"

# Keep the developer's git config (signing, hooks, templates) out of the throwaway repo.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAILED=0
CASES=0

commit() { # commit <message> [line] [file] — one commit appending a line to notes.txt (or the file)
    local file="${3:-notes.txt}"
    printf '%s\n' "${2:-$RANDOM}" >> "$file"
    git add "$file"
    git commit -q -m "$1"
}

new_repo() { # new_repo <name> — a repo whose first commit, tagged `base`, is the (clean) range start
    rm -rf "$WORK/$1"
    mkdir "$WORK/$1"
    cd "$WORK/$1"
    git init -q -b main
    git config user.name "Test"
    git config user.email "test@example.com"
    git config commit.gpgsign false
    commit "chore: start"
    git tag base
}

expect() { # expect <accept|reject|usage> <case name> <range> [expected text in the output]
    # accept: exit 0. reject: exit 1, the check found a problem. usage: exit 2, the check could not run.
    local want="$1" name="$2" range="$3" text="${4:-}" out status=0 wanted_status=0
    [[ "$want" == reject ]] && wanted_status=1
    [[ "$want" == usage ]] && wanted_status=2
    CASES=$((CASES + 1))
    out="$("$CHECK" "$range" 2>&1)" || status=$?
    if [[ $status -ne $wanted_status ]]; then
        echo "FAIL: $name — expected exit $wanted_status, got $status:"
        echo "$out" | sed 's/^/    /'
        FAILED=$((FAILED + 1))
    elif [[ -n "$text" && "$out" != *"$text"* ]]; then
        echo "FAIL: $name — output lacks '$text':"
        echo "$out" | sed 's/^/    /'
        FAILED=$((FAILED + 1))
    else
        echo "ok:   $name"
    fi
}

# --- clean history is accepted -------------------------------------------------------------
new_repo clean
commit "fix(sidebar): stop re-laying out the whole window every second"
commit "test(ticker): give the ticker a scratch cache" "a line with no trailing space"
expect accept "clean commits" "base..HEAD"

new_repo empty
expect accept "an empty range" "HEAD..HEAD"

new_repo merge
git checkout -q -b topic
commit "feat: on a branch" "" topic.txt
git checkout -q main
commit "feat: on main"
git merge -q --no-ff topic -m "Merge pull request #46: report through a watched file"
expect accept "a clean merge commit" "base..HEAD"

# --- attribution trailers and mentions are rejected ----------------------------------------
new_repo trailer
commit "feat: add a thing

Co-Authored-By: Someone Else <someone@example.com>"
expect reject "a Co-Authored-By trailer" "base..HEAD" "Co-Authored-By"

new_repo trailer-case
commit "feat: add a thing

co-authored-by: Someone Else <someone@example.com>"
expect reject "a lower-case co-authored-by trailer" "base..HEAD" "attribution trailer"

new_repo generated
commit "feat: add a thing

Generated with a code generator"
expect reject "a Generated with line" "base..HEAD" "Generated with"

new_repo session
commit "feat: add a thing

https://example.com/code/session_01ABCdef123"
expect reject "a session link" "base..HEAD" "session link"

new_repo claude-subject
commit "fix: teach ClAuDe about the sidebar"
expect reject "the word claude in the subject, any case" "base..HEAD" "claude"

new_repo claude-body
commit "fix: teach the sidebar

The body mentions claude in passing."
expect reject "the word claude in the body" "base..HEAD" "claude"

new_repo anthropic
commit "docs: thanks to ANTHROPIC for the tokens"
expect reject "the word anthropic, any case" "base..HEAD" "anthropic"

new_repo bad-merge
git checkout -q -b topic
commit "feat: on a branch" "" topic.txt
git checkout -q main
commit "feat: on main"
git merge -q --no-ff topic -m "Merge branch 'claude/experiment'"
expect reject "a merge commit that mentions claude" "base..HEAD" "claude"

# --- only the commits in the range count ---------------------------------------------------
new_repo old-bad
commit "chore: written by claude"
git tag mid
commit "fix: a clean follow-up"
expect accept "a bad commit before the range start" "mid..HEAD"
expect reject "the same bad commit once the range includes it" "base..HEAD" "claude"

new_repo bad-in-middle
commit "feat: one"
commit "feat: two

Co-Authored-By: Someone <s@example.com>"
commit "feat: three"
expect reject "a bad commit in the middle of the range" "base..HEAD" "Co-Authored-By"

new_repo two-bad
commit "feat: one, by claude"
commit "feat: two, by anthropic"
expect reject "every bad commit is named, not only the first" "base..HEAD" "anthropic"

# --- whitespace errors ---------------------------------------------------------------------
new_repo trailing-space
commit "fix: sloppy line" "a line with a trailing space "
expect reject "trailing whitespace in an added line" "base..HEAD" "trailing whitespace"

new_repo conflict-marker
commit "fix: forgot a marker" "<<<<<<< HEAD"
expect reject "a leftover conflict marker" "base..HEAD" "conflict marker"

new_repo fixed-whitespace
commit "fix: sloppy line" "a line with a trailing space "
printf 'a clean file\n' > notes.txt
git add notes.txt
git commit -q -m "fix: tidy the line"
expect accept "whitespace fixed within the range" "base..HEAD"

new_repo old-space
commit "fix: sloppy line" "a line with a trailing space "
git tag mid
commit "feat: clean" "a clean line"
expect accept "whitespace before the range start" "mid..HEAD"

new_repo moved-base
commit "chore: an old sloppy line" "a line with a trailing space "
git checkout -q -b topic
commit "feat: on a branch" "" topic.txt
git checkout -q main
printf 'a clean file\n' > notes.txt
git add notes.txt
git commit -q -m "fix: tidy the line on main"
expect accept "whitespace the base fixed after the branch left it" "main..topic"

# --- bad invocations fail loudly ------------------------------------------------------------
new_repo usage
CASES=$((CASES + 1))
status=0
"$CHECK" >/dev/null 2>&1 || status=$?
if [[ $status -ne 2 ]]; then
    echo "FAIL: no range argument — expected exit 2, got $status"
    FAILED=$((FAILED + 1))
else
    echo "ok:   no range argument"
fi
expect usage "an unknown revision" "no-such-ref..HEAD" "no-such-ref"
expect usage "a range with no dots" "HEAD" "range"

echo
if [[ $FAILED -ne 0 ]]; then
    echo "$FAILED of $CASES check-commits cases failed"
    exit 1
fi
echo "all $CASES check-commits cases passed"
