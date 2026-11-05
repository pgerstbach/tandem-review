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
T=$(mktemp -d "${TMPDIR:-/tmp}/tandem-test.XXXXXX")
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
[ -n "${FAKE_STDERR:-}" ] && printf '%s\n' "$FAKE_STDERR" >&2
[ -n "${FAKE_TOUCH_EARLY:-}" ] && echo touched >> "$FAKE_TOUCH_EARLY"
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
export TANDEM_CLAUDE_CMD="$FAKE" TANDEM_CODEX_CMD="$FAKE" TANDEM_ROLE=codex TANDEM_LOG_DIR="$T/log"
unset SUMMARY FOCUS TEST_CMD ROUND PREV_RESPONSE HUMAN_ANSWERS TANDEM_CLAUDE_ARGS TANDEM_CODEX_ARGS FAKE_SLEEP FAKE_TOUCH FAKE_RC FAKE_CHILD FAKE_IGNORE_TERM FAKE_STDERR FAKE_TOUCH_EARLY

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
case "$ERR" in *"tandem-review: verdict=APPROVE questions=0 changed=no response="*) ok "status line on stderr" ;; *) fail "status line on stderr" "$ERR" ;; esac

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
respond '## Verdict\nAPPROVE\n\n## Questions for the human\n- Untrusted partial question?\n'
FAKE_RC=3 FAKE_SLEEP=1 FAKE_STDERR="CLI-ERROR-MARKER" FAKE_TOUCH="$REPO/b.txt" run auto
expect_rc "CLI exits non-zero -> 8" 8
expect_in "failed CLI still checks changes and reports no verdict" "$T/err" 'verdict=CLI_FAILED questions=0 changed=yes'
if [ ! -s "$T/out" ]; then ok "failed CLI never prints a partial review on stdout"; else fail "failed CLI never prints a partial review on stdout"; fi
ERROR_RESPONSE=$(printf '%s\n' "$ERR" | sed -n 's/.*response=//p' | tail -n1)
ERROR_DIR=$(dirname "${ERROR_RESPONSE:-$T/missing/response.md}")
expect_in "failed CLI keeps its full stdout" "$ERROR_DIR/response.md" 'Untrusted partial question?'
expect_in "failed CLI keeps its full stderr" "$ERROR_DIR/cli.log" 'CLI-ERROR-MARKER'
expect_in "failed CLI records script exit" "$ERROR_DIR/meta" 'exit_code=8'
expect_in "failed CLI records raw CLI exit" "$ERROR_DIR/meta" 'cli_exit_code=3'
if [ -f "$ERROR_DIR/meta" ] && awk -F= '$1 == "duration_seconds" && $2 >= 1 { found=1 } END { exit !found }' "$ERROR_DIR/meta"; then
    ok "failed CLI records elapsed seconds"; else fail "failed CLI records elapsed seconds"; fi
for f in prompt.md review.diff; do
    if [ -s "$ERROR_DIR/$f" ]; then ok "failed CLI records $f"; else fail "failed CLI records $f"; fi
done
FAKE_RC=3 run codex; expect_rc "Codex CLI failure keeps exit 8" 8
expect_in "Codex CLI failure also reports status" "$T/err" 'verdict=CLI_FAILED questions=0 changed=no'
respond '## Verdict\nAPPROVE\n'
if command -v perl >/dev/null 2>&1; then
    FAKE_SLEEP=5 FAKE_TOUCH_EARLY="$REPO/b.txt" FAKE_STDERR="TIMEOUT-LOG-MARKER" TANDEM_TIMEOUT=1 run auto
    expect_rc "CLI too slow -> 7" 7
    expect_in "timeout still checks changes and reports status" "$T/err" 'verdict=TIMEOUT questions=0 changed=yes'
    TIMEOUT_RESPONSE=$(printf '%s\n' "$ERR" | sed -n 's/.*response=//p' | tail -n1)
    TIMEOUT_DIR=$(dirname "${TIMEOUT_RESPONSE:-$T/missing/response.md}")
    expect_in "timeout saves CLI output" "$TIMEOUT_DIR/cli.log" 'TIMEOUT-LOG-MARKER'
    expect_in "timeout records script exit" "$TIMEOUT_DIR/meta" 'exit_code=7'
    expect_in "timeout records raw CLI exit" "$TIMEOUT_DIR/meta" 'cli_exit_code=124'
    if [ -f "$TIMEOUT_DIR/meta" ] && awk -F= '$1 == "duration_seconds" && $2 >= 1 { found=1 } END { exit !found }' "$TIMEOUT_DIR/meta"; then
        ok "timeout records elapsed seconds"; else fail "timeout records elapsed seconds"; fi
    if [ -f "$TIMEOUT_DIR/response.md" ]; then ok "timeout keeps even an empty response"; else fail "timeout keeps even an empty response"; fi

    # The reviewer leaves a child behind that ignores TERM and writes a file
    # 8s after start. The timeout (1s) must kill it (KILL after 5s grace),
    # exit 7 rather than 8, and return only once the child is gone.
    rm -f "$T/late"
    FAKE_CHILD="$T/late" FAKE_SLEEP=20 TANDEM_TIMEOUT=1 run auto
    expect_rc "timeout with a TERM-ignoring child -> 7" 7
    sleep 9
    if [ ! -e "$T/late" ]; then ok "TERM-ignoring child killed before return"; else fail "TERM-ignoring child killed before return" "child wrote after the timeout"; fi

    # The reviewer itself ignores TERM and has to be KILLed: still exit 7
    # (GNU timeout would report 137, which looked like a CLI failure).
    FAKE_IGNORE_TERM=1 FAKE_SLEEP=20 TANDEM_TIMEOUT=1 run auto
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
    FAKE_SLEEP=2 TANDEM_TIMEOUT=1 run auto
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
FAKE_RC=3 FAKE_TOUCH="$T/fail-add" PATH="$SHIM:$PATH" run auto
expect_rc "CLI and after-snapshot failure preserve exit 8" 8
expect_in "CLI and after-snapshot failure report uncertainty" "$T/err" 'verdict=CLI_FAILED questions=0 changed=unknown'
rm -f "$T/fail-add"

echo "targets and setup"
TANDEM_ROLE=codex run auto; expect_rc "auto as codex runs" 0
TANDEM_ROLE=claude TANDEM_CODEX_CMD="$T/does-not-exist" run auto; expect_rc "auto as claude needs codex -> 2 when missing" 2
EMPTY_BIN="$T/empty-bin"; mkdir -p "$EMPTY_BIN"
TANDEM_CODEX_CMD='' PATH="$EMPTY_BIN:/usr/bin:/bin" run codex; expect_rc "codex CLI missing -> 2" 2
case "$ERR" in *"Codex app is not enough"*"codex login status"*) ok "missing codex CLI explains how to install" ;; *) fail "missing codex CLI explains how to install" "$ERR" ;; esac
TANDEM_CLAUDE_CMD='' PATH="$EMPTY_BIN:/usr/bin:/bin" run claude; expect_rc "claude CLI missing -> 2" 2
case "$ERR" in *"Claude app is not enough"*) ok "missing claude CLI explains how to install" ;; *) fail "missing claude CLI explains how to install" "$ERR" ;; esac
TANDEM_ROLE=claude TANDEM_CLAUDE_CMD="$T/does-not-exist" run auto; expect_rc "auto as claude picks codex (claude CLI irrelevant)" 0
case "$ERR" in *"-r1-codex."*) ok "auto as claude dispatched to codex" ;; *) fail "auto as claude dispatched to codex" "$ERR" ;; esac
TANDEM_ROLE='' CLAUDECODE='' CODEX_SANDBOX='' CODEX_SANDBOX_NETWORK_DISABLED='' CODEX_THREAD_ID='' \
    CODEX_MANAGED_BY_NPM='' CODEX_MANAGED_BY_BUN='' CODEX_MANAGED_BY_PNPM='' run auto
expect_rc "auto with unknown role -> 2" 2
TANDEM_ROLE=claude run claude; expect_rc "explicit self-review runs" 0
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
RESP_PATH=$(printf '%s\n' "$ERR" | sed -n 's/.*response=//p' | tail -n1)
TREE=$(sed -n 's/^tree=//p' "$(dirname "$RESP_PATH")/meta")
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
SUMMARY="Adds the second line" FOCUS="Check the newline" ROUND=2 TANDEM_MAX_ROUNDS=4 run auto
expect_in "summary in prompt" "$T/prompt.txt" "Adds the second line"
expect_in "focus in prompt" "$T/prompt.txt" "Check the newline"
expect_in "round in prompt" "$T/prompt.txt" "Round: 2 of at most 4"
expect_in "no test command noted" "$T/prompt.txt" "none configured"
expect_in "response format embedded" "$T/prompt.txt" "## What I did NOT check"
TEST_CMD="make check" run auto
expect_in "TEST_CMD in prompt" "$T/prompt.txt" '`make check`'
printf 'test_cmd=npm test\n' > .tandem-review
run auto; expect_in ".tandem-review test_cmd used" "$T/prompt.txt" '`npm test`'
TEST_CMD="pytest -q" run auto; expect_in "TEST_CMD overrides .tandem-review" "$T/prompt.txt" '`pytest -q`'
rm -f .tandem-review
printf '## Verdict\nBLOCK\n\n## Findings\n- `a.txt:2` — PREVIOUS-MARKER\n' > "$T/prev.md"
PREV_RESPONSE="$T/prev.md" HUMAN_ANSWERS="Yes, keep the old API." run auto
expect_in "previous response in prompt" "$T/prompt.txt" "PREVIOUS-MARKER"
expect_in "human answers in prompt" "$T/prompt.txt" "Yes, keep the old API."
PREV_RESPONSE="$T/missing.md" run auto; expect_rc "missing PREV_RESPONSE only warns" 0
# ROUND follows from the meta file next to a recorded PREV_RESPONSE.
mkdir -p "$T/prev-run"; cp "$T/prev.md" "$T/prev-run/response.md"
printf 'target=codex\nround=2\nverdict=BLOCK\n' > "$T/prev-run/meta"
PREV_RESPONSE="$T/prev-run/response.md" run auto
expect_in "ROUND derived from PREV_RESPONSE meta" "$T/prompt.txt" "Round: 3 of at most 3"
ROUND=5 PREV_RESPONSE="$T/prev-run/response.md" run auto
expect_in "explicit ROUND wins over meta" "$T/prompt.txt" "Round: 5 of"
printf 'round=x\nverdict=APPROVE\n' > "$T/prev-run/meta"
PREV_RESPONSE="$T/prev-run/response.md" run auto
expect_in "bad meta round -> default 1" "$T/prompt.txt" "Round: 1 of"
PREV_RESPONSE="$T/prev.md" run auto
expect_in "PREV_RESPONSE outside a record -> default 1" "$T/prompt.txt" "Round: 1 of"
# A recorded run without a valid verdict is refused as the previous review.
for v in MALFORMED TIMEOUT CLI_FAILED ''; do
    printf 'round=2\nverdict=%s\n' "$v" > "$T/prev-run/meta"; rm -f "$T/prompt.txt"
    PREV_RESPONSE="$T/prev-run/response.md" ROUND=3 run auto
    expect_rc "PREV_RESPONSE with verdict='$v' -> 1" 1
    if [ ! -e "$T/prompt.txt" ]; then ok "reviewer not started with verdict='$v'"; else fail "reviewer not started with verdict='$v'"; fi
done
case "$ERR" in *"verdict=none"*) ok "refusal names the bad verdict" ;; *) fail "refusal names the bad verdict" "$ERR" ;; esac
# Real failed run end to end: its response cannot be the next PREV_RESPONSE.
respond '## Verdict\nAPPROVE\n'; FAKE_RC=3 run auto
FAILED_RESP=$(printf '%s\n' "$ERR" | sed -n 's/.*response=//p' | tail -n1)
PREV_RESPONSE="$FAILED_RESP" run auto; expect_rc "recorded CLI_FAILED response refused -> 1" 1

echo "extra CLI arguments"
# Fake claude/codex in PATH that record their arguments, for the default
# (non-TANDEM_*_CMD) invocations.
ARGS_BIN="$T/args-bin"; mkdir -p "$ARGS_BIN"
for cli in claude codex; do
    cat > "$ARGS_BIN/$cli" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FAKE_DIR/args.txt"
cat > "$FAKE_DIR/prompt.txt"
# codex writes its final message to the file after -o.
out=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
if [ -n "$out" ]; then cat "$FAKE_DIR/response.md" > "$out"; else cat "$FAKE_DIR/response.md"; fi
EOF
    chmod +x "$ARGS_BIN/$cli"
done
respond '## Verdict\nAPPROVE\n'
TANDEM_CODEX_CMD='' TANDEM_CODEX_ARGS="-m test-model  -c model_reasoning_effort=high" PATH="$ARGS_BIN:$PATH" run codex
expect_rc "codex with extra args -> 0" 0
expect_in "codex gets extra args" "$T/args.txt" "test-model"
expect_in "codex extra args split on whitespace" "$T/args.txt" "model_reasoning_effort=high"
expect_in "codex keeps its permission profile" "$T/args.txt" 'default_permissions="tandem_reviewer"'
expect_in "codex keeps --ignore-user-config" "$T/args.txt" "--ignore-user-config"
TANDEM_CLAUDE_CMD='' TANDEM_CLAUDE_ARGS="--model test-model" PATH="$ARGS_BIN:$PATH" run claude
expect_rc "claude with extra args -> 0" 0
expect_in "claude gets extra args" "$T/args.txt" "test-model"
expect_in "claude keeps --restricted" "$T/args.txt" "--restricted"
expect_in "claude keeps --strict-mcp-config" "$T/args.txt" "--strict-mcp-config"
TANDEM_CLAUDE_CMD='' PATH="$ARGS_BIN:$PATH" run claude
expect_rc "claude without extra args (empty array, bash 3.2) -> 0" 0
TANDEM_CODEX_CMD='' TANDEM_CODEX_ARGS=$'-m test-model\n-c second-line-arg' PATH="$ARGS_BIN:$PATH" run codex
expect_in "multiline extra args: all lines used" "$T/args.txt" "second-line-arg"
TANDEM_CODEX_ARGS="--marker-arg" TANDEM_CODEX_CMD="$ARGS_BIN/codex" run codex
expect_in "extra args appended to TANDEM_CODEX_CMD" "$T/args.txt" "--marker-arg"
TANDEM_CLAUDE_ARGS="*" TANDEM_CLAUDE_CMD="$ARGS_BIN/claude" run claude
if [ "$(cat "$T/args.txt")" = "*" ]; then ok "extra args are not globbed"; else fail "extra args are not globbed" "$(cat "$T/args.txt")"; fi

echo "recording and change detection"
rm -rf "$T/log"
ROUND=3 run auto
RESP_PATH=$(printf '%s\n' "$ERR" | sed -n 's/.*response=//p' | tail -n1)
if [ -f "$RESP_PATH" ] && grep -q '^## Verdict' "$RESP_PATH"; then ok "response path in status line exists"; else fail "response path in status line exists" "$RESP_PATH"; fi
for f in prompt.md response.md cli.log review.diff meta; do
    if ls "$T"/log/*-r3-claude.*/"$f" >/dev/null 2>&1; then ok "recorded $f"; else fail "recorded $f"; fi
done
expect_in "successful review records script exit" "$(dirname "$RESP_PATH")/meta" 'exit_code=0'
expect_in "successful review records raw CLI exit" "$(dirname "$RESP_PATH")/meta" 'cli_exit_code=0'
expect_in "successful review still prints its response" "$T/out" '## Verdict'
# Two rounds in the same second with the same round number and reviewer
# must not overwrite each other.
respond '## Verdict\nAPPROVE\n\n## Reason\nFIRST\n'; ROUND=7 run auto
P1=$(printf '%s\n' "$ERR" | sed -n 's/.*response=//p' | tail -n1)
respond '## Verdict\nAPPROVE\n\n## Reason\nSECOND\n'; ROUND=7 run auto
P2=$(printf '%s\n' "$ERR" | sed -n 's/.*response=//p' | tail -n1)
if [ "$P1" != "$P2" ] && grep -q FIRST "$P1" && grep -q SECOND "$P2"; then
    ok "same round twice in a row keeps both records"; else fail "same round twice in a row keeps both records" "$P1 / $P2"; fi
respond '## Verdict\nAPPROVE\n'
TANDEM_LOG=0 TANDEM_LOG_DIR="$T/nolog" run auto
if [ ! -d "$T/nolog" ]; then ok "TANDEM_LOG=0 records nothing"; else fail "TANDEM_LOG=0 records nothing"; fi
RESP_PATH=$(printf '%s\n' "$ERR" | sed -n 's/.*response=//p' | tail -n1)
if [ -f "$RESP_PATH" ]; then ok "TANDEM_LOG=0 still keeps the response for PREV_RESPONSE"; rm -f "$RESP_PATH"; else fail "TANDEM_LOG=0 still keeps the response"; fi
FAKE_RC=3 TANDEM_LOG=0 TANDEM_LOG_DIR="$T/nolog" run auto
expect_rc "TANDEM_LOG=0 also preserves CLI failure exit" 8
if [ ! -d "$T/nolog" ]; then ok "TANDEM_LOG=0 disables failed-round records too"; else fail "TANDEM_LOG=0 disables failed-round records too"; fi
RESP_PATH=$(printf '%s\n' "$ERR" | sed -n 's/.*response=//p' | tail -n1)
if [ -f "$RESP_PATH" ]; then ok "TANDEM_LOG=0 keeps failed response too"; rm -f "$RESP_PATH"; else fail "TANDEM_LOG=0 keeps failed response too"; fi

# A recording failure must not mask the review/CLI result or delete diagnostics.
printf 'not a directory\n' > "$T/blocked-log"
mkdir -p "$T/recording-tmp"
FAKE_RC=3 TANDEM_LOG_DIR="$T/blocked-log" TMPDIR="$T/recording-tmp" run auto
expect_rc "log directory failure preserves CLI exit 8" 8
expect_in "log directory failure warns" "$T/err" 'could not save review records'
RESP_PATH=$(printf '%s\n' "$ERR" | sed -n 's/.*response=//p' | tail -n1)
FALLBACK_DIR=$(dirname "${RESP_PATH:-$T/missing/response.md}")
for f in response.md cli.log prompt.md review.diff meta; do
    if [ -f "$FALLBACK_DIR/$f" ]; then ok "recording failure retains $f"; else fail "recording failure retains $f"; fi
done
TANDEM_LOG_DIR="$T/blocked-log" TMPDIR="$T/recording-tmp" run auto
expect_rc "log directory failure preserves APPROVE exit 0" 0

# Also retain temporary output when the response-only save cannot be created.
REAL_MKTEMP=$(command -v mktemp)
mkdir -p "$T/mktemp-shim"
cat > "$T/mktemp-shim/mktemp" <<EOF
#!/usr/bin/env bash
case "\$*" in *tandem-response.*) exit 1 ;; esac
exec "$REAL_MKTEMP" "\$@"
EOF
chmod +x "$T/mktemp-shim/mktemp"
FAKE_RC=3 TANDEM_LOG=0 PATH="$T/mktemp-shim:$PATH" TMPDIR="$T/recording-tmp" run auto
expect_rc "response-only save failure preserves CLI exit 8" 8
expect_in "response-only save failure warns" "$T/err" 'could not save review records'
RESP_PATH=$(printf '%s\n' "$ERR" | sed -n 's/.*response=//p' | tail -n1)
if [ -f "$RESP_PATH" ]; then ok "response-only save failure retains the response"; else fail "response-only save failure retains the response"; fi

FAKE_TOUCH="$REPO/b.txt" run auto
case "$ERR" in *"changed=yes"*) ok "modification during review detected" ;; *) fail "modification during review detected" "$ERR" ;; esac
expect_rc "verdict exit kept despite change" 0

echo "codex permission profile"
# A fake `codex` on PATH stands in for the default call (no TANDEM_CODEX_CMD):
# it records its arguments and environment and answers via -o.
FAKEBIN="$T/fakebin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/codex" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FAKE_DIR/codex-args.txt"
printf 'GIT_CONFIG_GLOBAL=%s\nTMPDIR=%s\n' "${GIT_CONFIG_GLOBAL:-}" "${TMPDIR:-}" > "$FAKE_DIR/codex-env.txt"
cat > /dev/null
while [ $# -gt 0 ]; do
    if [ "$1" = -o ]; then printf '## Verdict\nAPPROVE\n' > "$2"; fi
    shift
done
EOF
chmod +x "$FAKEBIN/codex"
# run_codex — default codex call through the fake.
run_codex() { TANDEM_CODEX_CMD='' PATH="$FAKEBIN:$PATH" run codex; }
profile() { sed -n 's/^permissions\.tandem_reviewer\.filesystem=//p' "$T/codex-args.txt"; }
expect_profile() { # <name> <fixed string>
    if profile | grep -qF -- "$2"; then ok "$1"; else fail "$1" "'$2' not in $(profile)"; fi
}

new_repo
TOP_ABS=$(pwd -P)
run_codex; expect_rc "default codex call runs" 0
if grep -qxE -- '-s|--sandbox|workspace-write' "$T/codex-args.txt"; then
    fail "no -s (it would silently disable the profile)"; else ok "no -s (it would silently disable the profile)"; fi
expect_in "profile selected" "$T/codex-args.txt" 'default_permissions="tandem_reviewer"'
expect_in "approval policy never" "$T/codex-args.txt" 'approval_policy="never"'
expect_in "user config ignored" "$T/codex-args.txt" '--ignore-user-config'
expect_profile ":minimal readable" '":minimal"="read"'
expect_profile "repo writable" "\"$TOP_ABS\"=\"write\""
expect_profile "/tmp denied" '"/tmp"="deny"'
RTMP=$(sed -n 's/^TMPDIR=//p' "$T/codex-env.txt")
if [ -n "$RTMP" ] && [ "$RTMP" != /tmp ] && profile | grep -qF "$(cd "$(dirname "$RTMP")" && pwd -P)/$(basename "$RTMP")\"=\"write\""; then
    ok "private TMPDIR, writable"; else fail "private TMPDIR, writable" "TMPDIR=$RTMP; $(profile)"; fi
if [ -n "$RTMP" ] && [ ! -e "$RTMP" ]; then ok "private TMPDIR removed afterwards"; else fail "private TMPDIR removed afterwards" "$RTMP"; fi
expect_in "GIT_CONFIG_GLOBAL=/dev/null" "$T/codex-env.txt" "GIT_CONFIG_GLOBAL=/dev/null"
if profile | grep -qF "$HOME\""; then fail "home directory not in profile"; else ok "home directory not in profile"; fi

for bad in "-s danger-full-access" "--sandbox=workspace-write" "-c sandbox_mode=danger-full-access" \
           "-c default_permissions=x" "--dangerously-bypass-approvals-and-sandbox" "--full-auto"; do
    rm -f "$T/codex-args.txt"
    TANDEM_CODEX_ARGS="$bad" run_codex
    if [ "$RC" -eq 1 ] && [ ! -e "$T/codex-args.txt" ]; then ok "TANDEM_CODEX_ARGS '$bad' refused"
    else fail "TANDEM_CODEX_ARGS '$bad' refused" "exit $RC"; fi
done
TANDEM_CODEX_ARGS="-m some-model -c model_reasoning_effort=high" run_codex
expect_rc "harmless TANDEM_CODEX_ARGS still allowed" 0

mkdir -p "$T/tools one" "$T/tools2" "$T/home/.nvm" "$T/quo\"te"
# The script writes resolved paths (on macOS $TMPDIR is under the /var
# symlink and ends in a slash).
TR=$(cd "$T" && pwd -P)
TANDEM_CODEX_READ="$T/tools one:$T/tools2:$T/quo\"te" run_codex
expect_profile "TANDEM_CODEX_READ dir with space" "\"$TR/tools one\"=\"read\""
expect_profile "TANDEM_CODEX_READ second dir" "\"$TR/tools2\"=\"read\""
expect_profile "quote in path escaped for TOML" "\"$TR/quo\\\"te\"=\"read\""
printf 'test_cmd=./t.sh\ncodex_read=~/.nvm\ncodex_read=%s/missing\n' "$T" > .tandem-review
HOME="$T/home" run_codex
expect_profile "codex_read with ~/ from .tandem-review" "\"$TR/home/.nvm\"=\"read\""
case "$ERR" in *"codex_read path"*"missing"*"skipped"*) ok "missing codex_read path warned and skipped" ;; *) fail "missing codex_read path warned and skipped" "$ERR" ;; esac
if profile | grep -qF "/missing\""; then fail "missing path not in profile"; else ok "missing path not in profile"; fi
rm -f .tandem-review

# A linked worktree keeps its git directory in the main repository.
git add -A && git commit -qm wip2
git worktree add -q "$T/wt" 2>/dev/null
(cd "$T/wt" && printf 'wt change\n' >> a.txt && TANDEM_CODEX_CMD='' PATH="$FAKEBIN:$PATH" "$REVIEW" codex >/dev/null 2>&1)
RC=$?; expect_rc "review in a linked worktree" 0
expect_profile "main repo's git dir readable from a worktree" "\"$TOP_ABS/.git\"=\"read\""

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
