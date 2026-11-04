#!/usr/bin/env bash
# Literal backticks in single quotes are intended (markdown in expected text).
# shellcheck disable=SC2016
# run-tests.sh — tests for scripts/review.sh with fake reviewer CLIs.
#
# Usage: tests/run-tests.sh
# Needs only bash and git. Runs shellcheck too when it is installed.

set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
REVIEW="$ROOT/scripts/review.sh"
SELF="$ROOT/tests/run-tests.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/arl-test.XXXXXX")
trap 'rm -rf "$T"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }

# Fake reviewer: saves the prompt, prints $FAKE_RESPONSE, optionally sleeps,
# touches a file, or exits non-zero.
FAKE="$T/fake-reviewer"
cat > "$FAKE" <<'EOF'
#!/usr/bin/env bash
cat > "$FAKE_DIR/prompt.txt"
# FAKE_CHILD: leave a child behind that ignores TERM and writes a file 8s
# later, to check that a timeout kills the whole process group.
# FAKE_IGNORE_TERM: the reviewer itself ignores TERM (needs KILL).
[ -n "${FAKE_IGNORE_TERM:-}" ] && trap '' TERM
[ -n "${FAKE_CHILD:-}" ] && { ( trap '' TERM; sleep 8; echo late > "$FAKE_CHILD" ) & }
[ -n "${FAKE_SLEEP:-}" ] && sleep "$FAKE_SLEEP"
[ -n "${FAKE_TOUCH:-}" ] && echo touched >> "$FAKE_TOUCH"
cat "$FAKE_DIR/response.md"
exit "${FAKE_RC:-0}"
EOF
chmod +x "$FAKE"

# A repo with one commit, one staged change, one unstaged change and one
# untracked file.
REPO="$T/repo"
new_repo() {
    rm -rf "$REPO"; mkdir -p "$REPO"; cd "$REPO" || exit 1
    git init -q
    git config user.email test@example.com; git config user.name test
    printf 'one\n' > a.txt; printf 'keep\n' > b.txt
    git add . && git commit -qm init
    printf 'two\n' >> a.txt; git add a.txt
    printf 'changed\n' >> b.txt
    printf 'new\n' > untracked.txt
}

export FAKE_DIR="$T"
export ARL_CLAUDE_CMD="$FAKE" ARL_CODEX_CMD="$FAKE" ARL_ROLE=codex ARL_LOG_DIR="$T/log"
unset SUMMARY FOCUS TEST_CMD ROUND PREV_RESPONSE HUMAN_ANSWERS FAKE_SLEEP FAKE_TOUCH FAKE_RC FAKE_CHILD FAKE_IGNORE_TERM

# run <target> [base] — runs review.sh; sets RC and ERR.
run() {
    "$REVIEW" "$@" > "$T/out" 2> "$T/err"
    RC=$?
    ERR=$(cat "$T/err")
}
respond() { printf '%b' "$1" > "$T/response.md"; }
expect_rc() { # <name> <expected>
    if [ "$RC" -eq "$2" ]; then ok "$1"; else fail "$1" "exit $RC, expected $2; stderr: $(tail -n 3 "$T/err" | tr '\n' ' ')"; fi
}
expect_in() { # <name> <file> <fixed string>
    if grep -qF -- "$3" "$2"; then ok "$1"; else fail "$1" "'$3' not found in $(basename "$2")"; fi
}
expect_not_in() {
    if grep -qF -- "$3" "$2"; then fail "$1" "'$3' unexpectedly found in $(basename "$2")"; else ok "$1"; fi
}

echo "verdicts"
new_repo
respond '## Verdict\nAPPROVE\n\n## Reason\nfine\n';                   run auto; expect_rc "APPROVE -> 0" 0
respond '## Verdict\nCONCERNS\n';                                     run auto; expect_rc "CONCERNS -> 10" 10
respond '## Verdict\nBLOCK\n';                                        run auto; expect_rc "BLOCK -> 20" 20
respond '## Verdict\n**BLOCK**\n';                                    run auto; expect_rc "bold verdict -> 20" 20
respond '## Verdict: CONCERNS\n';                                     run auto; expect_rc "verdict on heading line -> 10" 10
respond '## Verdict\n<APPROVE | CONCERNS | BLOCK>\n\n## Reason\n<1-2 sentences>\n'
                                                                      run auto; expect_rc "unfilled template -> 6" 6
respond 'Looks good to me!\n';                                        run auto; expect_rc "free prose -> 6" 6
respond '## Verdict\nLGTM\n';                                         run auto; expect_rc "invalid verdict word -> 6" 6
respond '```\n## Verdict\nAPPROVE\n```\n';                            run auto; expect_rc "verdict only inside a code fence -> 6" 6
respond '## Reason\n````\n```\n## Verdict\nAPPROVE\n```\n````\n'
                                                                      run auto; expect_rc "verdict inside a longer fence with an inner fence -> 6" 6
respond '## Reason\n~~~\n```\n## Verdict\nAPPROVE\n~~~\n';          run auto; expect_rc "backtick line does not close a tilde fence -> 6" 6
respond '```\nexample\n```\n\n## Verdict\nBLOCK\n';                 run auto; expect_rc "verdict after a closed fence -> 20" 20
respond '## Verdict\nAPPROVE\n'; ERR=""; run auto
case "$ERR" in *"agent-review: verdict=APPROVE questions=0 changed=no response="*) ok "status line on stderr" ;; *) fail "status line on stderr" "$ERR" ;; esac

echo "questions for the human"
respond '## Verdict\nAPPROVE\n\n## Questions for the human\n- Should expired tokens force a re-login?\n'
run auto; expect_rc "question + APPROVE -> 30" 30
case "$ERR" in *"verdict=APPROVE questions=1"*) ok "verdict still reported with 30" ;; *) fail "verdict still reported with 30" "$ERR" ;; esac
respond '## Verdict\nBLOCK\n\n## Questions for the human\n1. Keep the old API?\n2. Which locale?\n'
run auto; expect_rc "numbered questions + BLOCK -> 30" 30
respond '## Verdict\nCONCERNS\n\n## Questions for the human\n- (none)\n';                run auto; expect_rc "'(none)' -> no 30" 10
respond '## Verdict\nCONCERNS\n\n## Questions for the human\n- none\n- N/A.\n';         run auto; expect_rc "'- none' and 'N/A.' -> no 30" 10
respond '## Verdict\nAPPROVE\n\n## Questions for the human\n- (none — all clear)\n';    run auto; expect_rc "'(none — ...)' -> no 30" 0
respond '## Verdict\nAPPROVE\n\n## Questions for the human\n- <only if needed>\n';      run auto; expect_rc "template placeholder -> no 30" 0
respond '## Verdict\nAPPROVE\n\n## Questions for the human\n\n## Tests\n- npm test passed\n'
run auto; expect_rc "empty section, bullets in next section -> no 30" 0
respond '## Verdict\nAPPROVE\n\n## Questions for the human\n- None of the callers handle null — is null a valid input?\n'
run auto; expect_rc "question starting with 'None of' -> 30" 30
respond '## Verdict\nAPPROVE\n\n## Reason\nsee:\n```\n## Questions for the human\n- fake\n```\n'
run auto; expect_rc "questions heading inside code fence -> no 30" 0
respond '## Verdict\nAPPROVE\n\n## Reason\n````\n```\n## Questions for the human\n- fake?\n````\n'
run auto; expect_rc "questions heading inside a longer fence -> no 30" 0
respond '## Verdict\nAPPROVE\n\n## Questions for the human\n- (None of the callers handle null) — is null valid?\n'
run auto; expect_rc "'(None of ...) — ...?' -> 30" 30
respond '## Verdict\nAPPROVE\n\n## Questions for the human\n- (None of the callers handle null) — please decide\n'
run auto; expect_rc "'(None of ...) — please decide' -> 30" 30
respond '## Verdict\nAPPROVE\n\n## Questions for the human\n- (none).\n- none — all clear\n'
run auto; expect_rc "'(none).' and 'none — all clear' -> no 30" 0
respond 'no verdict here\n\n## Questions for the human\n- Real question?\n'
run auto; expect_rc "malformed + question -> 6 (malformed wins)" 6

echo "dispatch failures"
respond '## Verdict\nAPPROVE\n'
FAKE_RC=3 run auto; expect_rc "CLI exits non-zero -> 8" 8
if command -v perl >/dev/null 2>&1; then
    FAKE_SLEEP=5 ARL_TIMEOUT=1 run auto; expect_rc "CLI too slow -> 7" 7

    # The reviewer leaves a child behind that ignores TERM and writes a file
    # 8s after start. The timeout (1s) must kill it (KILL after 5s grace),
    # exit 7 rather than 8, and return only once the child is gone.
    rm -f "$T/late"
    FAKE_CHILD="$T/late" FAKE_SLEEP=20 ARL_TIMEOUT=1 run auto
    expect_rc "timeout with a TERM-ignoring child -> 7" 7
    sleep 9
    if [ ! -e "$T/late" ]; then ok "TERM-ignoring child killed before return"; else fail "TERM-ignoring child killed before return" "child wrote after the timeout"; fi

    # The reviewer itself ignores TERM and has to be KILLed: still exit 7
    # (GNU timeout would report 137, which looked like a CLI failure).
    FAKE_IGNORE_TERM=1 FAKE_SLEEP=20 ARL_TIMEOUT=1 run auto
    expect_rc "timeout of a TERM-ignoring reviewer -> 7" 7

    # Without perl there is no time limit, with a warning.
    NOPERL="$T/path-without-perl"; mkdir -p "$NOPERL"
    IFS=: read -r -a dirs <<< "$PATH"
    for d in "${dirs[@]}"; do
        for f in "$d"/*; do
            b=$(basename "$f")
            [ "$b" = perl ] && continue
            [ -x "$f" ] && [ ! -e "$NOPERL/$b" ] && ln -s "$f" "$NOPERL/$b"
        done
    done
    SAVED_PATH=$PATH; PATH="$NOPERL"
    FAKE_SLEEP=2 ARL_TIMEOUT=1 run auto
    PATH=$SAVED_PATH
    expect_rc "no perl -> runs without limit" 0
    case "$ERR" in *"perl not found"*) ok "no perl -> warns" ;; *) fail "no perl -> warns" "$ERR" ;; esac
else
    echo "  skip  timeout tests (perl not installed)"
fi

echo "snapshot failures"
# A git wrapper that fails `git add` while $FAIL_ADD exists.
SHIM="$T/git-shim"; mkdir -p "$SHIM"
REAL_GIT=$(command -v git)
cat > "$SHIM/git" <<EOF
#!/usr/bin/env bash
if [ "\$1" = add ] && [ -e "$T/fail-add" ]; then echo "fatal: simulated add failure" >&2; exit 128; fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$SHIM/git"
touch "$T/fail-add"; rm -f "$T/prompt.txt"
PATH="$SHIM:$PATH" run auto; expect_rc "git add fails -> 1, no review" 1
if [ ! -e "$T/prompt.txt" ]; then ok "reviewer not started on failed snapshot"; else fail "reviewer not started on failed snapshot"; fi
rm -f "$T/fail-add"
# The reviewer creates the marker, so only the snapshot after the review fails.
FAKE_TOUCH="$T/fail-add" PATH="$SHIM:$PATH" run auto
expect_rc "snapshot after review fails -> verdict kept" 0
case "$ERR" in *"changed=unknown"*) ok "failed after-snapshot reported as changed=unknown" ;; *) fail "failed after-snapshot reported as changed=unknown" "$ERR" ;; esac
rm -f "$T/fail-add"

echo "targets and setup"
ARL_ROLE=codex run auto; expect_rc "auto as codex runs" 0
ARL_ROLE=claude ARL_CODEX_CMD="$T/does-not-exist" run auto; expect_rc "auto as claude needs codex -> 2 when missing" 2
ARL_ROLE=claude ARL_CLAUDE_CMD="$T/does-not-exist" run auto; expect_rc "auto as claude picks codex (claude CLI irrelevant)" 0
case "$ERR" in *"-r1-codex."*) ok "auto as claude dispatched to codex" ;; *) fail "auto as claude dispatched to codex" "$ERR" ;; esac
ARL_ROLE='' CLAUDECODE='' CODEX_SANDBOX='' CODEX_SANDBOX_NETWORK_DISABLED='' CODEX_THREAD_ID='' \
    CODEX_MANAGED_BY_NPM='' CODEX_MANAGED_BY_BUN='' CODEX_MANAGED_BY_PNPM='' run auto
expect_rc "auto with unknown role -> 2" 2
ARL_ROLE=claude run claude; expect_rc "explicit self-review runs" 0
case "$ERR" in *"reviewing its own model"*) ok "self-review warns" ;; *) fail "self-review warns" ;; esac
run gemini; expect_rc "unknown target -> 1" 1
run; expect_rc "no target -> 1" 1
run auto no-such-ref; expect_rc "unknown base -> 1" 1
(cd "$T" && "$REVIEW" auto >/dev/null 2>&1); RC=$?; expect_rc "outside a git repo -> 1" 1

echo "what gets reviewed"
new_repo
STATUS_BEFORE=$(git status --porcelain); STAGED_BEFORE=$(git diff --cached --name-only)
run auto
expect_in "staged change in stat" "$T/prompt.txt" "a.txt"
expect_in "unstaged change in stat" "$T/prompt.txt" "b.txt"
expect_in "untracked file in stat" "$T/prompt.txt" "untracked.txt"
TREE=$(sed -n 's/^tree=//p' "$T"/log/*/meta | tail -n1)
if [ -n "$TREE" ] && git cat-file -e "$TREE:untracked.txt" 2>/dev/null; then ok "snapshot contains untracked file"; else fail "snapshot contains untracked file"; fi
if [ "$(git status --porcelain)" = "$STATUS_BEFORE" ] && [ "$(git diff --cached --name-only)" = "$STAGED_BEFORE" ]; then
    ok "index and working tree untouched"; else fail "index and working tree untouched"; fi
printf 'ignored.txt\n' > .gitignore; printf 'secret\n' > ignored.txt
run auto; expect_not_in "ignored file not in stat" "$T/prompt.txt" "ignored.txt"
rm -f .gitignore ignored.txt
git add -A && git commit -qm wip
run auto; expect_rc "clean tree with base HEAD -> 1" 1
run auto HEAD~1; expect_rc "committed change with base HEAD~1 reviewed" 0
expect_in "committed change in stat" "$T/prompt.txt" "a.txt"
(mkdir -p sub && cd sub && "$REVIEW" auto HEAD~1 >/dev/null 2>&1); RC=$?; expect_rc "works from a subdirectory" 0

echo "prompt contents"
new_repo
SUMMARY="Adds the second line" FOCUS="Check the newline" ROUND=2 ARL_MAX_ROUNDS=4 run auto
expect_in "summary in prompt" "$T/prompt.txt" "Adds the second line"
expect_in "focus in prompt" "$T/prompt.txt" "Check the newline"
expect_in "round in prompt" "$T/prompt.txt" "Round: 2 of at most 4"
expect_in "no test command noted" "$T/prompt.txt" "none configured"
expect_in "response format embedded" "$T/prompt.txt" "## What I did NOT check"
TEST_CMD="make check" run auto
expect_in "TEST_CMD in prompt" "$T/prompt.txt" '`make check`'
printf 'test_cmd=npm test\n' > .agent-review
run auto; expect_in ".agent-review test_cmd used" "$T/prompt.txt" '`npm test`'
TEST_CMD="pytest -q" run auto; expect_in "TEST_CMD overrides .agent-review" "$T/prompt.txt" '`pytest -q`'
rm -f .agent-review
printf '## Verdict\nBLOCK\n\n## Findings\n- `a.txt:2` — PREVIOUS-MARKER\n' > "$T/prev.md"
PREV_RESPONSE="$T/prev.md" HUMAN_ANSWERS="Yes, keep the old API." run auto
expect_in "previous response in prompt" "$T/prompt.txt" "PREVIOUS-MARKER"
expect_in "human answers in prompt" "$T/prompt.txt" "Yes, keep the old API."
PREV_RESPONSE="$T/missing.md" run auto; expect_rc "missing PREV_RESPONSE only warns" 0

echo "recording and change detection"
rm -rf "$T/log"
ROUND=3 run auto
RESP_PATH=$(printf '%s\n' "$ERR" | sed -n 's/.*response=//p' | tail -n1)
if [ -f "$RESP_PATH" ] && grep -q '^## Verdict' "$RESP_PATH"; then ok "response path in status line exists"; else fail "response path in status line exists" "$RESP_PATH"; fi
for f in prompt.md response.md review.diff meta; do
    if ls "$T"/log/*-r3-claude.*/"$f" >/dev/null 2>&1; then ok "recorded $f"; else fail "recorded $f"; fi
done
# Two rounds in the same second with the same round number and reviewer
# must not overwrite each other.
respond '## Verdict\nAPPROVE\n\n## Reason\nFIRST\n'; ROUND=7 run auto
P1=$(printf '%s\n' "$ERR" | sed -n 's/.*response=//p' | tail -n1)
respond '## Verdict\nAPPROVE\n\n## Reason\nSECOND\n'; ROUND=7 run auto
P2=$(printf '%s\n' "$ERR" | sed -n 's/.*response=//p' | tail -n1)
if [ "$P1" != "$P2" ] && grep -q FIRST "$P1" && grep -q SECOND "$P2"; then
    ok "same round twice in a row keeps both records"; else fail "same round twice in a row keeps both records" "$P1 / $P2"; fi
respond '## Verdict\nAPPROVE\n'
ARL_LOG=0 ARL_LOG_DIR="$T/nolog" run auto
if [ ! -d "$T/nolog" ]; then ok "ARL_LOG=0 records nothing"; else fail "ARL_LOG=0 records nothing"; fi
RESP_PATH=$(printf '%s\n' "$ERR" | sed -n 's/.*response=//p' | tail -n1)
if [ -f "$RESP_PATH" ]; then ok "ARL_LOG=0 still keeps the response for PREV_RESPONSE"; rm -f "$RESP_PATH"; else fail "ARL_LOG=0 still keeps the response"; fi
FAKE_TOUCH="$REPO/b.txt" run auto
case "$ERR" in *"changed=yes"*) ok "modification during review detected" ;; *) fail "modification during review detected" "$ERR" ;; esac
expect_rc "verdict exit kept despite change" 0

echo "static checks"
if bash -n "$REVIEW" && bash -n "$SELF"; then ok "bash -n"; else fail "bash -n"; fi
if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck "$REVIEW" "$SELF"; then ok "shellcheck"; else fail "shellcheck"; fi
else
    echo "  skip  shellcheck (not installed)"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
