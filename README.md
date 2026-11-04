# agent-review-loop

A small skill for **Claude Code** and **Codex**: the agent that wrote a change
has the other one review it, fixes or rejects the findings, and repeats —
autonomously. The human is only asked when the reviewer has a question only
a human can answer, or when the loop does not converge.

## How it works

1. The implementer runs `scripts/review.sh auto`.
2. The script snapshots the working tree as a git tree object (tracked
   changes plus untracked, non-ignored files). Nothing has to be committed,
   and the index and files are not touched.
3. It starts the other agent's CLI headless **in the live working directory**.
   The reviewer gets the diff command, the implementer's summary and focus,
   the previous round's review, and the human's answers. It reads whatever
   it needs and may run the test command.
4. The verdict comes back as the exit code; `SKILL.md` tells the implementer
   what to do with each one, including round limits and when to escalate.
   The loop ends at APPROVE (with no changes during the review), even if the
   reviewer still lists suggestions — those are optional — or at a CONCERNS
   round whose findings needed no further changes.
5. Every dispatched run, including CLI failures and timeouts, is recorded in
   a unique directory under `.git/agent-review/`: prompt, diff, response,
   full CLI output (`cli.log` alongside `response.md`), and metadata with
   snapshot hashes, script/CLI exit codes, and elapsed seconds for the CLI.
   The script re-snapshots after every run and warns about changes or an
   unsuccessful check. `changed=yes` or `changed=unknown` requires another
   review of the current tree before the skill can report completion.

| Exit | Meaning |
|------|---------|
| `0` / `10` / `20` | APPROVE / CONCERNS / BLOCK |
| `30` | Reviewer has questions for the human (verdict is in the status line) |
| `6` | Malformed response |
| `7` / `8` | Reviewer timed out / CLI failed |
| `1` / `2` | Usage/snapshot error or nothing to review / CLI missing |

The final stderr line includes `verdict`, `questions`, `changed`, and the
saved `response` path, including on exits 7/8 (`verdict=TIMEOUT` or
`verdict=CLI_FAILED`). Exit codes are unchanged by the change check.
With `ARL_LOG=0`, only the response is retained, including on failed runs.
If saving records fails, the script warns and retains the temporary run
directory instead; the review/CLI exit code is preserved.

## Install

```bash
git clone https://github.com/pgerstbach/agent-review-loop ~/src/agent-review-loop

# Claude Code
mkdir -p ~/.claude/skills && ln -s ~/src/agent-review-loop ~/.claude/skills/agent-review-loop
# Codex
mkdir -p ~/.agents/skills && ln -s ~/src/agent-review-loop ~/.agents/skills/agent-review-loop
```

Start a new session afterwards.

**Both command-line tools must be installed and logged in — the desktop apps
alone are not enough**, they do not put `claude` or `codex` in your PATH:

```bash
brew install --cask codex && codex login && codex login status
curl -fsSL https://claude.ai/install.sh | bash && claude   # log in once
```

`review.sh` exits with 2 and prints this hint if the reviewer CLI is missing.

## Use

Ask your agent for a review by the other agent ("let Codex review this").
The skill does the rest. By hand:

```bash
export SUMMARY="Adds div() with tests" FOCUS="edge cases" TEST_CMD="./test.sh"
~/src/agent-review-loop/scripts/review.sh codex          # uncommitted changes only
~/src/agent-review-loop/scripts/review.sh codex main     # everything since main
```

Put the project's test command into `.agent-review` so every round uses it:

```
test_cmd=npm test
```

To choose the reviewer's model or effort, add arguments to the normal call
instead of replacing it with `ARL_*_CMD` (which drops its restrictions):

```bash
ARL_CODEX_ARGS="-m <model> -c model_reasoning_effort=high"
ARL_CLAUDE_ARGS="--model opus --effort high"
```

They are split on whitespace, without quoting. Do not use them to loosen the
reviewer's restrictions.

All inputs and knobs are listed in the header of `scripts/review.sh`.

## What the reviewer may do

| | Claude reviewer | Codex reviewer |
|---|---|---|
| Read files | in the repo only | anywhere |
| Run commands | only the exact diff commands and the test command | anything, inside the Codex sandbox |
| Write files | no write tools; denied commands fail immediately | in the repo and `/tmp` (sandbox `workspace-write`) |
| Network, MCP | none (`--strict-mcp-config`); the test command itself is not sandboxed | network blocked by the sandbox; user config and MCP ignored |

The test command runs project code. This design assumes you trust both
agents and the project equally — it runs live in your working tree, not in
an isolated copy.

## Limits

- Reviews take minutes. The implementer has to call the script with a long
  tool timeout or in the background.
- A Codex implementer must run the script outside its sandbox, because the
  Claude CLI needs network access.
- Without a test command a Claude reviewer cannot run tests.
- The time limit (`ARL_TIMEOUT`) needs `perl` (present on macOS and nearly
  every Linux). Without it the reviewer runs without a limit, with a warning.
- **Isolated mode is not built.** A review in a separate git worktree would
  protect the working tree but lacks ignored files (`node_modules`, virtual
  envs, build output), so tests would fail without a per-project setup
  step. Add it when a project actually needs it.

## Status

Tested: `tests/run-tests.sh` (fake reviewers), and real loops in a
throwaway repository in both directions:

- Claude Code implementing, **Codex 0.166 reviewing**: two rounds, verdicts
  parsed correctly, `changed=no` was right, and a prompt injection planted
  in the repository was reported by Codex as a finding instead of followed.
- Codex implementing, Claude Code reviewing.

This repository's own changes are also reviewed with the skill.

## Tests

```bash
tests/run-tests.sh     # needs bash and git; uses shellcheck if installed
```

## License

MIT. Parts of `scripts/review.sh` are adapted from
[ai-collab-bridge](https://github.com/owgit/ai-collab-bridge); see `LICENSE`.
