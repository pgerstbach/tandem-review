#!/usr/bin/env bash
# review.sh — have another coding agent review the current working tree
#
# Usage:
#   scripts/review.sh <claude|codex|auto> [base-ref]
#
#   target    claude | codex | auto   (auto = the agent that is not you)
#   base-ref  what to diff against (default: HEAD, i.e. only uncommitted
#             changes). Use e.g. `main` to review everything since the
#             branch point, committed or not.
#
# The reviewer runs LIVE in this repository's working directory. Nothing has
# to be committed: the script snapshots the working tree (tracked changes plus
# untracked, non-ignored files) as a git tree object, without touching your
# index, branches or files, and asks the reviewer to review `git diff <base>
# <snapshot>`. After the review it snapshots again and warns if anything in
# the working tree changed meanwhile.
#
# Inputs (env, all optional):
#   SUMMARY         what the change does and why (written by the implementer)
#   FOCUS           what the reviewer should look at in particular
#   TEST_CMD        test command the reviewer may run (default: `test_cmd=`
#                   line in .agent-review at the repo root)
#   ROUND           review round number, shown to the reviewer (default 1)
#   PREV_RESPONSE   path to the previous round's response
#   HUMAN_ANSWERS   the human's answers to the previous round's questions
#
# Knobs (env):
#   ARL_MAX_ROUNDS  round limit shown to the reviewer (default 3)
#   ARL_TIMEOUT     seconds before the reviewer and all its child processes
#                   are killed (default 1200, 0 = none; needs perl, without
#                   perl there is no limit and a warning)
#   ARL_ROLE        your own role (claude|codex) if auto-detection fails
#   ARL_LOG_DIR     where rounds are recorded (default <git-dir>/agent-review)
#   ARL_LOG=0       do not record rounds
#   ARL_CLAUDE_CMD  replace the claude invocation (prompt on stdin,
#   ARL_CODEX_CMD   response on stdout; whitespace-split, no quoting)
#
# Output: the review on stdout; one status line on stderr:
#   agent-review: verdict=<V> questions=<n> changed=<yes|no|unknown> response=<path>
#   CLI failures use verdict=TIMEOUT or CLI_FAILED, never a partial verdict.
#   Every dispatched run is checked for changes and recorded (unless ARL_LOG=0),
#   including full CLI output, script/CLI exit codes and CLI elapsed seconds.
#   On recording errors, temporary output is retained and the exit code is kept.
#
# Exit codes:
#   0   APPROVE
#   10  CONCERNS
#   20  BLOCK
#   30  reviewer has questions for the human (any valid verdict)
#   6   response has no valid verdict (malformed)
#   7   reviewer timed out
#   8   reviewer CLI failed
#   1   usage error, not a git repo, unknown base, nothing to review,
#       working tree could not be snapshotted
#   2   reviewer CLI not installed / no target for auto

set -euo pipefail

usage() {
    sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 1
}

TARGET="${1:-}"
BASE="${2:-HEAD}"
[ -n "$TARGET" ] || usage
case "$TARGET" in claude|codex|auto) ;; -h|--help) usage ;; *)
    echo "Error: unknown target '$TARGET' (use claude, codex or auto)" >&2; exit 1 ;;
esac

SKILL_DIR=$(cd "$(dirname "$0")/.." && pwd)

TOP=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "Error: not inside a git repository" >&2; exit 1; }
cd "$TOP"

BASE_SHA=$(git rev-parse --verify --quiet "$BASE^{commit}") || {
    echo "Error: base ref '$BASE' does not exist" >&2; exit 1; }

# --- role and target --------------------------------------------------------

detect_role() {
    if [ -n "${ARL_ROLE:-}" ]; then echo "$ARL_ROLE"; return; fi
    if [ "${CLAUDECODE:-}" = "1" ]; then echo claude; return; fi
    # Codex sets these in the environment of the commands it runs.
    if [ -n "${CODEX_SANDBOX:-}${CODEX_SANDBOX_NETWORK_DISABLED:-}${CODEX_THREAD_ID:-}${CODEX_MANAGED_BY_NPM:-}${CODEX_MANAGED_BY_BUN:-}${CODEX_MANAGED_BY_PNPM:-}" ]; then
        echo codex; return
    fi
    echo unknown
}

cmd_for() {
    case "$1" in
        claude) echo "${ARL_CLAUDE_CMD:-claude}" ;;
        codex)  echo "${ARL_CODEX_CMD:-codex}" ;;
    esac
}

installed() {
    local cmd
    cmd=$(cmd_for "$1")
    command -v "${cmd%% *}" >/dev/null 2>&1
}

ROLE=$(detect_role)
if [ "$TARGET" = "auto" ]; then
    case "$ROLE" in
        claude) TARGET=codex ;;
        codex)  TARGET=claude ;;
        *)
            echo "Error: cannot tell whether you are claude or codex — set ARL_ROLE or name the target." >&2
            exit 2 ;;
    esac
fi
if ! installed "$TARGET"; then
    echo "Error: '$(cmd_for "$TARGET")' not found in PATH (target '$TARGET')." >&2
    exit 2
fi
if [ "$TARGET" = "$ROLE" ]; then
    echo "Warning: '$TARGET' is reviewing its own model's work. A fresh context still helps, but shared blind spots stay blind — mention this to the human." >&2
fi

# --- snapshot ---------------------------------------------------------------

# snapshot — print a tree hash of the working tree: tracked files as they are
# on disk plus untracked, non-ignored files. Uses a throwaway index, so the
# real index (staged state) is never touched. The tree object lands in the
# object store unreferenced; `git gc` prunes it after its grace period.
# Every step is checked explicitly: errexit does not apply inside $(...),
# and a failed `git add` would otherwise leave the copied real index in
# place and silently snapshot a stale state.
snapshot() {
    local idx tree
    idx=$(mktemp "${TMPDIR:-/tmp}/arl-index.XXXXXX") || return 1
    # Start from the real index so unchanged files keep their stat cache.
    cp "$(git rev-parse --git-path index)" "$idx" 2>/dev/null || rm -f "$idx"
    if ! GIT_INDEX_FILE="$idx" git add -A >/dev/null; then
        rm -f "$idx"; return 1
    fi
    if ! tree=$(GIT_INDEX_FILE="$idx" git write-tree); then
        rm -f "$idx"; return 1
    fi
    rm -f "$idx"
    [ -n "$tree" ] || return 1
    echo "$tree"
}

TREE=$(snapshot) || {
    echo "Error: could not snapshot the working tree (see the git error above)." >&2
    exit 1
}

if git diff --quiet "$BASE_SHA" "$TREE"; then
    echo "Error: nothing to review — no difference between '$BASE' and the working tree." >&2
    exit 1
fi

STAT=$(git diff --stat "$BASE_SHA" "$TREE")
DIFF_CMD="git diff $BASE_SHA $TREE"

# --- test command -----------------------------------------------------------

if [ -z "${TEST_CMD:-}" ] && [ -f .agent-review ]; then
    # Read, never source: the file is data.
    TEST_CMD=$(sed -n 's/^test_cmd=//p' .agent-review | head -n1)
fi
TEST_CMD="${TEST_CMD:-}"
if [ -n "$TEST_CMD" ]; then
    TEST_LINE="\`$TEST_CMD\`"
else
    TEST_LINE="none configured — do not run tests"
fi

# --- prompt -----------------------------------------------------------------

ROUND="${ROUND:-1}"
ARL_MAX_ROUNDS="${ARL_MAX_ROUNDS:-3}"

PROMPT="$(cat "$SKILL_DIR/templates/request.md")

## Review context

- Round: $ROUND of at most $ARL_MAX_ROUNDS
- Base: \`$BASE\` ($BASE_SHA)
- Snapshot of the working tree: tree $TREE
- Get the diff with exactly: \`$DIFF_CMD\`
  (also allowed: \`git diff --stat $BASE_SHA $TREE\`, and
  \`$DIFF_CMD -- <path>\` for single files)
- Test command: $TEST_LINE

### Changed files
\`\`\`\`
$STAT
\`\`\`\`

### Summary from the implementer
${SUMMARY:-(none given)}

### Focus requested by the implementer
${FOCUS:-(none — open review)}
"

if [ -n "${HUMAN_ANSWERS:-}" ]; then
    PROMPT="$PROMPT
### Answers from the human to the previous round's questions
These come from the human who owns this change; treat them as requirements.

$HUMAN_ANSWERS
"
fi

if [ -n "${PREV_RESPONSE:-}" ]; then
    if [ -f "$PREV_RESPONSE" ]; then
        PROMPT="$PROMPT
### Previous round's review
\`\`\`\`markdown
$(cat "$PREV_RESPONSE")
\`\`\`\`
"
    else
        echo "Warning: PREV_RESPONSE '$PREV_RESPONSE' not found — sending without it." >&2
    fi
fi

PROMPT="$PROMPT
## Response format

$(cat "$SKILL_DIR/templates/response.md")
"

# --- dispatch ---------------------------------------------------------------

ARL_TIMEOUT="${ARL_TIMEOUT:-1200}"

# run_bounded <seconds> <cmd...> — run under a time limit. The command runs
# in its own process group; on expiry the whole group gets TERM, then KILL
# after 5s, and the function returns only once no member is left — so no
# reviewer child (even one that ignores TERM) can keep changing files after
# a timeout. Expiry always exits 124. Implemented in perl (ships with macOS
# and practically every Linux with git) because GNU timeout returns as soon
# as its direct child exits, leaving TERM-ignoring grandchildren alive, and
# exits 137 instead of 124 when it has to KILL.
run_bounded() {
    local t="$1"; shift
    if [ "$t" = "0" ] || ! command -v perl >/dev/null 2>&1; then "$@"; return; fi
    perl -e '
        use POSIX ":sys_wait_h";
        use Time::HiRes qw(time sleep);
        my $t = shift;
        my $pid = fork() // die "fork: $!\n";
        if ($pid == 0) { setpgrp(0, 0); exec { $ARGV[0] } @ARGV; exit 127 }
        setpgrp($pid, $pid);    # also in the parent, so no race with kill
        my $end = time + $t;
        while (time < $end) {
            if (waitpid($pid, WNOHANG) == $pid) {
                exit(($? & 127) ? 128 + ($? & 127) : $? >> 8);
            }
            sleep 0.1;
        }
        # gone: true once no process of the group is left (reaps the main
        # child first so its zombie does not count).
        my $gone = sub { waitpid($pid, WNOHANG); return !kill(0, -$pid) };
        my $wait_gone = sub {
            my $until = time + shift;
            while (time < $until) { return 1 if $gone->(); sleep 0.1 }
            return $gone->();
        };
        kill "TERM", -$pid;
        unless ($wait_gone->(5)) { kill "KILL", -$pid; $wait_gone->(5) }
        exit 124;
    ' "$t" "$@"
}

# Warn here, not in run_bounded: its stderr goes to the CLI log.
if [ "$ARL_TIMEOUT" != "0" ] && ! command -v perl >/dev/null 2>&1; then
    echo "Warning: perl not found — running the reviewer without a time limit (ARL_TIMEOUT ignored)." >&2
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/arl-run.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
RESP="$WORK/response.md"
CLI_LOG="$WORK/cli.log"
: > "$RESP"

# Exported for custom ARL_*_CMD wrappers.
export ARL_BASE_SHA="$BASE_SHA" ARL_TREE="$TREE" ARL_TEST_CMD="$TEST_CMD"

rc=0
STARTED=$SECONDS
case "$TARGET" in
    claude)
        if [ -n "${ARL_CLAUDE_CMD:-}" ]; then
            # shellcheck disable=SC2086
            printf '%s\n' "$PROMPT" | run_bounded "$ARL_TIMEOUT" $ARL_CLAUDE_CMD > "$RESP" 2> "$CLI_LOG" || rc=$?
        else
            # --restricted confines file tools to the working directory and
            # removes code-running tools unless named; Bash is then limited
            # to the exact commands below. Exact rules, not `git diff *`:
            # a wildcard would also allow `git diff --output=<file>`.
            # --permission-prompts none denies anything else immediately
            # instead of waiting for an approval nobody can give.
            allowed=(Read Grep Glob
                "Bash($DIFF_CMD)"
                "Bash(git diff --stat $BASE_SHA $TREE)"
                "Bash($DIFF_CMD -- *)")
            [ -n "$TEST_CMD" ] && allowed+=("Bash($TEST_CMD)")
            printf '%s\n' "$PROMPT" | run_bounded "$ARL_TIMEOUT" claude -p \
                --restricted --strict-mcp-config --no-session-persistence \
                --permission-prompts none \
                --tools "Read,Grep,Glob,Bash" --allowedTools "${allowed[@]}" \
                > "$RESP" 2> "$CLI_LOG" || rc=$?
        fi
        ;;
    codex)
        if [ -n "${ARL_CODEX_CMD:-}" ]; then
            # shellcheck disable=SC2086
            printf '%s\n' "$PROMPT" | run_bounded "$ARL_TIMEOUT" $ARL_CODEX_CMD > "$RESP" 2> "$CLI_LOG" || rc=$?
        else
            # workspace-write: tests may write caches/build output in the
            # repo; network stays off. --ignore-user-config skips user MCP
            # servers (extra tools, and they can hang non-interactive runs).
            # -o captures the final message; the session log goes to CLI_LOG.
            printf '%s\n' "$PROMPT" | run_bounded "$ARL_TIMEOUT" codex exec \
                --ephemeral --ignore-user-config \
                -s workspace-write -c 'approval_policy="never"' \
                -C "$TOP" -o "$RESP" - \
                > "$CLI_LOG" 2>&1 || rc=$?
        fi
        ;;
esac
DURATION=$((SECONDS - STARTED))

out=0
if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 124 ]; then
        echo "Error: $TARGET timed out after ${ARL_TIMEOUT}s (ARL_TIMEOUT)." >&2
        out=7
    else
        echo "Error: $TARGET exited with code $rc." >&2
        out=8
    fi
    if [ -s "$CLI_LOG" ] || [ -s "$RESP" ]; then
        echo "Last output from the CLI:" >&2
        cat "$CLI_LOG" "$RESP" 2>/dev/null | tail -n 20 >&2
    fi
fi

# --- evaluate ---------------------------------------------------------------

# Did the working tree change while the reviewer ran?
CHANGED=no
if ! TREE_AFTER=$(snapshot); then
    CHANGED=unknown
    TREE_AFTER=""
    echo "Warning: could not snapshot the working tree after the review — changes during the review cannot be ruled out." >&2
elif [ "$TREE_AFTER" != "$TREE" ]; then
    CHANGED=yes
    echo "Warning: the working tree changed during the review (by the reviewer or someone else):" >&2
    git diff --stat "$TREE" "$TREE_AFTER" >&2 || true
fi

# Code fences, CommonMark style: an opening run of >= 3 backticks or tildes
# (indented at most 3 spaces) is closed only by a run of the same character
# that is at least as long and has nothing after it. Lines inside a fence
# are invisible to both parsers below, so quoted examples never count.
# shellcheck disable=SC2016  # awk code, not shell
FENCE_AWK='
function fence(line,   ind, c, n, rest) {
    ind = 0
    while (substr(line, 1, 1) == " " && ind < 4) { line = substr(line, 2); ind++ }
    if (ind > 3) return 0
    c = substr(line, 1, 1)
    if (c != "`" && c != "~") return 0
    n = 0
    while (substr(line, n + 1, 1) == c) n++
    if (n < 3) return 0
    rest = substr(line, n + 1)
    if (!infence) {
        if (c == "`" && index(rest, "`")) return 0
        infence = 1; fch = c; flen = n
        return 1
    }
    if (c == fch && n >= flen && rest ~ /^[ \t]*$/) { infence = 0; return 1 }
    return 0
}
fence($0) { next }
infence { next }
'

# Verdict: the first non-empty line after a `Verdict` heading (or the rest
# of the heading line, e.g. "## Verdict: BLOCK") must be exactly one verdict,
# ignoring markdown emphasis. The unfilled template "<APPROVE | CONCERNS |
# BLOCK>" does not qualify. Headings inside code fences are ignored.
VERDICT=$(awk "$FENCE_AWK"'
    !found && /^#+[[:space:]]*Verdict/ {
        found = 1
        rest = $0; sub(/^#+[[:space:]]*Verdict[[:space:]]*:?/, "", rest)
        if (rest ~ /[^[:space:]]/) { print rest; exit }
        next
    }
    found && /[^[:space:]]/ { print; exit }
' "$RESP" | tr -d '*_`' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:].!]*$//')
case "$VERDICT" in APPROVE|CONCERNS|BLOCK) ;; *) VERDICT="" ;; esac

# Questions: bullets under "## Questions for the human" up to the next
# heading of level 1-2 or a horizontal rule. A bullet is a placeholder only
# if it is nothing but a "none" marker — "none", "(none)", "n/a", "- none —
# all clear", "<...>". Anything with a question mark, or any other text
# (e.g. "(None of the callers handle null) — is that valid"), counts: when
# in doubt, ask the human.
QUESTIONS=$(awk "$FENCE_AWK"'
    /^##?[[:space:]]/ { inq = ($0 ~ /^##?[[:space:]]*Questions for the human/); next }
    /^(---|\*\*\*|___)[[:space:]]*$/ { inq = 0; next }
    !inq { next }
    /^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]+/ {
        c = $0
        sub(/^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]+/, "", c)
        gsub(/[*_`]/, "", c)
        c = tolower(c)
        sub(/^[[:space:]]+/, "", c); sub(/[[:space:].!:]+$/, "", c)
        if (index(c, "?")) { n++; next }
        if (c ~ /^<.*>$/) next
        if (c ~ /^\(.*\)$/ || c ~ /^\[.*\]$/) {
            c = substr(c, 2, length(c) - 2)
            sub(/^[[:space:]]+/, "", c); sub(/[[:space:].!:]+$/, "", c)
        }
        if (c ~ /^(none|n\/a|na|no|nothing|-|—|no questions?( for the human)?|none at this time|no open questions|not applicable)$/) next
        if (c ~ /^none[[:space:]]*(—|–|-|:|,|;)/) next
        n++
    }
    END { print n + 0 }
' "$RESP")

# A failing CLI may have printed a partial response, even APPROVE/questions.
# Keep that output for diagnosis, but do not treat it as a review result.
if [ "$rc" -ne 0 ]; then
    VERDICT=CLI_FAILED
    [ "$out" -eq 7 ] && VERDICT=TIMEOUT
    QUESTIONS=0
elif [ -z "$VERDICT" ]; then
    VERDICT=MALFORMED
    out=6
    echo "Warning: no valid verdict in the response — treat it as malformed." >&2
elif [ "$QUESTIONS" -gt 0 ]; then
    out=30
else
    case "$VERDICT" in
        APPROVE)  out=0 ;;
        CONCERNS) out=10 ;;
        BLOCK)    out=20 ;;
    esac
fi

# --- record -----------------------------------------------------------------

# All commands must be checked explicitly: the caller tests this function,
# which disables errexit inside it. Prepare artifacts before copying so a
# bad log directory still leaves the full diagnostics in WORK.
record_round() {
    local log_dir run_log
    printf '%s\n' "$PROMPT" > "$WORK/prompt.md" &&
    git diff "$BASE_SHA" "$TREE" > "$WORK/review.diff" &&
    printf 'target=%s\nround=%s\nbase=%s\nbase_sha=%s\ntree=%s\ntree_after=%s\nchanged=%s\nverdict=%s\nquestions=%s\nexit_code=%s\ncli_exit_code=%s\nduration_seconds=%s\n' \
        "$TARGET" "$ROUND" "$BASE" "$BASE_SHA" "$TREE" "$TREE_AFTER" "$CHANGED" "$VERDICT" "$QUESTIONS" "$out" "$rc" "$DURATION" > "$WORK/meta" &&
    log_dir="${ARL_LOG_DIR:-$(git rev-parse --absolute-git-dir)/agent-review}" &&
    mkdir -p "$log_dir" &&
    run_log=$(mktemp -d "$log_dir/$(date +%Y%m%dT%H%M%S)-r$ROUND-$TARGET.XXXXXX") &&
    cp "$RESP" "$CLI_LOG" "$WORK/prompt.md" "$WORK/review.diff" "$WORK/meta" "$run_log/" || return 1
    SAVED="$run_log/response.md"
}

RECORDED=no
if [ "${ARL_LOG:-1}" != "0" ]; then
    if record_round; then RECORDED=yes; fi
elif SAVED=$(mktemp "${TMPDIR:-/tmp}/arl-response.XXXXXX") && cp "$RESP" "$SAVED"; then
    RECORDED=yes
fi
if [ "$RECORDED" = no ]; then
    SAVED="$RESP"
    trap - EXIT
    echo "Warning: could not save review records; temporary output retained in $WORK." >&2
fi

if [ "$rc" -eq 0 ]; then cat "$RESP"; fi
echo "agent-review: verdict=$VERDICT questions=$QUESTIONS changed=$CHANGED response=$SAVED" >&2
exit "$out"
