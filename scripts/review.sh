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
#   ARL_TIMEOUT     seconds before the reviewer is killed (default 1200, 0 = none)
#   ARL_ROLE        your own role (claude|codex) if auto-detection fails
#   ARL_LOG_DIR     where rounds are recorded (default <git-dir>/agent-review)
#   ARL_LOG=0       do not record rounds
#   ARL_CLAUDE_CMD  replace the claude invocation (prompt on stdin,
#   ARL_CODEX_CMD   response on stdout; whitespace-split, no quoting)
#
# Output: the review on stdout; one status line on stderr:
#   agent-review: verdict=<V> questions=<n> changed=<yes|no> response=<path>
#
# Exit codes:
#   0   APPROVE
#   10  CONCERNS
#   20  BLOCK
#   30  reviewer has questions for the human (any valid verdict)
#   6   response has no valid verdict (malformed)
#   7   reviewer timed out
#   8   reviewer CLI failed
#   1   usage error, not a git repo, unknown base, nothing to review
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
snapshot() {
    local idx tree
    idx=$(mktemp "${TMPDIR:-/tmp}/arl-index.XXXXXX")
    # Start from the real index so unchanged files keep their stat cache.
    cp "$(git rev-parse --git-path index)" "$idx" 2>/dev/null || rm -f "$idx"
    GIT_INDEX_FILE="$idx" git add -A >/dev/null 2>&1
    tree=$(GIT_INDEX_FILE="$idx" git write-tree)
    rm -f "$idx"
    echo "$tree"
}

TREE=$(snapshot)

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

# run_bounded <seconds> <cmd...> — timeout(1), gtimeout, or perl alarm on
# systems without coreutils (macOS). Expiry exits 124 (timeout) or 142 (perl).
run_bounded() {
    local t="$1"; shift
    if [ "$t" = "0" ]; then "$@"; return; fi
    if command -v timeout >/dev/null 2>&1; then timeout "$t" "$@"
    elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$t" "$@"
    elif command -v perl >/dev/null 2>&1; then perl -e 'alarm shift; exec @ARGV' "$t" "$@"
    else "$@"
    fi
}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/arl-run.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
RESP="$WORK/response.md"
CLI_LOG="$WORK/cli.log"
: > "$RESP"

# Exported for custom ARL_*_CMD wrappers.
export ARL_BASE_SHA="$BASE_SHA" ARL_TREE="$TREE" ARL_TEST_CMD="$TEST_CMD"

rc=0
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

if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 142 ]; then
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
    exit "$out"
fi

# --- evaluate ---------------------------------------------------------------

# Did the working tree change while the reviewer ran?
TREE_AFTER=$(snapshot)
CHANGED=no
if [ "$TREE_AFTER" != "$TREE" ]; then
    CHANGED=yes
    echo "Warning: the working tree changed during the review (by the reviewer or someone else):" >&2
    git diff --stat "$TREE" "$TREE_AFTER" >&2 || true
fi

# Verdict: the first non-empty line after a `Verdict` heading (or the rest
# of the heading line, e.g. "## Verdict: BLOCK") must be exactly one verdict,
# ignoring markdown emphasis. The unfilled template "<APPROVE | CONCERNS |
# BLOCK>" does not qualify. Headings inside code fences are ignored.
VERDICT=$(awk '
    /^[[:space:]]*(```|~~~)/ { fence = !fence; next }
    fence { next }
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
# heading of level 1-2 or a horizontal rule. Placeholders ("none", "(none)",
# "n/a", "<...>") do not count; anything else, e.g. "None of the tests …?",
# does.
QUESTIONS=$(awk '
    /^[[:space:]]*(```|~~~)/ { fence = !fence; next }
    fence { next }
    /^##?[[:space:]]/ { inq = ($0 ~ /^##?[[:space:]]*Questions for the human/); next }
    /^(---|\*\*\*|___)[[:space:]]*$/ { inq = 0; next }
    !inq { next }
    /^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]+/ {
        c = $0
        sub(/^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]+/, "", c)
        gsub(/[*_`]/, "", c)
        c = tolower(c)
        sub(/^[[:space:]]+/, "", c); sub(/[[:space:].!:]+$/, "", c)
        if (c ~ /^<.*>$/) next
        if (c ~ /^\(none/ || c ~ /^\[none/) next
        sub(/^[[(]/, "", c); sub(/[])]$/, "", c)
        if (c ~ /^(none|n\/a|na|no|nothing|-|—|no questions?( for the human)?|none at this time|no open questions|not applicable)$/) next
        n++
    }
    END { print n + 0 }
' "$RESP")

# --- record -----------------------------------------------------------------

SAVED="$RESP"
if [ "${ARL_LOG:-1}" != "0" ]; then
    LOG_DIR="${ARL_LOG_DIR:-$(git rev-parse --absolute-git-dir)/agent-review}"
    mkdir -p "$LOG_DIR"
    STEM="$LOG_DIR/$(date +%Y%m%dT%H%M%S)-r$ROUND-$TARGET"
    cp "$RESP" "$STEM-response.md"
    printf '%s\n' "$PROMPT" > "$STEM-prompt.md"
    git diff "$BASE_SHA" "$TREE" > "$STEM.diff"
    printf 'target=%s\nround=%s\nbase=%s\nbase_sha=%s\ntree=%s\ntree_after=%s\nverdict=%s\nquestions=%s\n' \
        "$TARGET" "$ROUND" "$BASE" "$BASE_SHA" "$TREE" "$TREE_AFTER" "${VERDICT:-MALFORMED}" "$QUESTIONS" > "$STEM.meta"
    SAVED="$STEM-response.md"
else
    # Keep the response past the cleanup trap so it can be PREV_RESPONSE.
    SAVED=$(mktemp "${TMPDIR:-/tmp}/arl-response.XXXXXX")
    cp "$RESP" "$SAVED"
fi

cat "$RESP"
echo "agent-review: verdict=${VERDICT:-MALFORMED} questions=$QUESTIONS changed=$CHANGED response=$SAVED" >&2

if [ -z "$VERDICT" ]; then
    echo "Warning: no valid verdict in the response — treat it as malformed." >&2
    exit 6
fi
if [ "$QUESTIONS" -gt 0 ]; then exit 30; fi
case "$VERDICT" in
    APPROVE)  exit 0 ;;
    CONCERNS) exit 10 ;;
    BLOCK)    exit 20 ;;
esac
