---
name: tandem-review
description: Have the other coding agent (Claude Code or Codex) review your current changes and iterate on its findings autonomously, only involving the human for real decisions or when the loop does not converge. Use when the user asks for a "tandem review" (e.g. "make a tandem review", "tandem-review this"), a review by Claude/Codex, a second opinion from another agent, "let the other agent check this", a cross-agent or peer review, or before declaring a non-trivial change done when the user has asked for agent reviews.
---

# Tandem review

You are the **implementer**. You made a change; another agent reviews it live
in this repository, can read any file and run the configured test command.
You fix what is right, reject what is wrong with a reason, and repeat until
the review is clean — without bothering the human unless it is needed.

Nothing has to be committed. The script reviews the working tree as it is.

## Running one round

```bash
SUMMARY="What changed and why, 1-3 sentences" \
FOCUS="What the reviewer should look at" \
<skill-dir>/scripts/review.sh auto [base-ref]
```

- `auto` picks the other agent (Claude → Codex, Codex → Claude). Name
  `claude` or `codex` to choose; reviewing with your own model works but
  says so in a warning, and you must tell the human.
- `base-ref` defaults to `HEAD` = only uncommitted changes. Use `main` (or the
  branch point) when the change spans commits.
- Test command: `TEST_CMD="npm test"`, or a `test_cmd=npm test` line in
  `.tandem-review` at the repo root. Without one, a Claude reviewer cannot run
  tests at all, so set it whenever the project has tests.
- Re-review rounds pass `PREV_RESPONSE=<path>`: the `response=` path of the
  most recent round with a valid verdict (exit 0/10/20/30), unchanged when
  retrying 6/7/8. The script refuses a recorded response without one. The
  round number follows from it; set `ROUND=<n>` only with `TANDEM_LOG=0`.
  After the human answered questions, add
  `HUMAN_ANSWERS="<their answers, verbatim>"`.
- A Codex reviewer cannot read your home directory. If its tests fail for a
  missing toolchain (e.g. `node`/`python` not found), ask the human whether
  to add the directory as a `codex_read=<dir>` line in `.tandem-review` (or
  `TANDEM_CODEX_READ`); do not add it on your own.
- Model or effort: `TANDEM_CLAUDE_ARGS` / `TANDEM_CODEX_ARGS` (e.g. `--model
  opus`), only when the human asked for it, never to loosen restrictions.

**A review takes minutes.** Run the command with a long tool timeout (≥ 20
min) or in the background and wait for it. Do not edit files while it runs —
the reviewer reads the live working tree.

**Codex as implementer:** the script calls the Claude CLI, which needs
network access. Run it outside the sandbox (request escalated permissions
for this command).

The review is printed on stdout (empty on exits 7/8). The last stderr line
is the status:

```
tandem-review: verdict=CONCERNS questions=0 changed=no response=<path>
```

Every dispatched run is recorded; next to `response=` are `cli.log`,
`prompt.md`, `review.diff` and `meta` (with `TANDEM_LOG=0` only the response). On exits 7/8 the status says
`verdict=TIMEOUT` / `CLI_FAILED`, and any partial response is not a verdict.

## What to do with the result

| Exit | Meaning | Action |
|------|---------|--------|
| `0` | APPROVE | Done if `changed=no` — even with open suggestions, they are optional. Otherwise see "Changes during a run". |
| `10` | CONCERNS | Triage every finding (below). If you changed code or `changed` is not `no`, run the next round; otherwise you are done. |
| `20` | BLOCK | Fix the blocking findings, triage the rest, run the next round. |
| `30` | Questions for the human | **Stop the loop.** Pass the questions to the human verbatim, wait for the answer, then run the next round with `HUMAN_ANSWERS`. The verdict is in the status line; handle its findings in the same round. |
| `6` | Malformed response | Retry the same round once. If it fails again, report to the human. |
| `7`, `8` | Timeout / CLI failed | Read `cli.log`. Retry once only if the cause is plausibly transient (or the time limit too short); otherwise report the error and its path to the human. |
| `1`, `2` | Usage / setup error | Fix the call (wrong base, nothing to review, bad `PREV_RESPONSE`); do not count it as a round. For a missing CLI, pass the script's install hint to the human. |

**Not logged in** (expired/revoked token, invalid OAuth grant): stop and
ask the human to log in to that CLI, with the error and its path. Do not
retry before they have.

**Changes during a run** (`changed=yes`, also after 7/8): the files changed,
but not necessarily by the reviewer. Undo only changes you can confidently
attribute to the reviewer and tell the human; keep the rest. Then review the
current tree again. `changed=unknown`: fix the snapshot error and repeat.
Neither allows a clean final summary, and such rounds still count.

### Triage

For each finding decide:

- **Fix** — it is right. When an automated regression test is appropriate,
  add it and confirm that it reproduces the finding before fixing the code;
  then make the fix and rerun the relevant checks.
- **Reject** — it is wrong or not worth it. Write down one sentence why. Put
  the rejection and its reason into `SUMMARY` of the next round, so the
  reviewer can weigh it instead of repeating itself.

Do not fix things you were not asked to fix just to make the reviewer happy,
and do not reject a correct finding because the fix is inconvenient.

## Limits — when to stop and ask the human

Count the rounds: calls that returned a verdict (exits 0/10/20/30); retries
and setup errors do not count. The round number is also in every recorded
`meta` under `.git/tandem-review/`.

Escalate to the human — stop and give a short list of the open points with
both positions — when:

1. you reach the round limit, `TANDEM_MAX_ROUNDS` (default **3**), without an
   APPROVE with `changed=no` or a CONCERNS round with `changed=no` that
   needed no further changes, or
2. you and the reviewer disagree on the same finding twice: you rejected it
   with a reason, and the reviewer raised it again in two later rounds.

## Final summary for the human

When the loop ends, for whatever reason, tell the human briefly:

- reviewer, rounds, final verdict (and if it was a self-review)
- what was fixed, one line per finding
- what was deliberately rejected, with the reason
- open points or escalations, if any
- whether the reviewer ran the tests, and the result

## Files

| File | Purpose |
|------|---------|
| `scripts/review.sh` | Runs one review round. Options and exit codes in its header. |
| `templates/request.md` | Instructions sent to the reviewer. |
| `templates/response.md` | Response format the reviewer must use. |
| `tests/run-tests.sh` | Tests with fake reviewer CLIs. |
