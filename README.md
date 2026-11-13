# tandem-review

Let **Claude Code** and **Codex** review each other's work. The agent that
made a change asks the other one for a review, fixes what is right, rejects
what is wrong with a reason, and repeats until the review is clean. You are
only asked when the reviewer has a question that needs a human decision, or
when the two agents do not converge.

It is a skill for both CLIs plus one shell script. No server, no
dependencies beyond `bash`, `git` and `perl`.

```
you:     Add integer division to calc.sh, then let Codex review it.
agent:   …implements, runs scripts/review.sh auto…
         tandem-review: verdict=CONCERNS questions=0 changed=no response=…
         …fixes the division-by-zero finding, rejects one suggestion with a
         reason, runs round 2…
         tandem-review: verdict=APPROVE questions=0 changed=no response=…
agent:   Review done: 2 rounds with Codex, final APPROVE. Fixed: … Rejected: …
         Tests: ./test.sh run by the reviewer, passing.
```

<details>
<summary>An actual review response (excerpt)</summary>

```markdown
## Verdict
CONCERNS

## Findings

### Bugs
- `calc.sh:5` — `div 6 0` hits bash's "division by 0" arithmetic error.
  Nothing in `div()` checks for a zero divisor or reports it clearly. […]

### Quality
- `calc.sh:5` — Bash `/` truncates toward zero (`-7 / 2` gives `-3`), which
  is not floor division. […]

## Tests
`./test.sh` → `ALL PASS`

## What I did NOT check
- […]
```

</details>

## Requirements

- macOS or Linux, `bash` ≥ 3.2, `git`, `perl` (for the time limit)
- **Both CLIs installed and logged in.** The desktop apps are not enough;
  they do not put `claude` or `codex` in your PATH:

  ```bash
  curl -fsSL https://claude.ai/install.sh | bash && claude   # log in once
  brew install --cask codex && codex login && codex login status
  ```

- Every review round uses the reviewer's subscription quota or API credits.

## Install

```bash
git clone https://github.com/pgerstbach/tandem-review ~/src/tandem-review

# Claude Code
mkdir -p ~/.claude/skills && ln -s ~/src/tandem-review ~/.claude/skills/tandem-review
# Codex
mkdir -p ~/.agents/skills && ln -s ~/src/tandem-review ~/.agents/skills/tandem-review
```

Start a new session afterwards. To uninstall, remove the two symlinks.

## Use

Ask your agent for a review by the other agent — "let Codex review this",
"have Claude check your changes". The skill (`SKILL.md`) does the rest:
rounds, triage, escalation, and a final summary.

Tell the reviewer how to run your tests, once per project:

```bash
echo 'test_cmd=npm test' > .tandem-review
echo .tandem-review >> .git/info/exclude     # or commit it
```

Without a test command a Claude reviewer cannot run tests at all.

A Codex reviewer can only read the repository and system/tool directories
(see below). If your tests need a toolchain in your home directory, allow
it explicitly:

```
codex_read=~/.nvm
codex_read=~/.pyenv
```

By hand, one round:

```bash
SUMMARY="Adds div() with tests" FOCUS="edge cases" \
  ~/src/tandem-review/scripts/review.sh codex          # uncommitted changes only
SUMMARY="Adds div() with tests" \
  ~/src/tandem-review/scripts/review.sh codex main     # everything since main
```

Nothing has to be committed. The default base `HEAD` reviews exactly the
uncommitted changes.

## Where your code goes — read this first

The reviewer runs **live in your working directory** with the permissions
below, and everything it reads is sent to its vendor's API: Anthropic for a
Claude reviewer, OpenAI for a Codex reviewer. The same is already true for
the agent you work with; the review adds the other vendor.

| | Claude reviewer | Codex reviewer |
|---|---|---|
| Can read | files in the repository, including git-ignored ones such as `.env` | the repository (incl. git-ignored files), system directories, the Codex and Homebrew/`/usr/local` installs, Command Line Tools (macOS), and directories you add with `codex_read` — **not** your home directory, other repositories or shared temp directories |
| Can run | only the exact `git diff` commands and the test command | any command, inside the Codex sandbox |
| Can write | nothing (no write tools); the test command may | the repository and a private temp directory |
| Network | the test command is not sandboxed; the reviewer has no network tools | blocked by the sandbox |
| MCP servers, user config | not loaded (`--strict-mcp-config`, `--restricted`) | not loaded (`--ignore-user-config`) |

Consequences:

- **The test command runs project code** — and comes from `.tandem-review`
  in the working tree, so a change can alter it. That edit shows up in the
  reviewed diff.
- Both reviewers can read secrets inside the repository, such as `.env`.
- The Claude reviewer itself is confined to the repository, but the test
  command it runs is not sandboxed. The Codex reviewer's commands, including
  the test command, run in a Codex permission profile; it was verified with
  `codex exec` on macOS and with the Codex sandbox on Linux.
- This design assumes you trust both agents and the project equally. It does
  not isolate the review from your working tree.

Repository content is treated as data: the reviewer is told not to follow
instructions found in files or diffs and to report them as security
findings. In a test, Codex reported a planted prompt injection instead of
following it. That is a mitigation, not a guarantee.

## How it works

1. `scripts/review.sh` snapshots the working tree — tracked changes plus
   untracked, non-ignored files — as a git tree object through a throwaway
   index. Your index, branches and files are not touched.
2. It starts the other agent's CLI headless in the working directory, with
   the prompt on stdin: review instructions, `git diff <base> <snapshot>`
   as the exact command to run, your summary and focus, the previous
   round's review, and your answers to earlier questions.
3. The response must follow a fixed format. The verdict becomes the exit
   code:

   | Exit | Meaning |
   |------|---------|
   | `0` / `10` / `20` | APPROVE / CONCERNS / BLOCK |
   | `30` | The reviewer has questions for you (any verdict) |
   | `6` | Malformed response (e.g. no verdict, unfilled template) |
   | `7` / `8` | Reviewer timed out / CLI failed |
   | `1` / `2` | Usage or snapshot error, nothing to review / CLI missing |

   The last stderr line is a status, also on exits 7 and 8:
   `tandem-review: verdict=… questions=… changed=… response=<path>`.
4. After the run the script snapshots again and reports `changed=yes` if
   the working tree changed during the review (`unknown` if it could not
   check). A changed tree needs another review before the loop may finish.
5. Every run is recorded in its own directory under `.git/tandem-review/`:
   prompt, diff, response, full CLI output, and metadata (snapshot hashes,
   exit codes, duration). `TANDEM_LOG=0` keeps only the response.
6. On a timeout the reviewer and all its child processes are terminated
   before the script returns.

`SKILL.md` turns the exit codes into the loop: fix or reject each finding,
re-run with the previous response, stop at APPROVE (open suggestions are
optional), stop and ask you on exit 30, retry 6/7/8 once, escalate after
`TANDEM_MAX_ROUNDS` (default 3) or when the agents disagree on the same finding
twice.

## Configuration

All inputs are environment variables; the full list is in the header of
`scripts/review.sh`. The ones you are most likely to set:

| Variable | Default | Purpose |
|---|---|---|
| `TEST_CMD` | `test_cmd=` in `.tandem-review` | Test command the reviewer may run |
| `TANDEM_MAX_ROUNDS` | `3` | Rounds before escalating to you |
| `TANDEM_TIMEOUT` | `1200` | Seconds per review (`0` = no limit) |
| `TANDEM_CLAUDE_ARGS` / `TANDEM_CODEX_ARGS` | — | Extra reviewer arguments, e.g. model and effort |
| `TANDEM_CODEX_READ` | `codex_read=` lines in `.tandem-review` | Extra directories a Codex reviewer may read (colon-separated) |
| `TANDEM_LOG_DIR` / `TANDEM_LOG=0` | `.git/tandem-review` | Where runs are recorded / record only the response |

Reviewer model or effort, added to the normal call:

```bash
TANDEM_CLAUDE_ARGS="--model opus --effort high"
TANDEM_CODEX_ARGS="-m <model> -c model_reasoning_effort=high"
```

They are split on whitespace, without quoting, and placed before the
restrictions, so repeating `--tools` does not override Claude's (the later
value wins). For Codex, sandbox and permission options (`-s`,
`--sandbox`, `sandbox_mode`, `default_permissions`, `--full-auto`,
`--dangerously-…`) are refused with exit 1, because any sandbox mode makes
Codex silently ignore the permission profile. For Claude, options that add
permissions (`--allowedTools`, `--dangerously-skip-permissions`) still
loosen the restrictions: whoever sets these variables is responsible for
what they pass. `TANDEM_CLAUDE_CMD` / `TANDEM_CODEX_CMD` replace
the call entirely and drop all restrictions; they exist for wrappers and
tests.

## Limits

- A review takes minutes. The implementing agent has to call the script with
  a long tool timeout or in the background; the skill tells it to.
- A Codex reviewer can only write to the repository and its private temp
  directory. Tools that ignore `TMPDIR` and write to fixed per-user caches
  can fail there. The clang/Swift module cache is redirected
  (`CLANG_MODULE_CACHE_PATH`) and rebuilt each round, so Swift builds are
  slower; warnings about the SwiftPM or `xcrun` caches are harmless. If
  another tool fails this way, please open an issue.
- **Swift on macOS: a Codex reviewer cannot run `swift test`.** Tested on a
  real project: with the module cache redirected and SwiftPM's own sandbox
  off (`--disable-sandbox`; macOS does not nest sandboxes), the build still
  fails with an I/O error in its own build directory — most likely because
  Foundation writes through the per-user temp directory
  (`/var/folders/…/T/TemporaryItems`), which the profile denies. That
  directory is shared by all your apps' in-progress saves, so it stays
  denied. Other toolchains that write to fixed per-user directories can hit
  the same wall.
- If a project's tests cannot run under the Codex sandbox, either leave its
  test command unset for Codex reviews (the reviewer then reads the code and
  says it did not run tests; the implementer runs them and reports the
  result in `SUMMARY`), or use the Claude reviewer (`review.sh claude`),
  whose test command runs outside any sandbox but may only be that one
  command. If Claude is also the implementer, that is a self-review.
  There is deliberately no switch to run the Codex reviewer unsandboxed: the
  agent calls the script, so it could set such a switch just as well as you,
  and an unsandboxed Codex reviewer can read your home directory again.
- A Codex implementer must run the script outside its own sandbox, because
  the Claude CLI needs network access. Codex asks you for that permission.
- Without `perl` there is no time limit (the script warns).
- Self-review (same model on both sides) works, with a warning, but loses
  the point of a second model.
- **No isolated mode.** A review in a separate git worktree would protect the
  working tree, but it lacks ignored files (`node_modules`, virtual envs,
  build output), so tests would fail without a per-project setup step.

## Status

Tested with Claude Code 2.1.318 and Codex 0.166 on macOS and Linux:

- `tests/run-tests.sh` with fake reviewer CLIs (exit codes, parsing,
  snapshots, recording, timeouts incl. child processes).
- Real loops in a throwaway repository in both directions. Claude
  implementing, Codex reviewing: two rounds, Codex reported a planted prompt
  injection instead of following it. Codex implementing, Claude reviewing:
  round 1 BLOCK with three real bugs the passing tests missed, round 2
  APPROVE; Codex found the skill on its own.
- This repository's own changes are reviewed with the skill.

The CLIs change quickly. If a reviewer call breaks after an update, run the
script by hand and check `cli.log` in the recorded run.

**Experimental: Mistral Vibe.** Support for
[Mistral Vibe](https://docs.mistral.ai/vibe/code/cli/install-setup) as a
third agent (reviewer and implementer), plus an interactive installer, is on
the [`vibe-reviewer`](https://github.com/pgerstbach/tandem-review/tree/vibe-reviewer)
branch and not yet in `main`. To try it, run `git switch vibe-reviewer` in
your clone; its README describes the limits of the Vibe reviewer.

## Development

```bash
tests/run-tests.sh     # bash and git; uses shellcheck if installed
```

Contributor notes are in `AGENTS.md` (also read by Claude Code through
`CLAUDE.md`). CI runs the tests on Ubuntu and macOS.

## License

MIT, see `LICENSE`. Parts of `scripts/review.sh` are adapted from
[ai-collab-bridge](https://github.com/owgit/ai-collab-bridge).
