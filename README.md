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
5. Every round is recorded in `.git/agent-review/` (prompt, diff, response,
   metadata incl. snapshot hash). The script re-snapshots after the review
   and warns if the working tree changed during it.

| Exit | Meaning |
|------|---------|
| `0` / `10` / `20` | APPROVE / CONCERNS / BLOCK |
| `30` | Reviewer has questions for the human (verdict is in the status line) |
| `6` | Malformed response |
| `7` / `8` | Reviewer timed out / CLI failed |
| `1` / `2` | Usage error or nothing to review / CLI missing |

## Install

```bash
git clone https://github.com/pgerstbach/agent-review-loop ~/src/agent-review-loop

# Claude Code
mkdir -p ~/.claude/skills && ln -s ~/src/agent-review-loop ~/.claude/skills/agent-review-loop
# Codex
mkdir -p ~/.agents/skills && ln -s ~/src/agent-review-loop ~/.agents/skills/agent-review-loop
```

Start a new session afterwards. Both CLIs must be installed and logged in.
The Codex skill path is taken from the Codex 0.166 binary and not yet
verified end to end; if Codex does not pick the skill up, point it at
`SKILL.md` from your `AGENTS.md`.

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
- **Isolated mode is not built.** A review in a separate git worktree would
  protect the working tree but lacks ignored files (`node_modules`, virtual
  envs, build output), so tests would fail without a per-project setup
  step. Add it when a project actually needs it.

## Status

Tested here: `tests/run-tests.sh` (fake reviewers), and a real round with
Claude Code 2.1.318 as the reviewer. Not tested end to end: a real Codex
review (Codex 0.166 installed, but not logged in in the test environment;
only its sandbox behavior was checked).

## Tests

```bash
tests/run-tests.sh     # needs bash and git; uses shellcheck if installed
```

## License

MIT. Parts of `scripts/review.sh` are adapted from
[ai-collab-bridge](https://github.com/owgit/ai-collab-bridge); see `LICENSE`.
